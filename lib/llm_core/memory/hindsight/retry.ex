defmodule LlmCore.Memory.Hindsight.Retry do
  @moduledoc """
  Retry logic with exponential backoff for Hindsight operations.

  Features:
  - Configurable max retries and backoff timing
  - Jitter to prevent thundering herd
  - Retry classification (retry transient, fail fast on client errors)

  ## Retry Classification

  - **Retry**: connection_refused, timeout, 5xx errors
  - **No retry**: 4xx errors, invalid response
  """

  require Logger

  alias LlmCore.Memory.Hindsight.Config

  @type retry_result :: {:ok, term()} | {:error, term()}

  @doc """
  Wraps an operation with retry logic.

  ## Options
  - `:max_retries` - maximum retry attempts (default from config)
  - `:backoff_ms` - list of backoff delays in ms (default from config)

  ## Example

      Retry.with_retry(fn -> do_request() end, max_retries: 3)
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), keyword()) :: retry_result()
  def with_retry(operation, opts \\ []) when is_function(operation, 0) do
    config = Config.effective_config()
    max_retries = Keyword.get(opts, :max_retries, config.max_retries)
    backoff_ms = Keyword.get(opts, :backoff_ms, config.retry_backoff_ms)

    do_retry(operation, 0, max_retries, backoff_ms)
  end

  # Private implementation

  defp do_retry(operation, attempt, max_retries, backoff_ms) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        if should_retry?(reason) and attempt < max_retries do
          delay = get_delay(attempt, backoff_ms)

          Logger.debug(
            "Hindsight retry #{attempt + 1}/#{max_retries} after #{delay}ms: #{inspect(reason)}"
          )

          Process.sleep(delay)
          do_retry(operation, attempt + 1, max_retries, backoff_ms)
        else
          if attempt > 0 do
            Logger.warning(
              "Hindsight request failed after #{attempt} retries: #{inspect(reason)}"
            )
          end

          error
        end
    end
  end

  @doc """
  Determines if an error should be retried.
  """
  @spec should_retry?(term()) :: boolean()
  def should_retry?(reason) do
    case reason do
      # Transport errors - retry
      {:transport_error, :econnrefused} -> true
      {:transport_error, :timeout} -> true
      {:transport_error, :closed} -> true
      {:transport_error, :nxdomain} -> true
      {:transport_error, _} -> true
      # Timeout - retry
      :timeout -> true
      # Server errors (5xx) - retry
      {:http_error, status} when status >= 500 and status < 600 -> true
      {:http_error, status, _body} when status >= 500 and status < 600 -> true
      # Client errors (4xx) - don't retry
      {:http_error, status} when status >= 400 and status < 500 -> false
      {:http_error, status, _body} when status >= 400 and status < 500 -> false
      # Circuit open - don't retry (handled by circuit breaker)
      :circuit_open -> false
      # Unknown errors - don't retry
      _ -> false
    end
  end

  @doc """
  Gets the delay for a specific retry attempt with jitter.
  """
  @spec get_delay(non_neg_integer(), [pos_integer()]) :: pos_integer()
  def get_delay(attempt, backoff_ms) do
    base_delay =
      if attempt < length(backoff_ms) do
        Enum.at(backoff_ms, attempt)
      else
        List.last(backoff_ms) || 4_000
      end

    # Add jitter (±10%)
    jitter_range = div(base_delay, 10)
    jitter = :rand.uniform(jitter_range * 2) - jitter_range

    max(100, base_delay + jitter)
  end
end
