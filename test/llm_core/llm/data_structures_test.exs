defmodule LlmCore.LLM.DataStructuresTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.{Error, Provider, Response}

  describe "Response struct" do
    test "new/1 creates response with required fields" do
      response = Response.new(content: "Hello", provider: :claude_code, model: "claude-3")

      assert %Response{} = response
      assert response.content == "Hello"
      assert response.provider == :claude_code
      assert response.model == "claude-3"
    end

    test "new/1 accepts optional fields" do
      usage = %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
      raw = %{"id" => "resp-123"}
      metadata = %{latency_ms: 150}

      response =
        Response.new(
          content: "Test",
          provider: :openai,
          model: "gpt-4",
          usage: usage,
          raw: raw,
          metadata: metadata
        )

      assert response.usage == usage
      assert response.raw == raw
      assert response.metadata == metadata
    end
  end

  describe "Error struct" do
    test "new/2 builds error structs" do
      error = Error.new(:connection, message: "Connection refused")

      assert %Error{} = error
      assert error.type == :connection
      assert error.message == "Connection refused"
      assert %DateTime{} = error.timestamp
    end

    test "wrap/3 keeps provider details" do
      source_error = %{code: 500}

      error =
        Error.wrap(:provider_error, source_error,
          message: "Provider failed",
          provider: :openai
        )

      assert error.type == :provider_error
      assert error.details == source_error
      assert error.provider == :openai
    end
  end

  describe "Provider behaviour" do
    test "exports required callbacks" do
      callbacks = Provider.behaviour_info(:callbacks)

      assert {:send, 2} in callbacks
      assert {:stream, 2} in callbacks
      assert {:available?, 0} in callbacks
      assert {:capabilities, 0} in callbacks
      assert {:provider_type, 0} in callbacks
    end
  end
end
