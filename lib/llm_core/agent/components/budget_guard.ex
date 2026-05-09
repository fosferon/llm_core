defmodule LlmCore.Agent.Components.BudgetGuard do
  @moduledoc """
  Enforces iteration budget limits.

  If the current iteration count has reached `max_iterations - 1` (i.e.
  this is the last allowed iteration), halts the pipeline with an error
  decision. Future extensions may add token budget and cost budget
  enforcement.

  Skips processing when the decision is already `:done` (no tool calls)
  or when the pipeline is in error status.

  Analogous to budget guard clauses in step-oriented loop executors:
  that check recursion depth before proceeding.
  """

  alias LlmCore.Agent.Context

  @doc """
  Checks iteration count against `max_iterations`.

  ## Parameters

    * `ctx` — `%Context{}` with `iteration` and `max_iterations`
    * `opts` — ALF stage options (unused)

  ## Returns

    * Unchanged context when within budget
    * Context with `status: :error` and `decision: {:error, :budget_exceeded}`
      when the iteration limit is reached
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx
  def call(%Context{decision: {:done, _}} = ctx, _opts), do: ctx

  def call(%Context{iteration: i, max_iterations: max} = ctx, _opts) when i >= max - 1 do
    %{
      ctx
      | status: :error,
        error: {:budget_exceeded, :max_iterations, i + 1},
        decision: {:error, :budget_exceeded},
        trace: ctx.trace ++ [:budget_exceeded_iterations]
    }
  end

  def call(%Context{} = ctx, _opts) do
    %{ctx | trace: ctx.trace ++ [:budget_ok]}
  end
end
