defmodule LlmCore.LLM.HttpCompressionTest do
  # Req 0.6.1 made response decompression opt-in. llm_core's non-streaming
  # requests set `compressed: true` so a gzip-encoded JSON reply is still
  # decompressed and decoded. These tests drive the real transport (Req, Finch,
  # Mint) against a one-shot local socket server.
  use ExUnit.Case, async: true

  alias LlmCore.LLM.OpenAI

  @reply %{
    "choices" => [
      %{"message" => %{"role" => "assistant", "content" => "pong"}, "finish_reason" => "stop"}
    ],
    "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
  }

  test "a gzip-encoded JSON reply is decompressed and decoded" do
    {port, request_task} = start_server(:zlib.gzip(Jason.encode!(@reply)), gzip: true)

    assert {:ok, response} =
             OpenAI.send("ping", api_key: "test", base_url: "http://127.0.0.1:#{port}/v1")

    assert response.content == "pong"

    request = Task.await(request_task, 5_000)
    assert String.downcase(request) =~ ~r/accept-encoding: [^\r\n]*gzip/
  end

  test "a plain JSON reply is decoded" do
    {port, request_task} = start_server(Jason.encode!(@reply), gzip: false)

    assert {:ok, response} =
             OpenAI.send("ping", api_key: "test", base_url: "http://127.0.0.1:#{port}/v1")

    assert response.content == "pong"
    Task.await(request_task, 5_000)
  end

  defp start_server(body, gzip: gzip?) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        request = recv_request(socket, "")

        encoding = if gzip?, do: "content-encoding: gzip\r\n", else: ""

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: application/json\r\n" <>
            encoding <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        request
      end)

    {port, task}
  end

  # Reads the request head and its content-length body so the client is not
  # cut off mid-send.
  defp recv_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(body) >= length, do: acc, else: recv_more(socket, acc)

      [_] ->
        recv_more(socket, acc)
    end
  end

  defp recv_more(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_request(socket, acc <> chunk)
      {:error, _} -> acc
    end
  end
end
