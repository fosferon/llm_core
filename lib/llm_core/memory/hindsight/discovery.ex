defmodule LlmCore.Memory.Hindsight.Discovery do
  @moduledoc """
  Auto-discovery of Hindsight MCP endpoints.

  Probes default endpoints in order:
  1. http://localhost:8888/mcp/
  2. http://127.0.0.1:8888/mcp/

  Uses health check with 2-second timeout for fast discovery.
  Results are cached in ETS for session lifetime.
  """

  require Logger

  alias LlmCore.Memory.Hindsight.Config

  @default_endpoints [
    "http://localhost:8888/mcp/",
    "http://127.0.0.1:8888/mcp/"
  ]

  @health_timeout_ms 2_000

  @doc """
  Discovers Hindsight endpoint by probing default URLs.

  Returns the first responding endpoint or nil if none found.
  """
  @spec discover() :: String.t() | nil
  def discover do
    Logger.info("Discovering Hindsight MCP endpoint...")

    result =
      Enum.find(@default_endpoints, fn url ->
        case probe_health(url) do
          {:ok, _} ->
            Logger.info("Hindsight discovered at #{url}")
            true

          {:error, reason} ->
            Logger.debug("Hindsight probe failed for #{url}: #{inspect(reason)}")
            false
        end
      end)

    # Cache the result
    Config.set_discovered_url(result)

    if is_nil(result) do
      Logger.info("Hindsight not found, using local-only mode")
    end

    result
  end

  @doc """
  Returns cached discovery result without probing.
  """
  @spec cached_url() :: String.t() | nil
  def cached_url do
    Config.get_discovered_url()
  end

  @doc """
  Clears cached discovery and re-probes endpoints.
  """
  @spec refresh() :: String.t() | nil
  def refresh do
    Config.set_discovered_url(nil)
    discover()
  end

  @doc """
  Runs discovery asynchronously (non-blocking).
  """
  @spec discover_async() :: Task.t()
  def discover_async do
    Task.start(fn ->
      discover()
    end)
  end

  @doc """
  Probes a specific URL for health.
  """
  @spec probe_health(String.t()) :: {:ok, map()} | {:error, term()}
  def probe_health(url) do
    body = %{
      jsonrpc: "2.0",
      method: "hindsight/health",
      params: %{},
      id: generate_request_id()
    }

    case Req.post(url, json: body, receive_timeout: @health_timeout_ms) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

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

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
