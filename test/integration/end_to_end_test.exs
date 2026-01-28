defmodule LlmCore.Integration.EndToEndTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Router
  alias LlmCore.Router.RoutingTable

  setup do
    ensure_started(Store, fn -> Store.start_link([]) end)
    ensure_started(Registry, fn -> Registry.start_link(auto_discover: false) end)
    ensure_started(Router, fn -> Router.start_link([]) end)

    on_exit(fn ->
      Registry.list() |> Enum.each(&Registry.unregister(&1.name))
    end)

    :ok
  end

  test "router send resolves provider and applies structured output" do
    register_agent("basic-agent", LlmCore.TestProviders.Basic)
    put_routing(%{"default" => "basic-agent", "coding" => "basic-agent"})

    assert {:ok, response} =
             Router.send("ping", "coding", response_format: {:json_schema, %{}})

    assert response.provider == :test_basic
    assert response.structured == %{"echo" => "ping"}
  end

  test "router stream proxies provider chunks" do
    register_agent("basic-agent", LlmCore.TestProviders.Basic)
    put_routing(%{"default" => "basic-agent"})

    assert {:ok, stream} = Router.stream("hello", :default)
    assert Enum.to_list(stream) == ["hello"]
  end

  defp register_agent(name, provider) do
    {:ok, agent} = Agent.new(name, provider, %{})
    Registry.unregister(name)
    :ok = Registry.register(name, provider, agent.config)
  end

  defp put_routing(map) do
    table = RoutingTable.new(map)
    :ok = Store.put_routing(table)
  end

  defp ensure_started(name, starter) do
    case Process.whereis(name) do
      nil ->
        case starter.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(name)}: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end
end
