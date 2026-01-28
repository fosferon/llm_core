defmodule LlmCore.Pipelines.RoutingPipelineTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Pipelines.RoutingPipeline
  alias LlmCore.Router.RoutingTable
  alias StreamData, as: SD

  setup do
    start_store()
    start_registry()
    cleanup_registry()
    :ets.delete_all_objects(:llm_core_config)
    :ok
  end

  test "returns resolved route for configured task" do
    register_agent("basic-agent", LlmCore.TestProviders.Basic)
    put_routing(%{"default" => "basic-agent", "coding" => "basic-agent"})

    assert {:ok, route} = RoutingPipeline.route("coding")
    assert route.alias == "basic-agent"
    assert route.agent.provider == LlmCore.TestProviders.Basic
  end

  test "returns error when agent is missing" do
    put_routing(%{"default" => "ghost"})

    assert {:error, :provider_not_found} = RoutingPipeline.route("any")
  end

  property "resolves generated routing tables" do
    check all(fixture <- routing_case_generator()) do
      cleanup_registry()
      :ets.delete_all_objects(:llm_core_config)

      Enum.each(fixture.aliases, &register_agent(&1, LlmCore.TestProviders.Basic))

      routing_map =
        fixture.rules
        |> Enum.into(%{})
        |> Map.put("default", fixture.default_alias)

      put_routing(routing_map)

      Enum.each(fixture.rules, fn {task, alias_name} ->
        assert {:ok, route} = RoutingPipeline.route(task)
        assert route.alias == alias_name
      end)

      fallback_task = "fallback-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      assert {:ok, route} = RoutingPipeline.route(fallback_task)
      assert route.alias == fixture.default_alias
    end
  end

  defp start_store do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end
  end

  defp start_registry do
    unless Process.whereis(Registry) do
      start_supervised!({Registry, auto_discover: false})
    end
  end

  defp cleanup_registry do
    Registry.list()
    |> Enum.each(fn agent -> Registry.unregister(agent.name) end)
  end

  defp register_agent(name, provider) do
    {:ok, agent} = Agent.new(name, provider, %{})
    Registry.unregister(name)
    assert :ok = Registry.register(name, provider, agent.config)
  end

  defp put_routing(map) do
    table = RoutingTable.new(map)
    :ok = Store.put_routing(table)
  end

  defp routing_case_generator do
    gen all(
          aliases <- SD.uniq_list_of(alias_generator(), min_length: 1, max_length: 4),
          tasks <- SD.uniq_list_of(task_generator(), min_length: 1, max_length: 6),
          assignments <- SD.list_of(SD.member_of(aliases), length: length(tasks))
        ) do
      rules = Enum.zip(tasks, assignments)

      %{
        aliases: aliases,
        rules: rules,
        default_alias: hd(aliases)
      }
    end
  end

  defp alias_generator do
    SD.map(SD.string(:alphanumeric, min_length: 4, max_length: 10), &String.downcase/1)
  end

  defp task_generator do
    SD.string(:alphanumeric, min_length: 3, max_length: 12)
  end
end
