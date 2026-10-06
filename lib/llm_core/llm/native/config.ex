defmodule LlmCore.LLM.Native.Config do
  @moduledoc """
  The `[native]` configuration for the Native agentic loop.

  llm_core ships **no** native cascade, default models, or model-routing
  patterns: which providers a deployment can run, and in what order, is that
  deployment's decision. Configure it in any config layer (bundled base, home,
  project, `LLM_CORE_CONFIG`):

      [native]
      cascade = ["my_local", "my_cloud"]

      [native.default_models]
      my_cloud = "some-model-id"

      [[native.model_routing]]
      pattern = "some-substring"
      provider = "my_cloud"

  When `cascade` is missing or empty, the Native loop falls back to the single
  provider named by `[routing] default` (see `LlmCore.Router`). If that is also
  missing or cannot run the native loop, resolution fails with a structured
  `{:no_native_provider, details}` error instead of choosing a provider.

  Precedence: `config :llm_core, :native, ...` (explicit Elixir app env) beats
  the merged TOML layers. Layers are re-read on every config reload.
  """

  alias LlmCore.Config.Store

  @type t :: %{
          cascade: [String.t()],
          default_models: %{optional(String.t()) => String.t()},
          model_routing: [%{optional(String.t()) => String.t()}]
        }

  @doc "Returns the effective native config; every key is present, empty by default."
  @spec get() :: t()
  def get do
    case Application.get_env(:llm_core, :native) do
      env when is_map(env) and map_size(env) > 0 -> normalize(env)
      env when is_list(env) and env != [] -> normalize(Map.new(env))
      _ -> from_layers()
    end
  end

  @doc "Normalizes a string- or atom-keyed `[native]` map into the internal shape."
  @spec normalize(map()) :: t()
  def normalize(%{} = raw) do
    %{
      cascade: raw |> fetch(:cascade) |> list_of_strings(),
      default_models: raw |> fetch(:default_models) |> string_map(),
      model_routing: raw |> fetch(:model_routing) |> routing_entries()
    }
  end

  defp from_layers do
    case Store.fetch(:config, :raw) do
      {:ok, %{"native" => %{} = native}} -> normalize(native)
      _ -> normalize(%{})
    end
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp list_of_strings(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp list_of_strings(_), do: []

  defp string_map(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  defp string_map(_), do: %{}

  defp routing_entries(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{} = entry ->
        pattern = fetch(entry, :pattern)
        provider = fetch(entry, :provider)

        if is_binary(pattern) and pattern != "" and is_binary(provider) and provider != "" do
          [%{"pattern" => pattern, "provider" => provider}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp routing_entries(_), do: []
end
