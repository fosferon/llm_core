defmodule LlmCore.Tool.Codec do
  @moduledoc """
  Translates between provider-neutral tool structs and provider-specific
  wire formats.

  Three operations, three providers:

    * `encode_definitions/2` — Converts `[LlmToolkit.Tool.t()]` into the
      provider's request payload format for tool declarations.
    * `decode_tool_calls/2` — Extracts `[LlmToolkit.Tool.Call.t()]` from a
      raw provider response body.
    * `encode_result/2` — Formats a `LlmToolkit.Tool.Result.t()` as the
      provider's expected tool-result message.

  ## Provider Format Differences

  | Aspect             | OpenAI                    | Anthropic              | Ollama                    |
  |--------------------|---------------------------|------------------------|---------------------------|
  | Definition key     | `parameters`              | `input_schema`         | `parameters`              |
  | Definition wrapper | `{type, function: {...}}` | `{name, desc, schema}` | `{type, function: {...}}` |
  | Call arguments     | JSON **string**           | **object**             | **object**                |
  | Call ID            | present                   | present                | absent                    |
  | Result role        | `"tool"`                  | `"user"`               | `"tool"`                  |
  | Result ID ref      | `tool_call_id`            | `tool_use_id`          | (none)                    |
  """

  alias LlmToolkit.Tool
  alias LlmToolkit.Tool.Call

  @type provider :: :openai | :anthropic | :ollama

  # ---------------------------------------------------------------------------
  # encode_definitions
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a list of provider-neutral tool definitions into the wire format
  expected by the given provider.

  ## Examples

      iex> tool = %LlmToolkit.Tool{name: "ping", description: "Ping", parameters: %{"type" => "object"}, metadata: %{}}
      iex> [encoded] = LlmCore.Tool.Codec.encode_definitions([tool], :openai)
      iex> encoded["type"]
      "function"
      iex> encoded["function"]["name"]
      "ping"
  """
  @spec encode_definitions([Tool.t()], provider()) :: [map()]
  def encode_definitions(tools, :openai) do
    Enum.map(tools, &encode_openai_definition/1)
  end

  def encode_definitions(tools, :anthropic) do
    Enum.map(tools, &encode_anthropic_definition/1)
  end

  def encode_definitions(tools, :ollama) do
    # Ollama uses the OpenAI wire format for definitions
    encode_definitions(tools, :openai)
  end

  # ---------------------------------------------------------------------------
  # decode_tool_calls
  # ---------------------------------------------------------------------------

  @doc """
  Decodes tool call requests from a raw provider response body into
  provider-neutral `LlmToolkit.Tool.Call` structs.

  ## OpenAI

  Expects `response_body["choices"][0]["message"]["tool_calls"]` where each
  entry has `"id"`, `"function" => %{"name" => ..., "arguments" => json_string}`.

  ## Anthropic

  Expects `response_body["content"]` to contain blocks with
  `"type" => "tool_use"`, each having `"id"`, `"name"`, and `"input"` (object).

  ## Ollama

  Expects `response_body["message"]["tool_calls"]` where each entry has
  `"function" => %{"name" => ..., "arguments" => object}`. No IDs.

  Returns an empty list when no tool calls are found.
  """
  @spec decode_tool_calls(map(), provider()) :: [Call.t()]
  def decode_tool_calls(response_body, :openai) do
    response_body
    |> get_in(["choices", Access.at(0), "message", "tool_calls"])
    |> List.wrap()
    |> Enum.map(&decode_openai_call/1)
  end

  def decode_tool_calls(response_body, :anthropic) do
    response_body
    |> Map.get("content", [])
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(&decode_anthropic_call/1)
  end

  def decode_tool_calls(response_body, :ollama) do
    response_body
    |> get_in(["message", "tool_calls"])
    |> List.wrap()
    |> Enum.map(&decode_ollama_call/1)
  end

  # ---------------------------------------------------------------------------
  # encode_result
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a tool result into the message format the provider expects when
  feeding results back into the conversation.

  ## OpenAI

      %{"role" => "tool", "tool_call_id" => id, "content" => content}

  ## Anthropic

      %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => content}]}

  ## Ollama

      %{"role" => "tool", "content" => content}
  """
  @spec encode_result(LlmToolkit.Tool.Result.t(), provider()) :: map()
  def encode_result(%LlmToolkit.Tool.Result{} = result, :openai) do
    %{
      "role" => "tool",
      "tool_call_id" => result.tool_call_id,
      "content" => result.content
    }
  end

  def encode_result(%LlmToolkit.Tool.Result{} = result, :anthropic) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => result.tool_call_id,
          "content" => result.content
        }
      ]
    }
  end

  def encode_result(%LlmToolkit.Tool.Result{} = result, :ollama) do
    %{
      "role" => "tool",
      "content" => result.content
    }
  end

  # ---------------------------------------------------------------------------
  # Private — OpenAI
  # ---------------------------------------------------------------------------

  defp encode_openai_definition(%Tool{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    }
  end

  defp decode_openai_call(%{"id" => id, "function" => function}) do
    arguments = parse_arguments(function["arguments"])

    %Call{
      id: id,
      name: function["name"],
      arguments: arguments
    }
  end

  defp decode_openai_call(_), do: %Call{id: nil, name: "unknown", arguments: %{}}

  # ---------------------------------------------------------------------------
  # Private — Anthropic
  # ---------------------------------------------------------------------------

  defp encode_anthropic_definition(%Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.parameters
    }
  end

  defp decode_anthropic_call(%{"id" => id, "name" => name, "input" => input}) do
    %Call{
      id: id,
      name: name,
      arguments: ensure_map(input)
    }
  end

  defp decode_anthropic_call(_), do: %Call{id: nil, name: "unknown", arguments: %{}}

  # ---------------------------------------------------------------------------
  # Private — Ollama
  # ---------------------------------------------------------------------------

  defp decode_ollama_call(%{"function" => function}) do
    %Call{
      id: nil,
      name: function["name"],
      arguments: ensure_map(function["arguments"])
    }
  end

  defp decode_ollama_call(_), do: %Call{id: nil, name: "unknown", arguments: %{}}

  # ---------------------------------------------------------------------------
  # Private — Helpers
  # ---------------------------------------------------------------------------

  # OpenAI returns arguments as a JSON-encoded string; parse it.
  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}
end
