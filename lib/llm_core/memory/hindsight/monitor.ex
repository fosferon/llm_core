defmodule LlmCore.Memory.Hindsight.Monitor do
  @moduledoc false

  use GenServer
  require Logger

  alias LlmCore.Memory
  alias LlmCore.Memory.Backend.HindsightREST
  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.{Config, Discovery}

  @health_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @impl true
  def init(_opts) do
    send(self(), :configure)
    schedule_health_check()
    {:ok, %{snapshot: nil}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :configure)
    {:noreply, state}
  end

  @impl true
  def handle_info(:configure, state) do
    backend = MemoryConfig.backend()

    if backend in [:hindsight_rest, :foresight_http] do
      Logger.info("Configuring REST memory integration...")

      if backend == :hindsight_rest and is_nil(Config.effective_url()) do
        Discovery.discover()
      end
    end

    snapshot = {backend, Config.effective_url()}

    if snapshot != state.snapshot and rest_backend?(backend) and
         Config.effective_config().prefetch_on_startup do
      prefetch_common_queries()
    end

    {:noreply, %{state | snapshot: snapshot}}
  end

  @impl true
  def handle_info(:health_check, state) do
    notify_health(healthy?())
    schedule_health_check()
    {:noreply, state}
  rescue
    _error ->
      notify_health(false)
      schedule_health_check()
      {:noreply, state}
  end

  defp healthy? do
    case MemoryConfig.backend() do
      backend when backend in [:hindsight_rest, :foresight_http] ->
        match?({:ok, _}, HindsightREST.health_check())

      :foresight_inprocess ->
        Memory.available?()
    end
  end

  defp prefetch_common_queries do
    Task.Supervisor.start_child(LlmCore.Memory.TaskSupervisor, fn ->
      Logger.debug("Prefetching common memory queries...")
      Memory.recall("recent patterns", limit: 5)
      Memory.reflect(:workflow_effectiveness, workflow: "default")
    end)
  end

  defp notify_health(status) do
    :telemetry.execute(
      [:llm_core, :hindsight, :health],
      %{tests: 1},
      %{connected: status}
    )
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_interval_ms)
  end

  defp rest_backend?(backend), do: backend in [:hindsight_rest, :foresight_http]
end
