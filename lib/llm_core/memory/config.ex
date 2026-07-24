defmodule LlmCore.Memory.Config do
  @moduledoc false

  @ets_table :llm_core_memory_config
  @runtime_override_key :runtime_override

  @backends %{
    hindsight_rest: LlmCore.Memory.Backend.HindsightREST,
    foresight_http: LlmCore.Memory.Backend.ForesightHTTP,
    foresight_inprocess: LlmCore.Memory.Backend.ForesightInProcess
  }

  @spec backend() :: atom()
  def backend, do: Map.get(runtime_config(), :backend, :hindsight_rest)

  @spec backend_module() :: module()
  def backend_module, do: Map.fetch!(@backends, backend())

  @spec backend_options(atom()) :: map()
  def backend_options(backend \\ backend()) do
    options =
      runtime_config()
      |> Map.get(backend, %{})
      |> normalize_map()

    if backend == :foresight_http do
      Map.put_new(options, :url, "http://localhost:4012")
    else
      options
    end
  end

  @spec set_runtime_override(map()) :: :ok | {:error, {:invalid_memory_backend, term()}}
  def set_runtime_override(config) when is_map(config) do
    with {:ok, backend} <- parse_backend(get_value(config, :backend)) do
      ensure_ets_table()
      :ets.insert(@ets_table, {@runtime_override_key, normalize_memory_config(config, backend)})
      :ok
    end
  end

  @spec clear_runtime_override() :: :ok
  def clear_runtime_override do
    ensure_ets_table()
    :ets.delete(@ets_table, @runtime_override_key)
    :ok
  end

  @spec namespace(String.t() | nil, String.t() | nil) :: {atom(), String.t() | nil, String.t()}
  def namespace(url, bank_id), do: {backend(), url, bank_id || "default"}

  defp runtime_config do
    ensure_ets_table()

    case :ets.lookup(@ets_table, @runtime_override_key) do
      [{@runtime_override_key, config}] -> config
      _ -> %{}
    end
  end

  defp normalize_memory_config(config, backend) do
    %{
      backend: backend,
      hindsight_rest:
        config
        |> backend_section(:hindsight_rest, :hindsight)
        |> normalize_map(),
      foresight_http:
        config
        |> backend_section(:foresight_http, :foresight)
        |> normalize_map(),
      foresight_inprocess:
        config
        |> backend_section(:foresight_inprocess, :foresight)
        |> normalize_map()
    }
  end

  defp backend_section(config, primary, fallback) do
    get_value(config, primary) || get_value(config, fallback) || %{}
  end

  defp get_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp parse_backend(nil), do: {:ok, :hindsight_rest}

  defp parse_backend(value) when is_atom(value) do
    if Map.has_key?(@backends, value),
      do: {:ok, value},
      else: {:error, {:invalid_memory_backend, value}}
  end

  defp parse_backend(value) when is_binary(value) do
    case Enum.find(Map.keys(@backends), &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_memory_backend, value}}
      backend -> {:ok, backend}
    end
  end

  defp parse_backend(value), do: {:error, {:invalid_memory_backend, value}}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        normalized = String.replace(key, "-", "_")
        atom_key = Enum.find(known_option_keys(), key, &(Atom.to_string(&1) == normalized))
        {atom_key, value}

      pair ->
        pair
    end)
  end

  defp normalize_map(_value), do: %{}

  defp known_option_keys do
    [
      :url,
      :enabled,
      :default_bank_id,
      :tenant_id,
      :mode,
      :role_name,
      :prefix,
      :embedding_dim,
      :module,
      :context_module
    ]
  end

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public])
    end
  end
end
