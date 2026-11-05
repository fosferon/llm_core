defmodule LlmCore.Agent.ToolDispatch.Components.DirectResolve do
  @moduledoc """
  Executes a tool call directly via the resolver function.

  This is the passthrough path — no sub-tool orchestration, just
  a direct call. This branch exists so that ToolDispatch can handle
  ALL tool calls uniformly, whether they have recipes or not.
  """

  alias LlmCore.Agent.ToolDispatch.Event
  alias LlmCore.Agent.ToolDispatch.Execution

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
    case Execution.run(event, fn -> resolve_fn.(call) end) do
      {:ok, content} ->
        %{event | result: content, status: :ok}

      {:error, {:timeout, timeout_ms}} ->
        %{
          event
          | result: "Tool call timed out after #{timeout_ms}ms",
            status: :error,
            error: {:timeout, timeout_ms}
        }

      {:error, {:execution_error, reason}} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)

        %{
          event
          | result: "Tool execution error: #{message}",
            status: :error,
            error: reason
        }

      {:error, reason} ->
        %{event | result: "Error: #{inspect(reason)}", status: :error, error: reason}
    end
  end
end
