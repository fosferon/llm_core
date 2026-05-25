defmodule LlmCore.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.{Error, OpenAI}

  describe "build_stream_body/2" do
    test "requests usage in streamed completions" do
      body = OpenAI.build_stream_body("hello", model: "gpt-4o-mini", max_tokens: 32)

      assert body.model == "gpt-4o-mini"
      assert body.messages == [%{"role" => "user", "content" => "hello"}]
      assert body.stream == true
      assert body.stream_options == %{include_usage: true}
      assert body.max_tokens == 32
    end
  end

  describe "decode_stream_chunk/2" do
    test "keeps content chunks as strings and emits final usage distinctly" do
      chunk = """
      data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}

      data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}

      data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":5,\"total_tokens\":12}}

      data: [DONE]
      """

      assert {events, true, true} = OpenAI.decode_stream_chunk(chunk)

      assert events == [
               "Hel",
               "lo",
               {:usage, %{prompt_tokens: 7, completion_tokens: 5, total_tokens: 12}}
             ]
    end

    test "emits empty usage when the stream ends without provider usage" do
      chunk = """
      data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}

      data: [DONE]
      """

      assert {["Hi", {:usage, %{}}], true, false} = OpenAI.decode_stream_chunk(chunk)
    end

    test "does not duplicate usage when done arrives after a prior usage chunk" do
      assert {[], true, true} = OpenAI.decode_stream_chunk("data: [DONE]", true)
    end

    test "surfaces provider errors distinctly" do
      chunk = """
      data: {\"error\":{\"message\":\"rate limited\",\"type\":\"rate_limit\"}}
      """

      assert {[{:error, %Error{} = error}], false, false} = OpenAI.decode_stream_chunk(chunk)
      assert error.type == :provider_error
      assert error.message == "rate limited"
      assert error.provider == :openai
    end
  end
end
