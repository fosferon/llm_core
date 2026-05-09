defmodule LlmCore do
  @moduledoc """
  Public facade for LlmCore capabilities.

  This is the primary entry point for most LlmCore usage. It delegates to
  the routing pipeline, inference pipeline, and Hindsight memory client.

  ## Sending Prompts

      # Route by task type (configured in TOML [routing.tasks])
      {:ok, response} = LlmCore.send("Explain pattern matching", :reasoning)

      # Stream a response
      {:ok, stream} = LlmCore.stream("Write a GenServer example", :coding)
      Enum.each(stream, &IO.write/1)

      # Extract structured output
      {:ok, response} = LlmCore.send(prompt, :extraction,
        response_format: {:json_schema, %{type: "object", properties: %{...}}}
      )
      response.structured #=> %{"name" => "value"}

  ## Semantic Memory

      # Store (async, buffered)
      :ok = LlmCore.retain("Key architectural decision", %{context: "architecture"})

      # Recall by meaning
      {:ok, results} = LlmCore.recall("multi-tenancy patterns", bank_id: "my-bank")

      # Synthesize an insight
      {:ok, insight} = LlmCore.reflect("What patterns work best?", bank_id: "my-bank")

  ## Routing Introspection

      # View current routing table
      table = LlmCore.routing_table()

      # Force reload from config
      :ok = LlmCore.reload_routing()

      # Check Hindsight availability
      LlmCore.hindsight_available?()
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
