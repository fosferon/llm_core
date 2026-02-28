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
  require Logger

  import Kernel, except: [send: 2]

  @default_timeout 60_000
  @default_base_url "https://api.openai.com/v1"
  @completions_path "/chat/completions"

  @impl true
  def available? do
    api_key() not in [nil, ""]
  end

  @impl true
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

  @impl true
  def provider_type, do: :api

  @impl true
  def send(prompt, opts \\ []) do
    key = resolve_api_key(opts)

    if key in [nil, ""] do
      {:error, Error.new(:authentication, message: "No API key set (OPENAI_API_KEY or opts[:api_key])", provider: :openai)}
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

    headers = [
      {"Authorization", "Bearer #{key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(url, json: req_body, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])

        usage = case body["usage"] do
          %{"prompt_tokens" => p, "completion_tokens" => c} ->
            %{input_tokens: p, output_tokens: c, total_tokens: p + c}
          _ -> %{}
        end

        {:ok,
         Response.new(
           content: content,
           provider: :openai,
           model: model,
           usage: usage,
           raw: body
         )}

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

  @impl true
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
