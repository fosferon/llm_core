defmodule LlmCore.Agent.ToolDispatch.PipelineTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent.Pipeline.ToolDispatch, as: ToolDispatchPipeline
  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmCore.Tool.Call

  # ---------------------------------------------------------------------------
  # Setup / teardown
  # ---------------------------------------------------------------------------

  setup do
    # Ensure pipeline is started in sync mode for deterministic tests
    :ok = ToolDispatchPipeline.ensure_started(sync: true)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_call(name \\ "test_tool", args \\ %{}) do
    %Call{id: "call_1", name: name, arguments: args}
  end

  defp ok_resolve_fn do
    fn %Call{name: name} -> {:ok, "result from #{name}"} end
  end

  defp selective_resolve_fn do
    fn %Call{name: name, arguments: args} ->
      case name do
        "reflect" -> {:ok, "reflection on: #{args["query"]}"}
        "recall" -> {:ok, "recall for: #{args["query"]}"}
        "fail_tool" -> {:error, "tool failure"}
        other -> {:ok, "generic result from #{other}"}
      end
    end
  end

  defp make_recipe(opts \\ []) do
    serial = Keyword.get(opts, :serial, [])
    parallel = Keyword.get(opts, :parallel, [])
    compose = Keyword.get(opts, :compose, nil)

    fn _args ->
      plan = %{serial: serial, parallel: parallel}
      if compose, do: Map.put(plan, :compose, compose), else: plan
    end
  end

  # ---------------------------------------------------------------------------
  # Passthrough path — no recipe
  # ---------------------------------------------------------------------------

  describe "passthrough path (no recipe)" do
    test "executes tool directly when recipe is nil" do
      event = %Event{
        call: make_call("simple_tool", %{"key" => "val"}),
        resolve_fn: ok_resolve_fn(),
        recipe: nil
      }

      result = ToolDispatchPipeline.call(event)

      assert %Event{} = result
      assert result.strategy == :passthrough
      assert result.status == :ok
      assert result.result == "result from simple_tool"
    end
  end

  # ---------------------------------------------------------------------------
  # Recipe path — serial only
  # ---------------------------------------------------------------------------

  describe "recipe path with serial steps only" do
    test "executes serial steps and composes output" do
      recipe =
        make_recipe(
          serial: [
            %{tool: "reflect", arguments: %{"query" => "deep thought"}, label: "Reflect"},
            %{tool: "recall", arguments: %{"query" => "details"}, label: "Recall"}
          ]
        )

      event = %Event{
        call: make_call("research", %{}),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert result.strategy == :recipe
      assert length(result.serial_results) == 2
      assert result.result =~ "Sequential Results"
      assert result.result =~ "Reflect"
      assert result.result =~ "Recall"
    end
  end

  # ---------------------------------------------------------------------------
  # Recipe path — parallel only
  # ---------------------------------------------------------------------------

  describe "recipe path with parallel steps only" do
    test "fans out parallel steps and collects results" do
      recipe =
        make_recipe(
          parallel: [
            %{tool: "recall", arguments: %{"query" => "patterns"}, label: "Recall: patterns"},
            %{tool: "recall", arguments: %{"query" => "files"}, label: "Recall: files"},
            %{tool: "recall", arguments: %{"query" => "impl"}, label: "Recall: implementations"}
          ]
        )

      event = %Event{
        call: make_call("research", %{}),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert length(result.parallel_results) == 3
      assert result.result =~ "Additional Results"

      labels = Enum.map(result.parallel_results, & &1.label)
      assert "Recall: patterns" in labels
      assert "Recall: files" in labels
      assert "Recall: implementations" in labels
    end
  end

  # ---------------------------------------------------------------------------
  # Recipe path — serial + parallel
  # ---------------------------------------------------------------------------

  describe "recipe path with serial + parallel steps" do
    test "executes serial first, then fans out parallel, composes all" do
      recipe =
        make_recipe(
          serial: [
            %{tool: "reflect", arguments: %{"query" => "synthesis"}, label: "Deep synthesis"}
          ],
          parallel: [
            %{tool: "recall", arguments: %{"query" => "arch"}, label: "Recall: architecture"},
            %{tool: "recall", arguments: %{"query" => "files"}, label: "Recall: files"}
          ]
        )

      event = %Event{
        call: make_call("research_domain", %{"directive" => "research"}),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert length(result.serial_results) == 1
      assert length(result.parallel_results) == 2
      assert result.result =~ "Sequential Results"
      assert result.result =~ "Additional Results"
      assert result.result =~ "Deep synthesis"
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  describe "error cases" do
    test "recipe failure produces error event" do
      bad_recipe = fn _args -> raise "recipe evaluation failed" end

      event = %Event{
        call: make_call("broken"),
        resolve_fn: ok_resolve_fn(),
        recipe: bad_recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :error
      assert result.result =~ "Recipe evaluation error"
    end

    test "partial tool failure — some succeed, some fail" do
      recipe =
        make_recipe(
          parallel: [
            %{tool: "recall", arguments: %{"query" => "good"}, label: "Good call"},
            %{tool: "fail_tool", arguments: %{}, label: "Bad call"}
          ]
        )

      event = %Event{
        call: make_call("research"),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert length(result.parallel_results) == 1
      assert length(result.errors) == 1
      assert hd(result.errors).label == "Bad call"
    end

    test "all parallel tools fail" do
      recipe =
        make_recipe(
          parallel: [
            %{tool: "fail_tool", arguments: %{}, label: "Fail 1"},
            %{tool: "fail_tool", arguments: %{}, label: "Fail 2"}
          ]
        )

      event = %Event{
        call: make_call("research"),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert result.parallel_results == []
      assert length(result.errors) == 2
      assert result.result =~ "Errors"
    end

    test "serial tool failure collects error and continues" do
      recipe =
        make_recipe(
          serial: [
            %{tool: "fail_tool", arguments: %{}, label: "Failing serial"}
          ]
        )

      event = %Event{
        call: make_call("research"),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert result.serial_results == []
      assert length(result.errors) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Empty plan
  # ---------------------------------------------------------------------------

  describe "empty plan" do
    test "recipe with no serial and no parallel produces 'No results produced.'" do
      recipe = make_recipe(serial: [], parallel: [])

      event = %Event{
        call: make_call("empty"),
        resolve_fn: ok_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert result.result == "No results produced."
    end
  end

  # ---------------------------------------------------------------------------
  # Custom compose function
  # ---------------------------------------------------------------------------

  describe "custom compose function" do
    test "uses recipe-provided compose function" do
      custom_compose = fn %{serial_results: sr, parallel_results: pr, errors: errs} ->
        "Custom output: #{length(sr)}s #{length(pr)}p #{length(errs)}e"
      end

      recipe =
        make_recipe(
          serial: [
            %{tool: "reflect", arguments: %{"query" => "test"}, label: "Reflect"}
          ],
          parallel: [
            %{tool: "recall", arguments: %{"query" => "a"}, label: "Recall A"}
          ],
          compose: custom_compose
        )

      event = %Event{
        call: make_call("research"),
        resolve_fn: selective_resolve_fn(),
        recipe: recipe
      }

      result = ToolDispatchPipeline.call(event)

      assert result.status == :ok
      assert result.result == "Custom output: 1s 1p 0e"
    end
  end
end
