defmodule LlmCore.Memory.Hindsight.WriteBuffer do
  @moduledoc """
  Write-behind buffer for Hindsight retain operations.

  Features:
  - Buffers retain calls for batch sending
  - Sends batch every 5 seconds or at 50 items
  - Persists buffer to disk on shutdown
  - Restores buffer on startup
  - Retries failed batches with exponential backoff

  This ensures retain operations don't block callers and
  reduces the number of requests to Hindsight.
  """

  use GenServer
  require Logger

  alias LlmCore.Memory.Backend.HindsightREST
  alias LlmCore.Memory.Hindsight.Config

  @flush_interval_ms 5_000
  @max_buffer_size 50
  @buffer_file "hindsight_buffer.jsonl"

  @type state :: %{
          buffer: [map()],
          buffer_size: non_neg_integer(),
          flush_pending: boolean(),
          timer_ref: reference() | nil,
          retry_count: non_neg_integer()
        }

  # Client API

  @doc """
  Starts the write buffer GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Buffers a retain operation for batch sending.
  Returns immediately (non-blocking).
  """
  @spec buffer(String.t(), map(), keyword()) :: :ok
  def buffer(content, metadata, opts \\ []) do
    bank_id = Keyword.get(opts, :bank_id)

    api_key =
      if Keyword.get(opts, :api_key_resolved, false),
        do: Keyword.get(opts, :api_key),
        else: resolve_api_key(Keyword.get(opts, :api_key))

    url = Keyword.get(opts, :url) || Config.effective_url()
    GenServer.cast(__MODULE__, {:buffer, content, metadata, bank_id, api_key, url})
  end

  @doc """
  Flushes the buffer immediately (blocking).
  Used before shutdown or by CLI command.
  """
  @spec flush() :: :ok | {:error, term()}
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  @doc """
  Returns the current buffer size.
  """
  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    GenServer.call(__MODULE__, :buffer_size)
  end

  @doc false
  @spec clear_buffer() :: :ok
  def clear_buffer do
    GenServer.call(__MODULE__, :clear_buffer)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Restore buffer from disk if exists
    buffer = restore_buffer()

    # Schedule periodic flush
    timer_ref = schedule_flush()

    {:ok,
     %{
       buffer: buffer,
       buffer_size: length(buffer),
       flush_pending: false,
       timer_ref: timer_ref,
       retry_count: 0
     }}
  end

  @impl true
  def handle_cast({:buffer, content, metadata, bank_id, api_key, url}, state) do
    item = %{
      id: System.unique_integer([:positive, :monotonic]),
      content: content,
      metadata: metadata,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      project_id: get_project_id(),
      bank_id: bank_id,
      api_key: api_key,
      credential_state: if(api_key in [nil, ""], do: :absent, else: :resolved),
      url: url
    }

    new_buffer = [item | state.buffer]
    new_size = state.buffer_size + 1
    flush_pending = state.flush_pending || new_size >= @max_buffer_size

    if flush_pending && not state.flush_pending do
      send(self(), :flush_now)
    end

    {:noreply,
     %{
       state
       | buffer: new_buffer,
         buffer_size: new_size,
         flush_pending: flush_pending
     }}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {reply, state} = flush_state(state, :all)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:buffer_size, _from, state) do
    {:reply, state.buffer_size, state}
  end

  @impl true
  def handle_call(:clear_buffer, _from, state) do
    {:reply, :ok, %{state | buffer: [], buffer_size: 0, flush_pending: false}}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state =
      if state.buffer != [] do
        case flush_state(state, :all) do
          {:ok, state} ->
            state

          {{:error, reason}, state} ->
            Logger.warning("Hindsight write buffer flush failed: #{inspect(reason)}")
            schedule_retry(state.retry_count)
            %{state | retry_count: state.retry_count + 1, flush_pending: true}
        end
      else
        state
      end

    timer_ref = schedule_flush()
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:flush_now, state) do
    case flush_state(state, @max_buffer_size) do
      {:ok, state} ->
        if state.buffer_size >= @max_buffer_size, do: send(self(), :flush_now)
        {:noreply, %{state | flush_pending: state.buffer_size >= @max_buffer_size}}

      {{:error, reason}, state} ->
        Logger.warning("Hindsight write buffer flush failed: #{inspect(reason)}")
        schedule_retry(state.retry_count)
        {:noreply, %{state | flush_pending: true, retry_count: state.retry_count + 1}}
    end
  end

  @impl true
  def handle_info(:retry_flush, state) do
    send(self(), :flush_now)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Persist buffer to disk
    if state.buffer != [] do
      persist_buffer(state.buffer)
    end

    :ok
  end

  # Private helpers

  defp schedule_flush do
    Process.send_after(self(), :flush_timer, @flush_interval_ms)
  end

  defp schedule_retry(retry_count) do
    config = Config.effective_config()
    backoffs = config.retry_backoff_ms

    delay =
      if retry_count < length(backoffs) do
        Enum.at(backoffs, retry_count)
      else
        List.last(backoffs) || 4_000
      end

    Process.send_after(self(), :retry_flush, delay)
  end

  defp flush_state(state, limit) do
    items = take_oldest(state.buffer, limit)

    case do_flush(items) do
      {:ok, sent_ids} ->
        remaining = reject_sent(state.buffer, sent_ids)

        {:ok,
         %{
           state
           | buffer: remaining,
             buffer_size: length(remaining),
             flush_pending: false,
             retry_count: 0
         }}

      {:error, reason, sent_ids} ->
        remaining = reject_sent(state.buffer, sent_ids)

        {{:error, reason},
         %{
           state
           | buffer: remaining,
             buffer_size: length(remaining)
         }}
    end
  end

  defp do_flush([]), do: {:ok, MapSet.new()}

  defp do_flush(buffer) do
    fallback_url = Config.effective_url()

    buffer
    |> Enum.group_by(
      &{
        Map.get(&1, :url) || Map.get(&1, "url") || fallback_url,
        Map.get(&1, :bank_id) || Map.get(&1, "bank_id"),
        credential(&1)
      }
    )
    |> Enum.sort_by(fn {{url, bank_id, _api_key}, _items} ->
      {to_string(url), to_string(bank_id)}
    end)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      {{nil, _bank_id, _api_key}, items}, {:ok, sent_ids} ->
        Logger.debug("Memory backend not configured, skipping buffer flush")
        {:cont, {:ok, MapSet.union(sent_ids, item_ids(items))}}

      {{url, bank_id, {:missing, marker}}, _items}, {:ok, sent_ids} ->
        {:halt, {:error, {:missing_buffer_credential, marker, url, bank_id}, sent_ids}}

      {{url, bank_id, api_key}, items}, {:ok, sent_ids} ->
        case send_batch(url, bank_id, items, api_key) do
          :ok -> {:cont, {:ok, MapSet.union(sent_ids, item_ids(items))}}
          {:error, reason} -> {:halt, {:error, reason, sent_ids}}
        end
    end)
  end

  defp take_oldest(buffer, :all), do: Enum.reverse(buffer)

  defp take_oldest(buffer, limit) when is_integer(limit) do
    buffer
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  defp reject_sent(buffer, sent_ids) do
    Enum.reject(buffer, &(item_id(&1) in sent_ids))
  end

  defp item_ids(items), do: MapSet.new(items, &item_id/1)

  defp item_id(item) do
    Map.get(item, :id) || Map.get(item, "id") ||
      {:legacy, Map.get(item, :timestamp) || Map.get(item, "timestamp"), :erlang.phash2(item)}
  end

  defp credential(item) do
    api_key = fetch_item(item, :api_key)

    case fetch_item(item, :credential_state) do
      :resolved -> api_key
      "resolved" -> api_key
      :absent -> nil
      "absent" -> nil
      :redacted -> {:missing, item_id(item)}
      "redacted" -> {:missing, item_id(item)}
      nil when api_key in [nil, ""] -> nil
      nil -> api_key
    end
  end

  defp fetch_item(item, key) do
    case Map.fetch(item, key) do
      {:ok, value} -> value
      :error -> Map.get(item, Atom.to_string(key))
    end
  end

  defp send_batch(base_url, bank_id, items, api_key) do
    config = Config.effective_config()
    timeout = config.timeout_retain_ms

    # Build REST API retain request
    # bank_id is required in the URL path for Hindsight 0.4+
    effective_bank = bank_id || config.default_bank_id || "default"

    retain_items =
      Enum.map(items, fn item ->
        %{
          content: item[:content] || item["content"],
          context:
            get_in(item, [:metadata, :context]) || get_in(item, ["metadata", "context"]) ||
              "general"
        }
      end)

    body = %{items: retain_items, async: true}
    path = "/v1/default/banks/#{effective_bank}/memories"

    case HindsightREST.rest_post(base_url, path, body, timeout,
           api_key: api_key,
           api_key_resolved: true
         ) do
      {:ok, _response} ->
        Logger.debug("Hindsight batch retained #{length(items)} items in bank #{effective_bank}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:exception, error}}
  end

  @doc false
  defdelegate build_headers(api_key \\ nil), to: HindsightREST

  defp resolve_api_key(api_key) when api_key in [nil, ""], do: Config.get_api_key()
  defp resolve_api_key(api_key), do: api_key

  defp get_project_id do
    cwd = File.cwd!()
    :erlang.phash2(cwd) |> to_string()
  end

  defp buffer_file_path do
    Path.join(LlmCore.Paths.global_memory_dir(), @buffer_file)
  end

  defp persist_buffer(buffer) do
    path = buffer_file_path()
    File.mkdir_p!(Path.dirname(path))

    content =
      buffer
      |> Enum.map(&redact_credential/1)
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    File.write!(path, content)
    File.chmod!(path, 0o600)
    Logger.info("Persisted #{length(buffer)} items to Hindsight buffer file")
  rescue
    error ->
      Logger.warning("Failed to persist Hindsight buffer: #{inspect(error)}")
  end

  defp restore_buffer do
    path = buffer_file_path()

    case File.read(path) do
      {:ok, content} ->
        items =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        # Delete the file after reading
        File.rm(path)

        Logger.info("Restored #{length(items)} items from Hindsight buffer file")
        items

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp redact_credential(item) do
    state =
      case {fetch_item(item, :credential_state), fetch_item(item, :api_key)} do
        {value, _api_key} when value in [:resolved, "resolved"] -> :redacted
        {value, _api_key} when value in [:absent, "absent"] -> :absent
        {nil, api_key} when api_key in [nil, ""] -> :absent
        _ -> :redacted
      end

    item
    |> Map.delete(:api_key)
    |> Map.delete("api_key")
    |> Map.put(:credential_state, state)
  end
end
