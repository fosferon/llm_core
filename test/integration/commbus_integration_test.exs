defmodule LlmCore.Integration.CommBusInteropTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Router
  alias LlmCore.Router.RoutingTable

  alias CommBus.{Conversation, Entry, Message}

  setup do
    ensure_store()
    ensure_registry()
    cleanup_registry()
    :ets.delete_all_objects(:llm_core_config)
    CommBus.Protocol.SectionRoles.reset()
    :ok
  end

  test "CommBus pipeline packets flow through the router" do
    conversation = %Conversation{
      id: :integration,
      messages: [
        %Message{role: :user, content: "Need billing support."}
      ]
    }

    entries = [
      %Entry{
        id: :policy,
        content: "Support rules",
        section: :system,
        mode: :constant,
        token_count: 12
      },
      %Entry{
        id: :kb,
        content: "Billing KB summary",
        section: :pre_history,
        keywords: ["billing"],
        mode: :triggered,
        token_count: 6
      }
    ]

    {:ok, packet} = CommBus.Protocol.Pipeline.run({conversation, entries})

    routing_alias = unique_alias("commbus-capture")
    register_agent(routing_alias, LlmCore.TestProviders.CommBusCapture)
    put_routing(%{"default" => routing_alias, "support" => routing_alias})

    assert {:ok, response} = Router.send_packet(packet, task_type: "support")
    assert response.provider == :commbus_capture

    prompt_roles = Enum.map(response.metadata[:prompt], & &1.role)
    prompt_contents = Enum.map(response.metadata[:prompt], & &1.content)

    assert prompt_roles == [:system, :system, :user]
    assert hd(prompt_contents) == "Support rules"
    assert Enum.at(prompt_contents, 1) == "Billing KB summary"
    assert List.last(prompt_contents) =~ "Need billing support."

    assert response.metadata[:commbus][:included_entries] == packet.included_entries
    assert response.metadata[:commbus][:token_usage] == packet.token_usage
  end

  defp ensure_store do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end
  end

  defp ensure_registry do
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
    :ok = Registry.register(name, provider, agent.config)
  end

  defp put_routing(map) do
    table = RoutingTable.new(map)
    :ok = Store.put_routing(table)
  end

  defp unique_alias(prefix) do
    ref = :erlang.unique_integer([:positive])
    "#{prefix}-#{ref}"
  end
end
