defmodule LlmCore.LLM.MessagesTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Messages

  describe "normalize_chat/1" do
    test "wraps binary prompts as user message" do
      assert [%{"role" => "user", "content" => "hello"}] = Messages.normalize_chat("hello")
    end

    test "filters invalid message entries" do
      messages = [%{role: :user, content: "hi"}, %{role: :bad, content: "no"}]
      assert [%{"role" => "user", "content" => "hi"}] = Messages.normalize_chat(messages)
    end
  end

  describe "render_cli_prompt/1" do
    test "returns text for binaries" do
      assert Messages.render_cli_prompt("hi") == "hi"
    end

    test "renders chat messages" do
      prompt = [%{role: :system, content: "sys"}, %{role: :user, content: "hello"}]

      assert Messages.render_cli_prompt(prompt) == "[system] sys\n[user] hello"
    end

    test "preserves assistant tool calls and tool result ids" do
      rendered =
        Messages.render_cli_prompt([
          %{
            role: :assistant,
            content: "",
            tool_calls: [
              %LlmToolkit.Tool.Call{
                id: "call_1",
                name: "gc_mcpclient",
                arguments: %{"action" => "servers"}
              }
            ]
          },
          %{role: :tool, tool_call_id: "call_1", content: ~s({"servers":[{"name":"obsidian"}]})}
        ])

      assert rendered =~ "```llm_core_tool_calls"
      assert rendered =~ "\"gc_mcpclient\""
      assert rendered =~ "[tool id=call_1]"
      assert rendered =~ "\"obsidian\""
    end

    test "renders plain assistant messages without tool_calls block" do
      rendered =
        Messages.render_cli_prompt([
          %{role: :assistant, content: "I can help with that."},
          %{role: :user, content: "Thanks"}
        ])

      refute rendered =~ "llm_core_tool_calls"
      assert rendered =~ "[assistant] I can help with that."
      assert rendered =~ "[user] Thanks"
    end
  end
end
