defmodule LlmCore.Memory.Hindsight.Cache do
  @moduledoc """
  Smart caching layer for Hindsight operations.

  Features:
  - TTL-based expiry
  - LRU eviction when max entries exceeded
  - Stale-while-revalidate for fast responses
  - Background refresh before TTL expiry
  - Manual invalidation

  ## Cache Keys

  - Recall: `{:recall, query_hash, opts_hash}`
  - Reflect: `{:reflect, question_hash}`
  """

  use GenServer
  require Logger

  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.Config

  @ets_table :llm_core_hindsight_cache
  @sweep_interval_ms 60_000
  @stale_grace_ms 30_000

  @type cache_entry :: %{
          value: term(),
          inserted_at: integer(),
          ttl_ms: pos_integer(),
          last_access: integer()
        }

  @type stats :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          size: non_neg_integer()
        }

  # Client API

  @doc """
  Starts the cache GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a cached value by key, returning `{:hit, value}` or `:miss`.
  """
  @spec get(term()) :: {:hit, term()} | :miss
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Gets a cached value, allowing stale data within grace period.
  Returns `{:hit, value}` or `{:stale, value}` or `:miss`.
  """
  @spec get_with_stale(term()) :: {:hit, term()} | {:stale, term()} | :miss
  def get_with_stale(key) do
    GenServer.call(__MODULE__, {:get_with_stale, key})
  end

  @doc """
  Stores a value in the cache with TTL.
  """
  @spec put(term(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    GenServer.cast(__MODULE__, {:put, key, value, opts})
  end

  @doc false
  @spec claim_refresh(term()) :: boolean()
  def claim_refresh(key) do
    GenServer.call(__MODULE__, {:claim_refresh, key})
  end

  @doc false
  @spec finish_refresh(term()) :: :ok
  def finish_refresh(key) do
    GenServer.cast(__MODULE__, {:finish_refresh, key})
  end

  @doc """
  Invalidates a specific cache entry.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @doc """
  Invalidates entries matching a key prefix/pattern.
  """
  @spec invalidate_pattern(term()) :: :ok
  def invalidate_pattern(pattern) do
    GenServer.cast(__MODULE__, {:invalidate_pattern, pattern})
  end

  @doc """
  Clears all cached entries.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: stats()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Generates a cache key for recall operations.
  """
  @spec recall_key(String.t(), keyword()) :: term()
  def recall_key(query, opts) do
    project_id = Keyword.get(opts, :project_id)
    namespace = Keyword.get(opts, :memory_namespace, fallback_namespace(opts))

    opts_hash =
      opts
      |> Keyword.drop([:bypass_cache, :memory_namespace])
      |> :erlang.phash2()

    {:recall, namespace, :erlang.phash2(query), opts_hash, project_id}
  end

  @doc """
  Generates a cache key for reflect operations.
  """
  @spec reflect_key(String.t() | atom(), keyword()) :: term()
  def reflect_key(question, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    namespace = Keyword.get(opts, :memory_namespace, fallback_namespace(opts))
    opts_hash = opts |> Keyword.delete(:memory_namespace) |> :erlang.phash2()
    {:reflect, namespace, :erlang.phash2(question), opts_hash, project_id}
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic sweep
    schedule_sweep()

    {:ok, %{hits: 0, misses: 0, refreshing: MapSet.new()}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@ets_table, key) do
      [{^key, entry}] ->
        if entry.inserted_at + entry.ttl_ms > now do
          # Update access time
          :ets.insert(@ets_table, {key, %{entry | last_access: now}})
          {:reply, {:hit, entry.value}, %{state | hits: state.hits + 1}}
        else
          # Expired
          :ets.delete(@ets_table, key)
          {:reply, :miss, %{state | misses: state.misses + 1}}
        end

      [] ->
        {:reply, :miss, %{state | misses: state.misses + 1}}
    end
  end

  @impl true
  def handle_call({:get_with_stale, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@ets_table, key) do
      [{^key, entry}] ->
        cond do
          # Fresh
          entry.inserted_at + entry.ttl_ms > now ->
            :ets.insert(@ets_table, {key, %{entry | last_access: now}})
            {:reply, {:hit, entry.value}, %{state | hits: state.hits + 1}}

          # Stale but within grace period
          entry.inserted_at + entry.ttl_ms + @stale_grace_ms > now ->
            {:reply, {:stale, entry.value}, %{state | hits: state.hits + 1}}

          # Too stale
          true ->
            :ets.delete(@ets_table, key)
            {:reply, :miss, %{state | misses: state.misses + 1}}
        end

      [] ->
        {:reply, :miss, %{state | misses: state.misses + 1}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(@ets_table, :size)

    hit_rate =
      if state.hits + state.misses > 0 do
        Float.round(state.hits / (state.hits + state.misses) * 100, 1)
      else
        0.0
      end

    {:reply,
     %{
       hits: state.hits,
       misses: state.misses,
       size: size,
       hit_rate: hit_rate
     }, state}
  end

  @impl true
  def handle_call({:claim_refresh, key}, _from, state) do
    if MapSet.member?(state.refreshing, key) do
      {:reply, false, state}
    else
      {:reply, true, %{state | refreshing: MapSet.put(state.refreshing, key)}}
    end
  end

  @impl true
  def handle_cast({:put, key, value, opts}, state) do
    config = Config.effective_config()
    default_ttl = config.cache_ttl_ms
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl)
    now = System.monotonic_time(:millisecond)

    entry = %{
      value: value,
      inserted_at: now,
      ttl_ms: ttl_ms,
      last_access: now
    }

    :ets.insert(@ets_table, {key, entry})

    # Check if we need to evict
    max_entries = config.cache_max_entries

    if :ets.info(@ets_table, :size) > max_entries do
      evict_lru()
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:finish_refresh, key}, state) do
    {:noreply, %{state | refreshing: MapSet.delete(state.refreshing, key)}}
  end

  @impl true
  def handle_cast({:invalidate, key}, state) do
    :ets.delete(@ets_table, key)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:invalidate_pattern, pattern}, state) do
    # Pattern is the first element of the key tuple
    :ets.tab2list(@ets_table)
    |> Enum.each(fn {key, _value} ->
      if match_pattern?(key, pattern) do
        :ets.delete(@ets_table, key)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@ets_table)
    {:noreply, %{state | hits: 0, misses: 0, refreshing: MapSet.new()}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  # Private helpers

  defp fallback_namespace(opts) do
    bank_id = opts[:target_bank] || opts[:bank_id] || Config.effective_bank_id()
    MemoryConfig.namespace(Config.effective_url(), bank_id)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@ets_table)
    |> Enum.each(fn {key, entry} ->
      if entry.inserted_at + entry.ttl_ms + @stale_grace_ms < now do
        :ets.delete(@ets_table, key)
      end
    end)
  end

  defp evict_lru do
    # Find oldest accessed entry
    oldest =
      :ets.tab2list(@ets_table)
      |> Enum.min_by(fn {_key, entry} -> entry.last_access end, fn -> nil end)

    case oldest do
      {key, _entry} -> :ets.delete(@ets_table, key)
      nil -> :ok
    end
  end

  defp match_pattern?(key, pattern) when is_tuple(key) and is_atom(pattern) do
    elem(key, 0) == pattern
  end

  defp match_pattern?(key, pattern) do
    key == pattern
  end
end
