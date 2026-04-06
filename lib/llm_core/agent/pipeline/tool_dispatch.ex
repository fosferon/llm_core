defmodule LlmCore.Agent.Pipeline.ToolDispatch do
  @moduledoc """
  ALF pipeline for orchestrated tool dispatch.

  When `DispatchTools` encounters a tool call that has a registered dispatch
  recipe, it invokes this pipeline instead of calling the resolver directly.
  The pipeline orchestrates sub-tool execution using ALF's native components:

  - **Switch** routes between passthrough (simple tools) and recipe dispatch
  - **Composer** fans out one dispatch into N parallel sub-tool calls
  - **Stage + count:** executes sub-tools concurrently via GenStage workers
  - **Composer** fans in N results into one composed output

  ## Architecture

  This pipeline generalises the pattern established by bespoke dispatchers
  (e.g. `HuMan.ALF.Researcher`, `HuMan.ALF.Planner`) that hardcode their
  orchestration as sequential function calls. ToolDispatch makes it
  declarative via ALF components.

  ## Pipeline Structure

      ResolveStrategy → Switch(:dispatch_route)
        ├─ :passthrough → [DirectResolve]
        └─ :recipe → [BuildPlan, ExecuteSerial, FanOutParallel,
                       ExecuteOneCall(count:3), CollectResults, ComposeOutput]
  """

  use ALF.DSL

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

  @components [
    # Phase 1: Determine dispatch strategy
    stage(ResolveStrategy),

    # Phase 2: Route to the correct execution path
    switch(:dispatch_route,
      branches: %{
        # Simple tool — no recipe, call resolver directly
        passthrough: [
          stage(DirectResolve)
        ],

        # Recipe-based — full orchestrated dispatch
        recipe: [
          stage(BuildPlan),
          stage(ExecuteSerial),
          composer(FanOutParallel),
          stage(ExecuteOneCall, count: 3),
          composer(CollectResults, memo: []),
          stage(ComposeOutput)
        ]
      }
    )
  ]

  @doc """
  Switch routing function — called at runtime for each event.

  Returns the branch key based on the event's `strategy` field, which
  was set by `ResolveStrategy`.
  """
  @spec dispatch_route(LlmCore.Agent.ToolDispatch.Event.t(), keyword()) :: :recipe | :passthrough
  def dispatch_route(event, _opts) do
    if event.strategy == :recipe, do: :recipe, else: :passthrough
  end

  @doc """
  Starts the pipeline if not already running.

  ## Options

    * `:sync` — `true` for sequential execution (tests), `false` for
      async parallel execution (production). Default: `false`.

  ## Returns

    * `:ok` — pipeline is running
    * `{:error, reason}` — pipeline failed to start
  """
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> __MODULE__.start(opts)
      _pid -> :ok
    end
  end
end
