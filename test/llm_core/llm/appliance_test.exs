defmodule LlmCore.LLM.ApplianceTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.{Appliance, Error, Response}

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

  # Regression for GC-3389: LM Studio returns a bare JSON string body (e.g.
  # "Model unloaded." on idle model-unload) instead of an object. Both the
  # success path (build_response/2) and the error path (classify_error/2)
  # used to raise FunctionClauseError/ArgumentError on non-map bodies.
  describe "build_response/2 with non-map bodies" do
    test "bare binary body surfaces the string as content without raising" do
      response = Appliance.build_response("Model unloaded.", [])

      assert %Response{} = response
      assert response.provider == :appliance
      assert response.content == "Model unloaded."
      assert response.usage == %{}
      assert is_nil(response.tool_calls)
      assert response.raw == "Model unloaded."
      assert is_nil(response.metadata[:finish_reason])
    end

    test "list body does not raise" do
      response = Appliance.build_response(["Model unloaded."], [])

      assert %Response{} = response
      assert response.content == "Model unloaded."
      assert response.usage == %{}
      assert response.raw == ["Model unloaded."]
    end

    test "nil body does not raise" do
      response = Appliance.build_response(nil, [])

      assert %Response{} = response
      assert response.content == ""
      assert response.usage == %{}
      assert is_nil(response.raw)
    end

    test "map body still parses choices and usage (no regression)" do
      body = %{
        "id" => "chatcmpl-1",
        "model" => "qwen3:8b",
        "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "hi"}}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }

      response = Appliance.build_response(body, [])

      assert response.content == "hi"
      assert response.model == "qwen3:8b"

      assert response.usage == %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}
      assert response.metadata[:finish_reason] == "stop"
    end
  end

  describe "classify_error/2 with non-map bodies" do
    test "bare binary body preserves the diagnostic text" do
      error = Appliance.classify_error(500, "Model unloaded.")

      assert %Error{} = error
      assert error.message == "Model unloaded."
      assert error.details.status == 500
      assert error.details.body == "Model unloaded."
    end

    test "list body falls back to the status message without raising" do
      error = Appliance.classify_error(503, ["boom"])

      assert error.message == "Appliance API error (status 503)"
      assert error.details.body == ["boom"]
    end

    test "nil body falls back to the status message without raising" do
      error = Appliance.classify_error(500, nil)

      assert error.message == "Appliance API error (status 500)"
      assert error.details.body == nil
    end

    test "empty binary body falls back to the status message" do
      error = Appliance.classify_error(500, "")

      assert error.message == "Appliance API error (status 500)"
    end

    test "map body still extracts the nested error message (no regression)" do
      error = Appliance.classify_error(400, %{"error" => %{"message" => "bad request"}})

      assert error.message == "bad request"
      assert error.details.status == 400
    end

    test "map body without a nested message falls back to the status" do
      error = Appliance.classify_error(418, %{"foo" => "bar"})

      assert error.message == "Appliance API error (status 418)"
    end

    test "status code still maps to the correct error type" do
      assert Appliance.classify_error(401, "nope").type == :authentication
      assert Appliance.classify_error(403, "nope").type == :authentication
      assert Appliance.classify_error(429, "nope").type == :rate_limit
      assert Appliance.classify_error(408, "nope").type == :timeout
      assert Appliance.classify_error(504, "nope").type == :timeout
      assert Appliance.classify_error(500, "nope").type == :provider_error
    end
  end
end
