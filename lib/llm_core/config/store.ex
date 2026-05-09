defmodule LlmCore.Config.Store do
  @moduledoc """
  Lightweight ETS-backed storage for runtime configuration.

  The store keeps the latest routing tables, provider definitions, CLI configs,
  and other hot-reloadable artifacts so they can be accessed without disk I/O.

  ## Stored Namespaces

    * `{:config, :routing}` — Current `RoutingTable`
    * `{:config, :providers}` — Map of `%Definition{}` structs keyed by provider id
    * `{:config, :cli_providers}` — Map of `%CLIProvider.Config{}` structs keyed by atom name
    * `{:config, :telemetry}` — Telemetry settings map
    * `{:config, :raw}` — Raw merged TOML configuration

  ## Access Patterns

  Direct ETS reads (no GenServer call):

      {:ok, table} = LlmCore.Config.Store.get_routing()
      {:ok, providers} = LlmCore.Config.Store.fetch(:config, :providers)

  Writes go through the GenServer for serialisation:

      :ok = LlmCore.Config.Store.put_routing(%RoutingTable{...})
      :ok = LlmCore.Config.Store.put(:config, :telemetry, %{...})
  """

  use GenServer

  @table :llm_core_config

  @doc """
  Starts the config store GenServer and creates the backing ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc """
  Stores the current routing table.
  """
  @spec put_routing(LlmCore.Router.RoutingTable.t()) :: :ok
  def put_routing(%LlmCore.Router.RoutingTable{} = table) do
    :ets.insert(@table, {{:config, :routing}, table})
    :ok
  end

  @doc """
  Fetches the current routing table.
  """
  @spec get_routing() :: {:ok, LlmCore.Router.RoutingTable.t()} | {:error, :not_found}
  def get_routing do
    case :ets.lookup(@table, {:config, :routing}) do
      [{_, table}] -> {:ok, table}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Generic helper for storing custom config namespaces.
  """
  @spec put(atom(), atom(), term()) :: :ok
  def put(namespace, key, value) when is_atom(namespace) and is_atom(key) do
    :ets.insert(@table, {{namespace, key}, value})
    :ok
  end

  @doc """
  Fetches a value previously stored with `put/3`.
  """
  @spec fetch(atom(), atom()) :: {:ok, term()} | {:error, :not_found}
  def fetch(namespace, key) do
    case :ets.lookup(@table, {namespace, key}) do
      [{_, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end
end
