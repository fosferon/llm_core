defmodule LlmCore.Provider.Registry do
  @moduledoc """
  In-memory accessors for provider definitions loaded from TOML configuration.

  The registry reads provider metadata from `LlmCore.Config.Store` so callers
  can inspect capabilities, resolve modules, find providers by alias, and get
  fuzzy suggestions — all without touching disk.

  ## Querying Providers

      # All configured providers (keyed by id)
      LlmCore.Provider.Registry.all()
      #=> %{"anthropic" => %Definition{...}, "openai" => %Definition{...}, ...}

      # Only available providers (enabled, API key present / binary found)
      LlmCore.Provider.Registry.available()

      # By exact id
      {:ok, def} = LlmCore.Provider.Registry.fetch("anthropic")

      # By implementing module
      {:ok, def} = LlmCore.Provider.Registry.lookup_by_module(LlmCore.LLM.OpenAI)

      # By alias (returns all matching)
      defs = LlmCore.Provider.Registry.lookup_alias("claude")

      # Fuzzy suggestions (Jaro distance)
      LlmCore.Provider.Registry.suggest_alias("claud")
      #=> ["claude"]

      # Capable providers for requirements
      LlmCore.Provider.Registry.suggest_capable(%{streaming: true, tool_use: true})
      #=> [%{alias: "claude", provider: "anthropic", cost_tier: "premium", ...}]
  """

  alias LlmCore.Config.Store
  alias LlmCore.Provider.Definition

  @namespace :config
  @key :providers

  @doc """
  Returns the map of all provider definitions keyed by provider id.
  """
  @spec all() :: %{optional(String.t()) => Definition.t()}
  def all do
    case Store.fetch(@namespace, @key) do
      {:ok, providers} -> providers
      {:error, :not_found} -> %{}
    end
  end

  @doc """
  Returns only providers that are currently available (enabled and healthy).
  """
  @spec available() :: [Definition.t()]
  def available do
    all()
    |> Map.values()
    |> Enum.filter(& &1.available?)
  end

  @doc """
  Fetches a provider by id.
  """
  @spec fetch(String.t()) :: {:ok, Definition.t()} | {:error, :not_found}
  def fetch(id) do
    case Map.fetch(all(), id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Finds a provider definition by the implementing module.
  """
  @spec lookup_by_module(module()) :: {:ok, Definition.t()} | {:error, :not_found}
  def lookup_by_module(module) when is_atom(module) do
    all()
    |> Enum.find(fn {_id, definition} -> definition.module == module end)
    |> case do
      {_, definition} -> {:ok, definition}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Fetches provider definitions whose alias list contains the given alias.
  """
  @spec lookup_alias(String.t()) :: [Definition.t()]
  def lookup_alias(alias) when is_binary(alias) do
    normalized = normalize_alias(alias)

    all()
    |> Enum.map(fn {_id, definition} -> definition end)
    |> Enum.filter(fn definition -> normalized in definition.aliases end)
  end

  @doc """
  Suggests provider aliases that closely match the given term.
  """
  @spec suggest_alias(String.t(), keyword()) :: [String.t()]
  def suggest_alias(term, opts \\ []) when is_binary(term) do
    limit = Keyword.get(opts, :limit, 3)
    normalized_term = normalize_alias(term)

    all()
    |> Enum.flat_map(fn {_id, definition} ->
      Enum.map(definition.aliases, &{&1, definition})
    end)
    |> Enum.map(fn {alias, definition} ->
      score = String.jaro_distance(normalized_term, alias)
      {score, alias, definition}
    end)
    |> Enum.sort_by(fn {score, alias, _} -> {-score, alias} end)
    |> Enum.take(limit)
    |> Enum.map(fn {_score, alias, _} -> alias end)
  end

  @doc """
  Suggests providers capable of meeting the given capability requirements.
  Returns metadata so callers can surface cost tiers/model availability.
  """
  @spec suggest_capable(map(), keyword()) :: [map()]
  def suggest_capable(requirements, opts \\ []) when is_map(requirements) do
    limit = Keyword.get(opts, :limit, 3)

    available()
    |> Enum.filter(fn definition ->
      capability_match?(definition.capabilities || %{}, requirements)
    end)
    |> Enum.map(&format_suggestion/1)
    |> Enum.take(limit)
  end

  @doc false
  @spec capability_match?(map() | nil, map()) :: boolean()
  def capability_match?(capabilities, requirements) when is_map(requirements) do
    Enum.all?(requirements, fn {key, expected} ->
      capability_satisfies?(Map.get(capabilities || %{}, key), expected)
    end)
  end

  def capability_match?(_capabilities, _requirements), do: true

  defp capability_satisfies?(_value, nil), do: true
  defp capability_satisfies?(value, false) when is_boolean(value), do: true

  defp capability_satisfies?(value, true) do
    value in [true, "true"]
  end

  defp capability_satisfies?(value, expected) when is_integer(expected) do
    cond do
      is_integer(value) -> value >= expected
      is_binary(value) -> String.to_integer(value) >= expected
      true -> false
    end
  rescue
    ArgumentError -> false
  end

  defp capability_satisfies?(value, expected) when is_binary(expected) do
    cond do
      is_list(value) -> Enum.any?(value, &match_string?(&1, expected))
      is_binary(value) -> match_string?(value, expected)
      true -> false
    end
  end

  defp capability_satisfies?(value, expected) when is_list(expected) do
    cond do
      is_list(value) -> Enum.all?(expected, &capability_satisfies?(value, &1))
      true -> false
    end
  end

  defp capability_satisfies?(value, expected) when is_boolean(expected) do
    capability_satisfies?(value, true)
  end

  defp capability_satisfies?(_value, _expected), do: true

  defp match_string?(value, expected) do
    String.downcase(to_string(value)) == String.downcase(expected)
  end

  defp normalize_alias(alias) do
    alias
    |> String.trim()
    |> String.downcase()
  end

  defp format_suggestion(definition) do
    alias = List.first(definition.aliases) || definition.id
    models = Map.get(definition.capabilities || %{}, :models)
    cost = Map.get(definition.metadata || %{}, "cost_tier")

    %{
      alias: alias,
      provider: definition.id,
      cost_tier: cost,
      models: models,
      available?: definition.available?
    }
  end
end
