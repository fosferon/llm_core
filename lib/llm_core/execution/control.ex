defmodule LlmCore.Executor.Control do
  @moduledoc """
  Minimal execution control registry used by CLI providers to support HALT semantics.

  Consumers that need richer state management can override these functions
  or provide their own module via dependency injection, but the defaults keep
  track of active ports so they can be cleaned up when executions end.
  """

  @table :llm_core_execution_ports

  @doc """
  Registers a port as the active process for the given execution ID.

  The execution ID is any term; callers commonly use a binary, but HALT must
  work for whatever key the consumer uses.
  """
  @spec set_active_port(term(), port()) :: :ok
  def set_active_port(execution_id, port) when is_port(port) do
    ensure_table()
    :ets.insert(@table, {execution_id, port})
    :ok
  end

  @doc """
  Removes the active port registration for the given execution ID.
  """
  @spec clear_active(term()) :: :ok
  def clear_active(execution_id) do
    ensure_table()
    :ets.delete(@table, execution_id)
    :ok
  end

  @doc """
  Looks up the active port for the given execution ID.

  Returns `{:ok, port}` if found, `:error` otherwise.
  """
  @spec lookup(term()) :: {:ok, port()} | :error
  def lookup(execution_id) do
    ensure_table()

    case :ets.lookup(@table, execution_id) do
      [{^execution_id, port}] -> {:ok, port}
      [] -> :error
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ok
  end
end
