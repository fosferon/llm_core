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
  alias LlmCore.Memory
  alias LlmCore.Memory.Hindsight.{Cache, CircuitBreaker, Config, Monitor, WriteBuffer}

  @doc """
  Starts the Hindsight supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cache,
      WriteBuffer,
      CircuitBreaker,
      {Task.Supervisor, name: LlmCore.Memory.TaskSupervisor},
      Monitor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec refresh() :: :ok
  def refresh do
    if Process.whereis(Monitor), do: Monitor.refresh()
    :ok
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
    Memory.available?()
  rescue
    _ -> false
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
