defmodule LlmCore.Structured do
  @moduledoc """
  Utilities for extracting structured data from LLM responses.

  Provides lightweight JSON-mode extraction and schema validation so
  consuming applications can request structured output without pulling
  in heavy dependencies like Instructor.

  ## Supported Formats

    * `{:json_schema, schema}` — Decode JSON from the response, validate against a schema map
    * `{:json_schema, schema, opts}` — Same, with custom validator and options
    * `{:custom, fun}` — Apply a custom extraction function `(Response.t() -> {:ok, term()} | {:error, term()})`

  ## Usage

  Structured output is typically requested via `response_format` in the dispatch opts:

      {:ok, response} = LlmCore.send(prompt, :extraction,
        response_format: {:json_schema, %{type: "object", properties: %{name: %{type: "string"}}}}
      )

      response.structured
      #=> %{"name" => "value"}

  Or process a response directly:

      {:ok, response} = Structured.process({:ok, raw_response}, {:json_schema, schema})

  ## Custom Validators

      {:json_schema, schema, validator: fn value ->
        if value["score"] > 0.5, do: {:ok, value}, else: {:error, "score too low"}
      end}
  """

  alias LlmCore.LLM.Response
  alias LlmCore.Structured.{JsonMode, Validator}

  @type response_format ::
          {:json_schema, term()}
          | {:json_schema, term(), keyword()}
          | {:custom, (Response.t() -> {:ok, term()} | {:error, term()})}

  @spec process({:ok, Response.t()} | {:error, term()}, response_format() | nil) ::
          {:ok, Response.t()} | {:error, term()}
  def process(result, nil), do: result
  def process({:error, _} = error, _format), do: error

  def process({:ok, %Response{} = response}, {:json_schema, schema}) do
    process({:ok, response}, {:json_schema, schema, []})
  end

  def process({:ok, %Response{} = response}, {:json_schema, schema, opts}) do
    with {:ok, decoded} <- JsonMode.decode(response),
         {:ok, value} <- Validator.validate(decoded, schema, opts),
         {:ok, coerced} <- run_custom_validator(value, Keyword.get(opts, :validator), opts) do
      metadata = Map.put(response.metadata || %{}, :structured_format, :json_schema)
      {:ok, %{response | structured: coerced, metadata: metadata}}
    else
      {:error, reason} -> {:error, {:structured_output_error, reason}}
    end
  end

  def process({:ok, %Response{} = response}, {:custom, fun}) when is_function(fun, 1) do
    case fun.(response) do
      {:ok, value} ->
        metadata = Map.put(response.metadata || %{}, :structured_format, :custom)
        {:ok, %{response | structured: value, metadata: metadata}}

      {:error, reason} ->
        {:error, {:structured_output_error, reason}}
    end
  end

  def process({:ok, response}, _format) do
    {:ok, response}
  end

  defp run_custom_validator(value, nil, _opts), do: {:ok, value}

  defp run_custom_validator(value, fun, _opts) when is_function(fun, 1) do
    fun.(value)
  end

  defp run_custom_validator(value, fun, opts) when is_function(fun, 2) do
    fun.(value, opts)
  end

  defp run_custom_validator(value, _fun, _opts), do: {:ok, value}
end
