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

  alias LlmCore.Memory.Hindsight.Config

  @flush_interval_ms 5_000
  @max_buffer_size 50
  @buffer_file "hindsight_buffer.jsonl"

  @type state :: %{
          buffer: [map()],
          timer_ref: reference() | nil,
          retry_count: non_neg_integer()
        }

  # Client API

  @doc """
  Starts the write buffer GenServer.
  """
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
    GenServer.cast(__MODULE__, {:buffer, content, metadata, bank_id})
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

    {:ok, %{buffer: buffer, timer_ref: timer_ref, retry_count: 0}}
  end

  @impl true
  def handle_cast({:buffer, content, metadata, bank_id}, state) do
    item = %{
      content: content,
      metadata: metadata,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      project_id: get_project_id(),
      bank_id: bank_id
    }

    new_buffer = [item | state.buffer]

    # Check if we should flush
    if length(new_buffer) >= @max_buffer_size do
      send(self(), :flush_now)
    end

    {:noreply, %{state | buffer: new_buffer}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    case do_flush(state.buffer) do
      :ok ->
        {:reply, :ok, %{state | buffer: [], retry_count: 0}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:buffer_size, _from, state) do
    {:reply, length(state.buffer), state}
  end

  @impl true
  def handle_call(:clear_buffer, _from, state) do
    {:reply, :ok, %{state | buffer: []}}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state =
      if state.buffer != [] do
        case do_flush(state.buffer) do
          :ok ->
            %{state | buffer: [], retry_count: 0}

          {:error, reason} ->
            Logger.warning("Hindsight write buffer flush failed: #{inspect(reason)}")
            schedule_retry(state.retry_count)
            %{state | retry_count: state.retry_count + 1}
        end
      else
        state
      end

    timer_ref = schedule_flush()
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:flush_now, state) do
    case do_flush(state.buffer) do
      :ok ->
        {:noreply, %{state | buffer: [], retry_count: 0}}

      {:error, reason} ->
        Logger.warning("Hindsight write buffer flush failed: #{inspect(reason)}")
        {:noreply, state}
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

  defp do_flush([]), do: :ok

  defp do_flush(buffer) do
    url = Config.effective_url()

    if url do
      buffer
      |> Enum.group_by(&Map.get(&1, :bank_id))
      |> Enum.reduce_while(:ok, fn {bank_id, items}, _acc ->
        case send_batch(url, bank_id, items) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      Logger.debug("Hindsight not configured, skipping buffer flush")
      :ok
    end
  end

  defp send_batch(url, bank_id, items) do
    config = Config.effective_config()
    timeout = config.timeout_retain_ms

    sanitized_items = Enum.map(items, &Map.drop(&1, [:bank_id]))

    # Build batch request
    body = %{
      jsonrpc: "2.0",
      method: "hindsight/retain_batch",
      params:
        %{
          items: sanitized_items,
          host_version: host_version()
        }
        |> maybe_put(:bank_id, bank_id),
      id: generate_request_id()
    }

    headers = build_headers(url)

    case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: 200}} ->
        Logger.debug("Hindsight batch retained #{length(items)} items")
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

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
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    File.write!(path, content)
    Logger.info("Persisted #{length(buffer)} items to Hindsight buffer file")
  rescue
    error ->
      Logger.warning("Failed to persist Hindsight buffer: #{inspect(error)}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp host_version do
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
