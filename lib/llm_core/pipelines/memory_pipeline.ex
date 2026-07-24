defmodule LlmCore.Pipelines.MemoryPipeline.Context do
  @moduledoc false

  defstruct operation: nil,
            payload: %{},
            config: nil,
            url: nil,
            result: nil,
            cache_key: nil,
            bypass_cache: false
end

defmodule LlmCore.Pipelines.MemoryPipeline do
  @moduledoc """
  ALF pipeline orchestrating REST memory operations (retain, recall, reflect).
  It centralizes caching, circuit breaker gating, retries, and async buffering.
  """

  use ALF.DSL

  alias ALF.Manager
  alias LlmCore.Memory.Backend.HindsightREST
  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.{Cache, CircuitBreaker, Config, WriteBuffer}
  alias LlmCore.Pipelines.MemoryPipeline.Context
  alias LlmCore.Telemetry

  @components [
    stage(:load_config),
    stage(:normalize_request),
    stage(:ensure_availability),
    stage(:maybe_serve_from_cache),
    stage(:circuit_gate),
    stage(:execute_operation),
    stage(:maybe_cache_result),
    stage(:finalize_result)
  ]

  # -- Public API -----------------------------------------------------------

  @spec retain_async(String.t(), map(), keyword()) :: :ok
  def retain_async(content, metadata, opts \\ []) do
    execute(:retain_async, %{content: content, metadata: metadata || %{}, opts: opts})
  end

  @spec retain_sync(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retain_sync(content, metadata, opts \\ []) do
    execute(:retain_sync, %{content: content, metadata: metadata || %{}, opts: opts})
  end

  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recall(query, opts \\ []) do
    execute(:recall, %{query: query, opts: opts})
  end

  @spec reflect(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def reflect(question, opts \\ []) do
    execute(:reflect, %{question: question, opts: opts})
  end

  # -- Pipeline stages ------------------------------------------------------

  @doc false
  @spec load_config(Context.t(), keyword()) :: Context.t()
  def load_config(%Context{} = ctx, _opts) do
    config = Config.effective_config()
    %{ctx | config: config, url: Config.effective_url()}
  end

  @doc false
  @spec normalize_request(Context.t(), keyword()) :: Context.t()
  def normalize_request(%Context{operation: :retain_async, payload: payload} = ctx, _opts) do
    opts = Map.get(payload, :opts, [])
    metadata = Map.get(payload, :metadata, %{}) || %{}
    enriched = HindsightREST.enrich_metadata(metadata, opts)
    bank_id = HindsightREST.resolve_bank_id(opts)

    updated_payload =
      payload
      |> Map.put(:metadata, enriched)
      |> Map.put(:bank_id, bank_id)

    %{ctx | payload: updated_payload}
  end

  def normalize_request(%Context{operation: :retain_sync} = ctx, _opts), do: ctx

  def normalize_request(%Context{operation: :recall, payload: payload} = ctx, _opts) do
    opts = Map.get(payload, :opts, [])
    cache_key = Cache.recall_key(payload.query, with_namespace(opts, ctx))
    bypass = Keyword.get(opts, :bypass_cache, false)
    %{ctx | cache_key: cache_key, bypass_cache: bypass}
  end

  def normalize_request(%Context{operation: :reflect, payload: payload} = ctx, _opts) do
    opts = Map.get(payload, :opts, [])
    cache_key = Cache.reflect_key(payload.question, with_namespace(opts, ctx))
    %{ctx | cache_key: cache_key, bypass_cache: Keyword.get(opts, :bypass_cache, false)}
  end

  def normalize_request(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec ensure_availability(Context.t(), keyword()) :: Context.t()
  def ensure_availability(%Context{result: result} = ctx, _opts) when not is_nil(result), do: ctx

  def ensure_availability(
        %Context{operation: :retain_async, config: config, url: url} = ctx,
        _opts
      ) do
    if config.enabled && url do
      ctx
    else
      %{ctx | result: :ok}
    end
  end

  def ensure_availability(
        %Context{operation: :retain_sync, config: config, url: url} = ctx,
        _opts
      ) do
    if config.enabled && url do
      ctx
    else
      %{ctx | result: {:error, :not_configured}}
    end
  end

  def ensure_availability(%Context{operation: :recall, config: config, url: url} = ctx, _opts) do
    if config.enabled && url do
      ctx
    else
      %{ctx | result: {:ok, []}}
    end
  end

  def ensure_availability(%Context{operation: :reflect, config: config, url: url} = ctx, _opts) do
    if config.enabled && url do
      ctx
    else
      %{ctx | result: {:ok, "Hindsight unavailable"}}
    end
  end

  def ensure_availability(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec maybe_serve_from_cache(Context.t(), keyword()) :: Context.t()
  def maybe_serve_from_cache(%Context{result: result} = ctx, _opts) when not is_nil(result),
    do: ctx

  def maybe_serve_from_cache(%Context{operation: op, bypass_cache: true} = ctx, _opts)
      when op in [:recall, :reflect],
      do: ctx

  def maybe_serve_from_cache(%Context{operation: :recall, cache_key: key} = ctx, _opts)
      when not is_nil(key) do
    case Cache.get_with_stale(key) do
      {:hit, value} ->
        %{ctx | result: {:ok, value}}

      {:stale, value} ->
        refresh_recall_async(ctx.url, ctx.payload.query, ctx.payload.opts, key, elem(key, 1))
        %{ctx | result: {:ok, value}}

      :miss ->
        ctx
    end
  end

  def maybe_serve_from_cache(%Context{operation: :reflect, cache_key: key} = ctx, _opts)
      when not is_nil(key) do
    case Cache.get_with_stale(key) do
      {:hit, value} ->
        %{ctx | result: {:ok, value}}

      {:stale, value} ->
        refresh_reflect_async(ctx.url, ctx.payload.question, ctx.payload.opts, key, elem(key, 1))
        %{ctx | result: {:ok, value}}

      :miss ->
        ctx
    end
  end

  def maybe_serve_from_cache(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec circuit_gate(Context.t(), keyword()) :: Context.t()
  def circuit_gate(%Context{result: result} = ctx, _opts) when not is_nil(result), do: ctx

  def circuit_gate(%Context{operation: op} = ctx, _opts)
      when op not in [:retain_sync, :recall, :reflect],
      do: ctx

  def circuit_gate(%Context{} = ctx, _opts) do
    case CircuitBreaker.allow?(request_namespace(ctx)) do
      :ok -> ctx
      {:error, :circuit_open} -> %{ctx | result: {:error, :circuit_open}}
    end
  end

  @doc false
  @spec execute_operation(Context.t(), keyword()) :: Context.t()
  def execute_operation(%Context{result: result} = ctx, _opts) when not is_nil(result), do: ctx

  def execute_operation(%Context{operation: :retain_async, payload: payload} = ctx, _opts) do
    opts = Map.get(payload, :opts, [])

    api_key =
      case Keyword.get(opts, :api_key) do
        value when value in [nil, ""] -> System.get_env(ctx.config.api_key_env)
        value -> value
      end

    buffer_opts = [
      bank_id: Map.get(payload, :bank_id),
      url: ctx.url,
      api_key: api_key,
      api_key_resolved: true
    ]

    WriteBuffer.buffer(payload.content, payload.metadata, buffer_opts)
    %{ctx | result: :ok}
  end

  def execute_operation(
        %Context{operation: :retain_sync, url: url, payload: payload} = ctx,
        _opts
      ) do
    result = HindsightREST.do_retain(url, payload.content, payload.metadata, payload.opts)
    HindsightREST.report_result(result, request_namespace(ctx))
    %{ctx | result: result}
  end

  def execute_operation(%Context{operation: :recall, url: url, payload: payload} = ctx, _opts) do
    result = HindsightREST.do_recall(url, payload.query, payload.opts)
    HindsightREST.report_result(result, request_namespace(ctx))
    %{ctx | result: result}
  end

  def execute_operation(%Context{operation: :reflect, url: url, payload: payload} = ctx, _opts) do
    result = HindsightREST.do_reflect(url, payload.question, payload.opts)
    HindsightREST.report_result(result, request_namespace(ctx))
    %{ctx | result: result}
  end

  def execute_operation(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec maybe_cache_result(Context.t(), keyword()) :: Context.t()
  def maybe_cache_result(
        %Context{operation: :recall, result: {:ok, value}, cache_key: key, config: config} = ctx,
        _opts
      )
      when not is_nil(key) do
    Cache.put(key, value, ttl_ms: config.cache_ttl_ms)
    ctx
  end

  def maybe_cache_result(
        %Context{operation: :reflect, result: {:ok, value}, cache_key: key, config: config} = ctx,
        _opts
      )
      when not is_nil(key) do
    Cache.put(key, value, ttl_ms: config.cache_reflect_ttl_ms)
    ctx
  end

  def maybe_cache_result(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec finalize_result(Context.t(), keyword()) :: term()
  def finalize_result(%Context{result: result}, _opts) when not is_nil(result), do: result
  def finalize_result(_ctx, _opts), do: {:error, :hindsight_failed}

  # -- Helpers --------------------------------------------------------------

  defp with_namespace(opts, ctx) do
    Keyword.put(opts, :memory_namespace, request_namespace(ctx))
  end

  defp request_namespace(ctx) do
    opts = Map.get(ctx.payload, :opts, [])
    bank_id = opts[:target_bank] || opts[:bank_id] || ctx.config.default_bank_id
    MemoryConfig.namespace(ctx.url, bank_id)
  end

  defp execute(operation, payload) do
    ensure_started()

    context = %Context{operation: operation, payload: payload}

    Telemetry.span(:memory_pipeline, %{operation: operation}, fn ->
      result = Manager.call(context, __MODULE__, sync: true)
      {result, telemetry_result(result)}
    end)
  end

  defp telemetry_result({:ok, _}), do: %{status: :ok}
  defp telemetry_result(:ok), do: %{status: :ok}
  defp telemetry_result({:error, reason}), do: %{status: :error, error: reason}
  defp telemetry_result(%ALF.ErrorIP{error: reason}), do: %{status: :error, error: reason}

  defp ensure_started do
    unless Manager.started?(__MODULE__) do
      :ok = Manager.start(__MODULE__, sync: true)
    end
  end

  defp refresh_recall_async(nil, _query, _opts, _cache_key, _namespace), do: :ok

  defp refresh_recall_async(url, query, opts, cache_key, namespace) do
    start_refresh(cache_key, fn ->
      case CircuitBreaker.allow?(namespace) do
        :ok ->
          case HindsightREST.do_recall(url, query, opts) do
            {:ok, results} = ok ->
              HindsightREST.report_result(ok, namespace)
              Cache.put(cache_key, results)

            error ->
              HindsightREST.report_result(error, namespace)
          end

        _ ->
          :ok
      end
    end)
  end

  defp refresh_reflect_async(nil, _question, _opts, _cache_key, _namespace), do: :ok

  defp refresh_reflect_async(url, question, opts, cache_key, namespace) do
    start_refresh(cache_key, fn ->
      case CircuitBreaker.allow?(namespace) do
        :ok ->
          case HindsightREST.do_reflect(url, question, opts) do
            {:ok, result} = ok ->
              HindsightREST.report_result(ok, namespace)
              config = Config.effective_config()
              Cache.put(cache_key, result, ttl_ms: config.cache_reflect_ttl_ms)

            error ->
              HindsightREST.report_result(error, namespace)
          end

        _ ->
          :ok
      end
    end)
  end

  defp start_refresh(cache_key, refresh) do
    if Cache.claim_refresh(cache_key) do
      task = fn ->
        try do
          refresh.()
        after
          Cache.finish_refresh(cache_key)
        end
      end

      case Process.whereis(LlmCore.Memory.TaskSupervisor) do
        nil ->
          Cache.finish_refresh(cache_key)

        _pid ->
          case Task.Supervisor.start_child(LlmCore.Memory.TaskSupervisor, task) do
            {:ok, _pid} -> :ok
            {:error, _reason} -> Cache.finish_refresh(cache_key)
          end
      end
    end

    :ok
  end
end
