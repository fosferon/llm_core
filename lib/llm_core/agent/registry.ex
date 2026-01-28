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
          "steve" => %Agent{name: "steve", provider: LlmCore.LLM.ClaudeCode, ...},
          "gemini" => %Agent{name: "gemini", provider: LlmCore.LLM.GeminiCLI, ...},
          "codex" => %Agent{name: "codex", provider: LlmCore.LLM.CodexCLI, ...}
        }
      }

  ## Usage

      # Start the registry (usually via supervision tree)
      {:ok, pid} = Registry.start_link(name: LlmCore.Agent.Registry)

      # Register an agent
      :ok = Registry.register("steve", LlmCore.LLM.ClaudeCode, %{model: "claude-3-opus"})

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

  @default_name __MODULE__

  # Known provider modules to scan during auto-discovery
  @known_providers [
    LlmCore.LLM.ClaudeCode,
    LlmCore.LLM.GeminiCLI,
    LlmCore.LLM.CodexCLI,
    LlmCore.LLM.OpenAI,
    LlmCore.LLM.Zai
  ]

  # Default agent names for auto-discovered providers
  @provider_default_names %{
    LlmCore.LLM.ClaudeCode => "claude",
    LlmCore.LLM.GeminiCLI => "gemini",
    LlmCore.LLM.CodexCLI => "codex",
    LlmCore.LLM.OpenAI => "openai",
    LlmCore.LLM.Zai => "zai"
  }

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

      :ok = Registry.register("steve", LlmCore.LLM.ClaudeCode, %{model: "claude-3-opus"})
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
      #=> LlmCore.LLM.ClaudeCode
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

  ## Server Callbacks

  @impl true
  def init(%{auto_discover: auto_discover}) do
    state = %{agents: %{}}

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
          new_state = put_in(state.agents[name], agent)
          {:reply, :ok, new_state}
        end

      {:error, :invalid_name} ->
        {:reply, {:error, :invalid_name}, state}
    end
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    new_state = %{state | agents: Map.delete(state.agents, name)}
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
        new_state = put_in(state.agents[name], updated_agent)
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Private Functions

  # Auto-discover provider modules and register them with default names.
  #
  # Provider availability (API keys / CLI presence) is enforced by providers at call time.
  defp auto_discover_providers(state) do
    Enum.reduce(@known_providers, state, fn provider_module, acc_state ->
      # Check if module exists and implements the behaviour
      if provider_usable?(provider_module) do
        default_name =
          Map.get(@provider_default_names, provider_module, default_name_for(provider_module))

        case Agent.new(default_name, provider_module, %{}) do
          {:ok, agent} ->
            put_in(acc_state.agents[default_name], agent)

          {:error, _} ->
            acc_state
        end
      else
        acc_state
      end
    end)
  end

  # Check if a provider module is usable (loaded and implements required callbacks).
  defp provider_usable?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :send, 2) and
      function_exported?(module, :stream, 2) and
      function_exported?(module, :available?, 0) and
      function_exported?(module, :capabilities, 0) and
      function_exported?(module, :provider_type, 0)
  end

  # Generate a default name from module name
  defp default_name_for(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
