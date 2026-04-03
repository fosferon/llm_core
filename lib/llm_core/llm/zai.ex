defmodule LlmCore.LLM.Zai do
  @moduledoc """
  Z.ai API provider implementing the Provider behaviour.
  Compatible with OpenAI API.
  """
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Messages}

  import Kernel, except: [send: 2]

  @default_timeout 60_000
  # Hypothetical URL
  @api_url "https://api.z.ai/v1/chat/completions"

  @doc """
  Checks if the ZAI_API_KEY environment variable is set.
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    System.get_env("ZAI_API_KEY") != nil
  end

  @doc """
  Returns the Z.ai capability map.
  """
  @impl true
  @spec capabilities() :: LlmCore.LLM.Provider.capabilities()
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: ["zai-1"],
      max_context: 64_000
    }
  end

  @doc """
  Returns `:api` — Z.ai is a cloud API provider.
  """
  @impl true
  @spec provider_type() :: :api
  def provider_type, do: :api

  @doc """
  Sends a prompt to the Z.ai chat completions endpoint.
  """
  @impl true
  @spec send(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, LlmCore.LLM.Response.t()} | {:error, LlmCore.LLM.Error.t()}
  def send(prompt, opts \\ []) do
    if not available?() do
      {:error, Error.new(:authentication, message: "ZAI_API_KEY not set", provider: :zai)}
    else
      do_send(prompt, opts)
    end
  end

  defp do_send(prompt, opts) do
    model = Keyword.get(opts, :model, "zai-1")

    req_body = %{
      model: model,
      messages: Messages.normalize_chat(prompt)
    }

    headers = [
      {"Authorization", "Bearer #{System.get_env("ZAI_API_KEY")}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@api_url, json: req_body, headers: headers, receive_timeout: @default_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])

        {:ok,
         Response.new(
           content: content,
           provider: :zai,
           model: model,
           raw: body
         )}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(:provider_error,
           message: "Z.ai API error: #{status}",
           provider: :zai,
           details: body
         )}

      {:error, exception} ->
        {:error, Error.new(:connection, message: Exception.message(exception), provider: :zai)}
    end
  end

  @doc """
  Streams a response from the Z.ai chat completions endpoint.
  """
  @impl true
  @spec stream(LlmCore.LLM.Provider.prompt(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, LlmCore.LLM.Error.t()}
  def stream(prompt, opts \\ []) do
    if not available?() do
      {:error, Error.new(:authentication, message: "ZAI_API_KEY not set", provider: :zai)}
    else
      # Z.ai is OpenAI compatible, so we use similar logic
      do_stream(prompt, opts)
    end
  end

  defp do_stream(prompt, opts) do
    model = Keyword.get(opts, :model, "zai-1")

    req_body = %{
      model: model,
      messages: Messages.normalize_chat(prompt),
      stream: true
    }

    headers = [
      {"Authorization", "Bearer #{System.get_env("ZAI_API_KEY")}"},
      {"Content-Type", "application/json"}
    ]

    # Re-using the robust streaming logic pattern from OpenAI
    Stream.resource(
      fn -> start_streaming_request(@api_url, req_body, headers) end,
      fn
        {:req_pid, ref} -> receive_chunks(ref)
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
    |> then(&{:ok, &1})
  end

  # -- Private Helpers (Duplicated from OpenAI for standalone correctness) --
  # In a larger app, we'd extract this to a BaseProvider or Helper

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
    # Reuse the SSEParser logic
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
      60_000 -> {:halt, :done}
    end
  end

  defp extract_delta(%{"choices" => [%{"delta" => %{"content" => content}} | _]}), do: content
  defp extract_delta(_), do: nil
end
