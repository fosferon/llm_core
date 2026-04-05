defmodule LlmCore.Tool do
  @moduledoc """
  Provider-neutral tool definition.

  A tool is a pure data structure: name, description, and a JSON Schema
  describing the parameters the tool accepts. The callback (how to actually
  execute the tool) is **not** part of this struct — it is resolved at
  runtime by the host application via a resolver function or behaviour.

  This separation ensures tool definitions are serializable (YAML config,
  MCP exposure, storage) while callbacks remain a runtime concern.

  ## Fields

    * `name` - Unique tool identifier (required)
    * `description` - Human-readable description for the LLM (required)
    * `parameters` - JSON Schema map describing accepted arguments (required)
    * `metadata` - Optional map for tags, version, source, etc.

  ## Examples

      iex> LlmCore.Tool.new(%{
      ...>   name: "hindsight_recall",
      ...>   description: "Search semantic memory banks",
      ...>   parameters: %{
      ...>     "type" => "object",
      ...>     "properties" => %{
      ...>       "query" => %{"type" => "string"}
      ...>     },
      ...>     "required" => ["query"]
      ...>   }
      ...> })
      {:ok,
       %LlmCore.Tool{
         name: "hindsight_recall",
         description: "Search semantic memory banks",
         parameters: %{
           "type" => "object",
           "properties" => %{"query" => %{"type" => "string"}},
           "required" => ["query"]
         },
         metadata: %{}
       }}
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          metadata: map()
        }

  @enforce_keys [:name, :description, :parameters]
  defstruct [:name, :description, :parameters, metadata: %{}]

  @doc """
  Creates a new Tool from a map of attributes.

  Returns `{:ok, tool}` on success or `{:error, reason}` when required
  fields are missing or invalid.

  ## Parameters

    * `attrs` - Map with `:name` / `"name"`, `:description` / `"description"`,
      `:parameters` / `"parameters"`, and optional `:metadata` / `"metadata"`.

  ## Examples

      iex> LlmCore.Tool.new(%{name: "ping", description: "Ping", parameters: %{"type" => "object"}})
      {:ok, %LlmCore.Tool{name: "ping", description: "Ping", parameters: %{"type" => "object"}, metadata: %{}}}

      iex> LlmCore.Tool.new(%{name: "ping"})
      {:error, {:missing_keys, ["description", "parameters"]}}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    name = get_field(attrs, :name)
    description = get_field(attrs, :description)
    parameters = get_field(attrs, :parameters)
    metadata = get_field(attrs, :metadata) || %{}

    missing =
      []
      |> maybe_missing(name, "name")
      |> maybe_missing(description, "description")
      |> maybe_missing(parameters, "parameters")

    cond do
      missing != [] ->
        {:error, {:missing_keys, Enum.reverse(missing)}}

      not is_binary(name) ->
        {:error, {:invalid_field, :name, "must be a string"}}

      not is_binary(description) ->
        {:error, {:invalid_field, :description, "must be a string"}}

      not is_map(parameters) ->
        {:error, {:invalid_field, :parameters, "must be a map"}}

      not is_map(metadata) ->
        {:error, {:invalid_field, :metadata, "must be a map"}}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           description: description,
           parameters: parameters,
           metadata: metadata
         }}
    end
  end

  @doc """
  Creates a Tool from a plain map, typically loaded from YAML.

  Accepts string keys and converts them. Returns `{:ok, tool}` or
  `{:error, reason}`.

  ## Examples

      iex> LlmCore.Tool.from_map(%{"name" => "ping", "description" => "Ping", "parameters" => %{"type" => "object"}})
      {:ok, %LlmCore.Tool{name: "ping", description: "Ping", parameters: %{"type" => "object"}, metadata: %{}}}
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map), do: new(map)

  # -- Private helpers -------------------------------------------------------

  defp get_field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_missing(acc, nil, field), do: [field | acc]
  defp maybe_missing(acc, _value, _field), do: acc
end
