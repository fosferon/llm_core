defmodule LlmCore.Agent.Components.DispatchTools do
  @moduledoc """
  Executes validated tool calls via the resolver function.

  Calls `resolve_tool.(call)` for each validated tool call and collects
  results as `LlmCore.Tool.Result` structs. Failed tool executions produce
  error results (not pipeline errors) — the LLM sees the error message and
  can self-correct.

  Emits telemetry events for each tool call:

    * `[:llm_core, :agent, :tool_call, :start]`
    * `[:llm_core, :agent, :tool_call, :stop]`

  Analogous to `Mobus.Stepwise.Components.StepwiseAction`: the stage that
  executes the actual work (capabilities in stepwise, tool resolution here).
  """

  alias LlmCore.Agent.Context
  alias LlmCore.Tool.Call
  alias LlmCore.Tool.Result

  @doc """
  Dispatches each tool call through the resolver and collects results.

  ## Parameters

    * `ctx` — `%Context{}` with `tool_calls` and `resolve_tool`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Context{}` with `tool_results` populated. Error results from
    prior stages (e.g. unknown tool errors from `ValidateCalls`) are preserved
    and new results are appended.
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx
  def call(%Context{decision: {:done, _}} = ctx, _opts), do: ctx

  def call(
        %Context{tool_calls: calls, resolve_tool: resolve_fn, tool_results: prior} = ctx,
        _opts
      ) do
    new_results =
      Enum.map(calls, fn %Call{} = call ->
        :telemetry.execute(
          [:llm_core, :agent, :tool_call, :start],
          %{system_time: System.system_time()},
          %{tool_name: call.name, call_id: call.id}
        )

        {elapsed_us, result} = :timer.tc(fn -> execute_one(call, resolve_fn) end)

        :telemetry.execute(
          [:llm_core, :agent, :tool_call, :stop],
          %{duration_us: elapsed_us},
          %{tool_name: call.name, call_id: call.id}
        )

        result
      end)

    %{
      ctx
      | tool_results: prior ++ new_results,
        trace: ctx.trace ++ [{:dispatch, length(new_results)}]
    }
  end

  # -- Private ----------------------------------------------------------------

  @spec execute_one(Call.t(), (Call.t() -> {:ok, String.t()} | {:error, String.t()})) ::
          Result.t()
  defp execute_one(%Call{} = call, resolve_fn) do
    case resolve_fn.(call) do
      {:ok, content} when is_binary(content) ->
        %Result{tool_call_id: call.id, name: call.name, content: content}

      {:ok, content} ->
        %Result{tool_call_id: call.id, name: call.name, content: inspect(content)}

      {:error, reason} when is_binary(reason) ->
        %Result{tool_call_id: call.id, name: call.name, content: "Error: #{reason}"}

      {:error, reason} ->
        %Result{tool_call_id: call.id, name: call.name, content: "Error: #{inspect(reason)}"}
    end
  rescue
    e ->
      %Result{
        tool_call_id: call.id,
        name: call.name,
        content: "Tool execution error: #{Exception.message(e)}"
      }
  end
end
