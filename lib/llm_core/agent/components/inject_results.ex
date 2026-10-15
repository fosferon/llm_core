defmodule LlmCore.Agent.Components.InjectResults do
  @moduledoc """
  Builds the messages to append for the next LLM turn.

  Constructs:

  1. An assistant message containing the tool call requests (so the LLM
     sees its own tool calls in conversation history)
  2. Tool result messages (one per result) in the provider-neutral format

  These messages are stored in `ctx.result_messages` — the outer loop
  reads them and appends to the accumulated message list. This mirrors
  how a step-oriented loop executor accumulates `step_results` outside
  the pipeline.
  """

  alias LlmCore.Agent.Context

  @doc """
  Builds assistant + tool result messages from the current iteration.

  ## Parameters

    * `ctx` — `%Context{}` with `response`, `tool_calls`, and `tool_results`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Context{}` with `result_messages` populated.
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx
  def call(%Context{decision: {:done, _}} = ctx, _opts), do: ctx
  def call(%Context{decision: {:blank_stop, _}} = ctx, _opts), do: ctx
  def call(%Context{decision: {:nonterminal_stop, _}} = ctx, _opts), do: ctx

  # A lone terminal call has nothing to inject: no results, no transcript.
  def call(%Context{terminal_tool_call: %{}, tool_results: []} = ctx, _opts), do: ctx

  def call(%Context{response: response, tool_results: results} = ctx, _opts) do
    # The assistant message that requested the tool calls. It lists exactly
    # the calls that have a result — including calls that failed validation
    # (unknown tool, bad arguments) and therefore left `tool_calls` — so no
    # tool result is ever orphaned from its call, which providers reject.
    # The terminal call, which has no result, is never listed.
    result_ids = MapSet.new(results, & &1.tool_call_id)

    answered_calls =
      Enum.filter(response.tool_calls || [], &MapSet.member?(result_ids, &1.id))

    assistant_msg = %{
      role: :assistant,
      content: response.content,
      tool_calls: answered_calls
    }

    # One message per tool result
    result_msgs =
      Enum.map(results, fn result ->
        %{
          role: :tool,
          tool_call_id: result.tool_call_id,
          content: result.content
        }
      end)

    %{
      ctx
      | result_messages: [assistant_msg | result_msgs],
        trace: ctx.trace ++ [:inject_results]
    }
  end
end
