defmodule LlmCore.LLM.CLIPort do
  @moduledoc """
  Helpers for running CLI-based LLM providers via `Port`.

  This is used to support true HALT semantics by allowing the executor
  to interrupt in-flight CLI operations (SIGINT/SIGTERM/SIGKILL).
  """

  alias LlmCore.Executor.Control

  @type exec_result ::
          {:ok, iodata(), non_neg_integer()}
          | {:error, :timeout}
          | {:error, term()}

  @spec run(String.t(), [String.t()], timeout(), String.t() | nil) :: exec_result()
  def run(executable, args, timeout, execution_id \\ nil)
      when is_binary(executable) and is_list(args) and is_integer(timeout) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        # Use shell wrapper with </dev/null to close stdin immediately.
        # CLI tools like Claude Code wait for stdin to close when not in a TTY.
        escaped_args = Enum.map(args, &shell_escape/1)
        shell_cmd = Enum.join([path | escaped_args], " ") <> " </dev/null"

        port =
          Port.open({:spawn, shell_cmd}, [
            :binary,
            :exit_status,
            :stderr_to_stdout
          ])

        _ = maybe_set_active(execution_id, port)

        try do
          collect_output(port, timeout, [])
        after
          _ = maybe_clear_active(execution_id)
          safe_close(port)
        end
    end
  rescue
    e -> {:error, e}
  end

  @spec stream(String.t(), [String.t()], timeout(), String.t() | nil) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(executable, args, timeout, execution_id \\ nil)
      when is_binary(executable) and is_list(args) and is_integer(timeout) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        # Use shell wrapper with </dev/null to close stdin immediately.
        escaped_args = Enum.map(args, &shell_escape/1)
        shell_cmd = Enum.join([path | escaped_args], " ") <> " </dev/null"

        port =
          Port.open({:spawn, shell_cmd}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 1024}
          ])

        _ = maybe_set_active(execution_id, port)

        stream =
          Stream.resource(
            fn -> {port, timeout, execution_id} end,
            &stream_next/1,
            fn
              nil ->
                :ok

              {port, _timeout, execution_id} ->
                _ = maybe_clear_active(execution_id)
                safe_close(port)
                :ok
            end
          )

        {:ok, stream}
    end
  rescue
    e -> {:error, e}
  end

  @spec spawn(String.t(), [String.t()], String.t() | nil) :: {:ok, port()} | {:error, term()}
  def spawn(executable, args, execution_id \\ nil) when is_binary(executable) and is_list(args) do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        # Use shell wrapper with </dev/null to close stdin immediately.
        escaped_args = Enum.map(args, &shell_escape/1)
        shell_cmd = Enum.join([path | escaped_args], " ") <> " </dev/null"

        port =
          Port.open({:spawn, shell_cmd}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 1024}
          ])

        _ = maybe_set_active(execution_id, port)
        {:ok, port}
    end
  rescue
    e -> {:error, e}
  end

  defp collect_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp stream_next({port, timeout, execution_id}) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {[line <> "\n"], {port, timeout, execution_id}}

      {^port, {:data, {:noeol, line}}} ->
        {[line], {port, timeout, execution_id}}

      {^port, {:exit_status, _status}} ->
        {:halt, {port, timeout, execution_id}}
    after
      timeout ->
        safe_close(port)
        _ = maybe_clear_active(execution_id)
        {:halt, {port, timeout, execution_id}}
    end
  end

  defp maybe_set_active(nil, _port), do: :ok

  defp maybe_set_active(execution_id, port) when is_binary(execution_id) and is_port(port) do
    _ = Control.set_active_port(execution_id, port)
    :ok
  end

  defp maybe_clear_active(nil), do: :ok

  defp maybe_clear_active(execution_id) when is_binary(execution_id) do
    _ = Control.clear_active(execution_id)
    :ok
  end

  defp safe_close(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp shell_escape(arg) when is_binary(arg) do
    # Wrap in single quotes, escaping any existing single quotes
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
