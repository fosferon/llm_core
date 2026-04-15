defmodule LlmCore.Tool.Validator do
  @moduledoc """
  Validates tool call arguments against a tool's JSON Schema parameters.

  Performs lightweight, built-in validation without requiring an external
  JSON Schema library. Checks:

    * Required fields exist
    * Basic type checks (`string`, `number`, `integer`, `boolean`, `array`, `object`)
    * Enum membership when `"enum"` is specified in a property schema

  This is intentionally a *subset* of JSON Schema validation — sufficient
  for catching malformed LLM tool calls without pulling in a full schema
  validator dependency.
  """

  alias LlmToolkit.Tool
  alias LlmToolkit.Tool.Call

  @doc """
  Validates that a tool call's arguments satisfy the tool's parameter schema.

  Returns `:ok` when valid, or `{:error, reasons}` with a list of human-readable
  error strings.

  ## Examples

      iex> tool = %LlmToolkit.Tool{
      ...>   name: "search",
      ...>   description: "Search",
      ...>   parameters: %{
      ...>     "type" => "object",
      ...>     "properties" => %{
      ...>       "query" => %{"type" => "string"},
      ...>       "limit" => %{"type" => "integer"}
      ...>     },
      ...>     "required" => ["query"]
      ...>   },
      ...>   metadata: %{}
      ...> }
      iex> call = %LlmToolkit.Tool.Call{id: "1", name: "search", arguments: %{"query" => "hello"}}
      iex> LlmCore.Tool.Validator.validate_call(call, tool)
      :ok

      iex> bad_call = %LlmToolkit.Tool.Call{id: "2", name: "search", arguments: %{}}
      iex> LlmCore.Tool.Validator.validate_call(bad_call, tool)
      {:error, ["missing required field: query"]}
  """
  @spec validate_call(Call.t(), Tool.t()) :: :ok | {:error, [String.t()]}
  def validate_call(%Call{arguments: arguments}, %Tool{parameters: parameters}) do
    errors =
      []
      |> check_required(arguments, parameters)
      |> check_types(arguments, parameters)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  # ---------------------------------------------------------------------------
  # Required field checks
  # ---------------------------------------------------------------------------

  defp check_required(errors, arguments, %{"required" => required}) when is_list(required) do
    Enum.reduce(required, errors, fn field, acc ->
      if Map.has_key?(arguments, field) do
        acc
      else
        ["missing required field: #{field}" | acc]
      end
    end)
  end

  defp check_required(errors, _arguments, _parameters), do: errors

  # ---------------------------------------------------------------------------
  # Type checks
  # ---------------------------------------------------------------------------

  defp check_types(errors, arguments, %{"properties" => properties}) when is_map(properties) do
    Enum.reduce(arguments, errors, fn {key, value}, acc ->
      case Map.get(properties, key) do
        nil ->
          acc

        prop_schema ->
          acc
          |> check_type(key, value, prop_schema)
          |> check_enum(key, value, prop_schema)
      end
    end)
  end

  defp check_types(errors, _arguments, _parameters), do: errors

  defp check_type(errors, key, value, %{"type" => expected_type}) do
    if type_matches?(expected_type, value) do
      errors
    else
      ["field #{key}: expected type #{expected_type}, got #{inspect(value)}" | errors]
    end
  end

  defp check_type(errors, _key, _value, _prop_schema), do: errors

  # ---------------------------------------------------------------------------
  # Enum checks
  # ---------------------------------------------------------------------------

  defp check_enum(errors, key, value, %{"enum" => allowed}) when is_list(allowed) do
    if value in allowed do
      errors
    else
      ["field #{key}: value #{inspect(value)} not in allowed values #{inspect(allowed)}" | errors]
    end
  end

  defp check_enum(errors, _key, _value, _prop_schema), do: errors

  # ---------------------------------------------------------------------------
  # Type matching helpers
  # ---------------------------------------------------------------------------

  defp type_matches?("string", value), do: is_binary(value)
  defp type_matches?("number", value), do: is_number(value)
  defp type_matches?("integer", value), do: is_integer(value)
  defp type_matches?("boolean", value), do: is_boolean(value)
  defp type_matches?("array", value), do: is_list(value)
  defp type_matches?("object", value), do: is_map(value)
  defp type_matches?("null", value), do: is_nil(value)
  defp type_matches?(_, _value), do: true
end
