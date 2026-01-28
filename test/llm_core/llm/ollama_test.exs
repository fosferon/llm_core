defmodule LlmCore.LLM.OllamaTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Ollama

  describe "build_payload/3" do
    test "wraps string prompts into user message" do
      payload = Ollama.build_payload("hello", :send, [])
      default_model = Application.get_env(:llm_core, :ollama_default_model, "llama3.1:8b")

      assert payload["messages"] == [%{"role" => "user", "content" => "hello"}]
      assert payload["model"] == default_model
    end

    test "normalizes chat messages" do
      payload =
        Ollama.build_payload(
          [
            %{role: :system, content: "sys"},
            %{role: :user, content: "user"}
          ],
          :send,
          []
        )

      assert [%{"role" => "system", "content" => "sys"}, %{"role" => "user", "content" => "user"}] =
               payload["messages"]
    end

    test "includes generation options" do
      payload = Ollama.build_payload("hello", :send, temperature: 0.2, top_p: 0.95)
      assert payload["options"]["temperature"] == 0.2
      assert payload["options"]["top_p"] == 0.95
    end

    test "applies structured output instructions" do
      schema = %{type: "object", properties: %{answer: %{type: "string"}}}

      payload =
        Ollama.build_payload("hello", :send, response_format: {:json_schema, schema})

      [system_msg | _] = payload["messages"]
      assert system_msg["role"] == "system"
      assert payload["format"] == "json"
      assert String.contains?(system_msg["content"], "answer")
    end
  end

  describe "normalize_messages/1" do
    test "returns default when list is invalid" do
      assert [%{"role" => "user", "content" => ""}] = Ollama.normalize_messages([%{}])
    end
  end
end
