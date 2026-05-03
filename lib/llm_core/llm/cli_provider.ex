defmodule LlmCore.LLM.CLIProvider.Config do
  @moduledoc """
  Configuration for a CLI-based LLM provider.

  Pure data — loaded from TOML or constructed in code. This is what
  makes `CLIProvider` universal: a new CLI client is just a config entry,
  no Elixir code needed.

  ## Fields

    * `name` — atom identifying this provider (e.g. `:claude_code`, `:droid`)
    * `binary` — executable name (must be in PATH)
    * `subcommand` — optional subcommand prepended to args (e.g. `"exec"` for droid)
    * `provider_type` — always `:cli`
    * `default_timeout` — timeout in ms (default: 1_800_000 = 30 min)
    * `default_model` — model string returned in responses when no model specified
    * `flags` — map of opt key → CLI flag (e.g. `%{model: "--model", auto: "--auto"}`)
    * `prompt_position` — `:last` (default) or `:flagged` (e.g. claude uses `-p`)
    * `prompt_flag` — flag before the prompt when `prompt_position == :flagged` (e.g. `-p`)
    * `prefix_args` — args always prepended (e.g. `["--print"]` for claude)
    * `stdin_hack` — wrap with `/bin/sh -c 'exec "$0" "$@" < /dev/null'` (claude needs this)
    * `install_hint` — shown in not_installed error message
    * `prompt_transport` — optional semantic prompt transport (`:last`, `:flagged`, `:stdin`)
    * `system_prompt_transport` — optional semantic system prompt strategy
    * `cwd_flag` — optional explicit cwd flag for capability introspection
    * `add_dir_flag` — optional explicit add-dir flag for capability introspection
    * `output_mode` — optional output mode (`:stdout_text`, `:final_message_only`, `:json`)
    * `non_interactive_args` — optional args enabling non-interactive execution
    * `auto_approve_args` — optional args enabling unattended execution
    * `sandbox_bypass_args` — optional args for stronger sandbox/approval bypass
    * `preflight` — optional declarative preflight configuration
  """

  @type t :: %__MODULE__{
          name: atom(),
          binary: String.t(),
          subcommand: String.t() | nil,
          provider_type: :cli,
          default_timeout: pos_integer(),
          default_model: String.t(),
          flags: %{atom() => String.t()},
          prompt_position: :last | :flagged,
          prompt_flag: String.t() | nil,
          prefix_args: [String.t()],
          stdin_hack: boolean(),
          install_hint: String.t() | nil,
          prompt_transport: :last | :flagged | :stdin | nil,
          system_prompt_transport: :flag | :file_flag | :inline_fallback | :unsupported | nil,
          cwd_flag: String.t() | nil,
          add_dir_flag: String.t() | nil,
          output_mode: :stdout_text | :final_message_only | :json | nil,
          non_interactive_args: [String.t()],
          auto_approve_args: [String.t()],
          sandbox_bypass_args: [String.t()],
          preflight: map()
        }

  @enforce_keys [:name, :binary]
  defstruct [
    :name,
    :binary,
    :subcommand,
    :prompt_flag,
    :install_hint,
    :prompt_transport,
    :system_prompt_transport,
    :cwd_flag,
    :add_dir_flag,
    :output_mode,
    provider_type: :cli,
    default_timeout: 1_800_000,
    default_model: "cli-default",
    flags: %{},
    prompt_position: :last,
    prefix_args: [],
    stdin_hack: false,
    non_interactive_args: [],
    auto_approve_args: [],
    sandbox_bypass_args: [],
    preflight: %{}
  ]
end

defmodule LlmCore.LLM.CLIProvider do
  @moduledoc """
  Universal CLI-based LLM provider.

  One module, any CLI. Configuration is pure data — loaded from TOML
  or constructed in code. New CLI clients are added without writing
  Elixir code.

  ## Default Providers

  The following CLI providers ship as `type = "cli"` entries in
  `priv/config/llm_core.toml`. Override or remove them via project
  or global TOML overrides — no Elixir changes needed.

  | Name | Binary | Notes |
  |---|---|---|
  | `:claude_code` | `claude` | Wraps with `/bin/sh` for stdin redirect |
  | `:droid` | `droid` | Subcommand `exec`, rich flag set |
  | `:pi_cli` | `pi` | Pi CLI non-interactive dispatch (`--print`) |
  | `:kimi_cli` | `kimi-cli` | Kimi CLI with agent-file support |
  | `:codex_cli` | `codex` | OpenAI Codex CLI |
  | `:gemini_cli` | `gemini` | Google Gemini CLI |

  ## Usage

      {:ok, provider} = CLIProvider.from_config(:claude_code)

      # Check availability
      CLIProvider.available?(provider)
      #=> true

      # Send a prompt
      {:ok, response} = CLIProvider.send(provider, "Explain this code")

      # Stream
      {:ok, stream} = CLIProvider.stream(provider, "Write a story")

  ## Custom Provider (no code needed)

      config = %CLIProvider.Config{
        name: :my_tool,
        binary: "my-tool",
        default_timeout: 60_000,
        default_model: "v2",
        flags: %{model: "--model", temperature: "--temp"}
      }
      provider = CLIProvider.from_config(config)
      {:ok, response} = CLIProvider.send(provider, "hello", model: "v2")
  """

  alias LlmCore.LLM.{Response, Error}
  alias LlmCore.LLM.CLIProvider.Config

  # CLIProvider is a struct-based provider, not a module-conformant one.
  # Its `available?/1`, `capabilities/1`, `provider_type/1`, `send/3`, and
  # `stream/3` take the struct as the first argument, so it does not
  # implement the module-style `LlmCore.LLM.Provider` behaviour. Callers
  # invoke it through `LlmCore.LLM.Provider.dispatch/3`, which pattern-matches
  # on `%CLIProvider{}` and routes to these functions.

  # ── Built-in Configs ───────────────────────────────────────
  #
  # Historically, CLI provider configs were hard-coded here. They now
  # live in `priv/config/llm_core.toml` as `type = "cli"` provider
  # entries, loaded at runtime via Config.Loader. This map is kept
  # empty as a fallback merge target — all provider definitions are
  # config-driven, so new CLIs can be added, removed, or updated
  # without touching Elixir source.

  @builtins %{}

  defstruct [:config]

  @type t :: %__MODULE__{config: Config.t()}

  # ── Config Access ─────────────────────────────────────────

  @doc """
  Returns the config for a provider name.

  Resolution order:
  1. Runtime store (TOML-loaded CLI configs)
  2. Built-in `@builtins`
  3. Error
  """
  @spec config(atom()) :: {:ok, Config.t()} | {:error, String.t()}
  def config(name) when is_atom(name) do
    case fetch_runtime_config(name) do
      {:ok, cfg} ->
        {:ok, cfg}

      :error ->
        case Map.fetch(@builtins, name) do
          {:ok, cfg} -> {:ok, cfg}
          :error -> {:error, "Unknown CLI provider: #{name}"}
        end
    end
  end

  @doc "Creates a CLIProvider from a built-in name, a string id/alias, or a Config struct."
  @spec from_config(atom() | String.t() | Config.t()) :: t()
  def from_config(name) when is_atom(name) do
    case config(name) do
      {:ok, cfg} -> %__MODULE__{config: cfg}
      {:error, _} -> %__MODULE__{config: %Config{name: name, binary: Atom.to_string(name)}}
    end
  end

  def from_config(name) when is_binary(name) do
    from_config(safe_to_existing_atom(name))
  end

  def from_config(%Config{} = cfg), do: %__MODULE__{config: cfg}

  @doc """
  Returns the legacy built-in map (empty since all defaults moved to TOML).
  Use `list_all_configs/0` to get all known CLI provider configs.
  """
  @spec builtins() :: %{atom() => Config.t()}
  def builtins, do: @builtins

  @doc """
  Returns all known CLI provider configs — runtime (TOML) merged with builtins.
  Runtime configs override builtins with the same name.
  """
  @spec list_all_configs() :: %{atom() => Config.t()}
  def list_all_configs do
    runtime = runtime_cli_configs()
    Map.merge(@builtins, runtime)
  end

  @doc """
  Resolves an alias or id string to the canonical provider name atom.
  Checks runtime definitions first (via Provider.Registry aliases), then builtins.
  """
  @spec resolve_id(atom() | String.t()) :: {:ok, atom()} | {:error, :not_found}
  def resolve_id(name) when is_atom(name) do
    all = list_all_configs()
    if Map.has_key?(all, name), do: {:ok, name}, else: {:error, :not_found}
  end

  def resolve_id(name) when is_binary(name) do
    atom_name = safe_to_existing_atom(name)
    all = list_all_configs()

    cond do
      Map.has_key?(all, atom_name) ->
        {:ok, atom_name}

      true ->
        # Check provider definitions for alias match
        case find_cli_by_alias(name) do
          {:ok, id_atom} -> {:ok, id_atom}
          :error -> {:error, :not_found}
        end
    end
  end

  @doc """
  Fetches a CLI config by id or alias. Returns a ready-to-use `%CLIProvider.Config{}`.
  """
  @spec fetch_config(atom() | String.t()) :: {:ok, Config.t()} | {:error, :not_found}
  def fetch_config(name) when is_atom(name) do
    case config(name) do
      {:ok, cfg} -> {:ok, cfg}
      {:error, _} -> {:error, :not_found}
    end
  end

  def fetch_config(name) when is_binary(name) do
    case resolve_id(name) do
      {:ok, id} -> fetch_config(id)
      error -> error
    end
  end

  @doc """
  Builds a ready-to-use `%CLIProvider{}` struct from an id or alias.
  """
  @spec build_provider(atom() | String.t()) :: {:ok, t()} | {:error, :not_found}
  def build_provider(name) do
    case fetch_config(name) do
      {:ok, cfg} -> {:ok, %__MODULE__{config: cfg}}
      error -> error
    end
  end

  # ── Private: Runtime Store Access ─────────────────────────

  defp fetch_runtime_config(name) when is_atom(name) do
    case runtime_cli_configs() do
      configs when is_map(configs) -> Map.fetch(configs, name)
      _ -> :error
    end
  end

  defp runtime_cli_configs do
    case LlmCore.Config.Store.fetch(:config, :cli_providers) do
      {:ok, configs} when is_map(configs) -> configs
      _ -> %{}
    end
  rescue
    # Store may not be started yet (e.g. during compilation or early boot)
    ArgumentError -> %{}
  end

  defp find_cli_by_alias(alias_str) do
    alias_down = String.downcase(alias_str)

    # Check provider definitions for CLI providers with matching alias
    case LlmCore.Config.Store.fetch(:config, :providers) do
      {:ok, providers} ->
        providers
        |> Enum.find(fn {_id, def} ->
          def.provider_kind == :cli and alias_down in (def.aliases || [])
        end)
        |> case do
          {_id, def} -> {:ok, def.cli_config.name}
          nil -> :error
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> String.to_atom(str)
    end
  end

  # ── Provider API (struct-based; see Provider.dispatch/3) ─

  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{config: %Config{binary: bin}}) do
    System.find_executable(bin) != nil
  end

  @spec capabilities(t()) :: map()
  def capabilities(%__MODULE__{config: cfg}) do
    %{
      streaming: true,
      passthrough: true,
      dispatch_mode: ["non_interactive"],
      prompting: %{
        system_prompt: has_flag?(cfg, :system_prompt),
        system_prompt_file: has_flag?(cfg, :system_prompt_file),
        inline_fallback: effective_system_prompt_transport(cfg) == :inline_fallback
      },
      workspace: %{
        cwd: has_flag?(cfg, :cwd) or is_binary(cfg.cwd_flag),
        add_dir: has_flag?(cfg, :add_dir) or is_binary(cfg.add_dir_flag)
      },
      automation: %{
        auto_approve: cfg.auto_approve_args != [],
        sandbox_bypass: cfg.sandbox_bypass_args != []
      },
      output: %{mode: effective_output_mode(cfg)},
      persona: %{
        native_file: has_flag?(cfg, :system_prompt_file),
        inline_fallback: effective_system_prompt_transport(cfg) == :inline_fallback
      },
      detached_stdin: cfg.stdin_hack
    }
  end

  @doc "Returns whether the provider supports a semantic capability."
  @spec supports?(t(), atom()) :: boolean()
  def supports?(provider, capability) do
    caps = capabilities(provider)

    case capability do
      :cwd -> get_in(caps, [:workspace, :cwd]) == true
      :add_dir -> get_in(caps, [:workspace, :add_dir]) == true
      :system_prompt -> get_in(caps, [:prompting, :system_prompt]) == true
      :system_prompt_file -> get_in(caps, [:prompting, :system_prompt_file]) == true
      :inline_fallback -> get_in(caps, [:prompting, :inline_fallback]) == true
      :auto_approve -> get_in(caps, [:automation, :auto_approve]) == true
      :sandbox_bypass -> get_in(caps, [:automation, :sandbox_bypass]) == true
      :detached_stdin -> Map.get(caps, :detached_stdin) == true
      _ -> false
    end
  end

  @spec provider_type(t()) :: :cli
  def provider_type(%__MODULE__{}), do: :cli

  @spec send(t(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def send(provider, prompt, opts \\ []) do
    if not available?(provider) do
      {:error, build_error(provider, :not_installed, opts)}
    else
      execute(provider, prompt, opts)
    end
  end

  @spec stream(t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(provider, prompt, opts \\ []) do
    if not available?(provider) do
      {:error, build_error(provider, :not_installed, opts)}
    else
      create_stream(provider, prompt, opts)
    end
  end

  @doc """
  Returns a normalized invocation plan describing how the provider will run.
  """
  @spec invocation_plan(t(), String.t(), keyword()) :: map()
  def invocation_plan(%__MODULE__{config: cfg} = provider, prompt, opts \\ []) do
    {rendered_prompt, rendered_opts, render_meta} =
      prepare_prompt_and_opts(provider, prompt, opts)

    cli_args = do_build_args(cfg, rendered_prompt, rendered_opts)
    {executable, invocation_args} = build_invocation_from_args(cfg, cli_args)

    %{
      executable: executable,
      args: invocation_args,
      prompt: rendered_prompt,
      prompt_transport: effective_prompt_transport(cfg),
      system_prompt_transport: render_meta.system_prompt_transport,
      persona_strategy: render_meta.persona_strategy,
      output_mode: effective_output_mode(cfg),
      stdin_detached: cfg.stdin_hack
    }
  end

  @doc """
  Renders a prompt after applying any declared inline system-prompt fallback.
  """
  @spec render_prompt(t(), String.t(), keyword()) :: String.t()
  def render_prompt(provider, prompt, opts \\ []) do
    {rendered_prompt, _opts, _meta} = prepare_prompt_and_opts(provider, prompt, opts)
    rendered_prompt
  end

  @doc """
  Runs declarative checks proving the CLI surface matches the configured contract.
  """
  @spec preflight(t()) :: {:ok, map()} | {:error, map()}
  def preflight(%__MODULE__{config: cfg} = provider) do
    if not available?(provider) do
      {:error, %{reason: :not_installed, binary: cfg.binary}}
    else
      executable = System.find_executable(cfg.binary) || cfg.binary
      checks = []

      with {:ok, checks} <- maybe_run_help_check(executable, cfg, checks),
           {:ok, checks} <- maybe_run_version_check(executable, cfg, checks) do
        {:ok,
         %{binary: executable, checks: Enum.reverse(checks), capabilities: capabilities(provider)}}
      end
    end
  end

  # ── Arg Building (public for testing) ─────────────────────

  @doc "Builds the CLI argument list from prompt and opts."
  @spec build_args(t(), String.t(), keyword()) :: [String.t()]
  def build_args(%__MODULE__{config: cfg} = provider, prompt, opts) do
    {rendered_prompt, rendered_opts, _meta} = prepare_prompt_and_opts(provider, prompt, opts)
    do_build_args(cfg, rendered_prompt, rendered_opts)
  end

  defp do_build_args(cfg, prompt, opts) do
    args = []
    # Subcommand (e.g. "exec" for droid)
    args = if cfg.subcommand, do: args ++ [cfg.subcommand], else: args

    # Prefix args (e.g. ["--print"] for claude)
    args = args ++ cfg.prefix_args

    args =
      maybe_append_profile_args(
        args,
        cfg.non_interactive_args,
        Keyword.get(opts, :non_interactive)
      )

    args =
      maybe_append_profile_args(args, cfg.auto_approve_args, Keyword.get(opts, :auto_approve))

    args =
      maybe_append_profile_args(args, cfg.sandbox_bypass_args, Keyword.get(opts, :sandbox_bypass))

    # Prompt (placed before mapped flags for :flagged, after for :last)
    args =
      case effective_prompt_transport(cfg) do
        :flagged ->
          args ++ [cfg.prompt_flag, prompt]

        :last ->
          args

        :stdin ->
          args
      end

    # Flag-mapped opts
    args =
      Enum.reduce(cfg.flags, args, fn {opt_key, flag}, acc ->
        case Keyword.get(opts, opt_key) do
          nil -> acc
          true -> acc ++ [flag]
          false -> acc
          value -> acc ++ [flag, to_string(value)]
        end
      end)

    # Prompt at end for :last position
    args =
      case effective_prompt_transport(cfg) do
        :last -> args ++ [prompt]
        :flagged -> args
        :stdin -> args
      end

    args
  end

  # ── Invocation (public for testing) ───────────────────────

  @doc "Returns {executable, args} for the CLI invocation."
  @spec build_invocation(t(), String.t(), keyword()) :: {String.t(), [String.t()]}
  def build_invocation(%__MODULE__{config: cfg} = provider, prompt, opts) do
    {rendered_prompt, rendered_opts, _meta} = prepare_prompt_and_opts(provider, prompt, opts)
    cli_args = do_build_args(cfg, rendered_prompt, rendered_opts)
    build_invocation_from_args(cfg, cli_args)
  end

  # ── Response/Error Building (public for testing) ──────────

  @doc "Builds a Response struct from CLI output."
  @spec build_response(t(), String.t(), keyword()) :: Response.t()
  def build_response(%__MODULE__{config: cfg}, output, opts) do
    Response.new(
      content: String.trim(output),
      provider: cfg.name,
      model: Keyword.get(opts, :model, cfg.default_model),
      raw: %{output: output},
      metadata: %{executed_at: DateTime.utc_now()}
    )
  end

  @doc "Builds an Error struct for common failure modes."
  @spec build_error(t(), atom() | {:exit_code, non_neg_integer()}, keyword()) :: Error.t()
  def build_error(%__MODULE__{config: cfg}, :not_installed, _opts) do
    msg =
      if cfg.install_hint do
        "#{String.capitalize(to_string(cfg.binary))} CLI not available. #{cfg.install_hint}"
      else
        "#{String.capitalize(to_string(cfg.binary))} CLI not available"
      end

    Error.new(:provider_error,
      message: msg,
      provider: cfg.name,
      details: %{reason: :not_installed}
    )
  end

  def build_error(%__MODULE__{config: cfg}, :timeout, opts) do
    timeout = Keyword.get(opts, :timeout, cfg.default_timeout)

    Error.new(:timeout,
      message: "#{String.capitalize(to_string(cfg.binary))} CLI timed out after #{timeout}ms",
      provider: cfg.name,
      details: %{timeout: timeout}
    )
  end

  def build_error(%__MODULE__{config: cfg}, {:exit_code, code}, opts) do
    output = Keyword.get(opts, :output, "")

    Error.new(:provider_error,
      message: "#{String.capitalize(to_string(cfg.binary))} CLI exited with code #{code}",
      provider: cfg.name,
      details: %{exit_code: code, output: output}
    )
  end

  def build_error(%__MODULE__{config: cfg}, {:exec_error, err}, _opts) do
    Error.new(:provider_error,
      message: "#{String.capitalize(to_string(cfg.binary))} CLI execution error: #{inspect(err)}",
      provider: cfg.name,
      details: %{error: inspect(err)}
    )
  end

  # ── Private: Execution ────────────────────────────────────

  defp execute(%__MODULE__{config: cfg} = provider, prompt, opts) do
    timeout = Keyword.get(opts, :timeout, cfg.default_timeout)
    {executable, args} = build_invocation(provider, prompt, opts)
    execution_id = Keyword.get(opts, :execution_id)

    case run_port(executable, args, timeout, execution_id) do
      {:ok, output, 0} ->
        {:ok, build_response(provider, IO.iodata_to_binary(output), opts)}

      {:ok, output, exit_code} ->
        {:error,
         build_error(provider, {:exit_code, exit_code}, output: IO.iodata_to_binary(output))}

      {:error, :timeout} ->
        {:error, build_error(provider, :timeout, opts)}

      {:error, :not_found} ->
        {:error, build_error(provider, :not_installed, opts)}

      {:error, err} ->
        {:error, build_error(provider, {:exec_error, err}, opts)}
    end
  end

  defp create_stream(%__MODULE__{config: cfg} = provider, prompt, opts) do
    timeout = Keyword.get(opts, :timeout, cfg.default_timeout)
    {executable, args} = build_invocation(provider, prompt, opts)
    execution_id = Keyword.get(opts, :execution_id)

    case stream_port(executable, args, timeout, execution_id) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, :not_found} ->
        {:error, build_error(provider, :not_installed, opts)}

      {:error, err} ->
        {:error, build_error(provider, {:exec_error, err}, opts)}
    end
  end

  defp build_invocation_from_args(cfg, cli_args) do
    if cfg.stdin_hack do
      binary_path = System.find_executable(cfg.binary) || cfg.binary
      {"/bin/sh", ["-c", ~s|exec "$0" "$@" < /dev/null|, binary_path | cli_args]}
    else
      {cfg.binary, cli_args}
    end
  end

  defp prepare_prompt_and_opts(%__MODULE__{config: cfg}, prompt, opts) do
    system_prompt_text = system_prompt_text(opts)
    transport = effective_system_prompt_transport(cfg)

    cond do
      transport == :inline_fallback and is_binary(system_prompt_text) and system_prompt_text != "" ->
        {
          inline_system_prompt(system_prompt_text, prompt),
          opts |> Keyword.delete(:system_prompt) |> Keyword.delete(:system_prompt_file),
          %{system_prompt_transport: :inline_fallback, persona_strategy: :inline_fallback}
        }

      has_flag?(cfg, :system_prompt_file) and Keyword.has_key?(opts, :system_prompt_file) ->
        {prompt, opts, %{system_prompt_transport: :file_flag, persona_strategy: :native_file}}

      has_flag?(cfg, :system_prompt) and Keyword.has_key?(opts, :system_prompt) ->
        {prompt, opts, %{system_prompt_transport: :flag, persona_strategy: :native_text}}

      true ->
        {prompt, opts, %{system_prompt_transport: transport, persona_strategy: :none}}
    end
  end

  defp system_prompt_text(opts) do
    cond do
      is_binary(opts[:system_prompt]) and opts[:system_prompt] != "" ->
        opts[:system_prompt]

      is_binary(opts[:system_prompt_file]) and opts[:system_prompt_file] != "" ->
        case File.read(opts[:system_prompt_file]) do
          {:ok, contents} -> contents
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp inline_system_prompt(system_prompt, prompt) do
    String.trim("""
    System instructions:
    #{String.trim(system_prompt)}

    User request:
    #{prompt}
    """)
  end

  defp effective_prompt_transport(%Config{prompt_transport: transport})
       when transport in [:last, :flagged, :stdin],
       do: transport

  defp effective_prompt_transport(%Config{prompt_position: position}), do: position

  defp effective_system_prompt_transport(%Config{system_prompt_transport: transport})
       when transport in [:flag, :file_flag, :inline_fallback, :unsupported],
       do: transport

  defp effective_system_prompt_transport(%Config{} = cfg) do
    cond do
      has_flag?(cfg, :system_prompt_file) -> :file_flag
      has_flag?(cfg, :system_prompt) -> :flag
      true -> :unsupported
    end
  end

  defp effective_output_mode(%Config{output_mode: mode})
       when mode in [:stdout_text, :final_message_only, :json],
       do: mode

  defp effective_output_mode(%Config{}), do: :stdout_text

  defp has_flag?(%Config{flags: flags}, key), do: is_binary(Map.get(flags, key))

  defp maybe_append_profile_args(args, profile_args, true) when is_list(profile_args),
    do: args ++ profile_args

  defp maybe_append_profile_args(args, _profile_args, _enabled), do: args

  defp maybe_run_help_check(executable, %Config{preflight: %{help_args: help_args}} = cfg, checks)
       when is_list(help_args) do
    expect = Map.get(cfg.preflight, :expect_in_help, Map.get(cfg.preflight, "expect_in_help", []))

    case System.cmd(executable, help_args, stderr_to_stdout: true) do
      {output, 0} ->
        missing = Enum.reject(expect, &String.contains?(output, &1))

        if missing == [] do
          {:ok, [%{check: :help, ok: true, args: help_args} | checks]}
        else
          {:error,
           %{reason: :preflight_failed, failed_check: :help, missing: missing, output: output}}
        end

      {output, status} ->
        {:error,
         %{reason: :preflight_failed, failed_check: :help, exit_status: status, output: output}}
    end
  rescue
    error ->
      {:error,
       %{reason: :preflight_failed, failed_check: :help, details: Exception.message(error)}}
  end

  defp maybe_run_help_check(_executable, _cfg, checks), do: {:ok, checks}

  defp maybe_run_version_check(
         executable,
         %Config{preflight: %{version_args: version_args}},
         checks
       )
       when is_list(version_args) do
    case System.cmd(executable, version_args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, [%{check: :version, ok: true, args: version_args} | checks]}

      {output, status} ->
        {:error,
         %{reason: :preflight_failed, failed_check: :version, exit_status: status, output: output}}
    end
  rescue
    error ->
      {:error,
       %{reason: :preflight_failed, failed_check: :version, details: Exception.message(error)}}
  end

  defp maybe_run_version_check(_executable, _cfg, checks), do: {:ok, checks}

  # ── Port Helpers ──────────────────────────────────────────
  #
  # Direct Port-based execution (replaces dependency on DevMan.LLM.CLIPort).
  # This makes CLIProvider self-contained in llm_core.

  defp run_port(executable, args, timeout, _execution_id) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        try do
          collect_output(port, timeout, [])
        after
          safe_close(port)
        end
    end
  rescue
    e -> {:error, e}
  end

  defp stream_port(executable, args, timeout, _execution_id) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 1024},
            args: args
          ])

        stream =
          Stream.resource(
            fn -> {port, timeout} end,
            &stream_next/1,
            fn
              nil -> :ok
              {port, _} -> safe_close(port)
            end
          )

        {:ok, stream}
    end
  rescue
    e -> {:error, e}
  end

  defp collect_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp stream_next({port, timeout}) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {[line <> "\n"], {port, timeout}}

      {^port, {:data, {:noeol, line}}} ->
        {[line], {port, timeout}}

      {^port, {:exit_status, _status}} ->
        {:halt, {port, timeout}}
    after
      timeout ->
        safe_close(port)
        {:halt, {port, timeout}}
    end
  end

  defp safe_close(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
