defmodule LlmCore.Pipelines.RoutingPipeline.Context do
  @moduledoc """
  Internal state passed through the routing pipeline stages.
  """

  defstruct task_type: nil,
            opts: [],
            routing_table: nil,
            table_source: nil,
            route_entry: nil,
            agent: nil,
            result: nil
end

defmodule LlmCore.Pipelines.RoutingPipeline do
  @moduledoc """
  ALF pipeline that resolves task types to provider/agent configurations.

  The pipeline currently runs through `ALF.Manager` in synchronous mode so it
  can be embedded directly in the GenServer router workflow. We can switch to a
  supervised, asynchronous pipeline when higher throughput is required.
  """

  use ALF.DSL

  alias ALF.Manager
  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Provider.Registry, as: ProviderRegistry
  alias LlmCore.Telemetry
  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.Pipelines.RoutingPipeline.Context
  alias LlmCore.Router.{ResolvedRoute, RouteEntry, RoutingTable}

  @components [
    stage(:normalize_task_type),
    stage(:load_routing_table),
    stage(:resolve_entry),
    stage(:load_agent),
    stage(:ensure_capabilities),
    stage(:build_resolved_route),
    stage(:finalize_result)
  ]

  @doc """
  Executes the routing pipeline synchronously for a single task type.
  """
  @spec route(String.t() | atom(), keyword()) ::
          {:ok, ResolvedRoute.t()} | {:error, term()}
  def route(task_type, opts \\ []) do
    ensure_started()
    context = %Context{task_type: task_type, opts: opts}

    result =
      Telemetry.span(:routing_pipeline, %{task_type: task_type}, fn ->
        result = Manager.call(context, __MODULE__, sync: true)
        {result, telemetry_result(result)}
      end)

    emit_routing_error(result, task_type, opts)
    result
  end

  # Unconditional (not subject to span sampling): a routing failure must always
  # be observable, with the caller's opaque :caller_ref for correlation.
  defp emit_routing_error({:error, reason}, task_type, opts) do
    {tag, detail} =
      case reason do
        {tag, %{} = detail} when is_atom(tag) -> {tag, detail}
        {tag, detail} when is_atom(tag) -> {tag, %{detail: detail}}
        tag when is_atom(tag) -> {tag, %{}}
        other -> {:unknown, %{detail: other}}
      end

    :telemetry.execute([:llm_core, :routing, :error], %{}, %{
      reason: tag,
      detail: detail,
      task_type: task_type,
      caller_ref: Keyword.get(opts, :caller_ref)
    })
  end

  defp emit_routing_error(_result, _task_type, _opts), do: :ok

  # --- Stage callbacks ----------------------------------------------------

  @doc false
  @spec normalize_task_type(Context.t(), keyword()) :: Context.t()
  def normalize_task_type(%Context{task_type: task_type} = ctx, _opts) when is_atom(task_type) do
    %{ctx | task_type: Atom.to_string(task_type)}
  end

  def normalize_task_type(%Context{task_type: task_type} = ctx, _opts)
      when is_binary(task_type) do
    %{ctx | task_type: String.trim(task_type)}
  end

  def normalize_task_type(%Context{} = ctx, _opts) do
    %{ctx | task_type: "default"}
  end

  @doc false
  @spec load_routing_table(Context.t(), keyword()) :: Context.t()
  def load_routing_table(%Context{opts: opts} = ctx, _opts) do
    routing_table_opt = Keyword.get(opts, :routing_table)

    {routing_table, source} =
      case routing_table_opt do
        %RoutingTable{} = table -> {table, :provided}
        _ -> fetch_table_from_store()
      end

    %{ctx | routing_table: routing_table, table_source: source}
  end

  defp fetch_table_from_store do
    case Store.get_routing() do
      {:ok, table} -> {table, :store}
      {:error, :not_found} -> {ensure_table_from_disk(), :config_layers}
    end
  end

  @doc false
  @spec resolve_entry(Context.t(), keyword()) :: Context.t()
  def resolve_entry(
        %Context{routing_table: %RoutingTable{} = table, task_type: task} = ctx,
        _opts
      ) do
    case Map.get(table.rules, task, table.default) do
      nil ->
        %{
          ctx
          | result:
              {:error, {:no_routing_default, %{task_type: task, table_source: ctx.table_source}}}
        }

      entry ->
        %{ctx | route_entry: entry}
    end
  end

  @doc false
  @spec load_agent(Context.t(), keyword()) :: Context.t()
  def load_agent(%Context{result: {:error, _}} = ctx, _opts), do: ctx

  def load_agent(%Context{route_entry: %RouteEntry{alias: alias}} = ctx, _opts) do
    case Registry.get(alias) do
      {:ok, agent} ->
        %{ctx | agent: agent}

      {:error, :not_found} ->
        suggestions = ProviderRegistry.suggest_alias(alias)

        %{
          ctx
          | result: {:error, {:provider_not_found, %{alias: alias, suggestions: suggestions}}}
        }
    end
  end

  def load_agent(%Context{} = ctx, _opts) do
    %{ctx | result: {:error, :no_matching_route}}
  end

  @doc false
  @spec ensure_capabilities(Context.t(), keyword()) :: Context.t()
  def ensure_capabilities(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def ensure_capabilities(%Context{agent: nil} = ctx, _opts), do: ctx

  def ensure_capabilities(
        %Context{route_entry: %RouteEntry{capabilities: capabilities}} = ctx,
        _opts
      )
      when capabilities in [%{}, nil],
      do: ctx

  def ensure_capabilities(
        %Context{agent: %Agent{} = agent, route_entry: %RouteEntry{capabilities: requirements}} =
          ctx,
        _opts
      ) do
    if capability_match?(agent.provider, agent.name, requirements || %{}) do
      ctx
    else
      suggestions = ProviderRegistry.suggest_capable(requirements || %{})

      %{
        ctx
        | result:
            {:error,
             {:capability_mismatch,
              %{alias: agent.name, required: requirements, suggestions: suggestions}}}
      }
    end
  end

  def ensure_capabilities(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec build_resolved_route(Context.t(), keyword()) :: Context.t()
  def build_resolved_route(%Context{result: {:error, _}} = ctx, _opts), do: ctx

  def build_resolved_route(%Context{agent: agent, route_entry: entry} = ctx, _opts)
      when not is_nil(agent) and not is_nil(entry) do
    route = ResolvedRoute.new(entry.alias, entry.mode, agent)
    %{ctx | result: {:ok, route}}
  end

  def build_resolved_route(%Context{} = ctx, _opts) do
    %{ctx | result: {:error, :provider_not_found}}
  end

  @doc false
  @spec finalize_result(Context.t(), keyword()) :: {:ok, ResolvedRoute.t()} | {:error, term()}
  def finalize_result(%Context{result: result}, _opts) when not is_nil(result), do: result
  def finalize_result(_ctx, _opts), do: {:error, :route_resolution_failed}

  defp telemetry_result({:ok, %ResolvedRoute{} = route}) do
    %{status: :ok, provider_alias: route.alias, mode: route.mode}
  end

  defp telemetry_result({:error, reason}) do
    %{status: :error, error: reason}
  end

  defp telemetry_result(%ALF.ErrorIP{error: {kind, reason, stacktrace}}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp telemetry_result(%ALF.ErrorIP{error: reason}) do
    %{status: :error, error: reason}
  end

  # --- Helpers ------------------------------------------------------------

  defp ensure_table_from_disk do
    case Loader.reload_routing() do
      {:ok, table} -> table
      {:error, _} -> RoutingTable.new(%{})
    end
  end

  defp ensure_started do
    unless Manager.started?(__MODULE__) do
      :ok = Manager.start(__MODULE__, sync: true)
    end
  end

  defp capability_match?(provider_module, alias, requirements) do
    definition_capabilities =
      case ProviderRegistry.lookup_by_alias(alias) do
        {:ok, definition} -> definition.capabilities || %{}
        _ -> fetch_module_capabilities(provider_module)
      end

    ProviderRegistry.capability_match?(definition_capabilities, requirements)
  end

  defp fetch_module_capabilities(provider_module) do
    if function_exported?(provider_module, :capabilities, 0) do
      provider_module.capabilities() || %{}
    else
      %{}
    end
  end
end
