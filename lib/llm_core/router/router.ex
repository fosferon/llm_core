defmodule LlmCore.Router do
  @moduledoc """
  GenServer that resolves task types to full LLM agent configurations.
  """
  use GenServer
  require Logger

  alias LlmCore.Config.Store
  alias LlmCore.Pipelines.{InferencePipeline, RoutingPipeline}
  alias LlmCore.Router.{ResolvedRoute, RoutingTable}

  @sync_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Process.send_after(self(), :sync, @sync_interval_ms)
    {:ok, %{routing_table: nil, last_sync: nil}, {:continue, :load_routing}}
  end

  def handle_continue(:load_routing, state) do
    table =
      case Store.get_routing() do
        {:ok, table} ->
          table

        {:error, :not_found} ->
          Logger.warning("No routing config found, using safe default")
          default_routing_table()
      end

    {:noreply, %{state | routing_table: table, last_sync: DateTime.utc_now()}}
  end

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
  def resolve(task_type) when is_atom(task_type), do: resolve(Atom.to_string(task_type))

  def resolve(task_type) when is_binary(task_type),
    do: GenServer.call(__MODULE__, {:resolve, task_type})

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
  def get_routing_table do
    GenServer.call(__MODULE__, :get_routing_table)
  end

  @doc """
  Forces an immediate sync from the config store.
  """
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

  def handle_call({:resolve, task_type}, _from, state) do
    result = RoutingPipeline.route(task_type, routing_table: state.routing_table)
    {:reply, result, state}
  end

  def handle_call(:get_routing_table, _from, state) do
    {:reply, state.routing_table, state}
  end

  def handle_cast(:sync, state) do
    {:noreply, state, {:continue, :load_routing}}
  end

  defp default_routing_table do
    RoutingTable.new(%{"default" => "claude"})
  end
end
