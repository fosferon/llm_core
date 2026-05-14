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

    usage =
      case body["usage"] do
        %{"prompt_tokens" => p, "completion_tokens" => c} ->
          %{input_tokens: p, output_tokens: c, total_tokens: p + c}

        _ ->
          %{}
      end

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
    model = Keyword.get(opts, :model, "gpt-4o")
    url = completions_url(opts)

    req_body =
      %{model: model, messages: Messages.normalize_chat(prompt), stream: true}
      |> maybe_put(:max_tokens, opts[:max_tokens])
      |> maybe_put(:temperature, opts[:temperature])

    headers = [
      {"Authorization", "Bearer #{key}"},
      {"Content-Type", "application/json"}
    ]

    Stream.resource(
      fn -> start_streaming_request(url, req_body, headers) end,
      fn
        {:req_pid, ref} -> receive_chunks(ref)
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

  @spec maybe_put_tools(map(), [LlmToolkit.Tool.t()] | nil) :: map()
  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) when is_list(tools) do
    Map.put(body, :tools, Codec.encode_definitions(tools, :openai))
  end

  # ---------------------------------------------------------------------------
  # Streaming internals
  # ---------------------------------------------------------------------------

  defp start_streaming_request(url, body, headers) do
    ref = make_ref()
    parent = self()

    Task.start(fn ->
      Req.post(url,
        json: body,
        headers: headers,
        into: fn {:data, data}, {req, resp} ->
          send(parent, {:stream_chunk, ref, data})
          {:cont, {req, resp}}
        end
      )

      send(parent, {:stream_done, ref})
    end)

    {:req_pid, ref}
  end

  defp receive_chunks(ref) do
    receive do
      {:stream_chunk, ^ref, data} ->
        chunks =
          data
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&LlmCore.LLM.SSEParser.parse_line/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            :done -> true
            _ -> false
          end)

        if Enum.any?(chunks, &(&1 == :done)) do
          valid_content =
            chunks
            |> Enum.take_while(&(&1 != :done))
            |> Enum.map(fn {:ok, json} -> extract_delta(json) end)
            |> Enum.reject(&is_nil/1)

          {valid_content, :done}
        else
          content =
            chunks
            |> Enum.map(fn {:ok, json} -> extract_delta(json) end)
            |> Enum.reject(&is_nil/1)

          {content, {:req_pid, ref}}
        end

      {:stream_done, ^ref} ->
        {:halt, :done}
    after
      @default_timeout -> {:halt, :done}
    end
  end

  defp extract_delta(%{"choices" => [%{"delta" => %{"content" => content}} | _]}), do: content
  defp extract_delta(_), do: nil
end
