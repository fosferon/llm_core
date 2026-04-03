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

  alias LlmCore.Memory.Hindsight.Config

  @type state_name :: :closed | :open | :half_open

  @type state :: %{
          status: state_name(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          last_success_at: integer() | nil
        }

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
  @spec allow?() :: :ok | {:error, :circuit_open}
  def allow? do
    GenServer.call(__MODULE__, :allow?)
  end

  @doc """
  Reports a successful request.
  """
  @spec report_success() :: :ok
  def report_success do
    GenServer.cast(__MODULE__, :success)
  end

  @doc """
  Reports a failed request.
  """
  @spec report_failure(term()) :: :ok
  def report_failure(reason) do
    GenServer.cast(__MODULE__, {:failure, reason})
  end

  @doc """
  Returns the current circuit status.
  """
  @spec status() :: %{status: state_name(), failure_count: non_neg_integer()}
  def status do
    GenServer.call(__MODULE__, :status)
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
    {:ok,
     %{
       status: :closed,
       failure_count: 0,
       last_failure_at: nil,
       last_success_at: nil
     }}
  end

  @impl true
  def handle_call(:allow?, _from, state) do
    config = Config.effective_config()
    now = System.monotonic_time(:millisecond)

    case state.status do
      :closed ->
        {:reply, :ok, state}

      :open ->
        # Check if enough time has passed to try half-open
        if state.last_failure_at &&
             now - state.last_failure_at >= config.circuit_reset_ms do
          Logger.info("Hindsight circuit breaker: Open → Half-open")
          {:reply, :ok, %{state | status: :half_open}}
        else
          {:reply, {:error, :circuit_open}, state}
        end

      :half_open ->
        # Allow one probe request
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, failure_count: state.failure_count}, state}
  end

  @impl true
  def handle_cast(:success, state) do
    now = System.monotonic_time(:millisecond)

    new_state =
      case state.status do
        :half_open ->
          Logger.info("Hindsight circuit breaker: Half-open → Closed")
          %{state | status: :closed, failure_count: 0, last_success_at: now}

        _ ->
          %{state | failure_count: 0, last_success_at: now}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:failure, reason}, state) do
    config = Config.effective_config()
    now = System.monotonic_time(:millisecond)

    new_failure_count = state.failure_count + 1

    new_state =
      case state.status do
        :closed ->
          if new_failure_count >= config.circuit_failure_threshold do
            Logger.warning(
              "Hindsight circuit breaker: Closed → Open after #{new_failure_count} failures"
            )

            %{state | status: :open, failure_count: new_failure_count, last_failure_at: now}
          else
            %{state | failure_count: new_failure_count, last_failure_at: now}
          end

        :half_open ->
          Logger.warning(
            "Hindsight circuit breaker: Half-open → Open (probe failed: #{inspect(reason)})"
          )

          %{state | status: :open, failure_count: new_failure_count, last_failure_at: now}

        :open ->
          %{state | failure_count: new_failure_count, last_failure_at: now}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset, _state) do
    Logger.info("Hindsight circuit breaker: Manual reset to Closed")

    {:noreply,
     %{
       status: :closed,
       failure_count: 0,
       last_failure_at: nil,
       last_success_at: System.monotonic_time(:millisecond)
     }}
  end
end
