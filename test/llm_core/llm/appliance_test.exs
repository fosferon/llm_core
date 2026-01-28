defmodule LlmCore.LLM.ApplianceTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Appliance

  describe "build_payload/2" do
    test "normalizes chat prompts and sets defaults" do
      Application.put_env(:llm_core, :appliance_default_model, "qwen3:14b")
      Application.put_env(:llm_core, :appliance_max_tokens, 256)

      payload = Appliance.build_payload("hello", [])

      assert payload["model"] == "qwen3:14b"
      assert payload["max_tokens"] == 256
      assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    after
      Application.delete_env(:llm_core, :appliance_default_model)
      Application.delete_env(:llm_core, :appliance_max_tokens)
    end

    test "includes json schema response formats" do
      schema = %{type: "object", properties: %{answer: %{type: "string"}}}

      payload =
        Appliance.build_payload("hi", response_format: {:json_schema, schema, name: "Reply"})

      assert %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "Reply", "schema" => ^schema, "strict" => true}
             } = payload["response_format"]
    end
  end

  describe "decode_stream_chunk/1" do
    test "extracts deltas and notices done" do
      chunk = """
      data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}

      data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}

      data: [DONE]
      """

      assert {chunks, true} = Appliance.decode_stream_chunk(chunk)
      assert chunks == ["Hel", "lo"]
    end
  end

  describe "discover/0" do
    test "returns configured endpoints" do
      Application.put_env(:llm_core, :appliance_endpoints, [%{name: "spark", url: "http://a"}])

      assert [{"spark", %URI{scheme: "http"}}] = Appliance.discover()
    after
      Application.delete_env(:llm_core, :appliance_endpoints)
    end
  end
end
