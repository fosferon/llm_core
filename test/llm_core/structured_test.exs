defmodule LlmCore.StructuredTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Response
  alias LlmCore.Structured

  defmodule MockSchema do
    def validate(%{"foo" => value}), do: {:ok, %{foo: value}}
    def validate(_), do: {:error, :invalid}
  end

  test "process without format returns original result" do
    response = Response.new(content: "hello", provider: :test)
    assert {:ok, ^response} = Structured.process({:ok, response}, nil)
  end

  test "json_schema format decodes JSON and stores structured value" do
    response = Response.new(content: ~s({"foo": "bar"}), provider: :test)

    assert {:ok, updated} = Structured.process({:ok, response}, {:json_schema, %{}})
    assert updated.structured == %{"foo" => "bar"}
    assert updated.metadata[:structured_format] == :json_schema
  end

  test "json_schema map schema enforces required keys" do
    response = Response.new(content: ~s({"foo": "bar"}), provider: :test)
    schema = %{required: ["foo"]}

    assert {:ok, updated} = Structured.process({:ok, response}, {:json_schema, schema})
    assert updated.structured == %{"foo" => "bar"}
  end

  test "json_schema map schema errors on missing keys" do
    response = Response.new(content: ~s({"foo": "bar"}), provider: :test)
    schema = %{required: ["bar"]}

    assert {:error, {:structured_output_error, {:missing_keys, ["bar"]}}} =
             Structured.process({:ok, response}, {:json_schema, schema})
  end

  test "json_schema format can use validator" do
    response = Response.new(content: ~s({"foo": "bar"}))

    validator = fn value ->
      if Map.has_key?(value, "foo"), do: {:ok, value["foo"]}, else: {:error, :missing}
    end

    assert {:ok, updated} =
             Structured.process({:ok, response}, {:json_schema, %{}, validator: validator})

    assert updated.structured == "bar"
  end

  test "module schema validation" do
    response = Response.new(content: ~s({"foo": "bar"}))

    assert {:ok, updated} =
             Structured.process({:ok, response}, {:json_schema, MockSchema})

    assert updated.structured == %{foo: "bar"}
  end

  test "json_schema validation failure returns error" do
    response = Response.new(content: ~s({"foo": "bar"}))

    validator = fn _ -> {:error, :bad_schema} end

    assert {:error, {:structured_output_error, :bad_schema}} =
             Structured.process({:ok, response}, {:json_schema, %{}, validator: validator})
  end

  test "invalid json returns error" do
    response = Response.new(content: "not json")

    assert {:error, {:structured_output_error, {:invalid_json, _}}} =
             Structured.process({:ok, response}, {:json_schema, %{}})
  end

  test "instructor adapter reports availability" do
    adapter = LlmCore.Structured.InstructorAdapter

    if adapter.available?() do
      assert function_exported?(adapter, :chat_completion, 2)
    else
      assert {:error, _} = adapter.chat_completion([], nil)
    end
  end
end
