defmodule LlmCore.Config.TomlWriter do
  @moduledoc false

  @doc """
  Encodes a nested map into a TOML document.

  Supports strings, numbers, booleans, lists, and inline maps. This encoder is
  intentionally minimal – it produces deterministic output suitable for the
  llm_core configuration file.
  """
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(map) when is_map(map) do
    try do
      lines = build_root(map)
      {:ok, Enum.join(lines, "\n") |> String.trim()}
    rescue
      exception -> {:error, exception}
    end
  end

  defp build_root(map) do
    {scalars, tables} = split_map(map)

    scalar_lines =
      scalars
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(&format_scalar/1)

    table_lines =
      tables
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.flat_map(fn {key, value} -> encode_table([key], value) end)

    scalar_lines ++ blank_between(scalar_lines, table_lines) ++ table_lines
  end

  defp encode_table(path, map) when is_map(map) do
    header = "[#{Enum.join(Enum.map(path, &escape_key/1), ".")}]"
    {scalars, tables} = split_map(map)

    scalar_lines =
      scalars
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(&format_scalar/1)

    nested_lines =
      tables
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.flat_map(fn {key, value} -> encode_table(path ++ [key], value) end)

    [header]
    |> add_block(scalar_lines)
    |> add_block(nested_lines)
  end

  defp split_map(map) do
    Enum.split_with(map, fn {_k, v} -> not is_map(v) or inline_table?(v) end)
  end

  defp inline_table?(map) when is_map(map) do
    Enum.all?(map, fn {_k, v} -> not is_map(v) end)
  end

  defp inline_table?(_), do: false

  defp format_scalar({key, value}) do
    "#{escape_key(key)} = #{format_value(value)}"
  end

  defp format_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp format_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value),
    do: :io_lib.format("~.6f", [value]) |> IO.iodata_to_binary()

  defp format_value(list) when is_list(list) do
    formatted = list |> Enum.map(&format_value/1) |> Enum.join(", ")
    "[#{formatted}]"
  end

  defp format_value(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "#{escape_key(k)} = #{format_value(v)}" end)
      |> Enum.join(", ")

    "{ #{entries} }"
  end

  defp format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(%Date{} = value), do: Date.to_iso8601(value)
  defp format_value(%Time{} = value), do: Time.to_iso8601(value)

  defp format_value(other), do: inspect(other)

  defp escape_key(key) when is_atom(key), do: Atom.to_string(key)
  defp escape_key(key) when is_binary(key), do: key
  defp escape_key(key), do: to_string(key)

  defp blank_between([], []), do: []
  defp blank_between([], _tables), do: [""]
  defp blank_between(_scalars, []), do: []
  defp blank_between(_scalars, _tables), do: [""]

  defp add_block(lines, []), do: lines

  defp add_block(lines, block) do
    case lines do
      [] -> block
      _ -> lines ++ [""] ++ block
    end
  end
end
