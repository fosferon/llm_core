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
      terminal_tool: Keyword.get(opts, :terminal_tool),
      terminal_required: Keyword.get(opts, :terminal_required, false)
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

    test "terminal tool call is captured even with blank text content and leaves the decision to LoopDecision" do
      call = %Call{id: "c1", name: "done", arguments: %{"answer" => "x"}}
      response = %Response{content: nil, tool_calls: [call]}

      result = ParseToolCalls.call(ctx(response, terminal_tool: "done"), [])

      assert result.decision == nil
      assert result.tool_calls == []
      assert result.terminal_tool_call == call
      assert result.terminal_args == %{"answer" => "x"}
      assert {:parse_terminal_tool, "done"} in result.trace
    end

    test "sibling calls alongside the terminal call stay on the dispatch path" do
      sibling = %Call{id: "c1", name: "echo", arguments: %{}}
      terminal = %Call{id: "c2", name: "done", arguments: %{"answer" => "x"}}
      response = %Response{content: nil, tool_calls: [sibling, terminal]}

      result = ParseToolCalls.call(ctx(response, terminal_tool: "done"), [])

      assert result.tool_calls == [sibling]
      assert result.terminal_tool_call == terminal
      assert result.decision == nil
    end
  end

  describe "terminal_required" do
    test "prose without tool calls is a nonterminal stop" do
      response = %Response{content: "Let me do that now.", tool_calls: nil}

      result =
        ParseToolCalls.call(ctx(response, terminal_tool: "done", terminal_required: true), [])

      assert result.decision == {:nonterminal_stop, response}
      assert :parse_nonterminal_stop in result.trace
    end

    test "blank content is still a blank stop" do
      response = %Response{content: "", tool_calls: nil}

      result =
        ParseToolCalls.call(ctx(response, terminal_tool: "done", terminal_required: true), [])

      assert result.decision == {:blank_stop, response}
    end

    test "without terminal_tool the flag has no effect" do
      response = %Response{content: "plain", tool_calls: nil}

      result = ParseToolCalls.call(ctx(response, terminal_required: true), [])

      assert result.decision == {:done, response}
    end
  end
end
