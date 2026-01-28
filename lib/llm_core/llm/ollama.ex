defmodule LlmCore.LLM.Ollama do
  @moduledoc """
  Ollama provider implementing the `LlmCore.LLM.Provider` behaviour.

  Supports both synchronous and streaming chat completions, including optional
  structured-output mode using Ollama's JSON formatting.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Error, Response, Messages}
  import Kernel, except: [send: 2]

  @default_base_url "http://localhost:11434"
  @default_model "llama3.1:8b"
  @default_timeout 120_000

  @impl true
  def available? do
    base_url = base_url([])

    case Req.get(endpoint(base_url, "/api/tags"), receive_timeout: 1_000, retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..399 -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: [],
      max_context: nil
    }
  end

  @impl true
  def provider_type, do: :local

  @impl true
  def send(prompt, opts \\ []) do
    payload = build_payload(prompt, :send, opts)

    with {:ok, body} <- request_chat(payload, opts) do
      {:ok, build_response(body)}
    end
  end

  @impl true
  def stream(prompt, opts \\ []) do
    payload =
      prompt
      |> build_payload(:stream, opts)
      |> Map.put("stream", true)

    stream = build_stream(payload, opts)
    {:ok, stream}
  rescue
    exception ->
      {:error,
       Error.new(:provider_error,
         message: Exception.message(exception),
         provider: :ollama,
         details: %{stage: :stream}
       )}
  end

  @doc false
  def build_payload(prompt, mode, opts) when mode in [:send, :stream] do
    model = Keyword.get(opts, :model, default_model())
    messages = Messages.normalize_chat(prompt)

    payload =
      %{
        "model" => model,
        "messages" => messages,
        "options" => build_generation_options(opts)
      }
      |> maybe_put_keep_alive(opts)
      |> maybe_put_format(opts)

    case Keyword.get(opts, :response_format) do
      nil -> payload
      response_format -> apply_structured_format(payload, response_format)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp request_chat(payload, opts) do
    base_url = base_url(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Req.post(endpoint(base_url, "/api/chat"),
           json: payload,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(:provider_error,
           message: "Ollama responded with status #{status}",
           provider: :ollama,
           details: %{status: status, body: body}
         )}

      {:error, exception} ->
        {:error,
         Error.new(:connection,
           message: Exception.message(exception),
           provider: :ollama,
           details: %{stage: :chat}
         )}
    end
  end

  defp build_stream(payload, opts) do
    base_url = base_url(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    url = endpoint(base_url, "/api/chat")

    Stream.resource(
      fn -> start_stream_request(url, payload, timeout) end,
      &receive_stream_chunks/1,
      fn _ -> :ok end
    )
  end

  defp start_stream_request(url, payload, timeout) do
    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post(url,
          json: payload,
          receive_timeout: timeout,
          into: fn {:data, data}, acc ->
            send(parent, {:ollama_chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:error, exception} ->
          send(
            parent,
            {:ollama_error, ref,
             Error.new(:connection,
               message: Exception.message(exception),
               provider: :ollama,
               details: %{stage: :stream}
             )}
          )

        _ ->
          :ok
      end

      send(parent, {:ollama_done, ref})
    end)

    {:pending, ref}
  end

  defp receive_stream_chunks({:pending, ref}) do
    receive do
      {:ollama_chunk, ^ref, data} ->
        chunks = parse_stream_data(data)

        cond do
          chunks == [] ->
            {[], {:pending, ref}}

          Enum.member?(chunks, :done) ->
            content = Enum.take_while(chunks, &(&1 != :done))

            if content == [] do
              {:halt, :done}
            else
              {content, :done}
            end

          true ->
            {chunks, {:pending, ref}}
        end

      {:ollama_error, ^ref, %Error{} = error} ->
        throw({:ollama_stream_error, error})

      {:ollama_done, ^ref} ->
        {:halt, :done}
    after
      5_000 ->
        {:halt, :done}
    end
  end

  defp receive_stream_chunks(:done), do: {:halt, :done}

  defp parse_stream_data(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"done" => true} = json} ->
          response = Map.get(json, "response")
          [response, :done] |> Enum.reject(&is_nil/1)

        {:ok, %{"message" => %{"content" => content}}} ->
          [content]

        _ ->
          []
      end
    end)
  end

  defp build_generation_options(opts) do
    opts
    |> Keyword.take([:temperature, :top_p, :top_k, :seed, :num_ctx, :num_predict])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if is_nil(value) do
        acc
      else
        Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  defp maybe_put_keep_alive(payload, opts) do
    case Keyword.get(opts, :keep_alive) do
      nil -> payload
      value -> Map.put(payload, "keep_alive", value)
    end
  end

  defp maybe_put_format(payload, opts) do
    case Keyword.get(opts, :format) do
      nil -> payload
      format -> Map.put(payload, "format", format)
    end
  end

  defp apply_structured_format(payload, {:json_schema, schema}) do
    apply_structured_format(payload, {:json_schema, schema, []})
  end

  defp apply_structured_format(payload, {:json_schema, schema, _opts}) do
    schema_message = %{
      "role" => "system",
      "content" => "Respond strictly with JSON matching this schema: #{Jason.encode!(schema)}"
    }

    payload
    |> Map.update!("messages", fn messages -> [schema_message | messages] end)
    |> Map.put("format", "json")
  end

  defp apply_structured_format(payload, _other), do: payload

  defp build_response(body) do
    content = get_in(body, ["message", "content"])

    usage =
      %{}
      |> maybe_put("prompt_tokens", body["prompt_eval_count"])
      |> maybe_put("completion_tokens", body["eval_count"])

    Response.new(
      content: content,
      provider: :ollama,
      model: body["model"],
      usage: usage,
      raw: body,
      metadata: %{
        done: body["done"],
        total_duration: body["total_duration"],
        load_duration: body["load_duration"]
      }
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def normalize_messages(messages), do: Messages.normalize_chat(messages)

  defp base_url(opts) do
    opts[:base_url] ||
      Application.get_env(:llm_core, :ollama_base_url) ||
      Application.get_env(:llm_core, :ollama, [])
      |> Keyword.get(:base_url, @default_base_url)
  end

  defp default_model do
    Application.get_env(:llm_core, :ollama_default_model, @default_model)
  end

  defp endpoint(base_url, path) do
    String.trim_trailing(base_url, "/") <> path
  end
end
