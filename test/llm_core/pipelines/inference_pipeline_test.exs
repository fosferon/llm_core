defmodule LlmCore.Pipelines.InferencePipelineTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Pipelines.InferencePipeline
  alias LlmCore.Router.RoutingTable
  alias StreamData, as: SD

  @commbus_packet_struct CommBus.Protocol.Packet

  setup do
    ensure_store()
    ensure_registry()
    cleanup_registry()
    :ets.delete_all_objects(:llm_core_config)
    :ok
  end

  test "executes send and returns provider response" do
    agent_alias = unique_alias("basic")
    register_agent(agent_alias, LlmCore.TestProviders.Basic)
    put_routing(%{"default" => agent_alias, "coding" => agent_alias})

    assert {:ok, response} = InferencePipeline.execute(:send, "hello", "coding", [])
    assert response.provider == :test_basic
    assert response.model == "test-basic"
  end

  test "applies structured output when supported" do
    agent_alias = unique_alias("structured")
    register_agent(agent_alias, LlmCore.TestProviders.Basic)
    put_routing(%{"default" => agent_alias})

    schema = %{type: "object", properties: %{echo: %{type: "string"}}}

    assert {:ok, response} =
             InferencePipeline.execute(:send, "hi", :any, response_format: {:json_schema, schema})

    assert response.metadata[:structured_format] == :json_schema
    assert response.structured == %{"echo" => "hi"}
  end

  test "returns error when streaming unsupported" do
    agent_alias = unique_alias("no-stream")
    register_agent(agent_alias, LlmCore.TestProviders.NoStreaming)
    put_routing(%{"default" => agent_alias})

    assert {:error, :streaming_not_supported} =
             InferencePipeline.execute(:stream, "hi", :any, [])
  end

  test "returns error when structured output unsupported" do
    agent_alias = unique_alias("no-structured")
    register_agent(agent_alias, LlmCore.TestProviders.NoStructured)
    put_routing(%{"default" => agent_alias})

    assert {:error, :structured_output_not_supported} =
             InferencePipeline.execute(:send, "hi", :any, response_format: {:json_schema, %{}})
  end

  test "derives task type and prompt from CommBus packets" do
    default_alias = unique_alias("no-structured")
    coding_alias = unique_alias("basic")

    register_agent(default_alias, LlmCore.TestProviders.NoStructured)
    register_agent(coding_alias, LlmCore.TestProviders.Basic)

    put_routing(%{"default" => default_alias, "coding" => coding_alias})

    packet =
      commbus_packet(%{
        metadata: %{task_type: "coding"},
        messages: [
          %{role: :system, content: "rules", metadata: %{}},
          %{role: :user, content: "hello", metadata: %{}}
        ]
      })

    assert {:ok, response} = InferencePipeline.execute(:send, packet, :fallback, [])
    assert response.provider == :test_basic
    assert hd(response.raw.prompt)[:role] == :system
  end

  test "injects CommBus packet context into provider opts" do
    capture_alias = unique_alias("commbus")
    register_agent(capture_alias, LlmCore.TestProviders.CommBusCapture)
    put_routing(%{"default" => capture_alias})

    packet =
      commbus_packet(%{
        metadata: %{task_type: "capture"},
        sections: %{system: [%{id: "sys-1", content: "guardrails"}]},
        included_entries: [:sys],
        token_usage: %{total: 42},
        messages: [
          %{role: :system, content: "guard", metadata: %{section: :system}},
          %{role: :user, content: "ping", metadata: %{}}
        ]
      })

    assert {:ok, response} = InferencePipeline.execute(:send, packet, :any, [])

    assert response.metadata[:commbus][:sections][:system] == [
             %{id: "sys-1", content: "guardrails"}
           ]

    assert response.metadata[:commbus][:token_usage] == %{total: 42}
    assert Enum.count(response.metadata[:prompt]) == 2
  end

  test "returns error when CommBus packet lacks messages" do
    default_alias = unique_alias("basic-default")
    register_agent(default_alias, LlmCore.TestProviders.Basic)
    put_routing(%{"default" => default_alias})

    packet = commbus_packet(%{messages: []})

    assert {:error, :empty_packet_messages} = InferencePipeline.execute(:send, packet, :any, [])
  end

  property "enforces capability expectations across scenarios" do
    check all(scenario <- inference_case_generator()) do
      cleanup_registry()
      :ets.delete_all_objects(:llm_core_config)

      agent_alias = unique_alias("prop")
      register_agent(agent_alias, scenario.provider)

      routing_map = %{"default" => agent_alias, scenario.task_type => agent_alias}
      put_routing(routing_map)

      result =
        InferencePipeline.execute(
          scenario.mode,
          scenario.prompt,
          scenario.task_type,
          scenario.opts
        )

      assert_case_result(result, scenario.expectation)
    end
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

  defp inference_case_generator do
    prompt_gen = SD.string(:printable, min_length: 1, max_length: 32)
    schema = %{type: "object", properties: %{echo: %{type: "string"}}}

    gen all(
          prompt <- prompt_gen,
          scenario <-
            SD.member_of([
              :send_ok,
              :stream_ok,
              :stream_error,
              :structured_ok,
              :structured_error,
              :structured_stream_error
            ])
        ) do
      base = %{prompt: prompt, task_type: "task-" <> Atom.to_string(scenario)}

      case scenario do
        :send_ok ->
          Map.merge(base, %{
            mode: :send,
            provider: LlmCore.TestProviders.Basic,
            opts: [],
            expectation: {:ok, :response}
          })

        :stream_ok ->
          Map.merge(base, %{
            mode: :stream,
            provider: LlmCore.TestProviders.Basic,
            opts: [],
            expectation: {:ok, :stream}
          })

        :stream_error ->
          Map.merge(base, %{
            mode: :stream,
            provider: LlmCore.TestProviders.NoStreaming,
            opts: [],
            expectation: {:error, :streaming_not_supported}
          })

        :structured_ok ->
          Map.merge(base, %{
            mode: :send,
            provider: LlmCore.TestProviders.Basic,
            opts: [response_format: {:json_schema, schema}],
            expectation: {:ok, :response}
          })

        :structured_error ->
          Map.merge(base, %{
            mode: :send,
            provider: LlmCore.TestProviders.NoStructured,
            opts: [response_format: {:json_schema, schema}],
            expectation: {:error, :structured_output_not_supported}
          })

        :structured_stream_error ->
          Map.merge(base, %{
            mode: :stream,
            provider: LlmCore.TestProviders.Basic,
            opts: [response_format: {:json_schema, schema}],
            expectation: {:error, :structured_output_not_supported_in_streaming}
          })
      end
    end
  end

  defp assert_case_result({:ok, %LlmCore.LLM.Response{}} = result, {:ok, :response}) do
    assert {:ok, %LlmCore.LLM.Response{}} = result
  end

  defp assert_case_result({:ok, enumerable}, {:ok, :stream}) do
    refute Enum.empty?(Enum.take(enumerable, 1))
  end

  defp assert_case_result(result, {:error, reason}) do
    assert result == {:error, reason}
  end

  defp commbus_packet(attrs) do
    base = %{
      __struct__: @commbus_packet_struct,
      conversation: nil,
      messages: [
        %{role: :user, content: "hello", metadata: %{}}
      ],
      sections: %{},
      included_entries: [],
      excluded_entries: [],
      token_usage: %{},
      metadata: %{}
    }

    Map.merge(base, attrs)
  end
end
