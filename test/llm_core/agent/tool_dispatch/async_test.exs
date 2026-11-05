defmodule LlmCore.Agent.ToolDispatch.AsyncTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent.Components.DispatchTools
  alias LlmCore.Agent.Context
  alias LlmCore.Agent.Pipeline.ToolDispatch, as: ToolDispatchPipeline
  alias LlmCore.Agent.ToolDispatch.Components.ExecuteOneCall
  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmToolkit.Tool.Call

  defmodule Resolver do
    @moduledoc false
    @behaviour LlmToolkit.ToolResolver

    @impl true
    def resolve(%Call{name: name}) do
      {:error, "test resolver must supply resolve_tool for #{name}"}
    end

    @impl true
    def available_tools, do: []

    @impl true
    def dispatch_recipe("slow_dispatch") do
      fn _args ->
        %{parallel: [%{tool: "slow", arguments: %{}, label: "Slow"}]}
      end
    end

    def dispatch_recipe("ordered_dispatch") do
      fn _args ->
        %{
          parallel: [
            %{tool: "sleepy", arguments: %{"ms" => 80}, label: "first"},
            %{tool: "sleepy", arguments: %{"ms" => 10}, label: "second"},
            %{tool: "sleepy", arguments: %{"ms" => 40}, label: "third"}
          ]
        }
      end
    end

    def dispatch_recipe("blocking_dispatch") do
      fn args ->
        %{
          parallel: [
            %{tool: "blocking", arguments: %{"id" => args["id"]}, label: "blocking"}
          ]
        }
      end
    end

    def dispatch_recipe(_), do: nil
  end

  setup do
    stop_pipeline()
    :ok = ToolDispatchPipeline.ensure_started(sync: false)

    on_exit(fn -> stop_pipeline() end)
    :ok
  end

  test "a sub-call longer than ALF's default timeout succeeds when the budget allows" do
    alf_default = Application.get_env(:alf, :default_timeout, 10_000)
    assert alf_default < 400, "test config must lower ALF's default timeout"

    resolved_at = System.monotonic_time(:millisecond)

    resolve_fn = fn %Call{name: "slow"} ->
      Process.sleep(400)
      {:ok, "slow result after #{System.monotonic_time(:millisecond) - resolved_at}ms"}
    end

    ctx = context("slow_dispatch", resolve_fn, tool_timeout: 5_000)

    {elapsed_us, result} = :timer.tc(fn -> DispatchTools.call(ctx, []) end)

    assert [%{content: content}] = result.tool_results
    assert content =~ "slow result"
    assert elapsed_us >= 400_000
  end

  test "concurrent callers overlap without restarting the shared pipeline" do
    test_pid = self()

    resolve_fn = fn %Call{name: "blocking", arguments: %{"id" => id}} ->
      send(test_pid, {:started, id, self()})

      receive do
        :release -> {:ok, "blocking result #{id}"}
      after
        5_000 -> {:error, "test never released #{id}"}
      end
    end

    first =
      Task.async(fn ->
        DispatchTools.call(context("blocking_dispatch", resolve_fn, id: 1), [])
      end)

    assert_receive {:started, 1, first_worker}

    pipeline_pid = Process.whereis(ToolDispatchPipeline)
    assert is_pid(pipeline_pid)

    second =
      Task.async(fn ->
        DispatchTools.call(context("blocking_dispatch", resolve_fn, id: 2), [])
      end)

    assert_receive {:started, 2, second_worker}

    # The first call is still in flight and the pipeline was not restarted.
    assert Process.whereis(ToolDispatchPipeline) == pipeline_pid
    assert Process.alive?(first_worker)

    send(first_worker, :release)
    send(second_worker, :release)

    first_result = Task.await(first, 10_000)
    second_result = Task.await(second, 10_000)

    assert [%{content: first_content}] = first_result.tool_results
    assert [%{content: second_content}] = second_result.tool_results
    assert first_content =~ "blocking result 1"
    assert second_content =~ "blocking result 2"
    assert Process.whereis(ToolDispatchPipeline) == pipeline_pid
  end

  test "exceeding the per-call budget returns a bounded typed timeout" do
    resolve_fn = fn %Call{name: "slow"} ->
      Process.sleep(2_000)
      {:ok, "too late"}
    end

    ctx = context("slow_dispatch", resolve_fn, tool_timeout: 100)

    {elapsed_us, result} = :timer.tc(fn -> DispatchTools.call(ctx, []) end)

    assert [%{content: content}] = result.tool_results
    assert content == "Tool call timed out after 100ms"
    assert elapsed_us < 1_000_000
  end

  test "the execution helper reports a typed timeout" do
    event = %Event{
      call: %Call{id: "call", name: "slow", arguments: %{}},
      resolve_fn: fn _ -> Process.sleep(500) end,
      timeout: 100
    }

    result =
      ExecuteOneCall.call(
        %{event | current_step: %{tool: "slow", arguments: %{}, label: "Slow"}},
        []
      )

    assert %{error: {:timeout, 100}} = result.step_result
  end

  test "parallel fan-out returns results in the recipe's original order" do
    resolve_fn = fn %Call{name: "sleepy", arguments: %{"ms" => ms}} ->
      Process.sleep(ms)
      {:ok, "slept #{ms}ms"}
    end

    ctx = context("ordered_dispatch", resolve_fn, tool_timeout: 5_000)
    result = DispatchTools.call(ctx, [])

    assert [%{content: content}] = result.tool_results
    first = :binary.match(content, "### first") |> elem(0)
    second = :binary.match(content, "### second") |> elem(0)
    third = :binary.match(content, "### third") |> elem(0)

    assert first < second and second < third
  end

  defp context(tool_name, resolve_fn, opts) do
    %Context{
      tool_calls: [
        %Call{
          id: "call_#{tool_name}",
          name: tool_name,
          arguments: if(id = Keyword.get(opts, :id), do: %{"id" => id}, else: %{})
        }
      ],
      resolve_tool: resolve_fn,
      resolver_module: Resolver,
      tool_timeout: Keyword.get(opts, :tool_timeout, 5_000),
      tool_results: [],
      trace: []
    }
  end

  defp stop_pipeline do
    if Process.whereis(ToolDispatchPipeline), do: ToolDispatchPipeline.stop()
    :ok
  catch
    _, _ -> :ok
  end
end
