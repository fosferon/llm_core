defmodule LlmCore.Memory.Backend do
  @moduledoc """
  Contract implemented by semantic memory backends.
  """

  @callback available?() :: boolean()
  @callback recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback reflect(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback retain(String.t(), map(), keyword()) :: :ok
  @callback retain_sync(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
end
