defmodule LlmCore.Agent.ToolDispatch.Components.CollectResults do
  @moduledoc """
  Composer that collects parallel execution results back into a single event.

  Accumulates `step_result` from each fanned-out event in its memo. When all
  expected results have been collected (count matches `total_parallel`),
  emits a single event with all `parallel_results` populated.

  If the event was NOT fanned out (no parallel steps), it passes through.

  ## ALF Composer Contract

  Returns `{events, memo}`. Emits nothing until all parallel results are
  collected, then emits one composed event and resets memo.

  IMPORTANT: This Composer must have `count: 1` (the default) to ensure all
  fanned-out events reach the same worker for proper accumulation.
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Collection function for the ALF Composer.

  ## Parameters

    * `event` — `%Event{}` with `step_result` from parallel execution
    * `memo` — List of accumulated results
    * `opts` — ALF composer options (unused)

  ## Returns

    `{[Event.t()], [map()]}` — Empty list while collecting, single event
    when all results are gathered.
  """
  @spec call(Event.t(), [map()], keyword()) :: {[Event.t()], [map()]}

  # Pass-through for events that weren't fanned out
  def call(%Event{current_step: nil} = event, memo, _opts) do
    {[event], memo}
  end

  # Collect fanned-out results
  def call(%Event{step_result: nil, total_parallel: total} = event, memo, _opts)
      when total > 0 do
    # step_result is nil — a stage error or skip occurred. Record as error.
    error_result = %{
      index: event.step_index,
      label: (event.current_step && event.current_step[:label]) || "unknown",
      tool: (event.current_step && event.current_step[:tool]) || "unknown",
      error: "Step produced no result"
    }

    collect(event, memo ++ [error_result], total)
  end

  def call(%Event{step_result: result, total_parallel: total} = event, memo, _opts) do
    result = if is_map(result), do: Map.put_new(result, :index, event.step_index), else: result
    collect(event, memo ++ [result], total)
  end

  defp collect(event, collected, total) do
    if length(collected) >= total do
      # Workers finish out of order; restore the recipe's declared order.
      {successes, errors} =
        collected
        |> Enum.split_with(fn r -> is_map(r) and not Map.has_key?(r, :error) end)

      composed_event = %{
        event
        | parallel_results: ordered(successes),
          errors: event.errors ++ ordered(errors),
          current_step: nil,
          step_index: nil,
          step_result: nil
      }

      {[composed_event], []}
    else
      {[], collected}
    end
  end

  defp ordered(results) do
    results
    |> Enum.sort_by(& &1[:index], :asc)
    |> Enum.map(&Map.delete(&1, :index))
  end
end
