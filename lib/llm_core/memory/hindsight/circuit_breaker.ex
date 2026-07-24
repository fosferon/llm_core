defmodule LlmCore.Memory.Hindsight.CircuitBreaker do
  @moduledoc """
  Circuit breaker pattern for Hindsight MCP connections.

  States:
  - **Closed**: Normal operation, track failures
  - **Open**: Reject requests, return cached/error
  - **Half-open**: Allow 1 probe request

  ## State Transitions

  - Closed → Open: After threshold consecutive failures
  - Open → Half-open: After reset time elapsed
  - Half-open → Closed: On successful probe
  - Half-open → Open: On failed probe
  """

  use GenServer
  require Logger

  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.Config

  @max_namespaces 256

  @type state_name :: :closed | :open | :half_open

  @type circuit :: %{
          status: state_name(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          last_success_at: integer() | nil,
          last_touched_at: integer(),
          probe_in_flight: boolean(),
          failure_threshold: pos_integer(),
          reset_ms: pos_integer()
        }

  @type state :: %{circuits: %{optional(term()) => circuit()}}

  # Client API

  @doc """
  Starts the circuit breaker GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if the circuit allows a request.

  Returns:
  - `:ok` - proceed with request
  - `{:error, :circuit_open}` - circuit is open, use fallback
  """
  @spec allow?(term()) :: :ok | {:error, :circuit_open}
  def allow?(namespace \\ fallback_namespace()) do
    GenServer.call(__MODULE__, {:allow?, namespace})
  end

  @doc """
  Reports a successful request.
  """
  @spec report_success(term()) :: :ok
  def report_success(namespace \\ fallback_namespace()) do
    GenServer.cast(__MODULE__, {:success, namespace})
  end

  @doc """
  Reports a failed request.
  """
  @spec report_failure(term(), term()) :: :ok
  def report_failure(reason, namespace \\ fallback_namespace()) do
    GenServer.cast(__MODULE__, {:failure, reason, namespace})
  end

  @doc """
  Returns the current circuit status.
  """
  @spec status(term()) :: %{status: state_name(), failure_count: non_neg_integer()}
  def status(namespace \\ fallback_namespace()) do
    GenServer.call(__MODULE__, {:status, namespace})
  end

  @doc """
  Manually resets the circuit to closed state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{circuits: %{}}}
  end

  @impl true
  def handle_call({:allow?, namespace}, _from, state) do
    config = Config.effective_config()
    now = System.monotonic_time(:millisecond)
    circuit = get_circuit(state, namespace, config, now)

    {reply, circuit} =
      case circuit.status do
        :closed ->
          {:ok, circuit}

        :open ->
          if circuit.last_failure_at && now - circuit.last_failure_at >= circuit.reset_ms do
            Logger.info("Hindsight circuit breaker: Open → Half-open")
            {:ok, %{circuit | status: :half_open, probe_in_flight: true}}
          else
            {{:error, :circuit_open}, circuit}
          end

        :half_open ->
          if circuit.probe_in_flight do
            {{:error, :circuit_open}, circuit}
          else
            {:ok, %{circuit | probe_in_flight: true}}
          end
      end

    {:reply, reply, put_circuit(state, namespace, touch(circuit, now))}
  end

  @impl true
  def handle_call({:status, namespace}, _from, state) do
    config = Config.effective_config()
    now = System.monotonic_time(:millisecond)
    circuit = get_circuit(state, namespace, config, now)
    reply = %{status: circuit.status, failure_count: circuit.failure_count}
    {:reply, reply, put_circuit(state, namespace, touch(circuit, now))}
  end

  @impl true
  def handle_cast({:success, namespace}, state) do
    now = System.monotonic_time(:millisecond)
    config = Config.effective_config()
    circuit = get_circuit(state, namespace, config, now)

    circuit =
      case circuit.status do
        :half_open ->
          Logger.info("Hindsight circuit breaker: Half-open → Closed")

          %{
            circuit
            | status: :closed,
              failure_count: 0,
              last_success_at: now,
              probe_in_flight: false
          }

        _ ->
          %{circuit | failure_count: 0, last_success_at: now, probe_in_flight: false}
      end

    {:noreply, put_circuit(state, namespace, touch(circuit, now))}
  end

  @impl true
  def handle_cast({:failure, reason, namespace}, state) do
    config = Config.effective_config()
    now = System.monotonic_time(:millisecond)
    circuit = get_circuit(state, namespace, config, now)

    new_failure_count = circuit.failure_count + 1

    circuit =
      case circuit.status do
        :closed ->
          if new_failure_count >= circuit.failure_threshold do
            Logger.warning(
              "Hindsight circuit breaker: Closed → Open after #{new_failure_count} failures"
            )

            %{
              circuit
              | status: :open,
                failure_count: new_failure_count,
                last_failure_at: now,
                probe_in_flight: false
            }
          else
            %{circuit | failure_count: new_failure_count, last_failure_at: now}
          end

        :half_open ->
          Logger.warning(
            "Hindsight circuit breaker: Half-open → Open (probe failed: #{inspect(reason)})"
          )

          %{
            circuit
            | status: :open,
              failure_count: new_failure_count,
              last_failure_at: now,
              probe_in_flight: false
          }

        :open ->
          %{circuit | failure_count: new_failure_count, last_failure_at: now}
      end

    {:noreply, put_circuit(state, namespace, touch(circuit, now))}
  end

  @impl true
  def handle_cast(:reset, _state) do
    {:noreply, %{circuits: %{}}}
  end

  defp get_circuit(state, namespace, config, now) do
    case Map.get(state.circuits, namespace) do
      nil ->
        initial_circuit(config, now)

      circuit ->
        %{
          circuit
          | failure_threshold: config.circuit_failure_threshold,
            reset_ms: config.circuit_reset_ms
        }
    end
  end

  defp initial_circuit(config, now) do
    %{
      status: :closed,
      failure_count: 0,
      last_failure_at: nil,
      last_success_at: nil,
      last_touched_at: now,
      probe_in_flight: false,
      failure_threshold: config.circuit_failure_threshold,
      reset_ms: config.circuit_reset_ms
    }
  end

  defp put_circuit(state, namespace, circuit) do
    circuits =
      if Map.has_key?(state.circuits, namespace) or map_size(state.circuits) < @max_namespaces do
        state.circuits
      else
        {oldest_namespace, _circuit} =
          Enum.min_by(state.circuits, fn {_key, value} -> value.last_touched_at end)

        Map.delete(state.circuits, oldest_namespace)
      end

    %{state | circuits: Map.put(circuits, namespace, circuit)}
  end

  defp touch(circuit, now), do: %{circuit | last_touched_at: now}

  defp fallback_namespace do
    MemoryConfig.namespace(Config.effective_url(), Config.effective_bank_id())
  end
end
