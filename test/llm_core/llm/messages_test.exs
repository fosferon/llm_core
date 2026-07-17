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

    # GC-2634: the assistant message's tool_calls were silently dropped by the
    # generic role/content clause, orphaning the following tool-result message
    # so providers (Anthropic via OpenRouter) rejected the whole conversation.
    test "preserves assistant tool_calls in OpenAI wire shape" do
      messages = [
        %{role: :user, content: "send it"},
        %{
          role: :assistant,
          content: "On it.",
          tool_calls: [
            %LlmToolkit.Tool.Call{
              id: "call_1",
              name: "send_brochure",
              arguments: %{"visitor_email" => "a@b.com", "variant" => "ceo"}
            }
          ]
        },
        %{role: :tool, tool_call_id: "call_1", content: "Sent."}
      ]

      assert [
               %{"role" => "user", "content" => "send it"},
               %{"role" => "assistant", "content" => "On it.", "tool_calls" => [tc]},
               %{"role" => "tool", "content" => "Sent.", "tool_call_id" => "call_1"}
             ] = Messages.normalize_chat(messages)

      # OpenAI wire shape: id + type:function + function.name + JSON-STRING args.
      assert tc["id"] == "call_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "send_brochure"
      assert is_binary(tc["function"]["arguments"])
      assert Jason.decode!(tc["function"]["arguments"]) == %{
               "visitor_email" => "a@b.com",
               "variant" => "ceo"
             }
    end

    test "assistant tool-call message with nil content survives filtering, content defaults to \"\"" do
      messages = [
        %{
          role: :assistant,
          content: nil,
          tool_calls: [%LlmToolkit.Tool.Call{id: "c1", name: "t", arguments: %{}}]
        }
      ]

      assert [%{"role" => "assistant", "content" => "", "tool_calls" => [_]}] =
               Messages.normalize_chat(messages)
    end

    test "already-wire-shaped tool_calls pass through unchanged" do
      wire = %{"id" => "c1", "type" => "function", "function" => %{"name" => "t", "arguments" => "{}"}}
      messages = [%{"role" => "assistant", "content" => "hi", "tool_calls" => [wire]}]

      assert [%{"role" => "assistant", "content" => "hi", "tool_calls" => [^wire]}] =
               Messages.normalize_chat(messages)
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
