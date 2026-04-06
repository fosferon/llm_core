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

  @doc """
  Returns a dispatch recipe for the given tool name, or `nil`.

  When a recipe is returned, `DispatchTools` delegates to the
  `ToolDispatch` pipeline for orchestrated sub-tool execution instead
  of calling `resolve/1` directly.

  A recipe is a function that takes the tool call's arguments (a map)
  and returns an execution plan:

      %{
        serial: [%{tool: "name", arguments: %{...}, label: "Step label"}],
        parallel: [%{tool: "name", arguments: %{...}, label: "Step label"}],
        compose: &custom_compose_fn/1  # optional
      }

  ## Parameters

    * `tool_name` — The tool name to look up a recipe for

  ## Returns

    * A recipe function `(map() -> map())`, or
    * `nil` if the tool should be executed directly

  ## Example

      @impl true
      def dispatch_recipe("research_domain"), do: &MyRecipes.research_domain/1
      def dispatch_recipe(_), do: nil
  """
  @callback dispatch_recipe(String.t()) :: (map() -> map()) | nil

  @optional_callbacks [dispatch_recipe: 1]
end
