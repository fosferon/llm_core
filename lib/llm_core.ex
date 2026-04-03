defmodule LlmCore do
  @moduledoc """
  Public facade for llm_core capabilities.

  Provides convenience delegates for routing prompts and interacting
  with the resilient Hindsight client.
  """

  alias LlmCore.Router
  alias LlmCore.Memory.Hindsight

  @doc """
  Resolves a task type to a configured agent.
  """
  @spec route(String.t() | atom()) :: {:ok, LlmCore.Router.ResolvedRoute.t()} | {:error, term()}
  defdelegate route(task_type), to: Router, as: :resolve

  @doc """
  Sends a prompt through the router using the matching provider.
  """
  @spec send(String.t(), String.t() | atom(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, term()}
  defdelegate send(prompt, task_type, opts \\ []), to: Router

  @doc """
  Streams a prompt, returning the provider stream enumerable.
  """
  @spec stream(String.t(), String.t() | atom(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  defdelegate stream(prompt, task_type, opts \\ []), to: Router

  @doc """
  Fetches the current routing table.
  """
  @spec routing_table() :: LlmCore.Router.RoutingTable.t() | nil
  defdelegate routing_table(), to: Router, as: :get_routing_table

  @doc """
  Forces the router to reload configuration from disk/store.
  """
  @spec reload_routing() :: :ok
  defdelegate reload_routing(), to: Router, as: :sync

  @doc """
  Stores content in Hindsight for semantic indexing (async, buffered).
  """
  @spec retain(String.t(), map()) :: :ok
  defdelegate retain(content, metadata \\ %{}), to: Hindsight

  @doc """
  Stores content synchronously, bypassing the write buffer.
  """
  @spec retain_sync(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate retain_sync(content, metadata \\ %{}), to: Hindsight

  @doc """
  Semantic search for similar content with caching.
  """
  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate recall(query, opts \\ []), to: Hindsight

  @doc """
  Natural language reflection/synthesis over a bank's memories.
  """
  @spec reflect(String.t() | atom(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate reflect(query, opts \\ []), to: Hindsight

  @doc """
  Checks if Hindsight API is available and enabled.
  """
  @spec hindsight_available?() :: boolean()
  defdelegate hindsight_available?(), to: Hindsight, as: :available?
end
