defmodule LlmCore.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude API provider implementing `LlmCore.LLM.Provider`.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Messages, SSEParser}
  alias LlmCore.Tool.Codec

  import Kernel, except: [send: 2]

  @default_timeout 120_000
  @messages_path "/messages"

  @doc """
  Checks if the Anthropic API key is configured.
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    api_key() not in [nil, ""]
  end

  @doc """
  Returns Anthropic's capability map including streaming, structured output,
  tool use, and supported models.
  """
  @impl true
  @spec capabilities() :: LlmCore.LLM.Provider.capabilities()
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: true,
      vision: false,
      models: [
        "claude-3-5-sonnet-latest",
        "claude-3-opus-latest",
        "claude-3-haiku-latest"
      ],
      max_context: 200_000
    }
  end

  @doc """
  Returns `:api` — Anthropic is a cloud API provider.
  """
  @impl true
  @spec provider_type() :: :api
  def provider_type, do: :api

  @doc """
  Sends a prompt to the Anthropic Messages API and returns the response.

  When `opts[:tools]` contains a list of `LlmCore.Tool` structs, tool
  definitions are encoded into the request body. If the model responds
  with `stop_reason: "tool_use"`, the returned `Response.tool_calls`
  will contain decoded `LlmCore.Tool.Call` structs.
  """
  @impl true
  @spec send(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, LlmCore.LLM.Error.t()}
  def send(prompt, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      do_send(prompt, opts, api_key)
    end
  end

  defp do_send(prompt, opts, api_key) do
    payload = build_payload(prompt, opts)
    headers = build_headers(api_key, opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    url = messages_url(opts)

    case Req.post(url, json: payload, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, build_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, classify_error(status, body)}

      {:error, exception} ->
        {:error,
         Error.new(:connection,
           message: Exception.message(exception),
           provider: :anthropic,
           details: %{stage: :send}
         )}
    end
  end

  @doc """
  Streams a response from the Anthropic Messages API using Server-Sent Events.
  """
  @impl true
  @spec stream(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LlmCore.LLM.Error.t()}
  def stream(prompt, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      payload =
        prompt
        |> build_payload(opts)
        |> Map.put("stream", true)

      headers = build_headers(api_key, opts)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      url = messages_url(opts)

      stream =
        Stream.resource(
          fn -> start_stream_request(url, payload, headers, timeout) end,
          &receive_stream_chunks/1,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  rescue
    exception ->
      {:error,
       Error.new(:provider_error,
         message: Exception.message(exception),
         provider: :anthropic,
         details: %{stage: :stream}
       )}
  end

  @doc false
  @spec build_payload(LlmCore.LLM.Provider.prompt(), keyword()) :: map()
  def build_payload(prompt, opts \\ []) do
    normalized = Messages.normalize_chat(prompt)

    {system_messages, conversation} =
      Enum.split_with(normalized, fn message -> message_role(message) == "system" end)

    %{
      "model" => Keyword.get(opts, :model, default_model()),
      "max_tokens" => Keyword.get(opts, :max_tokens, default_max_tokens()),
      "messages" => build_conversation(conversation),
      "temperature" => Keyword.get(opts, :temperature, 0.7)
    }
    |> maybe_put("top_p", Keyword.get(opts, :top_p))
    |> maybe_put("metadata", Keyword.get(opts, :metadata))
    |> maybe_put("stop_sequences", Keyword.get(opts, :stop_sequences))
    |> maybe_put_system(system_messages)
    |> maybe_put_tools(Keyword.get(opts, :tools))
    |> maybe_put_response_format(Keyword.get(opts, :response_format))
  end

  @doc false
  @spec extract_content(map()) :: String.t() | nil
  def extract_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&text_from_block/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  def extract_content(_), do: nil

  @doc false
  @spec decode_stream_chunk(String.t()) :: {[String.t()], boolean()}
  def decode_stream_chunk(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], false}, fn line, {chunks, done?} ->
      case SSEParser.parse_line(line) do
        {:ok, json} ->
          case interpret_stream_event(json) do
            {:chunk, text} -> {[text | chunks], done?}
            :done -> {chunks, true}
            :ignore -> {chunks, done?}
          end

        :done ->
          {chunks, true}

        _ ->
          {chunks, done?}
      end
    end)
    |> then(fn {chunks, done?} -> {Enum.reverse(chunks), done?} end)
  end

  defp interpret_stream_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => text}
       })
       when is_binary(text) do
    {:chunk, text}
  end

  defp interpret_stream_event(%{"type" => "message_stop"}), do: :done
  defp interpret_stream_event(_), do: :ignore

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
            send(parent, {:anthropic_chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:ok, %Req.Response{status: status}} when status >= 400 ->
          send(parent, {:anthropic_error, ref, classify_error(status, %{})})

        {:error, exception} ->
          send(parent, {:anthropic_error, ref, exception})

        _ ->
          :ok
      end

      send(parent, {:anthropic_done, ref})
    end)

    {:pending, ref}
  end

  defp receive_stream_chunks({:pending, ref}) do
    receive do
      {:anthropic_chunk, ^ref, data} ->
        {chunks, done?} = decode_stream_chunk(data)

        cond do
          done? and chunks == [] ->
            {:halt, :done}

          done? ->
            {chunks, :done}

          true ->
            {chunks, {:pending, ref}}
        end

      {:anthropic_error, ^ref, %Error{} = error} ->
        throw({:anthropic_stream_error, error})

      {:anthropic_error, ^ref, exception} ->
        error =
          Error.new(:provider_error,
            message: Exception.message(exception),
            provider: :anthropic,
            details: %{stage: :stream}
          )

        throw({:anthropic_stream_error, error})

      {:anthropic_done, ^ref} ->
        {:halt, :done}
    after
      5_000 ->
        {:halt, :done}
    end
  end

  defp receive_stream_chunks(:done), do: {:halt, :done}

  defp build_response(body) do
    content = extract_content(body)
    stop_reason = body["stop_reason"]

    usage =
      %{}
      |> maybe_put(:prompt_tokens, get_in(body, ["usage", "input_tokens"]))
      |> maybe_put(:completion_tokens, get_in(body, ["usage", "output_tokens"]))
      |> maybe_put(:total_tokens, total_tokens(body))

    tool_calls =
      if stop_reason == "tool_use" do
        Codec.decode_tool_calls(body, :anthropic)
      else
        nil
      end

    Response.new(
      content: content,
      provider: :anthropic,
      model: body["model"],
      usage: usage,
      tool_calls: tool_calls,
      raw: body,
      metadata: %{
        id: body["id"],
        stop_reason: stop_reason
      }
    )
  end

  defp total_tokens(body) do
    case get_in(body, ["usage", "input_tokens"]) do
      nil -> nil
      input -> input + (get_in(body, ["usage", "output_tokens"]) || 0)
    end
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
        nil -> "Anthropic API error (status #{status})"
        msg -> msg
      end

    Error.new(type,
      message: message,
      provider: :anthropic,
      details: %{status: status, body: body}
    )
  end

  defp build_conversation([]) do
    [%{"role" => "user", "content" => [%{"type" => "text", "text" => ""}]}]
  end

  defp build_conversation(messages) do
    messages
    |> Enum.map(&normalize_message/1)
  end

  defp normalize_message(%{"role" => "tool", "content" => content} = msg) do
    # Anthropic expects tool results as user messages with tool_result content blocks
    tool_call_id = msg["tool_call_id"]

    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_call_id,
          "content" => content
        }
      ]
    }
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{
      "role" => normalize_role(role),
      "content" => normalize_content_blocks(content)
    }
  end

  defp normalize_role(role) when role in ["assistant", "user"], do: role
  defp normalize_role(_role), do: "user"

  defp normalize_content_blocks(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp normalize_content_blocks(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} = block when is_binary(text) ->
        Map.put_new(block, "type", block["type"] || "text")

      other ->
        %{"type" => "text", "text" => to_string(other)}
    end)
  end

  defp normalize_content_blocks(content) do
    [%{"type" => "text", "text" => to_string(content)}]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_tools(map(), [LlmCore.Tool.t()] | nil) :: map()
  defp maybe_put_tools(payload, nil), do: payload
  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) when is_list(tools) do
    Map.put(payload, "tools", Codec.encode_definitions(tools, :anthropic))
  end

  defp maybe_put_system(payload, []), do: payload

  defp maybe_put_system(payload, messages) do
    system_text =
      messages
      |> Enum.map(&Map.get(&1, "content"))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    if system_text == "" do
      payload
    else
      Map.put(payload, "system", system_text)
    end
  end

  defp maybe_put_response_format(payload, nil), do: payload

  defp maybe_put_response_format(payload, {:json_schema, schema}) do
    maybe_put_response_format(payload, {:json_schema, schema, []})
  end

  defp maybe_put_response_format(payload, {:json_schema, schema, opts}) do
    name = Keyword.get(opts, :name) || schema_name(schema)
    strict = Keyword.get(opts, :strict, true)

    Map.put(payload, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => schema,
        "strict" => strict
      }
    })
  end

  defp maybe_put_response_format(payload, _other), do: payload

  defp schema_name(%{"title" => title}) when is_binary(title), do: title
  defp schema_name(%{title: title}) when is_binary(title), do: title
  defp schema_name(_), do: "llm_core_schema"

  defp message_role(%{"role" => role}), do: role
  defp message_role(_), do: "user"

  defp text_from_block(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp text_from_block(_), do: nil

  defp fetch_api_key do
    case api_key() do
      nil ->
        {:error,
         Error.new(:authentication,
           message: "ANTHROPIC_API_KEY not set",
           provider: :anthropic
         )}

      key ->
        {:ok, key}
    end
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      Application.get_env(:llm_core, :anthropic_api_key)
  end

  defp messages_url(opts) do
    base_url =
      opts[:base_url] ||
        Application.get_env(:llm_core, :anthropic_base_url, "https://api.anthropic.com/v1")

    String.trim_trailing(base_url, "/") <> @messages_path
  end

  defp build_headers(api_key, opts) do
    version =
      opts[:api_version] ||
        Application.get_env(:llm_core, :anthropic_api_version, "2023-06-01")

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", version},
      {"content-type", "application/json"}
    ]

    beta = opts[:beta] || Application.get_env(:llm_core, :anthropic_beta)

    if beta do
      [{"anthropic-beta", beta} | headers]
    else
      headers
    end
  end

  defp default_model do
    Application.get_env(:llm_core, :anthropic_default_model, "claude-3-5-sonnet-latest")
  end

  defp default_max_tokens do
    Application.get_env(:llm_core, :anthropic_max_tokens, 1024)
  end
end
