defmodule LlmCore.Config.Loader do
  @moduledoc """
  Loads llm_core configuration files (routing, providers, etc.) from disk and updates the store.

  Handles the full TOML loading pipeline: reading multiple config layers, deep-merging,
  resolving environment variable placeholders, normalizing provider definitions, and
  broadcasting change notifications to dependent processes.

  ## Configuration Layers (later overrides earlier)

  1. **Compiled defaults** — `priv/config/llm_core.toml` (bundled with the library)
  2. **Global override** — `~/.llm_core/config/llm_core.toml`
  3. **Project override** — `<project>/.llm_core/llm_core.toml`
  4. **Environment variable** — path in `LLM_CORE_CONFIG`
  5. **Custom path** — explicit `:path` option

  ## Environment Variable Interpolation

  TOML values like `"${ANTHROPIC_API_KEY}"` are resolved at load time.
  Supports defaults: `"${OLLAMA_URL:http://localhost:11434}"`.

  ## Key Functions

    * `reload_providers/1` — Full TOML load + provider normalization + store update
    * `reload_routing/1` — Load and apply routing rules only
    * `load_config/1` — Read merged TOML without mutating runtime state
  """

  require Logger

  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Memory.Hindsight.Supervisor, as: MemorySupervisor
  alias LlmCore.Paths
  alias LlmCore.LLM.CLIProvider
  alias LlmCore.Provider.Definition
  alias LlmCore.Router.RoutingTable
  alias LlmCore.Telemetry.Settings, as: TelemetrySettings

  @config_filename "llm_core.toml"

  @doc """
  Loads the routing configuration from disk without mutating the store.
  """
  @spec load_routing(keyword()) :: {:ok, RoutingTable.t()} | {:error, term()}
  def load_routing(opts \\ []) do
    path = Keyword.get(opts, :path, default_routing_path())

    with {:ok, yaml} <- read_yaml(path),
         {:ok, table} <- build_routing_table(yaml) do
      {:ok, table}
    end
  end

  @doc """
  Loads the routing configuration and writes it to the runtime store.
  Broadcasts change notifications so dependent processes can refresh.

  When `routing.yml` is missing, the existing Store routing is preserved
  (e.g. a table already installed from TOML via `reload_providers/1`). Only
  when the Store has no routing at all does the safe `default => claude`
  fallback get installed.
  """
  @spec reload_routing(keyword()) :: {:ok, RoutingTable.t()} | {:error, term()}
  def reload_routing(opts \\ []) do
    case load_routing(opts) do
      {:ok, table} ->
        :ok = Store.put_routing(table)
        dispatch_reload(:routing)
        {:ok, table}

      {:error, :not_found} ->
        case Store.get_routing() do
          {:ok, existing} ->
            # Preserve routing already installed (e.g. from TOML via reload_providers).
            # Overwriting here would clobber consumer-defined [routing.tasks.*] rules.
            {:ok, existing}

          {:error, :not_found} ->
            table = RoutingTable.new(%{"default" => "claude"})
            :ok = Store.put_routing(table)
            dispatch_reload(:routing)
            {:ok, table}
        end

      error ->
        error
    end
  end

  @doc """
  Loads TOML configuration (providers, memory, routing defaults) and writes
  the normalized provider metadata to the runtime store.
  """
  @spec reload_providers(keyword()) ::
          {:ok, %{optional(String.t()) => Definition.t()}} | {:error, term()}
  def reload_providers(opts \\ []) do
    with {:ok, config} <- load_config(opts),
         {:ok, providers} <- build_providers(config),
         :ok <- apply_memory_config(config) do
      :ok = Store.put(:config, :raw, config)
      :ok = Store.put(:config, :providers, providers)
      store_cli_configs(providers)
      dispatch_reload(:providers)
      sync_registry()
      apply_config_sections(config)
      {:ok, providers}
    end
  end

  defp build_routing_table(nil) do
    {:ok, RoutingTable.new(%{"default" => "claude"})}
  end

  defp build_routing_table(%{} = yaml) do
    {:ok, RoutingTable.new(yaml)}
  rescue
    error -> {:error, {:invalid_routing, error}}
  end

  defp read_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, yaml} -> {:ok, yaml || %{}}
        {:error, reason} -> {:error, {:yaml_error, reason}}
      end
    else
      Logger.debug("Routing config not found at #{path}")
      {:error, :not_found}
    end
  end

  defp dispatch_reload(topic) do
    :telemetry.execute(
      [
        :llm_core,
        :config,
        :reloaded
      ],
      %{count: 1},
      %{config: topic}
    )

    send(LlmCore.Router, {:config_reloaded, topic})
  end

  defp default_routing_path do
    Path.join(LlmCore.Paths.project_config_dir(), "routing.yml")
  end

  @doc """
  Returns the merged TOML configuration without mutating runtime state.
  """
  @spec load_config(keyword()) :: {:ok, map()}
  def load_config(opts \\ []) do
    config =
      opts
      |> config_paths()
      |> Enum.reduce(%{}, fn path, acc ->
        case read_toml(path) do
          {:ok, map} ->
            deep_merge(acc, map)

          {:error, :not_found} ->
            acc

          {:error, reason} ->
            Logger.warning("Failed to read #{path}: #{inspect(reason)}")
            acc
        end
      end)
      |> resolve_env_placeholders()

    {:ok, config}
  end

  defp build_providers(config) when is_map(config) do
    providers =
      config
      |> Map.get("providers", %{})
      |> Enum.reduce(%{}, fn {id, attrs}, acc ->
        case normalize_provider(id, attrs) do
          {:ok, provider} ->
            Map.put(acc, id, provider)

          {:error, reason} ->
            Logger.warning("Skipping provider #{id}: #{inspect(reason)}")
            acc
        end
      end)

    {:ok, providers}
  end

  defp apply_config_sections(config) do
    config
    |> apply_routing_config()
    |> apply_telemetry_config()
  end

  defp config_paths(opts) do
    custom = Keyword.get(opts, :path)
    env_path = System.get_env("LLM_CORE_CONFIG")
    project = Path.join(Paths.project_config_dir(), @config_filename)
    global = Path.join(Paths.global_config_dir(), @config_filename)
    default = default_config_path()

    [default, global, project, env_path, custom]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp default_config_path do
    # Resolve via :code.priv_dir so the bundled defaults are found in the
    # build artifact (`_build/<env>/lib/llm_core/priv/config/llm_core.toml`).
    # Mix always copies `priv/` into the build dir, unlike top-level `config/`
    # which is build-tool-only.
    case :code.priv_dir(:llm_core) do
      {:error, _} -> nil
      priv -> Path.join([priv, "config", @config_filename])
    end
  end

  defp read_toml(nil), do: {:error, :not_found}

  defp read_toml(path) do
    if File.exists?(path) do
      case Toml.decode_file(path) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp normalize_provider(id, %{"type" => "cli"} = attrs) when is_binary(id) do
    normalize_cli_provider(id, attrs)
  end

  defp normalize_provider(id, attrs) when is_binary(id) and is_map(attrs) do
    with {:ok, mod} <- resolve_module(Map.get(attrs, "module")),
         {:ok, type} <- resolve_type(Map.get(attrs, "type")) do
      enabled = Map.get(attrs, "enabled", true)
      aliases = normalize_aliases(Map.get(attrs, "aliases", []), id)
      agent = Map.get(attrs, "agent", %{})
      agent_name = Map.get(agent, "name") || List.first(aliases) || id
      agent_config = Map.get(agent, "config", %{}) |> normalize_agent_config()
      default_model = Map.get(attrs, "default_model")

      agent_config =
        if default_model && not Map.has_key?(agent_config, :model) &&
             not Map.has_key?(agent_config, "model") do
          Map.put(agent_config, :model, default_model)
        else
          agent_config
        end

      capabilities =
        attrs
        |> Map.get("capabilities", %{})
        |> normalize_capabilities()
        |> merge_capabilities(mod)

      options = Map.merge(Map.get(attrs, "options", %{}), Map.get(attrs, "config", %{}))
      metadata = normalize_metadata(attrs)
      auth_defined? = Map.has_key?(attrs, "auth")

      auth =
        normalize_auth(Map.get(attrs, "auth", %{}), %{
          id: id,
          aliases: aliases,
          defined?: auth_defined?
        })

      {available?, availability} = evaluate_availability(enabled, mod, auth)

      provider = %Definition{
        id: id,
        module: mod,
        provider_kind: :module,
        type: type,
        enabled: enabled,
        aliases: aliases,
        default_agent: agent_name,
        default_model: default_model,
        agent_config: agent_config,
        options: options,
        capabilities: capabilities,
        auth: auth,
        metadata: metadata,
        available?: available?,
        availability: availability
      }

      {:ok, provider}
    end
  end

  defp normalize_provider(_, _), do: {:error, :invalid_provider}

  # ── CLI Provider Normalization ────────────────────────────

  defp normalize_cli_provider(id, attrs) do
    cli_attrs = Map.get(attrs, "cli", %{})

    case build_cli_config(id, cli_attrs) do
      {:ok, cli_config} ->
        enabled = Map.get(attrs, "enabled", true)
        aliases = normalize_aliases(Map.get(attrs, "aliases", []), id)
        agent = Map.get(attrs, "agent", %{})
        agent_name = Map.get(agent, "name") || List.first(aliases) || id
        default_model = blank_to_nil(Map.get(attrs, "default_model") || cli_config.default_model)
        model_resolution = resolve_cli_model_resolution(attrs, cli_config)
        metadata = normalize_metadata(attrs)

        capabilities =
          attrs
          |> Map.get("capabilities", %{})
          |> normalize_capabilities()

        {available?, availability} = evaluate_cli_availability(enabled, cli_config)

        provider = %Definition{
          id: id,
          module: nil,
          provider_kind: :cli,
          type: :cli,
          enabled: enabled,
          aliases: aliases,
          default_agent: agent_name,
          default_model: default_model,
          model_resolution: model_resolution,
          agent_config: %{},
          options: %{},
          capabilities: capabilities,
          auth: %{},
          metadata: metadata,
          cli_config: cli_config,
          available?: available?,
          availability: availability
        }

        {:ok, provider}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @valid_prompt_positions ~w(last flagged)
  @valid_prompt_transports ~w(last flagged stdin)
  @valid_system_prompt_transports ~w(flag file_flag inline_fallback unsupported)
  @valid_output_modes ~w(stdout_text final_message_only json)
  @valid_output_event_formats ~w(jsonl)
  @valid_file_transforms ~w(agent_spec_yaml)
  @valid_tool_call_transports ~w(llm_core_json)
  @valid_model_resolutions ~w(gc_default provider_runtime explicit_only)

  defp build_cli_config(id, attrs) when is_map(attrs) do
    binary = Map.get(attrs, "binary")

    cond do
      not is_binary(binary) or binary == "" ->
        {:error, {:cli_missing_binary, id}}

      true ->
        with :ok <- validate_cli_enums(id, attrs),
             :ok <- validate_cli_consistency(id, attrs) do
          name = safe_to_atom(id)

          config = %CLIProvider.Config{
            name: name,
            binary: binary,
            subcommand: blank_to_nil(Map.get(attrs, "subcommand")),
            default_timeout: Map.get(attrs, "default_timeout", 1_800_000),
            default_model: blank_to_nil(Map.get(attrs, "default_model")),
            model_resolution: resolve_model_resolution(attrs),
            flags: normalize_cli_flags(Map.get(attrs, "flags", %{})),
            prompt_position: safe_to_atom(Map.get(attrs, "prompt_position", "last")),
            prompt_flag: blank_to_nil(Map.get(attrs, "prompt_flag")),
            prefix_args: List.wrap(Map.get(attrs, "prefix_args", [])),
            stdin_hack: Map.get(attrs, "stdin_hack", false) == true,
            install_hint: blank_to_nil(Map.get(attrs, "install_hint")),
            prompt_transport: safe_to_atom_or_nil(Map.get(attrs, "prompt_transport")),
            system_prompt_transport:
              safe_to_atom_or_nil(Map.get(attrs, "system_prompt_transport")),
            cwd_flag: blank_to_nil(Map.get(attrs, "cwd_flag")),
            add_dir_flag: blank_to_nil(Map.get(attrs, "add_dir_flag")),
            output_mode: safe_to_atom_or_nil(Map.get(attrs, "output_mode")),
            output_event_format: safe_to_atom_or_nil(Map.get(attrs, "output_event_format")),
            output_event_select:
              normalize_output_event_select(Map.get(attrs, "output_event_select", %{})),
            output_event_text_path:
              normalize_output_event_text_path(Map.get(attrs, "output_event_text_path", [])),
            non_interactive_args: List.wrap(Map.get(attrs, "non_interactive_args", [])),
            auto_approve_args: List.wrap(Map.get(attrs, "auto_approve_args", [])),
            sandbox_bypass_args: List.wrap(Map.get(attrs, "sandbox_bypass_args", [])),
            preflight: normalize_cli_preflight(Map.get(attrs, "preflight", %{})),
            system_prompt_file_transform:
              safe_to_atom_or_nil(Map.get(attrs, "system_prompt_file_transform")),
            file_transform_defaults:
              normalize_file_transform_defaults(Map.get(attrs, "file_transform_defaults", %{})),
            output_file_flag: blank_to_nil(Map.get(attrs, "output_file_flag")),
            output_strip_patterns: List.wrap(Map.get(attrs, "output_strip_patterns", [])),
            tool_call_transport: safe_to_atom_or_nil(Map.get(attrs, "tool_call_transport"))
          }

          {:ok, config}
        end
    end
  end

  defp build_cli_config(id, _), do: {:error, {:cli_missing_config, id}}

  defp validate_cli_enums(id, attrs) do
    checks = [
      {"prompt_position", Map.get(attrs, "prompt_position"), @valid_prompt_positions},
      {"prompt_transport", Map.get(attrs, "prompt_transport"), @valid_prompt_transports},
      {"system_prompt_transport", Map.get(attrs, "system_prompt_transport"),
       @valid_system_prompt_transports},
      {"output_mode", Map.get(attrs, "output_mode"), @valid_output_modes},
      {"output_event_format", Map.get(attrs, "output_event_format"), @valid_output_event_formats},
      {"tool_call_transport", Map.get(attrs, "tool_call_transport"), @valid_tool_call_transports},
      {"model_resolution", Map.get(attrs, "model_resolution"), @valid_model_resolutions},
      {"system_prompt_file_transform", Map.get(attrs, "system_prompt_file_transform"),
       @valid_file_transforms}
    ]

    Enum.reduce_while(checks, :ok, fn {field, value, valid}, :ok ->
      cond do
        is_nil(value) -> {:cont, :ok}
        value in valid -> {:cont, :ok}
        true -> {:halt, {:error, {:cli_invalid_enum, id, field, value, valid}}}
      end
    end)
  end

  defp validate_cli_consistency(id, attrs) do
    prompt_position = Map.get(attrs, "prompt_position", "last")
    prompt_flag = Map.get(attrs, "prompt_flag")

    cond do
      prompt_position == "flagged" and (is_nil(prompt_flag) or prompt_flag == "") ->
        {:error, {:cli_consistency, id, "prompt_position=flagged requires prompt_flag"}}

      invalid_cli_default_model?(id, attrs) ->
        {:error,
         {:cli_consistency, id,
          "default_model must be a real model id, not a provider/binary placeholder"}}

      true ->
        :ok
    end
  end

  defp resolve_cli_model_resolution(attrs, %CLIProvider.Config{} = cli_config) do
    Map.get(attrs, "model_resolution") || cli_config.model_resolution
  end

  defp resolve_model_resolution(attrs) do
    case blank_to_nil(Map.get(attrs, "model_resolution")) do
      nil ->
        if blank_to_nil(Map.get(attrs, "default_model")), do: :gc_default, else: :provider_runtime

      "provider_runtime" ->
        if blank_to_nil(Map.get(attrs, "default_model")), do: :gc_default, else: :provider_runtime

      value ->
        safe_to_atom(value)
    end
  end

  defp invalid_cli_default_model?(id, attrs) do
    default_model = blank_to_nil(Map.get(attrs, "default_model"))
    binary = blank_to_nil(Map.get(attrs, "binary"))
    aliases = normalize_aliases(Map.get(attrs, "aliases", []), id)

    case default_model do
      nil ->
        false

      value ->
        normalized = String.downcase(value)

        normalized == String.downcase(id) or
          normalized == String.downcase(Path.basename(binary || "")) or
          normalized in Enum.map(aliases, &String.downcase/1) or
          String.ends_with?(normalized, "-cli")
    end
  end

  defp normalize_cli_flags(flags) when is_map(flags) do
    Map.new(flags, fn {k, v} -> {safe_to_atom(k), to_string(v)} end)
  end

  defp normalize_cli_flags(_), do: %{}

  defp normalize_cli_preflight(preflight) when is_map(preflight) do
    %{}
    |> maybe_put_list(:help_args, Map.get(preflight, "help_args"))
    |> maybe_put_list(:expect_in_help, Map.get(preflight, "expect_in_help"))
    |> maybe_put_list(:version_args, Map.get(preflight, "version_args"))
  end

  defp normalize_cli_preflight(_), do: %{}

  defp normalize_file_transform_defaults(defaults) when is_map(defaults) do
    Map.new(defaults, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_file_transform_defaults(_), do: %{}

  defp normalize_output_event_select(select) when is_map(select) do
    Map.new(select, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_output_event_select(_), do: %{}

  defp normalize_output_event_text_path(path) when is_list(path) do
    Enum.map(path, &to_string/1)
  end

  defp normalize_output_event_text_path(_), do: []

  defp maybe_put_list(map, _key, nil), do: map
  defp maybe_put_list(map, key, list) when is_list(list), do: Map.put(map, key, list)
  defp maybe_put_list(map, _key, _), do: map

  defp evaluate_cli_availability(false, _cli_config), do: {false, {:error, :disabled}}

  defp evaluate_cli_availability(true, %CLIProvider.Config{binary: binary}) do
    if System.find_executable(binary) do
      {true, :ok}
    else
      {false, {:error, :binary_not_found}}
    end
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> String.to_atom(value)
    end
  end

  defp safe_to_atom_or_nil(nil), do: nil
  defp safe_to_atom_or_nil(""), do: nil
  defp safe_to_atom_or_nil(value), do: safe_to_atom(value)

  defp resolve_module(nil), do: {:error, :missing_module}

  defp resolve_module(name) when is_binary(name) do
    module =
      name
      |> String.split(".")
      |> Module.concat()

    {:ok, module}
  rescue
    _ -> {:error, {:invalid_module, name}}
  end

  defp resolve_module(module) when is_atom(module), do: {:ok, module}

  defp resolve_type(nil), do: {:ok, :api}

  defp resolve_type(type) when is_binary(type) do
    try do
      {:ok, String.to_existing_atom(type)}
    rescue
      ArgumentError -> {:ok, String.to_atom(type)}
    end
  end

  defp resolve_type(type) when is_atom(type), do: {:ok, type}

  defp normalize_aliases(list, fallback) when is_list(list) do
    list
    |> Enum.map(&normalize_alias/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [fallback]
      aliases -> aliases
    end
  end

  defp normalize_aliases(_, fallback), do: [fallback]

  defp normalize_alias(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      <<>> -> nil
      alias -> alias
    end
  end

  defp normalize_alias(_), do: nil

  defp normalize_agent_config(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end

        {atom_key, value}

      other ->
        other
    end)
  end

  defp normalize_agent_config(value), do: value || %{}

  @capability_key_map %{
    "streaming" => :streaming,
    "structured_output" => :structured_output,
    "tool_use" => :tool_use,
    "vision" => :vision,
    "reasoning" => :reasoning,
    "attachment" => :attachment,
    "attachments" => :attachments,
    "temperature" => :temperature,
    "models" => :models,
    "max_context" => :max_context
  }

  defp normalize_capabilities(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        normalized = Map.get(@capability_key_map, String.downcase(key))

        atom_key =
          cond do
            normalized ->
              normalized

            true ->
              try do
                String.to_existing_atom(key)
              rescue
                ArgumentError -> key
              end
          end

        {atom_key, value}

      other ->
        other
    end)
  end

  defp normalize_capabilities(value), do: value || %{}

  defp normalize_metadata(attrs) do
    base = Map.get(attrs, "metadata", %{})
    cost = Map.get(attrs, "cost_tier") || get_in(attrs, ["options", "cost_tier"])

    base
    |> Map.put_new("cost_tier", cost)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp merge_capabilities(overrides, module) do
    base =
      if function_exported?(module, :capabilities, 0) do
        module.capabilities()
      else
        %{}
      end

    deep_merge(base, overrides)
  end

  defp normalize_auth(auth, context) when is_map(auth) do
    defined = Map.get(context, :defined?, true)
    inline = auth |> Map.get("api_key") |> blank_to_nil()
    env = auth |> Map.get("api_key_env") |> blank_to_nil()
    discover_envs = discover_env_candidates(auth, context)
    first_candidate = List.first(discover_envs)

    {api_key_env, source, present?} =
      cond do
        inline ->
          {env || first_candidate, :inline, true}

        env && env_present?(env) ->
          {env, {:env, env}, true}

        env ->
          {env, {:missing_env, env}, false}

        discovered = Enum.find(discover_envs, &env_present?/1) ->
          {discovered, {:discovered_env, discovered}, true}

        discover_envs != [] and defined ->
          candidate = hd(discover_envs)
          {candidate, {:missing_env, candidate}, false}

        true ->
          {nil, :none, not defined}
      end

    auth
    |> Map.put("api_key_env", api_key_env)
    |> Map.put("api_key_present", present?)
    |> Map.put("source", source)
    |> Map.put("discover_env", discover_envs)
    |> Map.delete("api_key")
  end

  defp normalize_auth(_, _), do: %{}

  defp evaluate_availability(false, _module, _auth), do: {false, {:error, :disabled}}

  defp evaluate_availability(true, module, auth) do
    cond do
      not Code.ensure_loaded?(module) ->
        {false, {:error, :module_not_loaded}}

      not provider_behaviour?(module) ->
        {false, {:error, :invalid_provider}}

      auth["api_key_present"] == false ->
        {false, {:error, :missing_credentials}}

      function_exported?(module, :available?, 1) ->
        # Provider implements available?/1 — pass resolved auth so it checks
        # the TOML-configured env var, not a hardcoded default.
        case module.available?(auth) do
          true -> {true, :ok}
          false -> {false, {:error, :provider_unavailable}}
        end

      function_exported?(module, :available?, 0) ->
        # Provider only implements available?/0 — call as-is.
        case module.available?() do
          true -> {true, :ok}
          false -> {false, {:error, :provider_unavailable}}
        end

      true ->
        {true, :ok}
    end
  end

  defp provider_behaviour?(module) do
    function_exported?(module, :send, 2) &&
      function_exported?(module, :stream, 2) &&
      function_exported?(module, :capabilities, 0)
  end

  defp deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, val1, val2 -> deep_merge(val1, val2) end)
  end

  defp deep_merge(_val1, val2), do: val2

  defp resolve_env_placeholders(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, resolve_env_placeholders(v)} end)
  end

  defp resolve_env_placeholders(value) when is_list(value) do
    Enum.map(value, &resolve_env_placeholders/1)
  end

  defp resolve_env_placeholders(value) when is_binary(value) do
    replace_env(value)
  end

  defp resolve_env_placeholders(value), do: value

  @env_regex ~r/^\$\{([A-Z0-9_]+)(?::([^}]+))?\}$/

  defp replace_env(value) do
    case Regex.run(@env_regex, value) do
      [_, var, default] -> System.get_env(var) || default
      [_, var] -> System.get_env(var)
      _ -> interpolate_env(value)
    end
  end

  defp interpolate_env(value) do
    Regex.replace(~r/\$\{([A-Z0-9_]+)(?::([^}]+))?\}/, value, fn _, var, default ->
      System.get_env(var) || default || ""
    end)
    |> case do
      <<>> -> nil
      other -> other
    end
  end

  defp store_cli_configs(providers) do
    cli_configs =
      providers
      |> Enum.filter(fn {_id, def} -> def.provider_kind == :cli and def.cli_config != nil end)
      |> Map.new(fn {_id, def} -> {def.cli_config.name, def.cli_config} end)

    :ok = Store.put(:config, :cli_providers, cli_configs)
  end

  defp sync_registry do
    if Process.whereis(LlmCore.Agent.Registry) do
      Registry.sync_with_providers()
    end
  end

  defp apply_routing_config(config) do
    case Map.get(config, "routing") do
      routing when is_map(routing) ->
        case routing_from_toml(routing) do
          {:ok, table} ->
            :ok = Store.put_routing(table)
            dispatch_reload(:routing)
            config

          {:error, reason} ->
            Logger.warning("Invalid routing config in TOML: #{inspect(reason)}")
            config
        end

      _ ->
        config
    end
  end

  defp routing_from_toml(%{} = routing) do
    tasks = Map.get(routing, "tasks", %{})

    map =
      tasks
      |> Enum.reduce(%{"default" => Map.get(routing, "default")}, fn {task, value}, acc ->
        Map.put(acc, task, normalize_route_value(value))
      end)

    {:ok, RoutingTable.new(map)}
  rescue
    error -> {:error, error}
  end

  defp normalize_route_value(value) when is_binary(value), do: value

  defp normalize_route_value(%{"alias" => alias} = map) do
    %{
      "alias" => alias,
      "mode" => Map.get(map, "mode"),
      "capabilities" => Map.get(map, "capabilities")
    }
  end

  defp normalize_route_value(%{alias: alias} = map) do
    %{
      "alias" => alias,
      "mode" => Map.get(map, :mode),
      "capabilities" => Map.get(map, :capabilities)
    }
  end

  defp normalize_route_value(value), do: value

  defp apply_memory_config(config) do
    memory =
      case Map.get(config, "memory", %{}) do
        value when is_map(value) -> value
        _value -> %{}
      end

    with :ok <- MemoryConfig.set_runtime_override(memory) do
      backend_options =
        case MemoryConfig.backend() do
          backend when backend in [:hindsight_rest, :foresight_http] ->
            MemoryConfig.backend_options(backend)

          :foresight_inprocess ->
            %{enabled: false}
        end

      with :ok <- HindsightConfig.set_runtime_override(backend_options) do
        MemorySupervisor.refresh()
      end
    end
  end

  defp apply_telemetry_config(config) do
    telemetry = Map.get(config, "telemetry", %{})
    :ok = Store.put(:config, :telemetry, telemetry)
    TelemetrySettings.apply(telemetry)
    config
  end

  defp discover_env_candidates(auth, %{id: id, aliases: aliases}) do
    configured =
      auth
      |> Map.get("discover_env", [])
      |> List.wrap()
      |> Enum.map(&String.upcase/1)

    alias_envs =
      aliases
      |> List.wrap()
      |> Enum.map(fn alias -> "LLM_CORE_" <> String.upcase(alias) <> "_API_KEY" end)

    provider_env = String.upcase(id) <> "_API_KEY"

    (configured ++ alias_envs ++ [provider_env])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp env_present?(nil), do: false
  defp env_present?(env), do: System.get_env(env) not in [nil, ""]

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp blank_to_nil(value), do: value
end
