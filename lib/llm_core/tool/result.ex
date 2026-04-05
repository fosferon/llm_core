defmodule LlmCore.Tool.Result do
  @moduledoc """
  The result of executing a tool call.

  After the host application resolves and executes a `LlmCore.Tool.Call`,
  the outcome is wrapped in a `Result` struct before being fed back to the
  LLM via `LlmCore.Tool.Codec.encode_result/2`.

  ## Fields

    * `tool_call_id` - Matches the originating `Call.id` (string or nil)
    * `name` - The tool name that was executed
    * `content` - String content returned by the tool

  ## Examples

      %LlmCore.Tool.Result{
        tool_call_id: "call_abc123",
        name: "hindsight_recall",
        content: "Found 3 relevant memories..."
      }
  """

  @type t :: %__MODULE__{
          tool_call_id: String.t() | nil,
          name: String.t(),
          content: String.t()
        }

  @enforce_keys [:name, :content]
  defstruct [:tool_call_id, :name, :content]

  @doc """
  Creates a new Result struct from a map of attributes.

  ## Parameters

    * `attrs` - Map with `:name` / `"name"`, `:content` / `"content"`,
      and optional `:tool_call_id` / `"tool_call_id"`.

  ## Examples

      iex> LlmCore.Tool.Result.new(%{name: "ping", content: "pong"})
      {:ok, %LlmCore.Tool.Result{tool_call_id: nil, name: "ping", content: "pong"}}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    name = get_field(attrs, :name)
    content = get_field(attrs, :content)
    tool_call_id = get_field(attrs, :tool_call_id)

    cond do
      is_nil(name) ->
        {:error, {:missing_keys, ["name"]}}

      is_nil(content) ->
        {:error, {:missing_keys, ["content"]}}

      not is_binary(name) ->
        {:error, {:invalid_field, :name, "must be a string"}}

      not is_binary(content) ->
        {:error, {:invalid_field, :content, "must be a string"}}

      true ->
        {:ok, %__MODULE__{tool_call_id: tool_call_id, name: name, content: content}}
    end
  end

  defp get_field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
