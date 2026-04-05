defmodule LlmCore.Agent.ToolResolver do
  @moduledoc """
  Behaviour for resolving tool calls to execution functions.

  Host applications implement this behaviour to map tool names to actual
  execution logic. The agentic loop uses the resolver to dispatch tool
  calls requested by the LLM.

  ## Example

      defmodule MyApp.ToolResolver do
        @behaviour LlmCore.Agent.ToolResolver

        @impl true
        def resolve(%LlmCore.Tool.Call{name: "search", arguments: args}) do
          case MyApp.Search.run(args["query"]) do
            {:ok, results} -> {:ok, format_results(results)}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end

        def resolve(%LlmCore.Tool.Call{name: name}) do
          {:error, "Unknown tool: \#{name}"}
        end

        @impl true
        def available_tools do
          [
            %LlmCore.Tool{
              name: "search",
              description: "Search the knowledge base",
              parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
            }
          ]
        end
      end
  """

  alias LlmCore.Tool
  alias LlmCore.Tool.Call

  @doc """
  Resolves and executes a tool call, returning the result content.

  ## Parameters

    * `call` — The tool call to execute

  ## Returns

    * `{:ok, content}` — Successful execution with string content
    * `{:error, reason}` — Execution failed with string reason
  """
  @callback resolve(Call.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Returns the list of tools available through this resolver.
  """
  @callback available_tools() :: [Tool.t()]
end
