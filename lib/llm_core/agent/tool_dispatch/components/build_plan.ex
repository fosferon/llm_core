defmodule LlmCore.Agent.ToolDispatch.Components.BuildPlan do
  @moduledoc """
  Evaluates the dispatch recipe to produce an execution plan.

  The recipe is a function that takes the tool call's arguments and returns
  an execution plan with serial steps (dependent, run in order) and
  parallel steps (independent, run concurrently).

  ## Plan Structure

      %{
        serial: [%{tool: "tool_name", arguments: %{...}, label: "Step label"}],
        parallel: [%{tool: "tool_name", arguments: %{...}, label: "Step label"}],
        compose: &custom_compose_fn/1  # optional
      }
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Evaluates the recipe function to produce an execution plan.

  ## Parameters

    * `event` — `%Event{}` with `recipe` function and `call`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `plan` and `total_parallel` populated.
    On recipe error, sets `status: :error` with details.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{status: :error} = event, _opts), do: event

  def call(%Event{recipe: recipe, call: call} = event, _opts) do
    plan = recipe.(call.arguments)

    %{event | plan: plan, total_parallel: length(Map.get(plan, :parallel, []))}
  rescue
    e ->
      %{
        event
        | status: :error,
          error: {:recipe_error, Exception.message(e)},
          result: "Recipe evaluation error: #{Exception.message(e)}"
      }
  end
end
