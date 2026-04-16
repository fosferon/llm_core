defmodule LlmCore.LLM.Native.Router do
  @moduledoc """
  Pure config-driven provider resolution for the Native agentic loop.

  Takes a model string (or nil) + a config map (loaded from TOML) and returns
  `{provider_module, resolved_model}`. Zero side-effects — no `available?()`
  calls, no network, no process dictionary.

  The caller (Native) wraps this with availability checks.

  ## Config Structure

      %{
        cascade: ["appliance", "zai", "anthropic"],
        default_models: %{"appliance" => "qwen-local", "zai" => "glm-5.1", ...},
        model_routing: [
          %{"pattern" => "claude", "provider" => "anthropic"},
          %{"pattern" => "glm", "provider" => "zai"},
          ...
        ]
      }

  ## Resolution Logic

    1. If model given and appliance has it → appliance (local = free)
    2. If model matches a routing pattern → that provider
    3. Walk cascade → first available provider with default model
    4. If nothing matches → `{:error, :no_provider}`
  """

  alias LlmCore.LLM.{Appliance, Zai, Anthropic, OpenAI}

  @type config :: %{
          optional(:cascade) => [String.t()],
          optional(:default_models) => %{String.t() => String.t()},
          optional(:model_routing) => [%{String.t() => String.t()}]
        }

  @type resolution :: {:ok, {module(), String.t()}} | {:error, :no_provider}

  @doc """
  Resolve a provider for the given model string.

  Returns `{:ok, {module, model}}` or `{:error, :no_provider}`.

  The `appliance_has_model` flag lets the caller indicate whether the model
  is available locally (checked externally via Appliance discovery).
  """
  @spec resolve(String.t() | nil, config(), keyword()) :: resolution
  def resolve(model, config, opts \\ [])

  def resolve(model, config, opts) when is_binary(model) do
    lower = String.downcase(model)
    appliance_has_model = Keyword.get(opts, :appliance_has_model, false)

    # 1. Local appliance wins if the model is loaded there (free)
    if appliance_has_model do
      {:ok, {Appliance, model}}
    else
      # 2. Try model routing patterns
      case route_model(lower, config) do
        {:ok, provider_alias} ->
          default = get_default_model(provider_alias, config)
          {:ok, {alias_to_module(provider_alias), model || default}}

        :no_match ->
          # 3. Walk cascade with the given model
          case cascade_pick(config, model) do
            {:ok, _} = result -> result
            {:error, :no_provider} -> {:error, :no_provider}
          end
      end
    end
  end

  def resolve(nil, config, _opts) do
    # No model specified — walk cascade, use default models
    cascade_pick(config, nil)
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

  @doc "Walk the cascade and return the first provider with a model."
  @spec cascade_pick(config(), String.t() | nil) :: resolution
  def cascade_pick(config, model) do
    cascade = Map.get(config, :cascade, [])

    case find_in_cascade(cascade, config, model) do
      {:ok, _} = result -> result
      :none -> {:error, :no_provider}
    end
  end

  defp find_in_cascade([], _config, _model), do: :none

  defp find_in_cascade([alias | rest], config, model) do
    mod = alias_to_module(alias)

    if mod != nil do
      resolved = model || get_default_model(alias, config) || ""
      {:ok, {mod, resolved}}
    else
      find_in_cascade(rest, config, model)
    end
  end

  # ── Alias Mapping ─────────────────────────────────────────

  @doc "Maps a config alias string to a provider module."
  @spec alias_to_module(String.t()) :: module() | nil
  def alias_to_module("appliance"), do: Appliance
  def alias_to_module("zai"), do: Zai
  def alias_to_module("anthropic"), do: Anthropic
  def alias_to_module("openai"), do: OpenAI
  def alias_to_module(_), do: nil

  @doc "Returns the default model for a provider alias from config."
  @spec get_default_model(String.t(), config()) :: String.t() | nil
  def get_default_model(alias, config) do
    defaults = Map.get(config, :default_models, %{})
    Map.get(defaults, to_string(alias))
  end
end
