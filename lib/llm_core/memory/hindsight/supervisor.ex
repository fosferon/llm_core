defmodule LlmCore.Memory.Hindsight.Supervisor do
  @moduledoc """
  Supervisor for Hindsight MCP integration components.

  Starts and manages:
  - Cache GenServer
  - WriteBuffer GenServer
  - CircuitBreaker GenServer
  - Health monitor
  """

  use Supervisor
  require Logger

  alias LlmCore.Memory.Hindsight.{Cache, CircuitBreaker, Config, Discovery, WriteBuffer}

  @doc """
  Starts the Hindsight supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.effective_config()

    children = [
      Cache,
      WriteBuffer,
      CircuitBreaker,
      {Task, fn -> startup_sequence(config) end}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the current Hindsight status for display.
  """
  @spec status() :: %{
          connected: boolean(),
          url: String.t() | nil,
          circuit_state: atom(),
          cache_stats: map(),
          buffer_size: non_neg_integer()
        }
  def status do
    %{
      connected: connected?(),
      url: Config.effective_url(),
      circuit_state: get_circuit_state(),
      cache_stats: get_cache_stats(),
      buffer_size: get_buffer_size()
    }
  end

  @doc """
  Checks if Hindsight is currently connected.
  """
  @spec connected?() :: boolean()
  def connected? do
    LlmCore.Memory.Hindsight.available?()
  rescue
    _ -> false
  end

  # Private helpers

  defp startup_sequence(config) do
    Logger.info("Starting Hindsight integration...")

    # 1. Run auto-discovery if no URL configured
    if is_nil(Config.effective_url()) do
      Discovery.discover()
    end

    # 2. Run prefetch if enabled
    if config.prefetch_on_startup do
      prefetch_common_queries()
    end

    # 3. Start background health monitoring
    spawn_link(fn -> health_monitor_loop() end)

    Logger.info("Hindsight integration started")
  end

  defp prefetch_common_queries do
    Task.start(fn ->
      Logger.debug("Prefetching common Hindsight queries...")

      # Prefetch recent patterns
      LlmCore.Memory.Hindsight.recall("recent patterns", limit: 5)

      # Prefetch workflow insights
      LlmCore.Memory.Hindsight.reflect(:workflow_effectiveness, workflow: "default")
    end)
  end

  defp health_monitor_loop do
    # Check health every 60 seconds
    Process.sleep(60_000)

    case LlmCore.Memory.Hindsight.health_check() do
      {:ok, _} -> notify_health(true)
      {:error, _reason} -> notify_health(false)
    end

    health_monitor_loop()
  rescue
    _ -> health_monitor_loop()
  end

  defp notify_health(status) do
    :telemetry.execute(
      [
        :llm_core,
        :hindsight,
        :health
      ],
      %{tests: 1},
      %{connected: status}
    )
  end

  defp get_circuit_state do
    if Process.whereis(CircuitBreaker) do
      CircuitBreaker.status().status
    else
      :not_started
    end
  rescue
    _ -> :unknown
  end

  defp get_cache_stats do
    if Process.whereis(Cache) do
      Cache.stats()
    else
      %{size: 0, hit_rate: 0.0, hits: 0, misses: 0}
    end
  rescue
    _ -> %{size: 0, hit_rate: 0.0, hits: 0, misses: 0}
  end

  defp get_buffer_size do
    if Process.whereis(WriteBuffer) do
      WriteBuffer.buffer_size()
    else
      0
    end
  rescue
    _ -> 0
  end
end
