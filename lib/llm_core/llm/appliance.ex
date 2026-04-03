defmodule LlmCore.LLM.Appliance do
  @moduledoc """
  Generic local inference appliance provider (DGX Spark, future devices).

  Assumes an OpenAI-compatible chat completion API exposed over HTTP.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Messages, SSEParser}

  import Kernel, except: [send: 2]

  @chat_path "/v1/chat/completions"
  @health_path "/health"
  @default_timeout 90_000

  @doc """
  Checks if the appliance base URL is configured and the health endpoint responds.
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    case base_url([]) do
      nil -> false
      url -> health(url)
    end
  end

  @doc """
  Returns the appliance capability map. Models and max_context are sourced from
  application config.
  """
  @impl true
  @spec capabilities() :: LlmCore.LLM.Provider.capabilities()
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: Application.get_env(:llm_core, :appliance_models, []),
      max_context: Application.get_env(:llm_core, :appliance_max_context)
    }
  end

  @doc """
  Returns `:local` — Appliance is a local inference provider.
  """
  @impl true
  @spec provider_type() :: :local
  def provider_type, do: :local

  @doc """
  Sends a prompt to the appliance chat completions endpoint.
  """
  @impl true
  @spec send(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, LlmCore.LLM.Error.t()}
  def send(prompt, opts \\ []) do
    with {:ok, url} <- fetch_base_url(opts) do
      payload = build_payload(prompt, opts)
      headers = build_headers(opts)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      case Req.post(url <> @chat_path,
             json: payload,
             headers: headers,
             receive_timeout: timeout
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, build_response(body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify_error(status, body)}

        {:error, exception} ->
          {:error,
           Error.new(:connection,
             message: Exception.message(exception),
             provider: :appliance,
             details: %{stage: :send}
           )}
      end
    end
  end

  @doc """
  Streams a response from the appliance chat completions endpoint via SSE.
  """
  @impl true
  @spec stream(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LlmCore.LLM.Error.t()}
  def stream(prompt, opts \\ []) do
    with {:ok, url} <- fetch_base_url(opts) do
      payload =
        prompt
        |> build_payload(opts)
        |> Map.put("stream", true)

      headers = build_headers(opts)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      stream =
        Stream.resource(
          fn -> start_stream_request(url <> @chat_path, payload, headers, timeout) end,
          &receive_stream_chunks/1,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  end

  @doc """
  Discover configured appliances (future mDNS hook).
  """
  @spec discover() :: [{String.t() | binary(), URI.t()}]
  def discover do
    Application.get_env(:llm_core, :appliance_endpoints, [])
    |> Enum.map(fn
      %{name: name, url: url} -> {name, URI.parse(url)}
      %{url: url} -> {url, URI.parse(url)}
      url when is_binary(url) -> {url, URI.parse(url)}
    end)
  end

  @doc """
  Perform a lightweight health check against the appliance.
  """
  @spec health(String.t() | URI.t()) :: boolean()
  def health(url) when is_binary(url) do
    endpoint = String.trim_trailing(url, "/") <> @health_path

    case Req.get(endpoint, receive_timeout: 2_000, retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..399 -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def health(%URI{} = uri), do: health(URI.to_string(uri))

  @doc false
  @spec build_payload(LlmCore.LLM.Provider.prompt(), keyword()) :: map()
  def build_payload(prompt, opts \\ []) do
    %{
      "model" => Keyword.get(opts, :model, default_model()),
      "messages" => Messages.normalize_chat(prompt)
    }
    |> maybe_put("temperature", Keyword.get(opts, :temperature))
    |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens, default_max_tokens()))
    |> maybe_put("top_p", Keyword.get(opts, :top_p))
    |> maybe_put("frequency_penalty", Keyword.get(opts, :frequency_penalty))
    |> maybe_put("presence_penalty", Keyword.get(opts, :presence_penalty))
    |> maybe_put("metadata", Keyword.get(opts, :metadata))
    |> maybe_put_response_format(Keyword.get(opts, :response_format))
  end

  @doc false
  @spec decode_stream_chunk(String.t()) :: {[String.t()], boolean()}
  def decode_stream_chunk(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], false}, fn line, {chunks, done?} ->
      case SSEParser.parse_line(line) do
        {:ok, json} ->
          case extract_delta(json) do
            nil -> {chunks, done?}
            :done -> {chunks, true}
            delta -> {[delta | chunks], done?}
          end

        :done ->
          {chunks, true}

        _ ->
          {chunks, done?}
      end
    end)
    |> then(fn {chunks, done?} -> {Enum.reverse(chunks), done?} end)
  end

  defp start_stream_request(url, payload, headers, timeout) do
    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post(url,
          json: payload,
          headers: headers,
          receive_timeout: timeout,
          into: fn {:data, data}, acc ->
            send(parent, {:appliance_chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:ok, %Req.Response{status: status}} when status >= 400 ->
          send(parent, {:appliance_error, ref, classify_error(status, %{})})

        {:error, exception} ->
          send(parent, {:appliance_error, ref, exception})

        _ ->
          :ok
      end

      send(parent, {:appliance_done, ref})
    end)

    {:pending, ref}
  end

  defp receive_stream_chunks({:pending, ref}) do
    receive do
      {:appliance_chunk, ^ref, data} ->
        {chunks, done?} = decode_stream_chunk(data)

        cond do
          done? and chunks == [] ->
            {:halt, :done}

          done? ->
            {chunks, :done}

          true ->
            {chunks, {:pending, ref}}
        end

      {:appliance_error, ^ref, %Error{} = error} ->
        throw({:appliance_stream_error, error})

      {:appliance_error, ^ref, exception} ->
        throw(
          {:appliance_stream_error,
           Error.new(:provider_error,
             message: Exception.message(exception),
             provider: :appliance,
             details: %{stage: :stream}
           )}
        )

      {:appliance_done, ^ref} ->
        {:halt, :done}
    after
      5_000 ->
        {:halt, :done}
    end
  end

  defp receive_stream_chunks(:done), do: {:halt, :done}

  defp build_response(body) do
    choice = body["choices"] |> List.first() || %{}
    message = choice["message"] || %{}

    usage =
      %{}
      |> maybe_put(:prompt_tokens, get_in(body, ["usage", "prompt_tokens"]))
      |> maybe_put(:completion_tokens, get_in(body, ["usage", "completion_tokens"]))
      |> maybe_put(:total_tokens, get_in(body, ["usage", "total_tokens"]))

    Response.new(
      content: content_string(message["content"]),
      provider: :appliance,
      model: body["model"] || message["model"],
      usage: usage,
      raw: body,
      metadata: %{
        id: body["id"],
        finish_reason: choice["finish_reason"]
      }
    )
  end

  defp classify_error(status, body) do
    type =
      cond do
        status in [401, 403] -> :authentication
        status == 429 -> :rate_limit
        status in [408, 504] -> :timeout
        true -> :provider_error
      end

    message =
      body
      |> get_in(["error", "message"])
      |> case do
        nil -> "Appliance API error (status #{status})"
        msg -> msg
      end

    Error.new(type,
      message: message,
      provider: :appliance,
      details: %{status: status, body: body}
    )
  end

  defp extract_delta(%{"choices" => [%{"delta" => %{"content" => content}} | _]}) do
    content_string(content)
  end

  defp extract_delta(%{"choices" => [%{"finish_reason" => _} | _]}), do: :done
  defp extract_delta(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_response_format(payload, nil), do: payload

  defp maybe_put_response_format(payload, {:json_schema, schema}) do
    maybe_put_response_format(payload, {:json_schema, schema, []})
  end

  defp maybe_put_response_format(payload, {:json_schema, schema, opts}) do
    strict = Keyword.get(opts, :strict, true)
    name = Keyword.get(opts, :name, schema_name(schema))

    Map.put(payload, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => schema,
        "strict" => strict
      }
    })
  end

  defp maybe_put_response_format(payload, :json) do
    Map.put(payload, "response_format", %{"type" => "json_object"})
  end

  defp maybe_put_response_format(payload, _other), do: payload

  defp build_headers(opts) do
    headers = Keyword.get(opts, :headers, [])
    api_key = opts[:api_key] || Application.get_env(:llm_core, :appliance_api_key)

    base_headers =
      [{"Content-Type", "application/json"} | headers]

    if api_key do
      [{"Authorization", "Bearer #{api_key}"} | base_headers]
    else
      base_headers
    end
  end

  defp fetch_base_url(opts) do
    case base_url(opts) do
      nil ->
        {:error,
         Error.new(:provider_error,
           message: "Appliance base_url not configured",
           provider: :appliance
         )}

      url ->
        {:ok, url}
    end
  end

  defp base_url(opts) do
    opts[:base_url] || Application.get_env(:llm_core, :appliance_base_url)
  end

  defp default_model do
    Application.get_env(:llm_core, :appliance_default_model, "qwen3:8b")
  end

  defp default_max_tokens do
    Application.get_env(:llm_core, :appliance_max_tokens, 1024)
  end

  defp schema_name(%{"title" => title}) when is_binary(title), do: title
  defp schema_name(%{title: title}) when is_binary(title), do: title
  defp schema_name(_), do: "appliance_schema"

  defp content_string(content) when is_binary(content), do: content

  defp content_string(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      %{"type" => "text", "text" => text} -> text
      other -> to_string(other)
    end)
    |> Enum.join("")
  end

  defp content_string(_), do: ""
end
