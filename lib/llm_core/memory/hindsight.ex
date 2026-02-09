defmodule LlmCore.Memory.Hindsight do
  @moduledoc """
  Hindsight MCP integration for semantic memory capabilities.

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
      url: http://localhost:8888/mcp/
      enabled: true
      cache_ttl_ms: 300000
  ```

  ## Usage

      # Semantic search
      {:ok, results} = Hindsight.recall("authentication patterns")

      # Insights
      {:ok, insight} = Hindsight.reflect("What patterns work best?")

      # Store content (async)
      :ok = Hindsight.retain("New pattern discovered", %{type: :pattern})

      # Store content (sync, for critical data)
      {:ok, _} = Hindsight.retain_sync("Critical execution", %{type: :execution})
  """

  require Logger

  alias LlmCore.Memory.Hindsight.{CircuitBreaker, Config, Retry}
  alias LlmCore.Pipelines.MemoryPipeline

  @doc """
  Checks if Hindsight MCP is available and enabled.
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
  Returns the effective Hindsight URL.
  """
  @spec url() :: String.t() | nil
  def url do
    Config.effective_url()
  end

  @doc """
  Stores content in Hindsight for semantic indexing (async, buffered).

  ## Options
    * `:target_bank` / `:bank_id` - Explicit memory bank to write to
    * `:context` - Short descriptor for the memory (defaults to `metadata` value)
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
  - `:project_id` - scope to project (nil for global)
  - `:type` - filter by content type
  - `:since` - filter by timestamp
  - `:bypass_cache` - force fresh query
  - `:target_bank` / `:bank_id` - Memory bank to query (defaults to config)
  - `:budget` - `:low | :mid | :high` (impacts recall cost)
  - `:max_tokens` - maximum tokens to allocate when summarizing results
  """
  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recall(query, opts \\ []) do
    MemoryPipeline.recall(query, opts)
  end

  @doc """
  Natural language or structured insight query with caching.

  Pass a binary question for free-form reflections or an atom for structured queries.

  ## Options
    * `:context` - Additional context for why reflection is needed
    * `:budget` - `:low | :mid | :high`
    * `:target_bank` / `:bank_id` - Memory bank to reflect on

  ## Structured Query Types
    * `:workflow_effectiveness` - stats for specific workflow
    * `:common_failures` - frequent failure patterns
    * `:project_insights` - project-specific learnings
    * `:cross_project` - patterns across projects
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
  Performs a health check on the Hindsight MCP endpoint.
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
  @spec list_banks(keyword()) :: {:ok, [map() | struct()]} | {:error, term()}
  def list_banks(opts \\ []) do
    with {:ok, url} <- require_enabled_url() do
      config = Config.effective_config()
      timeout = Keyword.get(opts, :timeout, config.timeout_recall_ms)

      body = %{
        jsonrpc: "2.0",
        method: "hindsight/list_banks",
        params: %{},
        id: generate_request_id()
      }

      case post_mcp(url, body, timeout) do
        {:ok, %{"result" => %{"banks" => banks}}} -> {:ok, banks}
        {:ok, %{"result" => banks}} when is_list(banks) -> {:ok, banks}
        {:ok, %{"result" => result}} -> {:ok, result}
        error -> error
      end
    end
  end

  @doc """
  Creates (or fetches) a memory bank profile.
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

        params =
          %{bank_id: trimmed}
          |> maybe_put(:name, Keyword.get(opts, :name))
          |> maybe_put(:mission, Keyword.get(opts, :mission))

        body = %{
          jsonrpc: "2.0",
          method: "hindsight/create_bank",
          params: params,
          id: generate_request_id()
        }

        case post_mcp(url, body, timeout) do
          {:ok, %{"result" => result}} -> {:ok, result}
          error -> error
        end
      end
    end
  end

  def create_bank(_bank_id, _opts), do: {:error, :invalid_bank_id}

  # RPC helpers shared with the memory pipeline

  @doc false
  def do_retain(url, content, metadata, opts) do
    config = Config.effective_config()
    enriched = enrich_metadata(metadata, opts)
    bank_id = resolve_bank_id(opts)

    body = %{
      jsonrpc: "2.0",
      method: "hindsight/retain",
      params:
        %{
          content: content,
          metadata: enriched,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          project_id: get_project_id()
        }
        |> maybe_put(:bank_id, bank_id),
      id: generate_request_id()
    }

    Retry.with_retry(fn ->
      post_mcp(url, body, config.timeout_retain_ms)
    end)
  end

  @doc false
  def do_recall(url, query, opts) do
    config = Config.effective_config()
    limit = Keyword.get(opts, :limit, 10)
    project_id = Keyword.get(opts, :project_id)
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)
    max_tokens = Keyword.get(opts, :max_tokens, 4_096)
    budget = normalize_budget(Keyword.get(opts, :budget, :low))
    bank_id = resolve_bank_id(opts)

    params =
      %{query: query, limit: limit}
      |> maybe_put(:project_id, project_id)
      |> maybe_put(:type, type)
      |> maybe_put(:since, since)
      |> maybe_put(:max_tokens, max_tokens)
      |> maybe_put(:budget, budget)
      |> maybe_put(:bank_id, bank_id)

    body = %{
      jsonrpc: "2.0",
      method: "hindsight/recall",
      params: params,
      id: generate_request_id()
    }

    Retry.with_retry(fn ->
      case post_mcp(url, body, config.timeout_recall_ms) do
        {:ok, %{"result" => results}} when is_list(results) -> {:ok, results}
        {:ok, _} -> {:ok, []}
        error -> error
      end
    end)
  end

  @doc false
  def do_reflect(url, question, opts) do
    config = Config.effective_config()
    budget = normalize_budget(Keyword.get(opts, :budget, :low))
    context = Keyword.get(opts, :context)
    bank_id = resolve_bank_id(opts)

    params =
      %{
        question: question,
        project_id: get_project_id()
      }
      |> maybe_put(:context, context)
      |> maybe_put(:budget, budget)
      |> maybe_put(:bank_id, bank_id)

    body = %{
      jsonrpc: "2.0",
      method: "hindsight/reflect",
      params: params,
      id: generate_request_id()
    }

    Retry.with_retry(fn ->
      case post_mcp(url, body, config.timeout_reflect_ms) do
        {:ok, %{"result" => %{"insight" => insight}}} -> {:ok, insight}
        {:ok, %{"result" => insight}} when is_binary(insight) -> {:ok, insight}
        {:ok, _} -> {:ok, "No insights available"}
        error -> error
      end
    end)
  end

  defp do_health_check(url) do
    config = Config.effective_config()

    body = %{
      jsonrpc: "2.0",
      method: "hindsight/health",
      params: %{},
      id: generate_request_id()
    }

    post_mcp(url, body, config.timeout_health_ms)
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

  defp post_mcp(url, body, timeout) do
    headers = build_headers(url)

    case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, %{reason: :timeout}} ->
        {:error, {:transport_error, :timeout}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:exception, error}}
  end

  defp build_headers(url) do
    headers = [{"Content-Type", "application/json"}]

    if Config.requires_auth?(url) do
      case Config.get_api_key() do
        nil -> headers
        key -> [{"Authorization", "Bearer #{key}"} | headers]
      end
    else
      headers
    end
  end

  @doc false
  def enrich_metadata(metadata, opts) do
    metadata
    |> maybe_put_new(:context, Keyword.get(opts, :context))
    |> Map.merge(%{
      host_version: application_version(),
      project_id: get_project_id(),
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

  defp get_project_id do
    cwd = File.cwd!()
    :erlang.phash2(cwd) |> to_string()
  end

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
  def report_result({:ok, _}), do: CircuitBreaker.report_success()

  @doc false
  def report_result({:error, reason}), do: CircuitBreaker.report_failure(reason)

  @doc false
  def generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc false
  def resolve_bank_id(opts) do
    opts[:target_bank] || opts[:bank_id] || Config.effective_bank_id()
  end

  @doc false
  def normalize_budget(nil), do: "low"

  @doc false
  def normalize_budget(budget) when is_atom(budget),
    do: budget |> Atom.to_string() |> String.downcase()

  @doc false
  def normalize_budget(budget) when is_binary(budget), do: String.downcase(budget)
  def normalize_budget(_), do: "low"

  @doc false
  def maybe_put(map, _key, nil), do: map

  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def maybe_put_new(map, _key, nil), do: map

  def maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
end
