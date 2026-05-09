defmodule LlmCore.Agent.Components.LoopDecision do
  @moduledoc """
  Determines whether the outer loop should continue or stop.

  If this stage is reached with non-empty `result_messages`, the decision
  is `{:continue, messages}` — the outer loop appends these messages and
  calls the LLM again.

  If no tool calls survived validation and the decision was not already set
  to `:done` by `ParseToolCalls`, this stage defaults to `{:done, response}`.

  Emits the `[:llm_core, :agent, :loop_iteration]` telemetry event.

  Analogous to a projection stage: the final
  stage that packages the pipeline output into the contract the consumer
  expects.
  """

  alias LlmCore.Agent.Context

  @doc """
  Sets the `decision` field based on pipeline processing results.

  ## Parameters

    * `ctx` — `%Context{}` after all prior stages
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Context{}` with `decision` set to one of:
    * `{:continue, messages}` — tool calls executed, loop again
    * `{:done, response}` — no more tool calls, return final response
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx
  def call(%Context{decision: {:done, _}} = ctx, _opts), do: ctx

  def call(%Context{result_messages: [_ | _] = msgs} = ctx, _opts) do
    :telemetry.execute(
      [:llm_core, :agent, :loop_iteration],
      %{iteration: ctx.iteration, tool_calls_count: length(ctx.tool_calls)},
      %{}
    )

    %{ctx | decision: {:continue, msgs}, trace: ctx.trace ++ [:loop_continue]}
  end

  # Edge case: no tool calls survived validation but decision wasn't set to :done
  def call(%Context{response: response} = ctx, _opts) do
    %{ctx | decision: {:done, response}, trace: ctx.trace ++ [:loop_done_fallback]}
  end
end
