defmodule LlmCore.Agent.ToolDispatch.Components.FanOutParallel do
  @moduledoc """
  Composer that fans out one dispatch event into N parallel call events.

  Each emitted event carries one parallel step to execute. With `count: N`
  on the subsequent `ExecuteOneCall` stage, these events are processed
  concurrently across GenStage workers (in async mode).

  If there are no parallel steps, the event passes through unchanged —
  the pipeline structure exists but acts as a pass-through.

  ## ALF Composer Contract

  Returns `{events, memo}` where `events` is a list of `Event` structs,
  one per parallel step. Memo is unused (`nil`).
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Fan-out function for the ALF Composer.

  ## Parameters

    * `event` — `%Event{}` with `plan.parallel` steps
    * `memo` — Composer memo (unused, always `nil`)
    * `opts` — ALF composer options (unused)

  ## Returns

    `{[Event.t()], nil}` — One event per parallel step, or the original
    event wrapped in a list if there are no parallel steps.
  """
  @spec call(Event.t(), nil, keyword()) :: {[Event.t()], nil}
  def call(%Event{status: :error} = event, nil, _opts), do: {[event], nil}

  def call(%Event{plan: %{parallel: parallel}} = event, nil, _opts)
      when parallel == [] or is_nil(parallel) do
    {[event], nil}
  end

  def call(%Event{plan: %{parallel: steps}} = event, nil, _opts) do
    total = length(steps)

    events =
      Enum.map(steps, fn step ->
        %{event |
          current_step: step,
          total_parallel: total
        }
      end)

    {events, nil}
  end

  # Pass-through when plan has no :parallel key
  def call(%Event{} = event, nil, _opts), do: {[event], nil}
end
