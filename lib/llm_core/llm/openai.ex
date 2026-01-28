defmodule LlmCore.LLM.OpenAI do
  @moduledoc """
  OpenAI API provider implementing the Provider behaviour.
  """
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Messages}
  require Logger

  import Kernel, except: [send: 2]

  @default_timeout 60_000
  @api_url "https://api.openai.com/v1/chat/completions"

  @impl true
  def available? do
    System.get_env("OPENAI_API_KEY") != nil
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
    if not available?() do
      {:error, Error.new(:authentication, message: "OPENAI_API_KEY not set", provider: :openai)}
    else
      do_send(prompt, opts)
    end
  end

  defp do_send(prompt, opts) do
    model = Keyword.get(opts, :model, "gpt-4o")
    messages = Messages.normalize_chat(prompt)

    req_body = %{
      model: model,
      messages: messages
    }

    headers = [
      {"Authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@api_url, json: req_body, headers: headers, receive_timeout: @default_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])

        {:ok,
         Response.new(
           content: content,
           provider: :openai,
           model: model,
           raw: body
         )}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(:provider_error,
           message: "OpenAI API error: #{status}",
           provider: :openai,
           details: body
         )}

      {:error, exception} ->
        {:error, Error.new(:connection, message: Exception.message(exception), provider: :openai)}
    end
  end

  @impl true
  def stream(prompt, opts \\ []) do
    if not available?() do
      {:error, Error.new(:authentication, message: "OPENAI_API_KEY not set", provider: :openai)}
    else
      do_stream(prompt, opts)
    end
  end

  defp do_stream(prompt, opts) do
    model = Keyword.get(opts, :model, "gpt-4o")

    req_body = %{
      model: model,
      messages: Messages.normalize_chat(prompt),
      stream: true
    }

    headers = [
      {"Authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"},
      {"Content-Type", "application/json"}
    ]

    # We use Stream.resource to wrap the lifecycle of the async request
    Stream.resource(
      fn -> start_streaming_request(@api_url, req_body, headers) end,
      fn
        {:req_pid, ref} -> receive_chunks(ref)
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
    # Wrap in result tuple
    |> then(&{:ok, &1})
  end

  defp start_streaming_request(url, body, headers) do
    ref = make_ref()
    parent = self()

    # Spawn a task to run the request and stream back to parent
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

        # Check if we hit [DONE] inside this batch
        if Enum.any?(chunks, &(&1 == :done)) do
          # Extract valid content before DONE and halt
          valid_content =
            chunks
            |> Enum.take_while(&(&1 != :done))
            |> Enum.map(fn {:ok, json} -> extract_delta(json) end)
            |> Enum.reject(&is_nil/1)

          # Next state is done to halt
          {valid_content, :done}
        else
          # Just regular chunks
          content =
            chunks
            |> Enum.map(fn {:ok, json} -> extract_delta(json) end)
            |> Enum.reject(&is_nil/1)

          {content, {:req_pid, ref}}
        end

      {:stream_done, ^ref} ->
        {:halt, :done}
    after
      # Timeout safety
      @default_timeout -> {:halt, :done}
    end
  end

  defp extract_delta(%{"choices" => [%{"delta" => %{"content" => content}} | _]}), do: content
  defp extract_delta(_), do: nil
end
