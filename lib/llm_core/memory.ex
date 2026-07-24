defmodule LlmCore.Memory do
  @moduledoc """
  Backend-neutral semantic memory API.
  """

  alias LlmCore.Memory.Config
  alias LlmCore.Memory.Request

  @spec backend() :: module()
  def backend, do: Config.backend_module()

  @spec available?() :: boolean()
  def available?, do: backend().available?()

  @spec retain(String.t(), map(), keyword()) :: :ok
  def retain(content, metadata \\ %{}, opts \\ []) do
    backend().retain(content, metadata, opts)
  end

  @spec retain_sync(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retain_sync(content, metadata \\ %{}, opts \\ []) do
    backend().retain_sync(content, metadata, opts)
  end

  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recall(query, opts \\ []) do
    backend().recall(query, opts)
  end

  @spec reflect(String.t() | atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def reflect(query, opts \\ [])

  def reflect(query, opts) when is_atom(query) do
    query
    |> Request.structured_question(opts)
    |> reflect(opts)
  end

  def reflect(query, opts) when is_binary(query) do
    backend().reflect(query, opts)
  end
end
