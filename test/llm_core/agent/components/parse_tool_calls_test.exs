defmodule LlmCore.Agent.Components.ParseToolCallsTest do
  @moduledoc """
  GC-5523: the completion contract. A no-tool-call response with blank
  content is a blank stop, never a successful completion.
  """

  use ExUnit.Case, async: true

  alias LlmCore.Agent.Components.ParseToolCalls
  alias LlmCore.Agent.Context
  alias LlmCore.LLM.Response
  alias LlmToolkit.Tool.Call

  defp ctx(response, opts \\ []) do
    %Context{
      response: response,
      tools: [],
      terminal_tool: Keyword.get(opts, :terminal_tool)
    }
  end

  describe "no tool calls, non-blank content" do
    test "completes as done" do
      response = %Response{content: "final answer", tool_calls: nil}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.decision == {:done, response}
      assert :parse_no_tools in result.trace
    end
  end

  describe "no tool calls, blank content (GC-5523)" do
    test "nil content is a blank stop, not done" do
      response = %Response{content: nil, tool_calls: nil, metadata: %{finish_reason: "stop"}}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.decision == {:blank_stop, response}
      assert :parse_blank_stop in result.trace
    end

    test "empty string content is a blank stop" do
      response = %Response{content: "", tool_calls: nil}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.decision == {:blank_stop, response}
    end

    test "whitespace-only content is a blank stop" do
      response = %Response{content: "  \n\t ", tool_calls: nil}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.decision == {:blank_stop, response}
    end

    test "blank content with structured output is done, not blank stop" do
      response = %Response{content: nil, tool_calls: nil, structured: %{"answer" => 42}}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.decision == {:done, response}
    end
  end

  describe "tool calls present" do
    test "populates tool_calls and defers the decision" do
      call = %Call{id: "c1", name: "echo", arguments: %{}}
      response = %Response{content: nil, tool_calls: [call]}

      result = ParseToolCalls.call(ctx(response), [])

      assert result.tool_calls == [call]
      assert result.decision == nil
    end

    test "terminal tool call is done even with blank text content" do
      call = %Call{id: "c1", name: "done", arguments: %{"answer" => "x"}}
      response = %Response{content: nil, tool_calls: [call]}

      result = ParseToolCalls.call(ctx(response, terminal_tool: "done"), [])

      assert result.decision == {:done, response}
      assert result.terminal_tool_call == call
      assert result.terminal_args == %{"answer" => "x"}
    end
  end
end
