defmodule LlmCore.Agent.Components.ParseToolCalls do
  @moduledoc """
  Extracts tool calls from the LLM response.

  If the response contains no tool calls (or an empty list), sets
  `decision` to `{:done, response}` — the LLM has produced a final text
  response and no further iteration is needed.

  If tool calls are present, populates `ctx.tool_calls` for downstream
  stages.

  When `ctx.terminal_tool` is set and a matching call is present, the
  pipeline marks the response as done and stores the matching call and raw
  arguments on the context. The call is not validated, dispatched, or injected
  into the next turn.

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
    * `decision: {:done, response}` plus terminal fields when the terminal
      tool is called
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx

  def call(%Context{response: response} = ctx, _opts) do
    case response.tool_calls do
      [_ | _] = calls ->
        case find_terminal_call(calls, ctx.terminal_tool) do
          nil ->
            %{ctx | tool_calls: calls, trace: ctx.trace ++ [:parse_tool_calls]}

          terminal_call ->
            %{
              ctx
              | tool_calls: calls,
                terminal_tool_call: terminal_call,
                terminal_args: terminal_call.arguments,
                decision: {:done, response},
                trace: ctx.trace ++ [{:parse_terminal_tool, terminal_call.name}]
            }
        end

      _ ->
        # No tool calls — LLM produced a final text response
        %{ctx | decision: {:done, response}, trace: ctx.trace ++ [:parse_no_tools]}
    end
  end

  defp find_terminal_call(_calls, nil), do: nil

  defp find_terminal_call(calls, terminal_tool) when is_binary(terminal_tool) do
    Enum.find(calls, &(&1.name == terminal_tool))
  end

  defp find_terminal_call(_calls, _terminal_tool), do: nil
end
