defmodule LlmCore.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible API provider implementing the Provider behaviour.

  Works with OpenAI, OpenRouter, Together, Groq, local vLLM — any endpoint
  that speaks the OpenAI chat completions format.

  ## Configuration

  Defaults to OpenAI. Override per-call via opts or globally via app config:

      # Per-call
      OpenAI.send(prompt, base_url: "https://openrouter.ai/api/v1",
                          api_key: System.get_env("OPENROUTER_API_KEY"),
                          model: "anthropic/claude-sonnet-4-20250514")

      # Global (application config)
      config :llm_core, :openai_base_url, "https://openrouter.ai/api/v1"
      config :llm_core, :openai_api_key, System.get_env("OPENROUTER_API_KEY")

  ## Auth Resolution Order

  1. `opts[:api_key]` (per-call)
  2. `Application.get_env(:llm_core, :openai_api_key)`
  3. `System.get_env("OPENAI_API_KEY")`

  ## URL Resolution Order

  1. `opts[:base_url]` (per-call)
  2. `Application.get_env(:llm_core, :openai_base_url)`
  3. `"https://api.openai.com/v1"` (default)
  """
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Messages}
  alias LlmCore.Tool.Codec
  require Logger

  import Kernel, except: [send: 2]

  @default_timeout 60_000
  @default_base_url "https://api.openai.com/v1"
  @completions_path "/chat/completions"
  @type stream_event :: String.t() | {:usage, map()} | {:error, Error.t()}

  @doc """
  Checks if an OpenAI-compatible API key is configured.
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    api_key() not in [nil, ""]
  end

  @doc """
  Checks availability using the TOML-resolved auth config.

  When a provider alias (e.g. zai) reuses this module with a different
  `api_key_env`, this callback checks the correct env var instead of
  the hardcoded `OPENAI_API_KEY` default.
  """
  @impl true
  @spec available?(map()) :: boolean()
  def available?(%{"api_key_env" => env} = auth) when is_binary(env) do
    if auth["api_key_present"] == true do
      true
    else
      api_key() not in [nil, ""]
    end
  end

  def available?(_auth), do: available?()

  @doc """
  Returns the OpenAI capability map including streaming, structured output,
  tool use, vision, and supported models.
  """
  @impl true
  @spec capabilities() :: LlmCore.LLM.Provider.capabilities()
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: true,
      vision: true,
      models: ["gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo"],
      max_context: 128_000
    }
  end

  @doc """
  Returns `:api` — OpenAI is a cloud API provider.
  """
  @impl true
  @spec provider_type() :: :api
  def provider_type, do: :api

  @doc """
  Sends a prompt to the OpenAI-compatible chat completions endpoint.

  When `opts[:tools]` contains a list of `LlmToolkit.Tool` structs, tool
  definitions are encoded into the request body. If the model responds
  with `finish_reason: "tool_calls"`, the returned `Response.tool_calls`
  will contain decoded `LlmToolkit.Tool.Call` structs.
  """
  @impl true
  @spec send(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, LlmCore.LLM.Error.t()}
  def send(prompt, opts \\ []) do
    key = resolve_api_key(opts)

    if key in [nil, ""] do
      {:error,
       Error.new(:authentication,
         message: "No API key set (OPENAI_API_KEY or opts[:api_key])",
         provider: :openai
       )}
    else
      do_send(prompt, opts, key)
    end
  end

  defp do_send(prompt, opts, key) do
    model = Keyword.get(opts, :model, "gpt-4o")
    messages = Messages.normalize_chat(prompt)
    url = completions_url(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    req_body =
      %{model: model, messages: messages}
      |> maybe_put(:max_tokens, opts[:max_tokens])
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put_tools(opts[:tools])

    headers = [
      {"Authorization", "Bearer #{key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(url, json: req_body, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        build_ok_response(body, model)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(:provider_error,
           message: "API error #{status}: #{error_message(body)}",
           provider: :openai,
           details: body
         )}

      {:error, exception} ->
        {:error, Error.new(:connection, message: Exception.message(exception), provider: :openai)}
    end
  end

  @spec build_ok_response(map(), String.t()) :: {:ok, Response.t()}
  defp build_ok_response(body, model) do
    content = get_in(body, ["choices", Access.at(0), "message", "content"])
    finish_reason = get_in(body, ["choices", Access.at(0), "finish_reason"])

    usage = usage_from_openai(body["usage"])

    tool_calls =
      if finish_reason == "tool_calls" do
        Codec.decode_tool_calls(body, :openai)
      else
        nil
      end

    {:ok,
     Response.new(
       content: content,
       provider: :openai,
       model: model,
       usage: usage,
       tool_calls: tool_calls,
       raw: body,
       metadata: %{finish_reason: finish_reason}
     )}
  end

  @doc """
  Streams a response from the OpenAI-compatible chat completions endpoint.
  """
  @impl true
  @spec stream(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LlmCore.LLM.Error.t()}
  def stream(prompt, opts \\ []) do
    key = resolve_api_key(opts)

    if key in [nil, ""] do
      {:error, Error.new(:authentication, message: "No API key set", provider: :openai)}
    else
      do_stream(prompt, opts, key)
    end
  end

  defp do_stream(prompt, opts, key) do
    url = completions_url(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    req_body = build_stream_body(prompt, opts)

    headers = [
      {"Authorization", "Bearer #{key}"},
      {"Content-Type", "application/json"}
    ]

    Stream.resource(
      fn -> start_streaming_request(url, req_body, headers, timeout) end,
      fn
        {:req_pid, ref, usage_seen?} -> receive_chunks(ref, usage_seen?)
        {:stream_error, error} -> {[{:error, error}], :done}
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
    |> then(&{:ok, &1})
  end

  # ---------------------------------------------------------------------------
  # Resolution helpers
  # ---------------------------------------------------------------------------

  defp resolve_api_key(opts) do
    opts[:api_key] || api_key()
  end

  defp api_key do
    Application.get_env(:llm_core, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp completions_url(opts) do
    base =
      opts[:base_url] ||
        Application.get_env(:llm_core, :openai_base_url, @default_base_url)

    String.trim_trailing(base, "/") <> @completions_path
  end

  defp error_message(%{"error" => %{"message" => msg}}), do: msg
  defp error_message(body) when is_map(body), do: inspect(body)
  defp error_message(body), do: to_string(body)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp usage_from_openai(%{"prompt_tokens" => prompt, "completion_tokens" => completion} = usage) do
    total = Map.get(usage, "total_tokens", prompt + completion)

    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: total
    }
  end

  defp usage_from_openai(%{"total_tokens" => total}) do
    %{total_tokens: total}
  end

  defp usage_from_openai(_), do: %{}

  @spec maybe_put_tools(map(), [LlmToolkit.Tool.t()] | nil) :: map()
  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) when is_list(tools) do
    Map.put(body, :tools, Codec.encode_definitions(tools, :openai))
  end

  # ---------------------------------------------------------------------------
  # Streaming internals
  # ---------------------------------------------------------------------------

  @doc false
  @spec build_stream_body(LlmCore.LLM.Provider.prompt(), keyword()) :: map()
  def build_stream_body(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, "gpt-4o")

    %{model: model, messages: Messages.normalize_chat(prompt), stream: true}
    |> Map.put(:stream_options, %{include_usage: true})
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:temperature, opts[:temperature])
  end

  @doc false
  @spec decode_stream_chunk(String.t(), boolean()) :: {[stream_event()], boolean(), boolean()}
  def decode_stream_chunk(data, usage_seen? \\ false) when is_binary(data) do
    {events, done?, usage_seen?} =
      data
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&LlmCore.LLM.SSEParser.parse_line/1)
      |> Enum.reduce({[], false, usage_seen?}, fn
        :done, {events, _done?, usage_seen?} ->
          {events, true, usage_seen?}

        {:ok, json}, {events, done?, usage_seen?} ->
          case extract_stream_event(json) do
            nil ->
              {events, done?, usage_seen?}

            {:usage, _usage} = event ->
              {[event | events], done?, true}

            event ->
              {[event | events], done?, usage_seen?}
          end

        _other, acc ->
          acc
      end)

    events = Enum.reverse(events)
    events = if done? and not usage_seen?, do: events ++ [{:usage, %{}}], else: events

    {events, done?, usage_seen?}
  end

  defp start_streaming_request(url, body, headers, timeout) do
    ref = make_ref()
    parent = self()

    case Task.start(fn ->
           result =
             Req.post(url,
               json: body,
               headers: headers,
               receive_timeout: timeout,
               into: fn {:data, data}, {req, resp} ->
                 send(parent, {:stream_chunk, ref, data})
                 {:cont, {req, resp}}
               end
             )

           case result do
             {:ok, %Req.Response{status: status}} when status in 200..299 ->
               send(parent, {:stream_done, ref})

             {:ok, %Req.Response{status: status, body: body}} ->
               send(parent, {:stream_error, ref, provider_error(status, body)})

             {:error, exception} ->
               send(parent, {:stream_error, ref, connection_error(exception)})
           end
         end) do
      {:ok, _pid} -> {:req_pid, ref, false}
      {:error, reason} -> {:stream_error, connection_error(reason)}
    end
  end

  defp provider_error(status, body) do
    Error.new(:provider_error,
      message: "API error #{status}: #{error_message(body)}",
      provider: :openai,
      details: body
    )
  end

  defp connection_error(%_{} = exception) do
    Error.new(:connection, message: Exception.message(exception), provider: :openai)
  end

  defp connection_error(reason) do
    Error.new(:connection, message: inspect(reason), provider: :openai)
  end

  defp receive_chunks(ref, usage_seen?) do
    receive do
      {:stream_chunk, ^ref, data} ->
        {events, done?, usage_seen?} = decode_stream_chunk(data, usage_seen?)
        next = if done?, do: :done, else: {:req_pid, ref, usage_seen?}

        {events, next}

      {:stream_error, ^ref, error} ->
        {[{:error, error}], :done}

      {:stream_done, ^ref} ->
        if usage_seen? do
          {:halt, :done}
        else
          {[{:usage, %{}}], :done}
        end
    after
      @default_timeout -> {:halt, :done}
    end
  end

  defp extract_stream_event(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when not is_nil(content),
       do: content

  defp extract_stream_event(%{"usage" => usage}) when not is_nil(usage),
    do: {:usage, usage_from_openai(usage)}

  defp extract_stream_event(%{"error" => error}),
    do:
      {:error,
       Error.new(:provider_error,
         message: error_message(%{"error" => error}),
         provider: :openai,
         details: error
       )}

  defp extract_stream_event(_), do: nil
end
