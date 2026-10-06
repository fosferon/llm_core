defmodule LlmCore.Router do
  @moduledoc """
  GenServer that resolves task types to full LLM agent configurations.

  The Router maintains a `RoutingTable` loaded from TOML configuration and
  resolves task strings (like `"coding"`, `"reasoning"`) to `ResolvedRoute`
  structs containing the provider alias, execution mode, and agent metadata.

  ## Configuration

  Routing rules are defined in TOML under `[routing]`. `default` is required in
  your project or home layer: llm_core ships none. Without it, task types that
  match no rule return `{:error, {:no_routing_default, %{task_type:, table_source:}}}`.

      [routing]
      default = "claude"

      [routing.tasks.coding]
      alias = "openai"
      mode = "passthrough"
      capabilities = { structured_output = true, tool_use = true }

  ## Usage

      # Resolve a task type
      {:ok, route} = LlmCore.Router.resolve(:coding)
      route.alias #=> "openai"
      route.mode #=> :passthrough

      # Correlate routing failures with a job/execution via telemetry
      LlmCore.Router.resolve(:coding, caller_ref: job_id)

      # Send a prompt through routing
      {:ok, response} = LlmCore.Router.send("Write a function", :coding)

      # Stream
      {:ok, stream} = LlmCore.Router.stream("Explain this", :reasoning)

  ## Hot Reload

  The Router listens for `{:config_reloaded, :routing}` messages and
  refreshes its routing table from `Config.Store`. It also syncs
  every 60 seconds as a safety net.
  """
  use GenServer
  require Logger

  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.Pipelines.{InferencePipeline, RoutingPipeline}
  alias LlmCore.Router.{ResolvedRoute, RoutingTable}

  @sync_interval_ms 60_000

  @doc """
  Starts the Router GenServer linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, map(), {:continue, :load_routing}}
  def init(_opts) do
    Process.send_after(self(), :sync, @sync_interval_ms)
    {:ok, %{routing_table: nil, last_sync: nil}, {:continue, :load_routing}}
  end

  @impl true
  def handle_continue(:load_routing, state) do
    table =
      case Store.get_routing() do
        {:ok, table} ->
          table

        {:error, :not_found} ->
          {:ok, table} = Loader.routing_from_layers()
          warn_if_no_default(table)
          table
      end

    {:noreply, %{state | routing_table: table, last_sync: DateTime.utc_now()}}
  end

  @impl true
  def handle_info({:config_reloaded, :routing}, state) do
    {:noreply, state, {:continue, :load_routing}}
  end

  def handle_info({:config_reloaded, :providers}, state) do
    {:noreply, state}
  end

  def handle_info(:sync, state) do
    Process.send_after(self(), :sync, @sync_interval_ms)
    {:noreply, state, {:continue, :load_routing}}
  end

  @doc """
  Resolves a task type (e.g., "coding", "planning") to a full agent config.
  """
  @spec resolve(String.t() | atom(), keyword()) :: {:ok, ResolvedRoute.t()} | {:error, term()}
  def resolve(task_type, opts \\ [])

  def resolve(task_type, opts) when is_atom(task_type),
    do: resolve(Atom.to_string(task_type), opts)

  def resolve(task_type, opts) when is_binary(task_type),
    do: GenServer.call(__MODULE__, {:resolve, task_type, Keyword.take(opts, [:caller_ref])})

  @doc """
  Resolves a task type using a provided routing table (used for execution snapshots).
  """
  @spec resolve_from_table(String.t() | atom(), RoutingTable.t()) ::
          {:ok, ResolvedRoute.t()} | {:error, term()}
  def resolve_from_table(task_type, %RoutingTable{} = table) when is_atom(task_type) do
    RoutingPipeline.route(task_type, routing_table: table)
  end

  def resolve_from_table(task_type, %RoutingTable{} = table) when is_binary(task_type) do
    RoutingPipeline.route(task_type, routing_table: table)
  end

  @doc """
  Returns the current routing table (debug/introspection).
  """
  @spec get_routing_table() :: RoutingTable.t() | nil
  def get_routing_table do
    GenServer.call(__MODULE__, :get_routing_table)
  end

  @doc """
  Forces an immediate sync from the config store.
  """
  @spec sync() :: :ok
  def sync, do: GenServer.cast(__MODULE__, :sync)

  @doc """
  Sends a prompt through the router, automatically selecting the provider.
  """
  @spec send(String.t(), String.t() | atom(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, term()}
  def send(prompt, task_type, opts \\ []) do
    InferencePipeline.execute(:send, prompt, task_type, opts)
  end

  @doc """
  Initiates a streaming prompt through the routed provider.
  """
  @spec stream(String.t(), String.t() | atom(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(prompt, task_type, opts \\ []) do
    InferencePipeline.execute(:stream, prompt, task_type, opts)
  end

  @doc """
  Sends a CommBus protocol packet through the router.
  Pass `:task_type` via opts to override metadata-derived routing.
  """
  @spec send_packet(map(), keyword()) :: {:ok, LlmCore.LLM.Response.t()} | {:error, term()}
  def send_packet(packet, opts \\ []) do
    {task_type, remaining_opts} = Keyword.pop(opts, :task_type)
    InferencePipeline.execute(:send, packet, task_type, remaining_opts)
  end

  @doc """
  Streams a CommBus protocol packet through the routed provider.
  """
  @spec stream_packet(map(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_packet(packet, opts \\ []) do
    {task_type, remaining_opts} = Keyword.pop(opts, :task_type)
    InferencePipeline.execute(:stream, packet, task_type, remaining_opts)
  end

  @impl true
  def handle_call({:resolve, task_type, opts}, _from, state) do
    result = RoutingPipeline.route(task_type, [routing_table: state.routing_table] ++ opts)
    {:reply, result, state}
  end

  def handle_call(:get_routing_table, _from, state) do
    {:reply, state.routing_table, state}
  end

  @impl true
  def handle_cast(:sync, state) do
    {:noreply, state, {:continue, :load_routing}}
  end

  defp warn_if_no_default(%RoutingTable{default: nil}) do
    Logger.warning(
      "No routing config in Store and no [routing] default in any config layer; " <>
        "dispatch will fail with :no_routing_default until one is configured"
    )
  end

  defp warn_if_no_default(%RoutingTable{}), do: :ok
end
