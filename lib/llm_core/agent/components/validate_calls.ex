defmodule LlmCore.Agent.Components.ValidateCalls do
  @moduledoc """
  Validates parsed tool calls against available tool definitions.

  Checks that each tool call's name exists in `ctx.tools`. Calls to
  unknown tools are removed from `tool_calls` and converted to error
  results so the LLM can self-correct in the next iteration.

  Optionally validates arguments via `LlmCore.Tool.Validator` when
  the tool definition includes parameter schemas.

  Skips processing when the decision is already `:done` (no tool calls)
  or when the pipeline is in error status.
  """

  alias LlmCore.Agent.Context
  alias LlmCore.Tool.Result
  alias LlmCore.Tool.Validator

  @doc """
  Validates tool calls against available tool definitions.

  Unknown tools produce error results that are fed back to the LLM.
  Tools with invalid arguments (per JSON Schema) also produce error
  results.

  ## Parameters

    * `ctx` — `%Context{}` with `tool_calls` and `tools`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Context{}` with validated `tool_calls`, error `tool_results`
    for invalid calls, and any `validation_errors`.
  """
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{status: :error} = ctx, _opts), do: ctx
  def call(%Context{decision: {:done, _}} = ctx, _opts), do: ctx

  def call(%Context{tool_calls: calls, tools: tools} = ctx, _opts) do
    tool_map = Map.new(tools, &{&1.name, &1})
    tool_names = MapSet.new(tools, & &1.name)

    {known, unknown} =
      Enum.split_with(calls, fn call -> MapSet.member?(tool_names, call.name) end)

    # Error results for unknown tools
    unknown_results =
      Enum.map(unknown, fn call ->
        available = tool_names |> MapSet.to_list() |> Enum.join(", ")

        %Result{
          tool_call_id: call.id,
          name: call.name,
          content: "Error: unknown tool '#{call.name}'. Available: #{available}"
        }
      end)

    unknown_errors = Enum.map(unknown, &{:unknown_tool, &1.name})

    # Validate arguments against schemas for known tools
    {valid, schema_results, schema_errors} = validate_arguments(known, tool_map)

    %{
      ctx
      | tool_calls: valid,
        tool_results: unknown_results ++ schema_results,
        validation_errors: unknown_errors ++ schema_errors,
        trace: ctx.trace ++ [:validate_calls]
    }
  end

  # -- Private ----------------------------------------------------------------

  @spec validate_arguments([LlmCore.Tool.Call.t()], map()) ::
          {[LlmCore.Tool.Call.t()], [Result.t()], [term()]}
  defp validate_arguments(calls, tool_map) do
    Enum.reduce(calls, {[], [], []}, fn call, {valid_acc, result_acc, error_acc} ->
      tool = Map.fetch!(tool_map, call.name)

      case Validator.validate_call(call, tool) do
        :ok ->
          {[call | valid_acc], result_acc, error_acc}

        {:error, reasons} ->
          result = %Result{
            tool_call_id: call.id,
            name: call.name,
            content: "Error: invalid arguments for '#{call.name}': #{Enum.join(reasons, "; ")}"
          }

          error = {:invalid_arguments, call.name, reasons}
          {valid_acc, [result | result_acc], [error | error_acc]}
      end
    end)
    |> then(fn {valid, results, errors} ->
      {Enum.reverse(valid), Enum.reverse(results), Enum.reverse(errors)}
    end)
  end
end
