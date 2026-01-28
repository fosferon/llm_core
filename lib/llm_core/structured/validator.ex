defmodule LlmCore.Structured.Validator do
  @moduledoc """
  Normalizes schema declarations and validates decoded structured data.

  The validator intentionally supports a small but extensible surface:

    * Function schemas – a single-arity validator function
    * Module schemas – modules that export `validate/1`, `cast/1`, `from_map/1`,
      or `changeset/2`
    * Map schemas – `%{required: [...], optional: [...]}` helpers or maps that
      enumerate fields
    * List schemas – treated as a list of required keys

  When no schema is provided, the decoded value is returned verbatim.
  """

  @type schema :: module() | map() | [atom() | String.t()] | (map() -> result()) | nil
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Validates the decoded payload against the supplied schema.
  """
  @spec validate(term(), schema(), keyword()) :: result()
  def validate(value, nil, _opts), do: {:ok, value}

  def validate(value, schema, _opts) when is_function(schema, 1) do
    safe_apply(schema, value)
  end

  def validate(value, schema, opts) when is_atom(schema) do
    module_validate(schema, value, opts)
  end

  def validate(value, schema, _opts) when is_map(schema) and map_size(schema) == 0 do
    {:ok, value}
  end

  def validate(value, schema, _opts) when is_map(schema) do
    map_validate(value, schema)
  end

  def validate(value, schema, _opts) when is_list(schema) do
    ensure_required_keys(value, schema)
  end

  def validate(value, _schema, _opts), do: {:ok, value}

  # -- function schemas -----------------------------------------------------

  defp safe_apply(fun, value) do
    case fun.(value) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:ok, other}
    end
  rescue
    error -> {:error, {:validator_exception, error}}
  end

  # -- module schemas -------------------------------------------------------

  defp module_validate(schema, value, opts) do
    cond do
      function_exported?(schema, :validate, 1) ->
        safe_apply(&schema.validate/1, value)

      function_exported?(schema, :cast, 1) ->
        safe_apply(&schema.cast/1, value)

      function_exported?(schema, :from_map, 1) ->
        safe_apply(&schema.from_map/1, value)

      function_exported?(schema, :new, 1) ->
        safe_apply(&schema.new/1, value)

      function_exported?(schema, :changeset, 2) and function_exported?(schema, :__struct__, 0) ->
        run_changeset(schema, value, opts)

      true ->
        {:error, {:unsupported_schema_module, schema}}
    end
  end

  defp run_changeset(schema, value, opts) do
    changeset = schema.changeset(struct(schema), value)
    action = Keyword.get(opts, :changeset_action, :insert)
    ecto_changeset = Module.concat(Ecto, Changeset)

    cond do
      function_exported?(ecto_changeset, :apply_action, 2) ->
        case ecto_changeset.apply_action(changeset, action) do
          {:ok, struct} -> {:ok, struct}
          {:error, reason} -> {:error, {:invalid_changeset, reason}}
        end

      function_exported?(ecto_changeset, :apply_changes, 1) ->
        {:ok, ecto_changeset.apply_changes(changeset)}

      true ->
        {:error, :ecto_not_available}
    end
  end

  # -- map schemas ----------------------------------------------------------

  defp map_validate(value, schema) when is_map(value) do
    required = Map.get(schema, :required) || Map.get(schema, "required") || []
    optional = Map.get(schema, :optional) || Map.get(schema, "optional") || []

    with {:ok, _} <- ensure_required_keys(value, required) do
      allowed = Enum.map(required ++ optional, &normalize_key/1)

      filtered =
        if allowed == [] do
          value
        else
          Enum.reduce(value, %{}, fn {k, v}, acc ->
            if normalize_key(k) in allowed do
              Map.put(acc, k, v)
            else
              acc
            end
          end)
        end

      {:ok, filtered}
    end
  end

  defp map_validate(_value, schema), do: {:error, {:invalid_value_for_schema, schema}}

  # -- helpers --------------------------------------------------------------

  defp ensure_required_keys(value, []), do: {:ok, value}

  defp ensure_required_keys(value, keys) when is_map(value) do
    missing =
      keys
      |> Enum.reject(fn key -> map_has_key?(value, key) end)
      |> Enum.map(&normalize_key/1)

    if missing == [], do: {:ok, value}, else: {:error, {:missing_keys, missing}}
  end

  defp ensure_required_keys(value, _keys) when is_list(value) do
    {:ok, value}
  end

  defp ensure_required_keys(_value, keys), do: {:error, {:invalid_required_keys, keys}}

  defp map_has_key?(map, key) when is_map(map) do
    normalized = normalize_key(key)

    Enum.any?(map, fn {existing_key, _value} ->
      normalize_key(existing_key) == normalized
    end)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
