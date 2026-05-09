defmodule LlmCore.Agent.Pipeline.Iteration do
  @moduledoc """
  ALF pipeline for processing a single agentic loop iteration.

  Given an LLM response that may contain tool calls, this pipeline:

  1. **ParseToolCalls** — Extracts tool calls from the response
  2. **ValidateCalls** — Checks names exist, validates args vs schema
  3. **BudgetGuard** — Iteration budget enforcement
  4. **DispatchTools** — Executes tools via the resolver, collects results
  5. **InjectResults** — Builds tool result messages for the next turn
  6. **LoopDecision** — Decides `{:continue, msgs}` or `{:done, response}`

  This is the per-iteration counterpart to the outer loop in
  `LlmCore.Agent.Loop`. The relationship mirrors the pattern of
  an outer iteration controller wrapping a per-event processing pipeline:

      GrooveExecutor.run_steps        ↔  LlmCore.Agent.Loop.run
      Stepwise.Pipeline.Stepwise      ↔  LlmCore.Agent.Pipeline.Iteration
      StepwiseAction / Advance / etc. ↔  ParseToolCalls / Dispatch / etc.
  """

  use ALF.DSL

  alias LlmCore.Agent.Components.BudgetGuard
  alias LlmCore.Agent.Components.DispatchTools
  alias LlmCore.Agent.Components.InjectResults
  alias LlmCore.Agent.Components.LoopDecision
  alias LlmCore.Agent.Components.ParseToolCalls
  alias LlmCore.Agent.Components.ValidateCalls

  @components [
    stage(ParseToolCalls),
    stage(ValidateCalls),
    stage(BudgetGuard),
    stage(DispatchTools),
    stage(InjectResults),
    stage(LoopDecision)
  ]

  @doc """
  Ensures the ALF pipeline process is running, starting it if necessary.

  Checks if the pipeline process is registered. If not, starts it with the
  given options. Supports `sync: true` for deterministic test execution.

  ## Parameters

    * `opts` — keyword list passed to the ALF manager. Common options:
      * `:sync` — when `true`, pipeline runs synchronously (useful for tests)

  ## Returns

    * `:ok` — pipeline is running
    * `{:error, reason}` — pipeline failed to start

  ## Examples

      :ok = LlmCore.Agent.Pipeline.Iteration.ensure_started(sync: true)

  """
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> __MODULE__.start(opts)
      _pid -> :ok
    end
  end
end
