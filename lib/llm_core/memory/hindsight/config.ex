defmodule LlmCore.Memory.Hindsight.Config do
  @moduledoc """
  Hindsight-specific configuration with multi-level precedence.

  ## Precedence (highest to lowest)
  1. UI runtime override (ETS, session-only)
  2. Project config (`config/devman/config.yml`)
  3. Global config (`~/.devman/config.yml`)
  4. Environment variable (`HINDSIGHT_URL`)
  5. Auto-discovered endpoint

  ## Configuration Options

  ```yaml
  memory:
    hindsight:
      url: http://localhost:8888/mcp/
      api_key_env: HINDSIGHT_API_KEY
      enabled: true
      default_bank_id: user-123
      timeout_health_ms: 2000
      timeout_retain_ms: 10000
      timeout_recall_ms: 30000
      timeout_reflect_ms: 60000
      max_retries: 3
      retry_backoff_ms: [1000, 2000, 4000]
      circuit_failure_threshold: 5
      circuit_reset_ms: 30000
      cache_ttl_ms: 300000
      cache_max_entries: 1000
      prefetch_on_startup: true
  ```
  """

  use TypedStruct
  require Logger

  @ets_table :llm_core_hindsight_config

  typedstruct do
    field(:url, String.t())
    field(:api_key_env, String.t(), default: "HINDSIGHT_API_KEY")
    field(:enabled, boolean(), default: true)
    field(:default_bank_id, String.t() | nil, default: nil)

    # Timeouts (milliseconds)
    field(:timeout_health_ms, pos_integer(), default: 2_000)
    field(:timeout_retain_ms, pos_integer(), default: 10_000)
    field(:timeout_recall_ms, pos_integer(), default: 30_000)
    field(:timeout_reflect_ms, pos_integer(), default: 60_000)

    # Retry settings
    field(:max_retries, non_neg_integer(), default: 3)
    field(:retry_backoff_ms, [pos_integer()], default: [1_000, 2_000, 4_000])

    # Circuit breaker
    field(:circuit_failure_threshold, pos_integer(), default: 5)
    field(:circuit_reset_ms, pos_integer(), default: 30_000)

    # Caching
    field(:cache_ttl_ms, pos_integer(), default: 300_000)
    field(:cache_reflect_ttl_ms, pos_integer(), default: 900_000)
    field(:cache_max_entries, pos_integer(), default: 1_000)
    field(:prefetch_on_startup, boolean(), default: true)

    # Retain options
    field(:retain_raw_llm, boolean(), default: false)
  end

  @doc """
  Returns the effective URL using precedence rules.
  """
  @spec effective_url() :: String.t() | nil
  def effective_url do
    # 1. UI override (ETS)
    case get_ui_override() do
      {:ok, url} when is_binary(url) and url != "" -> url
      _ -> resolve_url_from_config()
    end
  end

  defp resolve_url_from_config do
    # 2. Project config
    project_url = get_project_url()
    if project_url, do: project_url, else: resolve_url_fallbacks()
  end

  defp resolve_url_fallbacks do
    # 3. Global config
    global_url = get_global_url()

    # 4. Environment variable
    env_url = System.get_env("HINDSIGHT_URL")

    cond do
      global_url && global_url != "" -> global_url
      env_url && env_url != "" -> env_url
      true -> get_discovered_url()
    end
  end

  @doc """
  Returns the effective configuration merging all sources.
  """
  @spec effective_config() :: t()
  def effective_config do
    base = defaults()

    # Load global config
    global = load_global_config()

    # Load project config
    project = load_project_config()

    # Merge: base < global < project
    merged =
      base
      |> merge_config(global)
      |> merge_config(project)
      |> apply_env_overrides()

    struct(__MODULE__, Map.to_list(merged))
  end

  @doc """
  Returns default configuration.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      url: nil,
      api_key_env: "HINDSIGHT_API_KEY",
      enabled: true,
      timeout_health_ms: 2_000,
      timeout_retain_ms: 10_000,
      timeout_recall_ms: 30_000,
      timeout_reflect_ms: 60_000,
      max_retries: 3,
      retry_backoff_ms: [1_000, 2_000, 4_000],
      circuit_failure_threshold: 5,
      circuit_reset_ms: 30_000,
      cache_ttl_ms: 300_000,
      cache_reflect_ttl_ms: 900_000,
      cache_max_entries: 1_000,
      prefetch_on_startup: true,
      retain_raw_llm: false,
      default_bank_id: nil
    }
  end

  @doc """
  Returns the effective default bank identifier, if configured.
  """
  @spec effective_bank_id() :: String.t() | nil
  def effective_bank_id do
    effective_config().default_bank_id
  end

  @doc """
  Sets a UI override URL (session-only, not persisted).
  """
  @spec set_ui_override(String.t() | nil) :: :ok
  def set_ui_override(url) do
    ensure_ets_table()
    :ets.insert(@ets_table, {:ui_override_url, url})
    :ok
  end

  @doc """
  Clears the UI override.
  """
  @spec clear_ui_override() :: :ok
  def clear_ui_override do
    ensure_ets_table()
    :ets.delete(@ets_table, :ui_override_url)
    :ok
  end

  @doc """
  Stores a discovered URL (from auto-discovery).
  """
  @spec set_discovered_url(String.t() | nil) :: :ok
  def set_discovered_url(url) do
    ensure_ets_table()
    :ets.insert(@ets_table, {:discovered_url, url, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Gets the discovered URL if available.
  """
  @spec get_discovered_url() :: String.t() | nil
  def get_discovered_url do
    ensure_ets_table()

    case :ets.lookup(@ets_table, :discovered_url) do
      [{:discovered_url, url, _ts}] -> url
      _ -> nil
    end
  end

  @doc """
  Returns the API key for authentication (from configured env var).
  """
  @spec get_api_key() :: String.t() | nil
  def get_api_key do
    config = effective_config()
    System.get_env(config.api_key_env)
  end

  @doc """
  Checks if URL requires authentication (non-localhost).
  """
  @spec requires_auth?(String.t() | nil) :: boolean()
  def requires_auth?(nil), do: false

  def requires_auth?(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    host not in ["localhost", "127.0.0.1", "::1"]
  end

  # Private helpers

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public])
    end
  end

  defp get_ui_override do
    ensure_ets_table()

    case :ets.lookup(@ets_table, :ui_override_url) do
      [{:ui_override_url, url}] -> {:ok, url}
      _ -> :not_set
    end
  end

  defp get_project_url do
    project_config = load_project_config()
    project_config[:url]
  end

  defp get_global_url do
    global_config = load_global_config()
    global_config[:url]
  end

  defp load_global_config do
    config_path = Path.join(LlmCore.Paths.global_config_dir(), "config.yml")

    case File.read(config_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, yaml} -> parse_hindsight_config(yaml)
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp load_project_config do
    project_dir = LlmCore.Paths.project_config_dir()
    config_path = Path.join(project_dir, "config.yml")

    case File.read(config_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, yaml} -> parse_hindsight_config(yaml)
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp parse_hindsight_config(yaml) when is_map(yaml) do
    memory = Map.get(yaml, "memory", %{})
    hindsight = Map.get(memory, "hindsight", %{})

    %{
      url: hindsight["url"],
      api_key_env: hindsight["api_key_env"],
      enabled: parse_bool(hindsight["enabled"]),
      default_bank_id: hindsight["default_bank_id"] || hindsight["bank_id"],
      timeout_health_ms: hindsight["timeout_health_ms"],
      timeout_retain_ms: hindsight["timeout_retain_ms"],
      timeout_recall_ms: hindsight["timeout_recall_ms"],
      timeout_reflect_ms: hindsight["timeout_reflect_ms"],
      max_retries: hindsight["max_retries"],
      retry_backoff_ms: parse_backoff_list(hindsight["retry_backoff_ms"]),
      circuit_failure_threshold: hindsight["circuit_failure_threshold"],
      circuit_reset_ms: hindsight["circuit_reset_ms"],
      cache_ttl_ms: hindsight["cache_ttl_ms"],
      cache_reflect_ttl_ms: hindsight["cache_reflect_ttl_ms"],
      cache_max_entries: hindsight["cache_max_entries"],
      prefetch_on_startup: parse_bool(hindsight["prefetch_on_startup"]),
      retain_raw_llm: parse_bool(hindsight["retain_raw_llm"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_hindsight_config(_), do: %{}

  defp merge_config(base, overlay) do
    Map.merge(base, overlay, fn _k, _base_v, overlay_v -> overlay_v end)
  end

  defp apply_env_overrides(config) do
    config
    |> maybe_put_env_url()
    |> maybe_put_env_bank()
  end

  defp maybe_put_env_url(config) do
    env_url = System.get_env("HINDSIGHT_URL")

    if env_url && env_url != "" do
      Map.put(config, :url, env_url)
    else
      config
    end
  end

  defp maybe_put_env_bank(config) do
    env_bank =
      System.get_env("HINDSIGHT_BANK_ID") ||
        System.get_env("HINDSIGHT_DEFAULT_BANK")

    if env_bank && env_bank != "" do
      Map.put(config, :default_bank_id, env_bank)
    else
      config
    end
  end

  defp parse_bool(nil), do: nil
  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_backoff_list(nil), do: nil
  defp parse_backoff_list(list) when is_list(list), do: Enum.map(list, &parse_int/1)
  defp parse_backoff_list(_), do: nil

  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v), do: String.to_integer(v)
  defp parse_int(_), do: nil
end
