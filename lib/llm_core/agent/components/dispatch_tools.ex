defmodule LlmCore.Agent.Components.DispatchTools do
  @moduledoc """
  Executes validated tool calls via the resolver function.

  Calls `resolve_tool.(call)` for each validated tool call and collects
  results as `LlmToolkit.Tool.Result` structs. Failed tool executions produce
  error results (not pipeline errors) — the LLM sees the error message and
  can self-correct.

  When a `resolver_module` is set on the context and it implements
  `dispatch_recipe/1`, the stage checks for dispatch recipes before
  executing each tool call. If a recipe is found, the call is delegated
  to the `ToolDispatch` pipeline for orchestrated sub-tool execution.

  Emits telemetry events for each tool call:

    * `[:llm_core, :agent, :tool_call, :start]`
    * `[:llm_core, :agent, :tool_call, :stop]`

  Recipe-backed calls run through the async `ToolDispatch` pipeline with a
  per-dispatch timeout taken from the caller (`:tool_timeout`). The pipeline
  is shared by all callers and is never restarted from this stage.

  ## Fan-out timeout semantics

  A recipe's parallel sub-calls share the caller's `:tool_timeout` budget.
  If that budget expires for one call in a fan-out, the whole tool step
  reports the typed timeout (`Tool call timed out after Nms`); successful
  sibling results are not returned. Timeout handling is all-or-nothing,
  never a partial result.
  """

  alias LlmCore.Agent.Context
  alias LlmCore.Agent.Pipeline.ToolDispatch, as: ToolDispatchPipeline
  alias LlmCore.Agent.ToolDispatch.Event, as: DispatchEvent
  alias LlmCore.Agent.ToolDispatch.Execution
  alias LlmToolkit.Tool.Call
  alias LlmToolkit.Tool.Result

  require Logger

  @default_tool_timeout :infinity
  @alf_timeout_grace_ms 1_000

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
  def call(%Context{decision: {:blank_stop, _}} = ctx, _opts), do: ctx
  def call(%Context{decision: {:nonterminal_stop, _}} = ctx, _opts), do: ctx

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
                dispatch_via_pipeline(call, resolve_fn, recipe, ctx)
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

  @spec dispatch_via_pipeline(Call.t(), function(), function(), Context.t()) :: Result.t()
  defp dispatch_via_pipeline(%Call{} = call, resolve_fn, recipe, %Context{} = ctx) do
    timeout = tool_timeout(ctx)

    dispatch_event = %DispatchEvent{
      call: call,
      resolve_fn: resolve_fn,
      recipe: recipe,
      timeout: timeout,
      deadline: deadline(timeout)
    }

    # The pipeline is shared by every caller. Start it in async mode if it is
    # not running and never stop or restart it here: another caller may have
    # in-flight work. If the pipeline cannot be started at all, execute the
    # call directly as 0.9.2 did instead of failing the tool call.
    case ensure_pipeline_started() do
      :ok ->
        run_pipeline(call, dispatch_event, timeout)

      {:error, reason} ->
        Logger.warning(
          "ToolDispatch pipeline unavailable (#{inspect(reason)}); " <>
            "falling back to direct execution for #{call.name}"
        )

        execute_direct(call, resolve_fn, timeout)
    end
  end

  defp ensure_pipeline_started do
    case ToolDispatchPipeline.ensure_started() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_pipeline(call, dispatch_event, timeout) do
    # Give ALF enough time to receive the bounded error the execution helper
    # produces. The helper, not ALF's default, owns the caller's budget; with
    # no caller budget both waits are unbounded.
    alf_timeout = if timeout == :infinity, do: :infinity, else: timeout + @alf_timeout_grace_ms

    case ToolDispatchPipeline.call(dispatch_event, timeout: alf_timeout) do
      %DispatchEvent{status: :error, error: {:timeout, _timeout_ms}} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: timeout_content(timeout)
        }

      %DispatchEvent{status: :error, error: error} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Dispatch error: #{inspect(error)}"
        }

      %DispatchEvent{status: :ok, result: content} when is_binary(content) and content != "" ->
        %Result{tool_call_id: call.id, name: call.name, content: content}

      %ALF.ErrorIP{error: :timeout} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: timeout_content(timeout)
        }

      %ALF.ErrorIP{error: error} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Dispatch pipeline error: #{inspect(error)}"
        }

      # Defensive: nil means the pipeline produced no result, e.g. an ip was
      # destroyed without emitting one, or ALF's wait was exhausted before the
      # result arrived. Report a bounded timeout instead of silently re-running
      # through the direct-execution fallback.
      nil ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: timeout_content(timeout)
        }

      other ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Dispatch error: #{inspect(other)}"
        }
    end
  rescue
    exception ->
      %Result{
        tool_call_id: call.id,
        name: call.name,
        content: "Dispatch error: #{Exception.message(exception)}"
      }
  end

  defp deadline(:infinity), do: nil

  defp deadline(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp timeout_content(:infinity), do: "Tool call timed out"

  defp timeout_content(timeout) when is_integer(timeout),
    do: "Tool call timed out after #{timeout}ms"

  defp tool_timeout(%Context{tool_timeout: :infinity}), do: :infinity

  defp tool_timeout(%Context{tool_timeout: timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp tool_timeout(%Context{}), do: @default_tool_timeout

  # Direct execution is the fallback when the shared pipeline cannot start.
  # Outside the pipeline no ALF stage enforces the caller's budget, so a
  # finite :tool_timeout is applied explicitly through the same helper the
  # pipeline uses. With :infinity the previous unbounded behaviour is kept.
  @spec execute_direct(Call.t(), function(), pos_integer() | :infinity) :: Result.t()
  defp execute_direct(%Call{} = call, resolve_fn, :infinity) do
    execute_one(call, resolve_fn)
  end

  defp execute_direct(%Call{} = call, resolve_fn, timeout)
       when is_integer(timeout) and timeout > 0 do
    event = %DispatchEvent{
      call: call,
      resolve_fn: resolve_fn,
      timeout: timeout,
      deadline: deadline(timeout)
    }

    case Execution.run(event, fn -> execute_one(call, resolve_fn) end) do
      %Result{} = result ->
        result

      {:error, {:timeout, _timeout_ms}} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: timeout_content(timeout)
        }

      {:error, {:execution_error, reason}} ->
        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Tool execution error: #{inspect(reason)}"
        }
    end
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
