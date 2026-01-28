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
  end
end
