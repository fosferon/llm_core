defmodule LlmCore.Config.Editor do
  @moduledoc """
  Helpers for reading and mutating `llm_core.toml` files.

  The editor focuses on the project-level file but accepts custom paths so
  callers (mix tasks, tests) can operate on ad-hoc configs without touching
  user data.
  """

  alias LlmCore.Config.TomlWriter
  alias LlmCore.Paths

  @doc """
  Returns the default path to the project-level `llm_core.toml` file.
  """
  @spec default_path() :: String.t()
  def default_path do
    Paths.project_config_dir()
    |> Path.join("llm_core.toml")
    |> Path.expand()
  end

  @doc """
  Reads and decodes the TOML configuration file at `path`.

  Returns `{:ok, map()}` with the parsed contents, or `{:ok, %{}}` if the
  file does not exist.
  """
  @spec read(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read(path \\ default_path()) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:invalid_toml, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Encodes `map` as TOML and writes it to `path`, creating parent directories
  as needed.
  """
  @spec write(map(), String.t() | nil) :: :ok | {:error, term()}
  def write(map, path \\ default_path()) when is_map(map) do
    with {:ok, encoded} <- TomlWriter.encode(map) do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write(path, encoded <> "\n")
    end
  end

  @doc """
  Reads the config at `path`, applies the transformation function `fun`, and
  writes the result back.

  Returns `{:ok, new_config}` on success.
  """
  @spec update((map() -> map()), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def update(fun, path \\ default_path()) when is_function(fun, 1) do
    with {:ok, config} <- read(path) do
      new_config = fun.(config)
      :ok = write(new_config, path)
      {:ok, new_config}
    end
  end

  @doc """
  Sets a nested value in `config` at the given key path.

  Creates intermediate maps as needed.
  """
  @spec put_path(map(), [String.t()], term()) :: map()
  def put_path(config, [], _value), do: config

  def put_path(config, [key], value) do
    Map.put(config, key, value)
  end

  def put_path(config, [key | rest], value) do
    existing = Map.get(config, key, %{})

    updated =
      existing
      |> ensure_map()
      |> put_path(rest, value)

    Map.put(config, key, updated)
  end

  @doc """
  Removes the value at the given key path from `config`.
  """
  @spec delete_path(map(), [String.t()]) :: map()
  def delete_path(config, []), do: config

  def delete_path(config, [key]) do
    Map.delete(config, key)
  end

  def delete_path(config, [key | rest]) do
    case Map.get(config, key) do
      nil -> config
      value -> Map.put(config, key, delete_path(value, rest))
    end
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}
end
