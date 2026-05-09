defmodule LlmCore.Agent.Registry do
  @moduledoc """
  GenServer for runtime agent management and discovery.

  The Registry maintains a map of registered agents, each identified by a
  human-friendly name (alias) and associated with an LLM provider module.

  ## Features

  - Register agents with unique names, provider modules, and configuration
  - Lookup agents by alias
  - List all registered agents
  - Update agent configuration
  - Auto-discover available providers on startup

  ## State Structure

  The GenServer state is a map containing:

      %{
        agents: %{
          "steve" => %Agent{name: "steve", provider: LlmCore.LLM.CLIProvider, ...},
          "gemini" => %Agent{name: "gemini", provider: LlmCore.LLM.CLIProvider, ...},
          "codex" => %Agent{name: "codex", provider: LlmCore.LLM.CLIProvider, ...}
        }
      }

  ## Usage

      # Start the registry (usually via supervision tree)
      {:ok, pid} = Registry.start_link(name: LlmCore.Agent.Registry)

      # Register an agent
      :ok = Registry.register("steve", LlmCore.LLM.CLIProvider, %{model: "claude-3-opus"})

      # Lookup an agent
      {:ok, agent} = Registry.get("steve")

      # List all agents
      agents = Registry.list()

  ## Pattern Reference

  Follows VaultWise `Chat.Agent` schema pattern for agent management,
  adapted for in-memory GenServer storage rather than database persistence.
  """

  use GenServer

  alias LlmCore.Agent
  alias LlmCore.Provider.Definition
  alias LlmCore.Provider.Registry, as: ProviderRegistry

  alias MapSet
  alias LlmCore.Provider.Registry, as: ProviderRegistry
  alias LlmCore.Provider.Definition

  @default_name __MODULE__

  @fallback_providers [
    {"claude", LlmCore.LLM.CLIProvider},
    {"gemini", LlmCore.LLM.CLIProvider},
    {"codex", LlmCore.LLM.CLIProvider},
    {"droid", LlmCore.LLM.CLIProvider},
    {"openai", LlmCore.LLM.OpenAI},
    {"zai", LlmCore.LLM.Zai}
  ]

  ## Client API

  @doc """
  Starts the Registry GenServer.

  ## Options

    * `:name` - The name to register the GenServer under (default: `LlmCore.Agent.Registry`)
    * `:auto_discover` - Whether to auto-discover providers on startup (default: true)

  ## Examples

      {:ok, pid} = Registry.start_link(name: MyApp.Registry)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    auto_discover = Keyword.get(opts, :auto_discover, true)
    GenServer.start_link(__MODULE__, %{auto_discover: auto_discover}, name: name)
  end

  @doc """
  Registers an agent with the given name, provider module, and configuration.

  ## Parameters

    * `server` - The Registry GenServer (default: `LlmCore.Agent.Registry`)
    * `name` - Human-friendly alias for the agent
    * `provider` - Module implementing `LlmCore.LLM.Provider` behaviour
    * `config` - Provider-specific configuration map

  ## Returns

    * `:ok` - Successfully registered
    * `{:error, :already_registered}` - Name already taken
    * `{:error, :invalid_name}` - Invalid name format

  ## Examples

      :ok = Registry.register("steve", LlmCore.LLM.CLIProvider, %{model: "claude-3-opus"})
  """
  @spec register(GenServer.server(), String.t(), module(), map()) ::
          :ok | {:error, :already_registered | :invalid_name}
  def register(server \\ @default_name, name, provider, config) do
    GenServer.call(server, {:register, name, provider, config})
  end

  @doc """
  Unregisters an agent by name.

  ## Parameters

    * `server` - The Registry GenServer (default: `LlmCore.Agent.Registry`)
    * `name` - The agent name to unregister

  ## Returns

    * `:ok` - Successfully unregistered (or agent didn't exist)

  ## Examples

      :ok = Registry.unregister("steve")
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ @default_name, name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc """
  Looks up an agent by name.

  ## Parameters

    * `server` - The Registry GenServer (default: `LlmCore.Agent.Registry`)
    * `name` - The agent name to lookup

  ## Returns

    * `{:ok, Agent.t()}` - Agent found
    * `{:error, :not_found}` - No agent with that name

  ## Examples

      {:ok, agent} = Registry.get("steve")
      agent.provider
      #=> LlmCore.LLM.CLIProvider
  """
  @spec get(GenServer.server(), String.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def get(server \\ @default_name, name) do
    GenServer.call(server, {:get, name})
  end

  @doc """
  Returns all registered agents.

  ## Parameters

    * `server` - The Registry GenServer (default: `LlmCore.Agent.Registry`)

  ## Returns

    * List of `Agent.t()` structs

  ## Examples

      agents = Registry.list()
      Enum.map(agents, & &1.name)
      #=> ["steve", "gemini", "codex", "openai"]
  """
  @spec list(GenServer.server()) :: [Agent.t()]
  def list(server \\ @default_name) do
    GenServer.call(server, :list)
  end

  @doc """
  Updates an agent's configuration.

  ## Parameters

    * `server` - The Registry GenServer (default: `LlmCore.Agent.Registry`)
    * `name` - The agent name to update
    * `config` - New configuration map (replaces existing config)

  ## Returns

    * `:ok` - Successfully updated
    * `{:error, :not_found}` - No agent with that name

  ## Examples

      :ok = Registry.update("steve", %{model: "claude-3-opus", temperature: 0.9})
  """
  @spec update(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_found}
  def update(server \\ @default_name, name, config) do
    GenServer.call(server, {:update, name, config})
  end

  @doc """
  Synchronizes registered agents with provider definitions from TOML config.
  """
  @spec sync_with_providers(GenServer.server()) :: :ok
  def sync_with_providers(server \\ @default_name) do
    GenServer.cast(server, :sync_with_providers)
  end

  ## Server Callbacks

  @impl true
  def init(%{auto_discover: auto_discover}) do
    state = %{agents: %{}, auto_agents: MapSet.new()}

    state =
      if auto_discover do
        auto_discover_providers(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:register, name, provider, config}, _from, state) do
    case Agent.new(name, provider, config) do
      {:ok, agent} ->
        if Map.has_key?(state.agents, name) do
          {:reply, {:error, :already_registered}, state}
        else
          new_agents = Map.put(state.agents, name, agent)
          new_auto = MapSet.delete(state.auto_agents, name)
          new_state = %{state | agents: new_agents, auto_agents: new_auto}
          {:reply, :ok, new_state}
        end

      {:error, :invalid_name} ->
        {:reply, {:error, :invalid_name}, state}
    end
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    new_state = %{
      state
      | agents: Map.delete(state.agents, name),
        auto_agents: MapSet.delete(state.auto_agents, name)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.agents, name) do
      {:ok, agent} -> {:reply, {:ok, agent}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    agents = Map.values(state.agents)
    {:reply, agents, state}
  end

  @impl true
  def handle_call({:update, name, config}, _from, state) do
    case Map.fetch(state.agents, name) do
      {:ok, agent} ->
        updated_agent = %{agent | config: config}
        new_state = %{state | agents: Map.put(state.agents, name, updated_agent)}
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast(:sync_with_providers, state) do
    {:noreply, register_from_definitions(state, provider_definitions())}
  end

  ## Private Functions

  defp auto_discover_providers(state) do
    case provider_definitions() do
      [] -> register_fallback_providers(state)
      providers -> register_from_definitions(state, providers)
    end
  end

  defp provider_definitions do
    ProviderRegistry.all()
    |> Map.values()
  end

  defp register_fallback_providers(state) do
    Enum.reduce(@fallback_providers, state, fn {name, module}, acc_state ->
      if provider_usable?(module) do
        register_agent(acc_state, name, module, %{}, true)
      else
        acc_state
      end
    end)
  end

  defp register_from_definitions(state, providers) do
    manual_agents = Map.drop(state.agents, MapSet.to_list(state.auto_agents))
    base_state = %{state | agents: manual_agents, auto_agents: MapSet.new()}

    Enum.reduce(providers, base_state, fn %Definition{} = definition, acc_state ->
      aliases =
        definition.aliases
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> [definition.default_agent || definition.id]
          list -> list
        end

      case definition.provider_kind do
        :cli ->
          # CLI providers: register with CLIProvider module and the cli_provider
          # name in config so Agent.build_provider_struct resolves the struct.
          cli_name =
            if definition.cli_config, do: definition.cli_config.name, else: nil

          config =
            %{}
            |> maybe_put_model(cli_definition_model(definition))
            |> then(fn c ->
              if cli_name, do: Map.put(c, :cli_provider, cli_name), else: c
            end)

          Enum.reduce(aliases, acc_state, fn alias, state_acc ->
            register_agent(state_acc, alias, LlmCore.LLM.CLIProvider, config, true)
          end)

        _ ->
          # Module providers: existing path
          config =
            definition.agent_config
            |> merge_provider_options(definition.options)
            |> maybe_put_model(definition.default_model)

          Enum.reduce(aliases, acc_state, fn alias, state_acc ->
            register_agent(state_acc, alias, definition.module, config, true)
          end)
      end
    end)
  end

  defp cli_definition_model(%{model_resolution: :provider_runtime}), do: nil
  defp cli_definition_model(%{model_resolution: :explicit_only}), do: nil
  defp cli_definition_model(definition), do: definition.default_model

  defp register_agent(state, nil, _module, _config, _auto?), do: state

  defp register_agent(state, name, module, config, auto?) do
    normalized_name = to_string(name)

    cond do
      Map.has_key?(state.agents, normalized_name) and
          not MapSet.member?(state.auto_agents, normalized_name) ->
        state

      true ->
        case Agent.new(normalized_name, module, config) do
          {:ok, agent} ->
            new_agents = Map.put(state.agents, normalized_name, agent)

            new_auto =
              if auto?,
                do: MapSet.put(state.auto_agents, normalized_name),
                else: state.auto_agents

            %{state | agents: new_agents, auto_agents: new_auto}

          {:error, _} ->
            state
        end
    end
  end

  defp normalize_agent_config(nil), do: %{}

  defp normalize_agent_config(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        new_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end

        {new_key, value}

      other ->
        other
    end)
  end

  defp merge_provider_options(agent_config, nil), do: normalize_agent_config(agent_config)
  defp merge_provider_options(nil, options), do: normalize_agent_config(options)

  defp merge_provider_options(agent_config, options)
       when is_map(agent_config) and is_map(options) do
    # Both sides must be normalized to the same key type before merging,
    # otherwise `:base_url` and `"base_url"` collide silently — see GC-760.
    # `definition.agent_config` already has atom keys (normalized at Loader
    # time), but `definition.options` comes straight from Toml.decode_file/1
    # with string keys. Normalize options first, then merge so agent_config
    # wins on any collision.
    options
    |> normalize_agent_config()
    |> Map.merge(normalize_agent_config(agent_config))
  end

  defp merge_provider_options(agent_config, _options), do: normalize_agent_config(agent_config)

  defp maybe_put_model(map, nil), do: map
  defp maybe_put_model(map, model) when is_map(map), do: Map.put_new(map, :model, model)

  defp provider_usable?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :send, 2) and
      function_exported?(module, :stream, 2) and
      function_exported?(module, :available?, 0) and
      function_exported?(module, :capabilities, 0) and
      function_exported?(module, :provider_type, 0)
  end
end
