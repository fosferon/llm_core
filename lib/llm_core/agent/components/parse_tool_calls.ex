defmodule LlmCore.Agent.Components.ParseToolCalls do
  @moduledoc """
  Extracts tool calls from the LLM response.

  If the response contains no tool calls (or an empty list), sets
  `decision` to `{:done, response}` — the LLM has produced a final text
  response and no further iteration is needed.

  If tool calls are present, populates `ctx.tool_calls` for downstream
  stages.

  Analogous to a context merge stage: takes
  raw input and normalizes it into the pipeline's working format.
  """

  alias LlmCore.Agent.Context

  @doc """
  Extracts tool calls from `ctx.response.tool_calls`.

  Short-circuits when `ctx.status` is `:error`.

  ## Parameters

    * `ctx` — `%Context{}` with the LLM response
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Context{}` with either:
    * `tool_calls` populated and pipeline continues, or
    * `decision: {:done, response}` when no tool calls are present
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx

  def call(%Context{response: response} = ctx, _opts) do
    case response.tool_calls do
      [_ | _] = calls ->
        %{ctx | tool_calls: calls, trace: ctx.trace ++ [:parse_tool_calls]}

      _ ->
        # No tool calls — LLM produced a final text response
        %{ctx | decision: {:done, response}, trace: ctx.trace ++ [:parse_no_tools]}
    end
  end
end
