defmodule LlmCore.Agent.ToolDispatch.ComponentsTest do
  use ExUnit.Case, async: true

  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmCore.Agent.ToolDispatch.Components.{
    ResolveStrategy,
    DirectResolve,
    BuildPlan,
    ExecuteSerial,
    FanOutParallel,
    ExecuteOneCall,
    CollectResults,
    ComposeOutput
  }
  alias LlmCore.Tool.Call

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_call(name \\ "test_tool", args \\ %{}) do
    %Call{id: "call_1", name: name, arguments: args}
  end

  defp ok_resolve_fn do
    fn %Call{name: name} -> {:ok, "result from #{name}"} end
  end

  defp error_resolve_fn do
    fn %Call{} -> {:error, "tool failed"} end
  end

  defp base_event(overrides \\ []) do
    defaults = %{
      call: make_call(),
      resolve_fn: ok_resolve_fn(),
      recipe: nil,
      strategy: :passthrough,
      plan: nil,
      serial_results: [],
      serial_context: %{},
      current_step: nil,
      total_parallel: 0,
      step_result: nil,
      parallel_results: [],
      errors: [],
      result: nil,
      status: :ok,
      error: nil
    }

    struct(Event, Map.merge(defaults, Map.new(overrides)))
  end

  # ---------------------------------------------------------------------------
  # ResolveStrategy
  # ---------------------------------------------------------------------------

  describe "ResolveStrategy" do
    test "sets :passthrough when recipe is nil" do
      event = base_event(recipe: nil)
      result = ResolveStrategy.call(event, [])
      assert result.strategy == :passthrough
    end

    test "sets :recipe when recipe is a function" do
      recipe = fn _args -> %{serial: [], parallel: []} end
      event = base_event(recipe: recipe)
      result = ResolveStrategy.call(event, [])
      assert result.strategy == :recipe
    end
  end

  # ---------------------------------------------------------------------------
  # DirectResolve
  # ---------------------------------------------------------------------------

  describe "DirectResolve" do
    test "calls resolve_fn and returns ok result" do
      event = base_event(resolve_fn: ok_resolve_fn())
      result = DirectResolve.call(event, [])
      assert result.status == :ok
      assert result.result == "result from test_tool"
    end

    test "calls resolve_fn and captures error result" do
      event = base_event(resolve_fn: error_resolve_fn())
      result = DirectResolve.call(event, [])
      assert result.status == :error
      assert result.result =~ "Error:"
      assert result.error == "tool failed"
    end

    test "catches exceptions in resolve_fn" do
      crash_fn = fn %Call{} -> raise "boom" end
      event = base_event(resolve_fn: crash_fn)
      result = DirectResolve.call(event, [])
      assert result.status == :error
      assert result.result =~ "Tool execution error: boom"
    end
  end

  # ---------------------------------------------------------------------------
  # BuildPlan
  # ---------------------------------------------------------------------------

  describe "BuildPlan" do
    test "calls recipe with call arguments and populates plan" do
      recipe = fn args ->
        %{
          serial: [%{tool: "step1", arguments: args, label: "First"}],
          parallel: [
            %{tool: "p1", arguments: %{}, label: "Par 1"},
            %{tool: "p2", arguments: %{}, label: "Par 2"}
          ]
        }
      end

      event = base_event(recipe: recipe, call: make_call("research", %{"q" => "test"}))
      result = BuildPlan.call(event, [])

      assert result.plan.serial |> length() == 1
      assert result.plan.parallel |> length() == 2
      assert result.total_parallel == 2
    end

    test "skips on error status" do
      event = base_event(status: :error, error: :some_error)
      result = BuildPlan.call(event, [])
      assert result == event
    end

    test "captures recipe evaluation errors" do
      bad_recipe = fn _args -> raise "recipe broke" end
      event = base_event(recipe: bad_recipe)
      result = BuildPlan.call(event, [])
      assert result.status == :error
      assert result.result =~ "Recipe evaluation error: recipe broke"
    end
  end

  # ---------------------------------------------------------------------------
  # ExecuteSerial
  # ---------------------------------------------------------------------------

  describe "ExecuteSerial" do
    test "executes serial steps in order" do
      resolve_fn = fn %Call{name: name, arguments: args} ->
        {:ok, "#{name}(#{inspect(args)})"}
      end

      plan = %{
        serial: [
          %{tool: "step_a", arguments: %{"x" => 1}, label: "Step A"},
          %{tool: "step_b", arguments: %{"y" => 2}, label: "Step B"}
        ],
        parallel: []
      }

      event = base_event(resolve_fn: resolve_fn, plan: plan)
      result = ExecuteSerial.call(event, [])

      assert length(result.serial_results) == 2
      assert Enum.at(result.serial_results, 0).label == "Step A"
      assert Enum.at(result.serial_results, 1).label == "Step B"
      assert Map.has_key?(result.serial_context, "step_a")
      assert Map.has_key?(result.serial_context, "step_b")
      assert result.errors == []
    end

    test "passes through when serial is empty" do
      plan = %{serial: [], parallel: []}
      event = base_event(plan: plan)
      result = ExecuteSerial.call(event, [])
      assert result.serial_results == []
    end

    test "passes through when serial is nil" do
      plan = %{serial: nil, parallel: []}
      event = base_event(plan: plan)
      result = ExecuteSerial.call(event, [])
      assert result.serial_results == []
    end

    test "collects errors from failed serial steps" do
      resolve_fn = fn %Call{name: "fail_step"} -> {:error, "step failed"} end

      plan = %{
        serial: [%{tool: "fail_step", arguments: %{}, label: "Bad Step"}],
        parallel: []
      }

      event = base_event(resolve_fn: resolve_fn, plan: plan)
      result = ExecuteSerial.call(event, [])

      assert result.serial_results == []
      assert length(result.errors) == 1
      assert hd(result.errors).label == "Bad Step"
    end

    test "supports dynamic argument resolution via function" do
      resolve_fn = fn %Call{arguments: args} ->
        {:ok, "val=#{args["key"]}"}
      end

      plan = %{
        serial: [
          %{tool: "first", arguments: %{"key" => "initial"}, label: "First"},
          %{
            tool: "second",
            arguments: fn ctx -> %{"key" => ctx["first"]} end,
            label: "Second"
          }
        ],
        parallel: []
      }

      event = base_event(resolve_fn: resolve_fn, plan: plan)
      result = ExecuteSerial.call(event, [])

      assert length(result.serial_results) == 2
      # Second step should have used result from first step
      second_result = Enum.at(result.serial_results, 1)
      assert second_result.content =~ "val=initial"
    end

    test "skips on error status" do
      event = base_event(status: :error)
      assert ExecuteSerial.call(event, []) == event
    end
  end

  # ---------------------------------------------------------------------------
  # FanOutParallel (Composer)
  # ---------------------------------------------------------------------------

  describe "FanOutParallel" do
    test "0 parallel steps → passes event through" do
      plan = %{serial: [], parallel: []}
      event = base_event(plan: plan)
      {events, nil} = FanOutParallel.call(event, nil, [])
      assert length(events) == 1
      assert hd(events).current_step == nil
    end

    test "nil parallel steps → passes event through" do
      plan = %{serial: [], parallel: nil}
      event = base_event(plan: plan)
      {events, nil} = FanOutParallel.call(event, nil, [])
      assert length(events) == 1
    end

    test "1 parallel step → 1 event" do
      step = %{tool: "tool_a", arguments: %{}, label: "A"}
      plan = %{serial: [], parallel: [step]}
      event = base_event(plan: plan)
      {events, nil} = FanOutParallel.call(event, nil, [])

      assert length(events) == 1
      assert hd(events).current_step == step
      assert hd(events).total_parallel == 1
    end

    test "3 parallel steps → 3 events" do
      steps = [
        %{tool: "tool_a", arguments: %{}, label: "A"},
        %{tool: "tool_b", arguments: %{}, label: "B"},
        %{tool: "tool_c", arguments: %{}, label: "C"}
      ]

      plan = %{serial: [], parallel: steps}
      event = base_event(plan: plan)
      {events, nil} = FanOutParallel.call(event, nil, [])

      assert length(events) == 3

      Enum.each(events, fn e ->
        assert e.total_parallel == 3
        assert e.current_step != nil
      end)

      labels = Enum.map(events, & &1.current_step.label)
      assert labels == ["A", "B", "C"]
    end

    test "passes through error events unchanged" do
      event = base_event(status: :error, error: :bad)
      {events, nil} = FanOutParallel.call(event, nil, [])
      assert length(events) == 1
      assert hd(events).status == :error
    end
  end

  # ---------------------------------------------------------------------------
  # ExecuteOneCall
  # ---------------------------------------------------------------------------

  describe "ExecuteOneCall" do
    test "executes current_step and sets step_result" do
      step = %{tool: "my_tool", arguments: %{"q" => "hello"}, label: "My Tool"}

      event =
        base_event(
          resolve_fn: ok_resolve_fn(),
          current_step: step,
          total_parallel: 1
        )

      result = ExecuteOneCall.call(event, [])

      assert result.step_result.label == "My Tool"
      assert result.step_result.tool == "my_tool"
      assert result.step_result.content == "result from my_tool"
    end

    test "passes through when current_step is nil" do
      event = base_event(current_step: nil)
      result = ExecuteOneCall.call(event, [])
      assert result == event
    end

    test "captures error in step_result" do
      step = %{tool: "bad_tool", arguments: %{}, label: "Bad"}

      event =
        base_event(
          resolve_fn: error_resolve_fn(),
          current_step: step,
          total_parallel: 1
        )

      result = ExecuteOneCall.call(event, [])

      assert result.step_result.label == "Bad"
      assert Map.has_key?(result.step_result, :error)
    end

    test "catches exceptions" do
      step = %{tool: "crash_tool", arguments: %{}, label: "Crash"}
      crash_fn = fn %Call{} -> raise "kaboom" end

      event =
        base_event(
          resolve_fn: crash_fn,
          current_step: step,
          total_parallel: 1
        )

      result = ExecuteOneCall.call(event, [])
      assert Map.has_key?(result.step_result, :error)
    end

    test "skips on error status" do
      event = base_event(status: :error)
      assert ExecuteOneCall.call(event, []) == event
    end

    test "supports dynamic arguments from serial context" do
      step = %{
        tool: "dynamic_tool",
        arguments: fn ctx -> %{"from" => ctx["prev"]} end,
        label: "Dynamic"
      }

      resolve_fn = fn %Call{arguments: args} -> {:ok, "got #{args["from"]}"} end

      event =
        base_event(
          resolve_fn: resolve_fn,
          current_step: step,
          serial_context: %{"prev" => "value_from_serial"},
          total_parallel: 1
        )

      result = ExecuteOneCall.call(event, [])
      assert result.step_result.content == "got value_from_serial"
    end
  end

  # ---------------------------------------------------------------------------
  # CollectResults (Composer)
  # ---------------------------------------------------------------------------

  describe "CollectResults" do
    test "passes through events with nil current_step" do
      event = base_event(current_step: nil)
      {events, memo} = CollectResults.call(event, [], [])
      assert length(events) == 1
      assert memo == []
    end

    test "accumulates results until total is reached" do
      # First result — not yet complete
      event1 =
        base_event(
          current_step: %{tool: "a", label: "A"},
          step_result: %{label: "A", tool: "a", content: "res_a"},
          total_parallel: 3
        )

      {events, memo} = CollectResults.call(event1, [], [])
      assert events == []
      assert length(memo) == 1

      # Second result — still not complete
      event2 =
        base_event(
          current_step: %{tool: "b", label: "B"},
          step_result: %{label: "B", tool: "b", content: "res_b"},
          total_parallel: 3
        )

      {events, memo} = CollectResults.call(event2, memo, [])
      assert events == []
      assert length(memo) == 2

      # Third result — complete! Emits composed event
      event3 =
        base_event(
          current_step: %{tool: "c", label: "C"},
          step_result: %{label: "C", tool: "c", content: "res_c"},
          total_parallel: 3
        )

      {events, memo} = CollectResults.call(event3, memo, [])
      assert length(events) == 1
      assert memo == []

      composed = hd(events)
      assert length(composed.parallel_results) == 3
      assert composed.current_step == nil
      assert composed.step_result == nil
    end

    test "separates successes and errors" do
      event1 =
        base_event(
          current_step: %{tool: "ok", label: "OK"},
          step_result: %{label: "OK", tool: "ok", content: "good"},
          total_parallel: 2
        )

      {[], memo} = CollectResults.call(event1, [], [])

      event2 =
        base_event(
          current_step: %{tool: "fail", label: "Fail"},
          step_result: %{label: "Fail", tool: "fail", error: "bad"},
          total_parallel: 2
        )

      {[composed], []} = CollectResults.call(event2, memo, [])

      assert length(composed.parallel_results) == 1
      assert hd(composed.parallel_results).label == "OK"
      assert length(composed.errors) == 1
      assert hd(composed.errors).label == "Fail"
    end
  end

  # ---------------------------------------------------------------------------
  # ComposeOutput
  # ---------------------------------------------------------------------------

  describe "ComposeOutput" do
    test "formats serial results" do
      event =
        base_event(
          serial_results: [
            %{label: "Step 1", content: "data from step 1"},
            %{label: "Step 2", content: "data from step 2"}
          ],
          parallel_results: [],
          errors: [],
          plan: %{serial: [], parallel: []}
        )

      result = ComposeOutput.call(event, [])
      assert result.status == :ok
      assert result.result =~ "Sequential Results"
      assert result.result =~ "Step 1"
      assert result.result =~ "Step 2"
    end

    test "formats parallel results" do
      event =
        base_event(
          serial_results: [],
          parallel_results: [
            %{label: "Source A", content: "data from A"},
            %{label: "Source B", content: "data from B"}
          ],
          errors: [],
          plan: %{serial: [], parallel: []}
        )

      result = ComposeOutput.call(event, [])
      assert result.result =~ "Additional Results"
      assert result.result =~ "Source A"
      assert result.result =~ "Source B"
    end

    test "formats errors section" do
      event =
        base_event(
          serial_results: [],
          parallel_results: [],
          errors: [%{label: "Bad Tool", error: "timeout"}],
          plan: %{serial: [], parallel: []}
        )

      result = ComposeOutput.call(event, [])
      assert result.result =~ "Errors"
      assert result.result =~ "Bad Tool"
    end

    test "returns 'No results produced.' when everything is empty" do
      event =
        base_event(
          serial_results: [],
          parallel_results: [],
          errors: [],
          plan: %{serial: [], parallel: []}
        )

      result = ComposeOutput.call(event, [])
      assert result.result == "No results produced."
    end

    test "uses custom compose function from plan" do
      custom_compose = fn %{serial_results: sr, parallel_results: pr} ->
        "Custom: #{length(sr)} serial, #{length(pr)} parallel"
      end

      event =
        base_event(
          serial_results: [%{label: "A", content: "a"}],
          parallel_results: [%{label: "B", content: "b"}, %{label: "C", content: "c"}],
          errors: [],
          plan: %{serial: [], parallel: [], compose: custom_compose}
        )

      result = ComposeOutput.call(event, [])
      assert result.result == "Custom: 1 serial, 2 parallel"
    end

    test "skips on error status" do
      event = base_event(status: :error)
      result = ComposeOutput.call(event, [])
      assert result == event
    end

    test "formats combined serial + parallel + errors" do
      event =
        base_event(
          serial_results: [%{label: "Reflect", content: "synthesis"}],
          parallel_results: [%{label: "Recall 1", content: "recall data"}],
          errors: [%{label: "Recall 2", error: "timeout"}],
          plan: %{serial: [], parallel: []}
        )

      result = ComposeOutput.call(event, [])
      assert result.result =~ "Sequential Results"
      assert result.result =~ "Additional Results"
      assert result.result =~ "Errors"
    end
  end
end
