defmodule LlmCore.Agent.Components.ParseToolCalls do
  @moduledoc """
  Extracts tool calls from the LLM response.

  If the response contains tool calls (non-empty list), populates
  `ctx.tool_calls` for downstream stages.

  If the response contains no tool calls and non-blank content, sets
  `decision` to `{:done, response}` — the LLM has produced a final text
  response and no further iteration is needed.

  If the response contains no tool calls AND blank content (nil or
  whitespace-only), sets `decision` to `{:blank_stop, response}` — a
  degenerate completion that must not be accepted as final. Some
  OpenAI-compatible backends (observed on Ollama `gpt-oss`) occasionally
  return HTTP success with `finish_reason: "stop"`, empty content, and no
  tool calls while a tool-driven task is still incomplete. The outer loop
  (`LlmCore.Agent.Loop`) owns the bounded recovery policy for this
  decision: it retries the turn and terminates with a typed error when
  blanks repeat.

  When `ctx.terminal_tool` is set and a matching call is present, the
  terminal call and its raw arguments are stored on the context and removed
  from `tool_calls`; the call itself is never validated or dispatched. Any
  sibling calls in the same response stay in `tool_calls` and flow through
  validation and dispatch as usual — `LoopDecision` then completes the turn
  instead of continuing. A terminal-tool completion with blank text content
  is still complete — the payload travels in the tool arguments.

  When `ctx.terminal_required` is set alongside `terminal_tool`, a response
  with no tool calls and non-blank prose is `{:nonterminal_stop, response}`
  rather than `{:done, response}`: the model narrated instead of finishing
  through the terminal tool. The outer loop owns the bounded recovery.

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
    * `decision: {:done, response}` when no tool calls are present and the
      content is non-blank
    * `decision: {:blank_stop, response}` when no tool calls are present
      and the content is blank
    * `terminal_tool_call` / `terminal_args` set and the terminal call removed
      from `tool_calls` when the terminal tool is called (siblings remain)
    * `decision: {:nonterminal_stop, response}` when `terminal_required` is
      set and the response has prose but no tool calls
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
            siblings = List.delete(calls, terminal_call)

            %{
              ctx
              | tool_calls: siblings,
                terminal_tool_call: terminal_call,
                terminal_args: terminal_call.arguments,
                trace: ctx.trace ++ [{:parse_terminal_tool, terminal_call.name}]
            }
        end

      _ ->
        # No tool calls. Either a final text response, a degenerate empty
        # stop, or — under a required terminal tool — a narrated stop; the
        # outer loop recovers the latter two.
        cond do
          blank_stop?(response) ->
            %{ctx | decision: {:blank_stop, response}, trace: ctx.trace ++ [:parse_blank_stop]}

          terminal_required?(ctx) ->
            %{
              ctx
              | decision: {:nonterminal_stop, response},
                trace: ctx.trace ++ [:parse_nonterminal_stop]
            }

          true ->
            %{ctx | decision: {:done, response}, trace: ctx.trace ++ [:parse_no_tools]}
        end
    end
  end

  defp terminal_required?(%Context{terminal_required: true, terminal_tool: tool})
       when is_binary(tool),
       do: true

  defp terminal_required?(_ctx), do: false

  # A no-tool-call response is a blank stop when its text content is nil or
  # whitespace-only and it carries no structured output. Such a response
  # conveys nothing — it cannot be a valid final answer.
  defp blank_stop?(%{content: content, structured: nil}) when is_binary(content) do
    String.trim(content) == ""
  end

  defp blank_stop?(%{content: nil, structured: nil}), do: true

  defp blank_stop?(_response), do: false

  defp find_terminal_call(_calls, nil), do: nil

  defp find_terminal_call(calls, terminal_tool) when is_binary(terminal_tool) do
    Enum.find(calls, &(&1.name == terminal_tool))
  end

  defp find_terminal_call(_calls, _terminal_tool), do: nil
end
