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
  pipeline marks the response as done and stores the matching call and raw
  arguments on the context. The call is not validated, dispatched, or injected
  into the next turn. A terminal-tool completion with blank text content is
  still `:done` — the payload travels in the tool arguments.

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
        # No tool calls. Either a final text response, or a degenerate
        # empty stop that the outer loop must recover from.
        if blank_stop?(response) do
          %{ctx | decision: {:blank_stop, response}, trace: ctx.trace ++ [:parse_blank_stop]}
        else
          %{ctx | decision: {:done, response}, trace: ctx.trace ++ [:parse_no_tools]}
        end
    end
  end

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
