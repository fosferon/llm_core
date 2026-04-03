defmodule LlmCore.LLM.SSEParser do
  @moduledoc """
  Helper module for parsing Server-Sent Events (SSE) from LLM APIs.
  """
  require Logger

  @doc """
  Parses a raw SSE line and extracts the data payload.

  Returns `{:ok, data}` if data is found, `:done` if stream end signal, or `:ignore`.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | :done | :ignore
  def parse_line(line) do
    case line do
      "data: [DONE]" ->
        :done

      "data: " <> json_data ->
        case Jason.decode(json_data) do
          {:ok, decoded} -> {:ok, decoded}
          # Skip invalid JSON or keep-alive comments
          {:error, _} -> :ignore
        end

      _ ->
        :ignore
    end
  end

  @doc """
  Accumulates streamed chunks into a single content string.
  Useful for non-streaming consumers or testing.
  """
  @spec reduce_chunks(Enumerable.t()) :: String.t()
  def reduce_chunks(enum) do
    Enum.reduce(enum, "", fn chunk, acc -> acc <> chunk end)
  end
end
