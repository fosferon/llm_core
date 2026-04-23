defmodule LlmCore.Agent.ToolDispatch.Components.ExecuteSerial do
  @moduledoc """
  Executes serial tool call steps sequentially.

  Serial steps have data dependencies — each step can use results from
  prior steps via dynamic argument resolution. Results accumulate in
  `serial_context` for reference by later steps and by the compose stage.

  If there are no serial steps, this stage is a pass-through.
  """

  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmToolkit.Tool.Call

  @doc """
  Runs serial steps in order, threading results forward.

  ## Parameters

    * `event` — `%Event{}` with `plan.serial` steps and `resolve_fn`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `serial_results`, `serial_context`, and
    any accumulated `errors`.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{status: :error} = event, _opts), do: event

  def call(%Event{plan: %{serial: serial}} = event, _opts)
      when serial == [] or is_nil(serial) do
    event
  end

  def call(%Event{plan: %{serial: steps}} = event, _opts) do
    {results, context, errors} =
      Enum.reduce(steps, {[], %{}, []}, fn step, {results, context, errors} ->
        arguments = resolve_arguments(step.arguments, context)

        call = %Call{
          id: "dispatch_serial_#{System.unique_integer([:positive, :monotonic])}",
          name: step.tool,
          arguments: arguments
        }

        :telemetry.execute(
          [:llm_core, :tool_dispatch, :sub_call, :start],
          %{system_time: System.system_time()},
          %{tool_name: step.tool, label: step.label, phase: :serial}
        )

        case event.resolve_fn.(call) do
          {:ok, content} ->
            result = %{label: step.label, tool: step.tool, content: content}
            updated_context = Map.put(context, step.tool, content)
            {results ++ [result], updated_context, errors}

          {:error, reason} ->
            error = %{label: step.label, tool: step.tool, error: reason}
            {results, context, errors ++ [error]}
        end
      end)

    %{event | serial_results: results, serial_context: context, errors: event.errors ++ errors}
  end

  # Pass-through when plan has no :serial key
  def call(%Event{plan: _plan} = event, _opts), do: event

  @spec resolve_arguments(map() | (map() -> map()), map()) :: map()
  defp resolve_arguments(args, _context) when is_map(args), do: args
  defp resolve_arguments(args_fn, context) when is_function(args_fn, 1), do: args_fn.(context)
end
