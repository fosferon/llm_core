defmodule LlmCore.Agent.ToolDispatch.Components.ExecuteOneCall do
  @moduledoc """
  Executes a single parallel sub-tool call.

  With `count: N` in the pipeline definition, N GenStage workers run this
  stage concurrently. When the fan-out Composer emits N events, they
  distribute across workers for parallel execution.

  If the event has no `current_step` (passed through from fan-out with no
  parallel steps), this stage is a pass-through.
  """

  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmCore.Tool.Call

  @doc """
  Executes the tool call specified by `current_step`.

  ## Parameters

    * `event` — `%Event{}` with `current_step` and `resolve_fn`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `step_result` populated. The result is either
    a success map `%{label, tool, content}` or an error map `%{label, tool, error}`.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{status: :error} = event, _opts), do: event
  def call(%Event{current_step: nil} = event, _opts), do: event

  def call(%Event{current_step: step, resolve_fn: resolve_fn} = event, _opts) do
    call_struct = %Call{
      id: "dispatch_parallel_#{System.unique_integer([:positive, :monotonic])}",
      name: step.tool,
      arguments: resolve_arguments(step.arguments, event.serial_context)
    }

    :telemetry.execute(
      [:llm_core, :tool_dispatch, :sub_call, :start],
      %{system_time: System.system_time()},
      %{tool_name: step.tool, label: step.label, phase: :parallel}
    )

    case resolve_fn.(call_struct) do
      {:ok, content} ->
        %{event | step_result: %{label: step.label, tool: step.tool, content: content}}

      {:error, reason} ->
        %{event | step_result: %{label: step.label, tool: step.tool, error: reason}}
    end
  rescue
    e ->
      %{event | step_result: %{label: step.tool, tool: step.tool, error: Exception.message(e)}}
  end

  @spec resolve_arguments(map() | (map() -> map()), map()) :: map()
  defp resolve_arguments(args, _context) when is_map(args), do: args
  defp resolve_arguments(args_fn, context) when is_function(args_fn, 1), do: args_fn.(context)
end
