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
          install_hint: String.t() | nil
        }

  @enforce_keys [:name, :binary]
  defstruct [
    :name,
    :binary,
    :subcommand,
    :prompt_flag,
    :install_hint,
    provider_type: :cli,
    default_timeout: 1_800_000,
    default_model: "cli-default",
    flags: %{},
    prompt_position: :last,
    prefix_args: [],
    stdin_hack: false
  ]
end

defmodule LlmCore.LLM.CLIProvider do
  @moduledoc """
  Universal CLI-based LLM provider.

  One module, any CLI. Configuration is pure data — loaded from TOML
  or constructed in code. New CLI clients are added without writing
  Elixir code.

  ## Built-in Providers

  | Name | Binary | Notes |
  |---|---|---|
  | `:claude_code` | `claude` | Wraps with `/bin/sh` for stdin redirect |
  | `:droid` | `droid` | Subcommand `exec`, rich flag set |
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

  @builtins %{
    claude_code: %Config{
      name: :claude_code,
      binary: "claude",
      default_timeout: 1_800_000,
      default_model: "claude-code-cli",
      flags: %{model: "--model"},
      prompt_position: :flagged,
      prompt_flag: "-p",
      prefix_args: ["--print"],
      stdin_hack: true,
      install_hint: "Install with: npm install -g @anthropic/claude-code"
    },
    droid: %Config{
      name: :droid,
      binary: "droid",
      subcommand: "exec",
      default_timeout: 1_800_000,
      default_model: "claude-opus-4-6",
      flags: %{
        model: "--model",
        auto: "--auto",
        cwd: "--cwd",
        worktree: "--worktree",
        system_prompt: "--append-system-prompt",
        system_prompt_file: "--append-system-prompt-file",
        enabled_tools: "--enabled-tools",
        disabled_tools: "--disabled-tools"
      },
      prompt_position: :last,
      stdin_hack: false,
      install_hint: "Install with: curl -fsSL https://app.factory.ai/cli | sh"
    },
    codex_cli: %Config{
      name: :codex_cli,
      binary: "codex",
      default_timeout: 1_800_000,
      default_model: "codex-cli",
      flags: %{model: "--model"},
      prompt_position: :last,
      stdin_hack: false,
      install_hint: "Install with: npm install -g @openai/codex"
    },
    gemini_cli: %Config{
      name: :gemini_cli,
      binary: "gemini",
      default_timeout: 1_800_000,
      default_model: "gemini-cli",
      flags: %{model: "--model"},
      prompt_position: :last,
      stdin_hack: false,
      install_hint: "Install the Google Cloud CLI with Gemini support"
    }
  }

  defstruct [:config]

  @type t :: %__MODULE__{config: Config.t()}

  # ── Config Access ─────────────────────────────────────────

  @doc "Returns the built-in config for a known provider name."
  @spec config(atom()) :: {:ok, Config.t()} | {:error, String.t()}
  def config(name) when is_atom(name) do
    case Map.fetch(@builtins, name) do
      {:ok, cfg} -> {:ok, cfg}
      :error -> {:error, "Unknown CLI provider: #{name}"}
    end
  end

  @doc "Creates a CLIProvider from a built-in name or a Config struct."
  @spec from_config(atom() | Config.t()) :: t()
  def from_config(name) when is_atom(name) do
    case config(name) do
      {:ok, cfg} -> %__MODULE__{config: cfg}
      {:error, _} -> %__MODULE__{config: %Config{name: name, binary: Atom.to_string(name)}}
    end
  end

  def from_config(%Config{} = cfg), do: %__MODULE__{config: cfg}

  # ── Provider API (struct-based; see Provider.dispatch/3) ─

  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{config: %Config{binary: bin}}) do
    System.find_executable(bin) != nil
  end

  @spec capabilities(t()) :: map()
  def capabilities(%__MODULE__{}) do
    %{streaming: true, passthrough: true}
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

  # ── Arg Building (public for testing) ─────────────────────

  @doc "Builds the CLI argument list from prompt and opts."
  @spec build_args(t(), String.t(), keyword()) :: [String.t()]
  def build_args(%__MODULE__{config: cfg}, prompt, opts) do
    args = []

    # Subcommand (e.g. "exec" for droid)
    args = if cfg.subcommand, do: args ++ [cfg.subcommand], else: args

    # Prefix args (e.g. ["--print"] for claude)
    args = args ++ cfg.prefix_args

    # Prompt (placed before mapped flags for :flagged, after for :last)
    args =
      case cfg.prompt_position do
        :flagged ->
          args ++ [cfg.prompt_flag, prompt]

        :last ->
          args
      end

    # Flag-mapped opts
    args =
      Enum.reduce(cfg.flags, args, fn {opt_key, flag}, acc ->
        case Keyword.get(opts, opt_key) do
          nil -> acc
          value -> acc ++ [flag, to_string(value)]
        end
      end)

    # Prompt at end for :last position
    args =
      case cfg.prompt_position do
        :last -> args ++ [prompt]
        :flagged -> args
      end

    args
  end

  # ── Invocation (public for testing) ───────────────────────

  @doc "Returns {executable, args} for the CLI invocation."
  @spec build_invocation(t(), String.t(), keyword()) :: {String.t(), [String.t()]}
  def build_invocation(%__MODULE__{config: cfg} = provider, prompt, opts) do
    cli_args = build_args(provider, prompt, opts)

    if cfg.stdin_hack do
      binary_path = System.find_executable(cfg.binary) || cfg.binary
      {"/bin/sh", ["-c", ~s|exec "$0" "$@" < /dev/null|, binary_path | cli_args]}
    else
      {cfg.binary, cli_args}
    end
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
        {:error, build_error(provider, {:exit_code, exit_code}, output: IO.iodata_to_binary(output))}

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
