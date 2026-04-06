defmodule LlmCore.Agent.ToolDispatch.Components.DirectResolve do
  @moduledoc """
  Executes a tool call directly via the resolver function.

  This is the passthrough path — no sub-tool orchestration, just
  a direct call. This branch exists so that ToolDispatch can handle
  ALL tool calls uniformly, whether they have recipes or not.
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Calls `resolve_fn` with the original tool call.

  ## Parameters

    * `event` — `%Event{}` with `call` and `resolve_fn`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `result` and `status` populated.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{call: call, resolve_fn: resolve_fn} = event, _opts) do
    case resolve_fn.(call) do
      {:ok, content} ->
        %{event | result: content, status: :ok}

      {:error, reason} ->
        %{event | result: "Error: #{inspect(reason)}", status: :error, error: reason}
    end
  rescue
    e ->
      %{event | result: "Tool execution error: #{Exception.message(e)}", status: :error, error: e}
  end
end
