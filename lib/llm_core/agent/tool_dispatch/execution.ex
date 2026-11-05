defmodule LlmCore.Agent.ToolDispatch.Execution do
  @moduledoc false

  # Runs a single sub-tool call under the dispatch budget. The call runs in a
  # monitored process so a hung tool can be killed without taking down the
  # pipeline worker or the caller. Exceptions are returned as typed errors,
  # never raised across the pipeline.

  alias LlmCore.Agent.ToolDispatch.Event

  @type result :: term() | {:error, term()}

  @doc """
  Runs `fun` with the remaining budget carried by `event`.

  Returns whatever `fun` returns, or `{:error, {:timeout, remaining_ms}}`
  when the budget is exhausted. `{:error, {:execution_error, reason}}` is
  returned when the spawned call raises or exits.
  """
  @spec run(Event.t(), (-> result())) :: result()
  def run(%Event{} = event, fun) when is_function(fun, 0) do
    case remaining_ms(event) do
      remaining when remaining > 0 -> execute(fun, remaining)
      _ -> {:error, {:timeout, 0}}
    end
  end

  defp execute(fun, timeout_ms) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {ref, safe_apply(fun)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:execution_error, reason}}
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, {:timeout, timeout_ms}}
    end
  end

  defp safe_apply(fun) do
    fun.()
  rescue
    exception -> {:error, {:execution_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:execution_error, {kind, reason}}}
  end

  defp remaining_ms(%Event{deadline: nil, timeout: timeout}) when is_integer(timeout) do
    timeout
  end

  defp remaining_ms(%Event{deadline: deadline}) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
