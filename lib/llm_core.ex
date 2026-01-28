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
  defdelegate route(task_type), to: Router, as: :resolve

  @doc """
  Sends a prompt through the router using the matching provider.
  """
  defdelegate send(prompt, task_type, opts \\ []), to: Router

  @doc """
  Streams a prompt, returning the provider stream enumerable.
  """
  defdelegate stream(prompt, task_type, opts \\ []), to: Router

  @doc """
  Fetches the current routing table.
  """
  defdelegate routing_table(), to: Router, as: :get_routing_table

  @doc """
  Forces the router to reload configuration from disk/store.
  """
  defdelegate reload_routing(), to: Router, as: :sync

  defdelegate retain(content, metadata \\ %{}), to: Hindsight
  defdelegate retain_sync(content, metadata \\ %{}), to: Hindsight
  defdelegate recall(query, opts \\ []), to: Hindsight
  defdelegate reflect(query, opts \\ []), to: Hindsight
  defdelegate hindsight_available?(), to: Hindsight, as: :available?
end
