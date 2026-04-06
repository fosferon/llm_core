defmodule LlmCore.Agent.ToolDispatch.Components.ResolveStrategy do
  @moduledoc """
  Determines the dispatch strategy for a tool call.

  Checks if a recipe exists for the tool. If yes, strategy is `:recipe`
  and the event flows to the recipe branch. If no, strategy is `:passthrough`
  and the event goes to `DirectResolve`.

  This is a static structure with dynamic routing — the Switch after this
  stage uses the `strategy` field to route. The recipe branch exists whether
  or not any given call uses it.
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Sets the dispatch strategy based on recipe presence.

  ## Parameters

    * `event` — `%Event{}` with optional `recipe` field
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `strategy` set to `:passthrough` or `:recipe`.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{recipe: nil} = event, _opts) do
    %{event | strategy: :passthrough}
  end

  def call(%Event{recipe: recipe} = event, _opts) when is_function(recipe) do
    %{event | strategy: :recipe}
  end
end
