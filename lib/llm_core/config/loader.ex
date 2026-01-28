defmodule LlmCore.Config.Loader do
  @moduledoc """
  Loads llm_core configuration files (routing, etc.) from disk and updates the store.
  """

  require Logger

  alias LlmCore.Config.Store
  alias LlmCore.Router.RoutingTable

  @doc """
  Loads the routing configuration from disk without mutating the store.
  """
  @spec load_routing(keyword()) :: {:ok, RoutingTable.t()} | {:error, term()}
  def load_routing(opts \\ []) do
    path = Keyword.get(opts, :path, default_routing_path())

    with {:ok, yaml} <- read_yaml(path),
         {:ok, table} <- build_routing_table(yaml) do
      {:ok, table}
    end
  end

  @doc """
  Loads the routing configuration and writes it to the runtime store.
  Broadcasts change notifications so dependent processes can refresh.
  """
  @spec reload_routing(keyword()) :: {:ok, RoutingTable.t()} | {:error, term()}
  def reload_routing(opts \\ []) do
    case load_routing(opts) do
      {:ok, table} ->
        :ok = Store.put_routing(table)
        dispatch_reload(:routing)
        {:ok, table}

      {:error, :not_found} ->
        table = RoutingTable.new(%{"default" => "claude"})
        :ok = Store.put_routing(table)
        dispatch_reload(:routing)
        {:ok, table}

      error ->
        error
    end
  end

  defp build_routing_table(nil) do
    {:ok, RoutingTable.new(%{"default" => "claude"})}
  end

  defp build_routing_table(%{} = yaml) do
    {:ok, RoutingTable.new(yaml)}
  rescue
    error -> {:error, {:invalid_routing, error}}
  end

  defp read_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, yaml} -> {:ok, yaml || %{}}
        {:error, reason} -> {:error, {:yaml_error, reason}}
      end
    else
      Logger.debug("Routing config not found at #{path}")
      {:error, :not_found}
    end
  end

  defp dispatch_reload(topic) do
    :telemetry.execute(
      [
        :llm_core,
        :config,
        :reloaded
      ],
      %{count: 1},
      %{config: topic}
    )

    send(LlmCore.Router, {:config_reloaded, topic})
  end

  defp default_routing_path do
    Path.join(LlmCore.Paths.project_config_dir(), "routing.yml")
  end
end
