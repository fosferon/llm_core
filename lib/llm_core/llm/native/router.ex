defmodule LlmCore.LLM.Native.Router do
  @moduledoc """
  Config-driven provider resolution for the Native agentic loop.

  Resolves a provider name (or nil for cascade) into a fully-configured
  `{module, model, provider_opts}` tuple. Provider definitions are loaded
  from TOML at startup and stored in `LlmCore.Config.Store`.

  ## Resolution Logic

    0. If the caller reports the requested model is loaded on the local Appliance
       (`appliance_has_model: true`) **and** an Appliance-module provider is listed in the
       cascade (or is the fallback), that provider is used. With no Appliance provider
       configured the flag has no effect.
    1. Explicit provider (`llm_provider: "my_provider"`) → look up Definition by name/alias
    2. Model routing (`model` matches a pattern) → look up Definition for matched provider;
       an unusable target falls through to the cascade
    3. Cascade → walk the configured `[native]cascade` list, find the first usable provider
       Definition. With no cascade configured, the `:fallback` option (the routing default,
       passed by the caller) is the only member.
    4. Nothing matches → `{:error, :no_provider}`

  A cascade member is *usable* only if its Definition is enabled, can run the native
  loop (`provider_kind: :module`, not a CLI provider), and — when it declares an `auth`
  credential — that credential resolves. Anything else is skipped, and `skipped/2`
  reports why. llm_core ships no cascade of its own; see `LlmCore.LLM.Native.Config`.

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
    providers = fetch_providers()
    config = with_fallback_cascade(config, Keyword.get(opts, :fallback))

    # 1. A configured local appliance wins if the model is loaded there (free). The flag
    #    is ignored unless an Appliance provider is in the cascade/fallback.
    with true <- Keyword.get(opts, :appliance_has_model, false),
         {:ok, _} = local <- appliance_candidate(config, model, providers) do
      local
    else
      _ -> resolve_by_routing(lower, model, config, providers)
    end
  end

  def resolve(nil, config, opts) do
    # No model specified — walk cascade, use default models
    providers = fetch_providers()
    cascade_pick(with_fallback_cascade(config, Keyword.get(opts, :fallback)), nil, providers)
  end

  @doc """
  Resolve a provider by explicit name (e.g. "my_provider" from native:my_provider syntax).

  This is the direct routing path — no cascade, no model routing.
  Returns `{:ok, {module, model, provider_opts}}` or `{:error, :no_provider}`.
  """
  @spec resolve_provider(String.t()) :: resolution
  def resolve_provider(provider_name) do
    providers = fetch_providers()
    lookup_provider(provider_name, nil, providers, :explicit)
  end

  @doc """
  Returns an ordered list of candidates — primary first, then cascade fallbacks.

  The primary is what `resolve/3` would pick. Fallbacks are the remaining
  cascade providers with their own default models (NOT the originally requested
  model — a model id one provider serves usually can't run on another).

  The primary module is never duplicated in the tail. Callers walk the list
  and attempt each candidate in order, falling through on runtime failure.

  Returns `[]` when nothing resolves.
  """
  @spec candidates(String.t() | nil, config(), keyword()) :: [
          {module(), String.t(), provider_opts()}
        ]
  def candidates(model, config, opts \\ []) do
    config = with_fallback_cascade(config, Keyword.get(opts, :fallback))

    case resolve(model, config, opts) do
      {:error, :no_provider} ->
        []

      {:ok, primary} ->
        [primary | fallback_candidates(primary, config)]
    end
  end

  defp fallback_candidates({primary_mod, _, _}, config) do
    providers = fetch_providers()
    cascade = Map.get(config, :cascade, [])

    cascade
    |> Enum.reduce([], fn alias, acc ->
      case lookup_provider(alias, nil, providers) do
        {:ok, {^primary_mod, _, _}} -> acc
        {:ok, candidate} -> [candidate | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {mod, _, _} -> mod end)
  end

  @doc """
  Explains which cascade members are not usable and why.

  Accepts the same `:fallback` option as `candidates/3`. Reasons: `:no_provider`
  (no such definition), `:disabled`, `:not_native` (a CLI provider cannot run the
  native loop), `:no_credentials` (the definition's `auth` credential is unset).
  """
  @spec skipped(config(), keyword()) :: [%{provider: String.t(), reason: atom()}]
  def skipped(config, opts \\ []) do
    providers = fetch_providers()

    config
    |> with_fallback_cascade(Keyword.get(opts, :fallback))
    |> Map.get(:cascade, [])
    |> Enum.flat_map(fn alias ->
      case lookup_provider(alias, nil, providers) do
        {:ok, _} -> []
        {:error, reason} -> [%{provider: alias, reason: reason}]
      end
    end)
  end

  # No configured cascade: the caller's fallback (the routing default) is the only member.
  defp with_fallback_cascade(config, fallback) when is_binary(fallback) and fallback != "" do
    case Map.get(config, :cascade, []) do
      [] -> Map.put(config, :cascade, [fallback])
      _ -> config
    end
  end

  defp with_fallback_cascade(config, _fallback), do: config

  # 2. Model routing patterns; an unusable target falls through to the cascade.
  defp resolve_by_routing(lower, model, config, providers) do
    case route_model(lower, config) do
      {:ok, provider_alias} ->
        case lookup_provider(provider_alias, model, providers) do
          {:ok, _} = ok -> ok
          {:error, _} -> cascade_pick(config, model, providers)
        end

      :no_match ->
        # 3. Walk the cascade with the given model
        cascade_pick(config, model, providers)
    end
  end

  @doc """
  The alias of the first usable cascade member (or fallback) backed by the local
  `LlmCore.LLM.Appliance` module, or `nil`.

  Callers use it to decide whether probing the appliance for a loaded model is
  worthwhile at all: with no Appliance provider configured, nothing is probed.
  """
  @spec appliance_alias(config(), keyword()) :: String.t() | nil
  def appliance_alias(config, opts \\ []) do
    config = with_fallback_cascade(config, Keyword.get(opts, :fallback))
    providers = fetch_providers()

    Enum.find(Map.get(config, :cascade, []), fn alias ->
      appliance_member?(alias, providers) and
        match?({:ok, _}, lookup_provider(alias, nil, providers))
    end)
  end

  defp appliance_candidate(config, model, providers) do
    case Enum.find(Map.get(config, :cascade, []), &appliance_member?(&1, providers)) do
      nil -> {:error, :no_appliance}
      alias -> lookup_provider(alias, model, providers)
    end
  end

  defp appliance_member?(alias, providers) do
    match?(%Definition{module: LlmCore.LLM.Appliance}, find_definition(alias, providers))
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
      {:error, _} -> find_in_cascade(rest, model, providers)
    end
  end

  # ── Provider Lookup ────────────────────────────────────────

  # Look up a provider by name or alias in the provider definitions.
  # Returns {module, resolved_model, provider_opts} where provider_opts
  # carries base_url, api_key, and any other per-provider config.

  # `:strict` (cascade, fallback, model routing) refuses definitions that cannot run
  # the native loop right now; `:explicit` (caller named the provider) does not,
  # so the caller sees the provider's own error instead of a silent skip.
  defp lookup_provider(alias, model_override, providers, mode \\ :strict) do
    case find_definition(alias, providers) do
      %Definition{} = defn ->
        with :ok <- usable(defn, mode) do
          resolved_model = model_override || defn.default_model || ""
          opts = build_provider_opts(defn)
          {:ok, {defn.module, resolved_model, opts}}
        end

      nil ->
        {:error, :no_provider}
    end
  end

  defp usable(_defn, :explicit), do: :ok

  defp usable(%Definition{enabled: false}, :strict), do: {:error, :disabled}
  defp usable(%Definition{provider_kind: :cli}, :strict), do: {:error, :not_native}

  defp usable(%Definition{auth: auth}, :strict) do
    if credential_missing?(auth), do: {:error, :no_credentials}, else: :ok
  end

  # The config loader records the verdict in `"api_key_present"` (env set, inline key, or
  # discovered env; true when the provider declares no auth at all). Trust it when present;
  # hand-built definitions without it fall back to resolving the declared key directly.
  defp credential_missing?(%{"api_key_present" => present}), do: present != true

  defp credential_missing?(%{} = auth) do
    (Map.has_key?(auth, "api_key_env") or Map.has_key?(auth, "api_key")) and
      blank?(resolve_api_key(auth))
  end

  defp credential_missing?(_), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

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
