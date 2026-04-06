defmodule LlmCore.Agent.ToolDispatch.Components.ComposeOutput do
  @moduledoc """
  Formats collected results into a single consolidated output string.

  Uses the recipe's custom compose function if provided, otherwise
  falls back to structured markdown concatenation.

  The composed string becomes the tool result that the LLM sees —
  it should be informative and well-structured.
  """

  alias LlmCore.Agent.ToolDispatch.Event

  @doc """
  Composes serial and parallel results into a final output string.

  ## Parameters

    * `event` — `%Event{}` with `serial_results`, `parallel_results`, `errors`
    * `opts` — ALF stage options (unused)

  ## Returns

    Updated `%Event{}` with `result` set to the composed output string.
  """
  @spec call(Event.t(), keyword()) :: Event.t()
  def call(%Event{status: :error} = event, _opts), do: event

  def call(%Event{} = event, _opts) do
    compose_fn = get_compose_fn(event.plan)

    composed =
      if is_function(compose_fn, 1) do
        compose_fn.(%{
          serial_results: event.serial_results,
          parallel_results: event.parallel_results,
          errors: event.errors
        })
      else
        default_compose(event)
      end

    %{event | result: composed, status: :ok}
  end

  @spec get_compose_fn(map() | nil) :: (map() -> String.t()) | nil
  defp get_compose_fn(%{compose: compose_fn}) when is_function(compose_fn, 1), do: compose_fn
  defp get_compose_fn(_plan), do: nil

  @spec default_compose(Event.t()) :: String.t()
  defp default_compose(event) do
    sections = []

    sections =
      case event.serial_results do
        [] ->
          sections

        results ->
          text =
            results
            |> Enum.with_index(1)
            |> Enum.map(fn {%{label: label, content: content}, i} ->
              "### Step #{i}: #{label}\n#{content}"
            end)
            |> Enum.join("\n\n")

          sections ++ ["## Sequential Results\n\n#{text}"]
      end

    sections =
      case event.parallel_results do
        [] ->
          sections

        results ->
          text =
            results
            |> Enum.map(fn %{label: label, content: content} ->
              "### #{label}\n#{content}"
            end)
            |> Enum.join("\n\n")

          sections ++ ["## Additional Results\n\n#{text}"]
      end

    sections =
      case event.errors do
        [] ->
          sections

        errors ->
          text =
            errors
            |> Enum.map(fn %{label: l, error: e} -> "- **#{l}**: #{inspect(e)}" end)
            |> Enum.join("\n")

          sections ++ ["## Errors\n\n#{text}"]
      end

    case sections do
      [] -> "No results produced."
      _ -> Enum.join(sections, "\n\n")
    end
  end
end
