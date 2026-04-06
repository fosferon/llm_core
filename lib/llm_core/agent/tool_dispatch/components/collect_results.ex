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
  def call(%Event{step_result: result, total_parallel: total} = event, memo, _opts) do
    collected = memo ++ [result]

    if length(collected) >= total do
      # All results collected — separate successes and errors
      {successes, errors} =
        Enum.split_with(collected, fn r -> not Map.has_key?(r, :error) end)

      composed_event = %{event |
        parallel_results: successes,
        errors: event.errors ++ errors,
        current_step: nil,
        step_result: nil
      }

      {[composed_event], []}
    else
      # Still waiting for more results
      {[], collected}
    end
  end
end
