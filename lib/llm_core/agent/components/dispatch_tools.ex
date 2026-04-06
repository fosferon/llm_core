defmodule LlmCore.Agent.Components.DispatchTools do
  @moduledoc """
  Executes validated tool calls via the resolver function.

  Calls `resolve_tool.(call)` for each validated tool call and collects
  results as `LlmCore.Tool.Result` structs. Failed tool executions produce
  error results (not pipeline errors) — the LLM sees the error message and
  can self-correct.

  When a `resolver_module` is set on the context and it implements
  `dispatch_recipe/1`, the stage checks for dispatch recipes before
  executing each tool call. If a recipe is found, the call is delegated
  to the `ToolDispatch` pipeline for orchestrated sub-tool execution.

  Emits telemetry events for each tool call:

    * `[:llm_core, :agent, :tool_call, :start]`
    * `[:llm_core, :agent, :tool_call, :stop]`

  Analogous to `Mobus.Stepwise.Components.StepwiseAction`: the stage that
  executes the actual work (capabilities in stepwise, tool resolution here).
  """

  alias LlmCore.Agent.Context
  alias LlmCore.Agent.Pipeline.ToolDispatch, as: ToolDispatchPipeline
  alias LlmCore.Agent.ToolDispatch.Event, as: DispatchEvent
  alias LlmCore.Tool.Call
  alias LlmCore.Tool.Result

  @doc """
  Dispatches each tool call through the resolver and collects results.

  When a resolver module with `dispatch_recipe/1` is available, checks for
  recipes before direct execution. Recipe-matched calls are delegated to
  the `ToolDispatch` pipeline for orchestrated sub-tool execution.

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

        {elapsed_us, result} =
          :timer.tc(fn ->
            case lookup_recipe(call.name, ctx) do
              nil ->
                # No recipe — direct execution (existing behavior, unchanged)
                execute_one(call, resolve_fn)

              recipe ->
                # Recipe found — delegate to ToolDispatch pipeline
                dispatch_via_pipeline(call, resolve_fn, recipe)
            end
          end)

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

  @spec lookup_recipe(String.t(), Context.t()) :: (map() -> map()) | nil
  defp lookup_recipe(_tool_name, %Context{resolver_module: nil}), do: nil

  defp lookup_recipe(tool_name, %Context{resolver_module: mod}) do
    if function_exported?(mod, :dispatch_recipe, 1) do
      mod.dispatch_recipe(tool_name)
    else
      nil
    end
  end

  @spec dispatch_via_pipeline(Call.t(), function(), function()) :: Result.t()
  defp dispatch_via_pipeline(%Call{} = call, resolve_fn, recipe) do
    dispatch_event = %DispatchEvent{
      call: call,
      resolve_fn: resolve_fn,
      recipe: recipe
    }

    :ok = ToolDispatchPipeline.ensure_started(sync: true)

    case ToolDispatchPipeline.call(dispatch_event) do
      %DispatchEvent{result: content, status: :ok} ->
        %Result{tool_call_id: call.id, name: call.name, content: content}

      %DispatchEvent{result: content} when is_binary(content) ->
        %Result{tool_call_id: call.id, name: call.name, content: content}

      %DispatchEvent{} ->
        %Result{tool_call_id: call.id, name: call.name, content: "Dispatch error: no result"}

      %ALF.ErrorIP{error: error} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Dispatch pipeline error: #{inspect(error)}"
        }

      other ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Dispatch error: #{inspect(other)}"
        }
    end
  rescue
    e ->
      %Result{
        tool_call_id: call.id,
        name: call.name,
        content: "Dispatch error: #{Exception.message(e)}"
      }
  end

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
