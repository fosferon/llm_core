defmodule LlmCore.Agent.ToolDispatch.IntegrationTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent.Components.DispatchTools
  alias LlmCore.Agent.Context
  alias LlmCore.Agent.Pipeline.ToolDispatch, as: ToolDispatchPipeline
  alias LlmToolkit.Tool.Call

  # ---------------------------------------------------------------------------
  # Test resolver modules
  # ---------------------------------------------------------------------------

  defmodule ResolverWithRecipes do
    @moduledoc false
    @behaviour LlmToolkit.ToolResolver

    @impl true
    def resolve(%Call{name: "simple_tool"}) do
      {:ok, "simple result"}
    end

    def resolve(%Call{name: "reflect", arguments: args}) do
      {:ok, "reflection: #{args["query"]}"}
    end

    def resolve(%Call{name: "recall", arguments: args}) do
      {:ok, "recall: #{args["query"]}"}
    end

    def resolve(%Call{name: name}) do
      {:error, "Unknown tool: #{name}"}
    end

    @impl true
    def available_tools, do: []

    @impl true
    def dispatch_recipe("orchestrated_research") do
      fn _args ->
        %{
          serial: [
            %{tool: "reflect", arguments: %{"query" => "synthesis"}, label: "Synthesis"}
          ],
          parallel: [
            %{tool: "recall", arguments: %{"query" => "patterns"}, label: "Recall: patterns"},
            %{tool: "recall", arguments: %{"query" => "files"}, label: "Recall: files"}
          ]
        }
      end
    end

    def dispatch_recipe(_), do: nil
  end

  defmodule ResolverWithoutRecipes do
    @moduledoc false
    @behaviour LlmToolkit.ToolResolver

    @impl true
    def resolve(%Call{name: "simple_tool"}) do
      {:ok, "direct result"}
    end

    def resolve(%Call{name: name}) do
      {:error, "Unknown tool: #{name}"}
    end

    @impl true
    def available_tools, do: []

    # Note: does NOT implement dispatch_recipe/1
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    :ok = ToolDispatchPipeline.ensure_started(sync: true)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests: resolver with recipes
  # ---------------------------------------------------------------------------

  describe "DispatchTools with resolver that has recipes" do
    test "delegates orchestrated tool to ToolDispatch pipeline" do
      ctx = %Context{
        tool_calls: [
          %Call{id: "call_1", name: "orchestrated_research", arguments: %{"q" => "test"}}
        ],
        resolve_tool: &ResolverWithRecipes.resolve/1,
        resolver_module: ResolverWithRecipes,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])

      assert length(result.tool_results) == 1
      tool_result = hd(result.tool_results)
      assert tool_result.name == "orchestrated_research"
      assert tool_result.content =~ "Sequential Results"
      assert tool_result.content =~ "Synthesis"
      assert tool_result.content =~ "Additional Results"
    end

    test "non-recipe tools still execute directly" do
      ctx = %Context{
        tool_calls: [
          %Call{id: "call_2", name: "simple_tool", arguments: %{}}
        ],
        resolve_tool: &ResolverWithRecipes.resolve/1,
        resolver_module: ResolverWithRecipes,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])

      assert length(result.tool_results) == 1
      tool_result = hd(result.tool_results)
      assert tool_result.name == "simple_tool"
      assert tool_result.content == "simple result"
    end

    test "mixes recipe and non-recipe tools in same batch" do
      ctx = %Context{
        tool_calls: [
          %Call{id: "call_1", name: "simple_tool", arguments: %{}},
          %Call{id: "call_2", name: "orchestrated_research", arguments: %{}}
        ],
        resolve_tool: &ResolverWithRecipes.resolve/1,
        resolver_module: ResolverWithRecipes,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])

      assert length(result.tool_results) == 2

      simple_result = Enum.find(result.tool_results, &(&1.name == "simple_tool"))
      assert simple_result.content == "simple result"

      recipe_result = Enum.find(result.tool_results, &(&1.name == "orchestrated_research"))
      assert recipe_result.content =~ "Sequential Results"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: resolver without recipes (backward compatible)
  # ---------------------------------------------------------------------------

  describe "DispatchTools with resolver without dispatch_recipe/1" do
    test "executes all tools directly (backward compatible)" do
      ctx = %Context{
        tool_calls: [
          %Call{id: "call_1", name: "simple_tool", arguments: %{}}
        ],
        resolve_tool: &ResolverWithoutRecipes.resolve/1,
        resolver_module: ResolverWithoutRecipes,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])

      assert length(result.tool_results) == 1
      assert hd(result.tool_results).content == "direct result"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: no resolver module (backward compatible)
  # ---------------------------------------------------------------------------

  describe "DispatchTools with no resolver_module" do
    test "executes all tools directly when resolver_module is nil" do
      resolve_fn = fn %Call{name: "simple_tool"} -> {:ok, "resolved directly"} end

      ctx = %Context{
        tool_calls: [
          %Call{id: "call_1", name: "simple_tool", arguments: %{}}
        ],
        resolve_tool: resolve_fn,
        resolver_module: nil,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])

      assert length(result.tool_results) == 1
      assert hd(result.tool_results).content == "resolved directly"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: error handling and edge cases
  # ---------------------------------------------------------------------------

  describe "DispatchTools edge cases" do
    test "short-circuits on error status" do
      ctx = %Context{status: :error, error: :prior_error}
      result = DispatchTools.call(ctx, [])
      assert result == ctx
    end

    test "short-circuits on done decision" do
      ctx = %Context{decision: {:done, %{content: "done"}}}
      result = DispatchTools.call(ctx, [])
      assert result == ctx
    end

    test "appends trace entry for dispatched calls" do
      ctx = %Context{
        tool_calls: [
          %Call{id: "call_1", name: "simple_tool", arguments: %{}}
        ],
        resolve_tool: &ResolverWithRecipes.resolve/1,
        resolver_module: ResolverWithRecipes,
        tool_results: [],
        trace: []
      }

      result = DispatchTools.call(ctx, [])
      assert {:dispatch, 1} in result.trace
    end
  end
end
