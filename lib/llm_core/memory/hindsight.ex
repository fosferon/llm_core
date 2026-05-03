defmodule LlmCore.Memory.Hindsight do
  @moduledoc """
  Hindsight 0.4+ integration for semantic memory capabilities.

  Uses the Hindsight REST API (not MCP). Server runs at localhost:8888,
  REST endpoints at `/v1/default/banks/{bank_id}/...`.

  Provides:
  - Semantic search (recall) with intelligent caching
  - Insight queries (reflect) with longer TTL caching
  - Content retention with write-behind buffering
  - Auto-discovery, retry logic, and circuit breaker

  ## Configuration

  Configure in `~/.llm_core/config.yml`:

  ```yaml
  memory:
    hindsight:
      url: http://localhost:8888
      enabled: true
      default_bank_id: platform
      cache_ttl_ms: 300000
  ```

  ## Usage

      # Semantic search
      {:ok, results} = Hindsight.recall("authentication patterns", bank_id: "mobus")

      # Insights
      {:ok, insight} = Hindsight.reflect("What patterns work best?", bank_id: "mobus")

      # Store content (async)
      :ok = Hindsight.retain("New pattern discovered", %{}, bank_id: "mobus")

      # Store content (sync, for critical data)
      {:ok, _} = Hindsight.retain_sync("Critical execution", %{}, bank_id: "mobus")
  """

  require Logger

  alias LlmCore.Memory.Hindsight.{CircuitBreaker, Config, Retry}
  alias LlmCore.Pipelines.MemoryPipeline

  # ── Default bank for recall/reflect when none specified ──────────────────
  @default_bank "default"

  @doc """
  Checks if Hindsight API is available and enabled.
  """
  @spec available?() :: boolean()
  def available? do
    config = Config.effective_config()

    if config.enabled do
      case health_check() do
        {:ok, _} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Returns the effective Hindsight base URL.
  """
  @spec url() :: String.t() | nil
  def url do
    Config.effective_url()
  end

  @doc """
  Stores content in Hindsight for semantic indexing (async, buffered).

  ## Options
    * `:bank_id` / `:target_bank` - Memory bank to write to
    * `:context` - Short descriptor for the memory
  """
  @spec retain(String.t(), map(), keyword()) :: :ok
  def retain(content, metadata \\ %{}, opts \\ []) do
    MemoryPipeline.retain_async(content, metadata, opts)
  end

  @doc """
  Stores content synchronously, bypassing the write buffer.

  Use for critical data that must be persisted immediately.
  """
  @spec retain_sync(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retain_sync(content, metadata \\ %{}, opts \\ []) do
    MemoryPipeline.retain_sync(content, metadata, opts)
  end

  @doc """
  Semantic search for similar content with caching.

  ## Options
  - `:limit` - max results (default 10)
  - `:bank_id` / `:target_bank` - Memory bank to query (defaults to config)
  - `:budget` - `"low"` | `"mid"` | `"high"` (impacts recall cost)
  - `:max_tokens` - maximum tokens for result summarization
  - `:bypass_cache` - force fresh query
  """
  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recall(query, opts \\ []) do
    MemoryPipeline.recall(query, opts)
  end

  @doc """
  Natural language reflection/synthesis over a bank's memories.

  ## Options
    * `:bank_id` / `:target_bank` - Memory bank to reflect on
    * `:budget` - `"low"` | `"mid"` | `"high"`
    * `:context` - Additional context for the reflection
  """
  @spec reflect(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @spec reflect(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def reflect(question_or_type, opts \\ [])

  def reflect(question, opts) when is_binary(question) do
    MemoryPipeline.reflect(question, opts)
  end

  def reflect(query_type, opts) when is_atom(query_type) do
    question = build_structured_query(query_type, opts)
    MemoryPipeline.reflect(question, opts)
  end

  @doc """
  Performs a health check on the Hindsight API.
  """
  @spec health_check() :: {:ok, map()} | {:error, term()}
  def health_check do
    url = Config.effective_url()

    if url do
      do_health_check(url)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Lists available Hindsight memory banks.
  """
  @spec list_banks(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_banks(opts \\ []) do
    with {:ok, url} <- require_enabled_url() do
      config = Config.effective_config()
      timeout = Keyword.get(opts, :timeout, config.timeout_recall_ms)
      api_key = Keyword.get(opts, :api_key)

      case rest_get(url, "/v1/default/banks", timeout, api_key: api_key) do
        {:ok, %{"banks" => banks}} -> {:ok, banks}
        {:ok, other} -> {:ok, List.wrap(other["banks"] || [])}
        error -> error
      end
    end
  end

  @doc """
  Creates or updates a memory bank.
  """
  @spec create_bank(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_bank(bank_id, opts \\ [])

  def create_bank(bank_id, opts) when is_binary(bank_id) do
    trimmed = String.trim(bank_id)

    if trimmed == "" do
      {:error, :invalid_bank_id}
    else
      with {:ok, url} <- require_enabled_url() do
        config = Config.effective_config()
        timeout = Keyword.get(opts, :timeout, config.timeout_recall_ms)
        api_key = Keyword.get(opts, :api_key)

        body =
          %{name: Keyword.get(opts, :name, trimmed)}
          |> maybe_put(:mission, Keyword.get(opts, :mission))

        case rest_put(url, "/v1/default/banks/#{trimmed}", body, timeout, api_key: api_key) do
          {:ok, result} -> {:ok, result}
          error -> error
        end
      end
    end
  end

  def create_bank(_bank_id, _opts), do: {:error, :invalid_bank_id}

  @doc """
  Deletes a memory bank and all its contents.
  """
  @spec delete_bank(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_bank(bank_id, opts \\ []) do
    with {:ok, url} <- require_enabled_url() do
      config = Config.effective_config()
      timeout = Keyword.get(opts, :timeout, config.timeout_recall_ms)
      api_key = Keyword.get(opts, :api_key)

      case rest_delete(url, "/v1/default/banks/#{bank_id}", timeout, api_key: api_key) do
        {:ok, _} -> :ok
        {:error, {:http_error, 204, _}} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Returns stats for a specific bank.
  """
  @spec bank_stats(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bank_stats(bank_id, opts \\ []) do
    with {:ok, url} <- require_enabled_url() do
      config = Config.effective_config()
      timeout = Keyword.get(opts, :timeout, config.timeout_recall_ms)
      api_key = Keyword.get(opts, :api_key)

      rest_get(url, "/v1/default/banks/#{bank_id}/stats", timeout, api_key: api_key)
    end
  end

  # ── RPC helpers (called by MemoryPipeline) ───────────────────────────────

  @doc false
  @spec do_retain(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def do_retain(url, content, metadata, opts) do
    config = Config.effective_config()
    bank_id = resolve_bank_id(opts)
    context = Keyword.get(opts, :context) || metadata[:context] || "general"
    api_key = Keyword.get(opts, :api_key)

    body = %{
      items: [%{content: content, context: context}],
      async: false
    }

    Retry.with_retry(fn ->
      rest_post(url, "/v1/default/banks/#{bank_id}/memories", body, config.timeout_retain_ms,
        api_key: api_key
      )
    end)
  end

  @doc false
  @spec do_recall(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def do_recall(url, query, opts) do
    config = Config.effective_config()
    bank_id = resolve_bank_id(opts)
    max_tokens = Keyword.get(opts, :max_tokens, 4_096)
    budget = normalize_budget(Keyword.get(opts, :budget, :low))
    api_key = Keyword.get(opts, :api_key)

    body =
      %{query: query, budget: budget}
      |> maybe_put(:max_tokens, max_tokens)

    Retry.with_retry(fn ->
      case rest_post(
             url,
             "/v1/default/banks/#{bank_id}/memories/recall",
             body,
             config.timeout_recall_ms,
             api_key: api_key
           ) do
        {:ok, %{"results" => results}} when is_list(results) -> {:ok, results}
        {:ok, other} -> {:ok, Map.get(other, "results", [])}
        error -> error
      end
    end)
  end

  @doc false
  @spec do_reflect(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def do_reflect(url, question, opts) do
    config = Config.effective_config()
    bank_id = resolve_bank_id(opts)
    budget = normalize_budget(Keyword.get(opts, :budget, :low))
    api_key = Keyword.get(opts, :api_key)

    body = %{query: question, budget: budget}

    Retry.with_retry(fn ->
      case rest_post(url, "/v1/default/banks/#{bank_id}/reflect", body, config.timeout_reflect_ms,
             api_key: api_key
           ) do
        {:ok, %{"text" => text}} -> {:ok, text}
        {:ok, other} -> {:ok, Map.get(other, "text", "No insights available")}
        error -> error
      end
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp do_health_check(url) do
    config = Config.effective_config()
    rest_get(url, "/health", config.timeout_health_ms)
  end

  defp require_enabled_url do
    config = Config.effective_config()
    url = Config.effective_url()

    cond do
      not config.enabled -> {:error, :disabled}
      is_nil(url) -> {:error, :not_configured}
      true -> {:ok, url}
    end
  end

  # ── REST client ──────────────────────────────────────────────────────────

  defp rest_get(base_url, path, timeout, opts \\ []) do
    url = String.trim_trailing(base_url, "/") <> path
    api_key = Keyword.get(opts, :api_key)

    case Req.get(url, headers: build_headers(api_key), receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport_error, reason}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  @doc false
  @spec rest_post(String.t(), String.t(), map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def rest_post(base_url, path, body, timeout, opts \\ []) do
    url = String.trim_trailing(base_url, "/") <> path
    api_key = Keyword.get(opts, :api_key)

    case Req.post(url, json: body, headers: build_headers(api_key), receive_timeout: timeout) do
      {:ok, %{status: 200, body: response}} -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport_error, reason}}
      {:error, %{reason: :timeout}} -> {:error, {:transport_error, :timeout}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp rest_put(base_url, path, body, timeout, opts) do
    url = String.trim_trailing(base_url, "/") <> path
    api_key = Keyword.get(opts, :api_key)

    case Req.put(url, json: body, headers: build_headers(api_key), receive_timeout: timeout) do
      {:ok, %{status: s, body: response}} when s in 200..201 -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport_error, reason}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp rest_delete(base_url, path, timeout, opts) do
    url = String.trim_trailing(base_url, "/") <> path
    api_key = Keyword.get(opts, :api_key)

    case Req.delete(url, headers: build_headers(api_key), receive_timeout: timeout) do
      {:ok, %{status: s, body: response}} when s in 200..204 -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport_error, reason}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  @doc false
  def build_headers(api_key \\ nil) do
    headers = [{"content-type", "application/json"}]

    key =
      case api_key do
        nil -> Config.get_api_key()
        "" -> Config.get_api_key()
        k -> k
      end

    case key do
      nil -> headers
      "" -> headers
      k -> [{"authorization", "Bearer #{k}"} | headers]
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp build_structured_query(:workflow_effectiveness, opts) do
    workflow = Keyword.get(opts, :workflow, "default")

    "What is the effectiveness of the #{workflow} workflow? Include success rate and average duration."
  end

  defp build_structured_query(:common_failures, _opts) do
    "What are the most common failure patterns? List the top 5 with frequency."
  end

  defp build_structured_query(:project_insights, _opts) do
    "What are the key learnings and patterns for this project?"
  end

  defp build_structured_query(:cross_project, _opts) do
    "What patterns have been successful across multiple projects?"
  end

  @doc false
  @spec report_result({:ok, term()} | {:error, term()}) :: :ok
  def report_result({:ok, _}), do: CircuitBreaker.report_success()
  def report_result({:error, reason}), do: CircuitBreaker.report_failure(reason)

  @doc false
  @spec resolve_bank_id(keyword()) :: String.t()
  def resolve_bank_id(opts) do
    opts[:target_bank] || opts[:bank_id] || Config.effective_bank_id() || @default_bank
  end

  @doc false
  @spec normalize_budget(atom() | String.t() | nil) :: String.t()
  def normalize_budget(nil), do: "low"

  def normalize_budget(budget) when is_atom(budget),
    do: budget |> Atom.to_string() |> String.downcase()

  def normalize_budget(budget) when is_binary(budget), do: String.downcase(budget)
  def normalize_budget(_), do: "low"

  @doc false
  @spec maybe_put(map(), atom() | String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec maybe_put_new(map(), atom() | String.t(), term()) :: map()
  def maybe_put_new(map, _key, nil), do: map
  def maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  @doc false
  @spec enrich_metadata(map(), keyword()) :: map()
  def enrich_metadata(metadata, opts) do
    metadata
    |> maybe_put_new(:context, Keyword.get(opts, :context))
    |> Map.merge(%{
      host_version: application_version(),
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp application_version do
    cond do
      version = Application.spec(:dev_man, :vsn) -> to_string(version)
      version = Application.spec(:hu_man, :vsn) -> to_string(version)
      version = Application.spec(:llm_core, :vsn) -> to_string(version)
      true -> "unknown"
    end
  rescue
    _ -> "unknown"
  end
end
