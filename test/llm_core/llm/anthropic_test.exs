defmodule LlmCore.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Anthropic

  setup do
    default_model = Application.get_env(:llm_core, :anthropic_default_model)
    max_tokens = Application.get_env(:llm_core, :anthropic_max_tokens)

    Application.put_env(:llm_core, :anthropic_default_model, "claude-test")
    Application.put_env(:llm_core, :anthropic_max_tokens, 512)

    on_exit(fn ->
      put_or_delete(:anthropic_default_model, default_model)
      put_or_delete(:anthropic_max_tokens, max_tokens)
    end)

    :ok
  end

  describe "build_payload/2" do
    test "normalizes prompts and carries defaults" do
      payload = Anthropic.build_payload("hello", [])

      assert payload["model"] == "claude-test"
      assert payload["max_tokens"] == 512

      [%{"role" => "user", "content" => [%{"type" => "text", "text" => content}]}] =
        payload["messages"]

      assert content == "hello"
    end

    test "extracts system prompts" do
      payload =
        Anthropic.build_payload([
          %{role: :system, content: "sys"},
          %{role: :user, content: "hi"}
        ])

      assert payload["system"] == "sys"
      assert [%{"role" => "user", "content" => _}] = payload["messages"]
    end

    test "embeds json schema response formats" do
      schema = %{type: "object", properties: %{answer: %{type: "string"}}}

      payload =
        Anthropic.build_payload("hi", response_format: {:json_schema, schema, name: "Reply"})

      assert %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "Reply", "schema" => ^schema, "strict" => true}
             } = payload["response_format"]
    end
  end

  test "extract_content/1 concatenates text blocks" do
    body = %{
      "content" => [
        %{"type" => "text", "text" => "foo"},
        %{"type" => "text", "text" => "bar"}
      ]
    }

    assert Anthropic.extract_content(body) == "foobar"
  end

  test "decode_stream_chunk/1 returns emitted text and done flag" do
    data = """
    event: content_block_delta
    data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}

    event: content_block_delta
    data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}

    event: message_stop
    data: {\"type\":\"message_stop\"}
    """

    assert {chunks, true} = Anthropic.decode_stream_chunk(data)
    assert chunks == ["Hel", "lo"]
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:llm_core, key)
  defp put_or_delete(key, value), do: Application.put_env(:llm_core, key, value)
end
