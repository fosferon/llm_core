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

    # OpenAI-compatible servers send "finish_reason": null on every intermediate
    # chunk, including role-only deltas; those must not end the stream early.
    test "a null finish_reason on a role-only delta does not terminate the stream" do
      chunk = """
      data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}

      data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":null}]}
      """

      assert {["Hi"], false} = Appliance.decode_stream_chunk(chunk)
    end

    test "a non-null finish_reason ends the stream" do
      chunk = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n"

      assert {[], true} = Appliance.decode_stream_chunk(chunk)
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

  describe "build_response/2 with malformed choices" do
    test "a string where a choice object belongs yields empty content, not a raise" do
      response = Appliance.build_response(%{"choices" => ["garbage"], "model" => "m"}, [])

      assert response.content == ""
      assert response.model == "m"
      assert response.metadata[:finish_reason] == nil
    end

    test "a string where the message object belongs yields empty content" do
      body = %{"choices" => [%{"message" => "garbage", "finish_reason" => "stop"}]}
      response = Appliance.build_response(body, [])

      assert response.content == ""
      assert response.metadata[:finish_reason] == "stop"
    end

    test "choices missing or nil yields empty content" do
      assert Appliance.build_response(%{"id" => "x"}, []).content == ""
      assert Appliance.build_response(%{"choices" => nil}, []).content == ""
    end

    test "finish_reason tool_calls with a string message yields no tool calls, not a raise" do
      body = %{"choices" => [%{"message" => "garbage", "finish_reason" => "tool_calls"}]}
      response = Appliance.build_response(body, [])

      assert response.content == ""
      assert response.tool_calls == []
      assert response.metadata[:finish_reason] == "tool_calls"
    end

    test "a well-formed tool call is still decoded (no regression)" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "lookup", "arguments" => "{\"q\":\"x\"}"}
                }
              ]
            }
          }
        ]
      }

      response = Appliance.build_response(body, [])

      assert [%{name: "lookup"}] = response.tool_calls
    end

    test "a non-object usage field is ignored instead of raising" do
      for bad <- ["none", [], 7, nil] do
        response = Appliance.build_response(%{"choices" => [], "usage" => bad}, [])
        assert response.usage == %{}
      end
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

    # LM Studio reports a context overflow as 400 {"error": "<string>"}; the old
    # get_in(body, ["error", "message"]) raised FunctionClauseError in Access.get/3
    # on that string, so a prompt-too-long was logged as a parser crash.
    test "map body with a string-valued error keeps the string as the message" do
      msg =
        "The number of tokens to keep from the initial prompt is greater than the context length"

      error = Appliance.classify_error(400, %{"error" => msg})

      assert %Error{type: :provider_error} = error
      assert error.message == msg
      assert error.details.status == 400
      assert error.details.body == %{"error" => msg}
    end

    test "map body with a nil, list or empty-string error falls back to the status" do
      for bad <- [nil, ["boom"], "", %{"code" => 7}, 42] do
        error = Appliance.classify_error(400, %{"error" => bad})
        assert error.message == "Appliance API error (status 400)"
      end
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

  describe "probe connection isolation (GC-5857)" do
    test "health probe sends connection: close" do
      {port, request_task} = start_probe_server("ok")

      assert Appliance.health("http://127.0.0.1:#{port}")

      request = Task.await(request_task, 5_000)

      assert request =~ "GET /health"
      assert String.downcase(request) =~ "connection: close"
    end

    test "probe options isolate the request and bound the pool wait" do
      opts = Appliance.probe_options(2_000)

      assert opts[:headers] == [{"connection", "close"}]
      assert opts[:pool_timeout] == 2_000
      assert opts[:receive_timeout] == 2_000
      assert opts[:retry] == false
    end
  end

  defp start_probe_server(body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        request = recv_request_headers(socket, "")

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: text/plain\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        request
      end)

    {port, task}
  end

  defp recv_request_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> recv_request_headers(socket, acc <> chunk)
        {:error, _} -> acc
      end
    end
  end
end
