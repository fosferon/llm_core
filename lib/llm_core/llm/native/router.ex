defmodule LlmCore.LLM.Native.Router do
  @moduledoc """
  Config-driven provider resolution for the Native agentic loop.

  Resolves a provider name (or nil for cascade) into a fully-configured
  `{module, model, provider_opts}` tuple. Provider definitions are loaded
  from TOML at startup and stored in `LlmCore.Config.Store`.

  ## Resolution Logic

    1. Explicit provider (`llm_provider: "zai"`) → look up Definition by name/alias
    2. Model routing (`model` matches a pattern) → look up Definition for matched provider
    3. Cascade → walk `[native]cascade` list, find first available provider Definition
    4. Nothing matches → `{:error, :no_provider}`

  ## Adding a new provider

  Add a `[providers.my_provider]` section to `llm_core.toml`. Zero code changes.
  """

  alias LlmCore.Config.Store
  alias LlmCore.Provider.Definition

  @type config :: map()
  @type provider_opts :: keyword()
  @type resolution :: {:ok, {module(), String.t(), provider_opts()}} | {:error, :no_provider}

  # ── Public API ─────────────────────────────────────────────

  @doc """
  Resolve a provider for the given model string.

  Returns `{:ok, {module, model, provider_opts}}` or `{:error, :no_provider}`.

  The `appliance_has_model` flag lets the caller indicate whether the model
  is available locally (checked externally via Appliance discovery).
  """
  @spec resolve(String.t() | nil, config(), keyword()) :: resolution
  def resolve(model, config, opts \\ [])

  def resolve(model, config, opts) when is_binary(model) do
    lower = String.downcase(model)
    appliance_has_model = Keyword.get(opts, :appliance_has_model, false)

    providers = fetch_providers()

    # 1. Local appliance wins if the model is loaded there (free)
    if appliance_has_model do
      {:ok, {LlmCore.LLM.Appliance, model, []}}
    else
      # 2. Try model routing patterns
      case route_model(lower, config) do
        {:ok, provider_alias} ->
          lookup_provider(provider_alias, model, providers)

        :no_match ->
          # 3. Walk cascade with the given model
          cascade_pick(config, model, providers)
      end
    end
  end

  def resolve(nil, config, _opts) do
    # No model specified — walk cascade, use default models
    providers = fetch_providers()
    cascade_pick(config, nil, providers)
  end

  @doc """
  Resolve a provider by explicit name (e.g. "zai" from native:zai syntax).

  This is the direct routing path — no cascade, no model routing.
  Returns `{:ok, {module, model, provider_opts}}` or `{:error, :no_provider}`.
  """
  @spec resolve_provider(String.t()) :: resolution
  def resolve_provider(provider_name) do
    providers = fetch_providers()
    lookup_provider(provider_name, nil, providers)
  end

  # ── Model Routing ─────────────────────────────────────────

  @doc "Match a lowercased model string against routing patterns. First match wins."
  @spec route_model(String.t(), config()) :: {:ok, String.t()} | :no_match
  def route_model(lower, config) do
    routing = Map.get(config, :model_routing, [])

    Enum.find_value(routing, :no_match, fn entry ->
      pattern = Map.get(entry, "pattern", "")

      if String.contains?(lower, pattern) do
        {:ok, Map.get(entry, "provider", "")}
      else
        nil
      end
    end)
  end

  # ── Cascade ────────────────────────────────────────────────

  @doc "Walk the cascade and return the first available provider."
  @spec cascade_pick(config(), String.t() | nil, map()) :: resolution
  def cascade_pick(config, model, providers) do
    cascade = Map.get(config, :cascade, [])

    case find_in_cascade(cascade, model, providers) do
      {:ok, _} = result -> result
      :none -> {:error, :no_provider}
    end
  end

  defp find_in_cascade([], _model, _providers), do: :none

  defp find_in_cascade([alias | rest], model, providers) do
    case lookup_provider(alias, model, providers) do
      {:ok, _} = result -> result
      {:error, :no_provider} -> find_in_cascade(rest, model, providers)
    end
  end

  # ── Provider Lookup ────────────────────────────────────────

  # Look up a provider by name or alias in the provider definitions.
  # Returns {module, resolved_model, provider_opts} where provider_opts
  # carries base_url, api_key, and any other per-provider config.

  defp lookup_provider(alias, model_override, providers) do
    case find_definition(alias, providers) do
      %Definition{} = defn ->
        resolved_model = model_override || defn.default_model || ""
        opts = build_provider_opts(defn)
        {:ok, {defn.module, resolved_model, opts}}

      nil ->
        {:error, :no_provider}
    end
  end

  # Find a Definition by exact ID match, then by alias.
  defp find_definition(name, providers) when is_map(providers) do
    case Map.get(providers, name) do
      %Definition{} = defn -> defn
      nil -> find_by_alias(name, providers)
    end
  end

  defp find_by_alias(name, providers) do
    Enum.find(Map.values(providers), fn %Definition{aliases: aliases} ->
      name in aliases
    end)
  end

  # Build the keyword opts that get passed to the provider module's send/2.
  # Extracts base_url and api_key from the Definition's options and auth.
  defp build_provider_opts(%Definition{} = defn) do
    opts = []

    # base_url from provider options (merged from TOML [providers.*.config])
    opts =
      case get_in(defn.options, ["base_url"]) || Map.get(defn.options, :base_url) do
        nil -> opts
        url -> Keyword.put(opts, :base_url, url)
      end

    # api_key from auth section
    opts =
      case resolve_api_key(defn.auth) do
        nil -> opts
        key -> Keyword.put(opts, :api_key, key)
      end

    opts
  end

  defp resolve_api_key(%{"api_key_env" => env} = auth) when is_binary(env) do
    case System.get_env(env) do
      nil -> Map.get(auth, "api_key")
      key -> key
    end
  end

  defp resolve_api_key(%{"api_key" => key}), do: key
  defp resolve_api_key(_), do: nil

  # ── Config Access ──────────────────────────────────────────

  defp fetch_providers do
    case Store.fetch(:config, :providers) do
      {:ok, providers} when is_map(providers) -> providers
      _ -> %{}
    end
  end

  # Legacy helpers kept for backwards compatibility during transition.
  # These read from the old [native] config map, not from Store.

  @doc "Returns the default model for a provider alias from config."
  @spec get_default_model(String.t(), config()) :: String.t() | nil
  def get_default_model(alias, config) do
    defaults = Map.get(config, :default_models, %{})
    Map.get(defaults, to_string(alias))
  end
end
