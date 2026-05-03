defmodule LlmCore.Memory.Hindsight.WriteBufferTest do
  use ExUnit.Case, async: false

  alias LlmCore.Memory.Hindsight.WriteBuffer

  setup do
    old_env = System.get_env("HINDSIGHT_API_KEY")
    old_url = System.get_env("HINDSIGHT_URL")

    ensure_started(WriteBuffer)
    WriteBuffer.clear_buffer()

    on_exit(fn ->
      WriteBuffer.clear_buffer()

      if old_env do
        System.put_env("HINDSIGHT_API_KEY", old_env)
      else
        System.delete_env("HINDSIGHT_API_KEY")
      end

      if old_url do
        System.put_env("HINDSIGHT_URL", old_url)
      else
        System.delete_env("HINDSIGHT_URL")
      end
    end)

    :ok
  end

  describe "build_headers/2" do
    test "returns no auth header when no key is configured and no api_key is passed" do
      System.delete_env("HINDSIGHT_API_KEY")
      assert WriteBuffer.build_headers(nil) == [{"content-type", "application/json"}]
    end

    test "uses global env key when api_key is nil" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      assert [{"authorization", "Bearer global-key"}, {"content-type", "application/json"}] ==
               WriteBuffer.build_headers(nil)
    end

    test "uses passed api_key over global env key" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      assert [{"authorization", "Bearer per-call-key"}, {"content-type", "application/json"}] ==
               WriteBuffer.build_headers("per-call-key")
    end

    test "always includes auth header for localhost when key is available" do
      System.put_env("HINDSIGHT_API_KEY", "local-key")

      assert [{"authorization", "Bearer local-key"}, {"content-type", "application/json"}] ==
               WriteBuffer.build_headers(nil)
    end
  end

  describe "buffer/3 stores api_key" do
    test "stores api_key when provided" do
      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:9999")

      WriteBuffer.buffer("content", %{}, bank_id: "bank1", api_key: "key1")
      assert WriteBuffer.buffer_size() == 1
    end

    test "stores nil api_key when not provided" do
      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:9999")

      WriteBuffer.buffer("content", %{}, bank_id: "bank1")
      assert WriteBuffer.buffer_size() == 1
    end
  end

  describe "flush partitioning by api_key" do
    test "distinct api_keys result in distinct HTTP requests" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      System.delete_env("HINDSIGHT_API_KEY")

      WriteBuffer.buffer("a", %{}, bank_id: "bank1", api_key: "key-a")
      WriteBuffer.buffer("b", %{}, bank_id: "bank1", api_key: "key-b")
      WriteBuffer.buffer("c", %{}, bank_id: "bank1", api_key: "key-c")

      assert WriteBuffer.buffer_size() == 3
      assert :ok = WriteBuffer.flush()
      assert WriteBuffer.buffer_size() == 0

      reqs = receive_requests(3)
      auth_headers = Enum.map(reqs, &extract_auth_header/1)

      assert "Bearer key-a" in auth_headers
      assert "Bearer key-b" in auth_headers
      assert "Bearer key-c" in auth_headers
    end

    test "items without api_key flush as one request with global key" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      WriteBuffer.buffer("a", %{}, bank_id: "bank1")
      WriteBuffer.buffer("b", %{}, bank_id: "bank1")
      WriteBuffer.buffer("c", %{}, bank_id: "bank1")

      assert WriteBuffer.buffer_size() == 3
      assert :ok = WriteBuffer.flush()
      assert WriteBuffer.buffer_size() == 0

      reqs = receive_requests(1)
      assert length(reqs) == 1
      assert extract_auth_header(hd(reqs)) == "Bearer global-key"
    end

    test "mixed buffer groups correctly: nil-key items -> global request; distinct keys -> per-key requests" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      WriteBuffer.buffer("a", %{}, bank_id: "bank1")
      WriteBuffer.buffer("b", %{}, bank_id: "bank1", api_key: "key-x")
      WriteBuffer.buffer("c", %{}, bank_id: "bank1", api_key: "key-y")

      assert WriteBuffer.buffer_size() == 3
      assert :ok = WriteBuffer.flush()
      assert WriteBuffer.buffer_size() == 0

      reqs = receive_requests(3)
      auth_headers = Enum.map(reqs, &extract_auth_header/1) |> Enum.sort()

      assert auth_headers == ["Bearer global-key", "Bearer key-x", "Bearer key-y"]
    end

    test "localhost with configured key carries Authorization header" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      System.put_env("HINDSIGHT_API_KEY", "local-auth-key")

      WriteBuffer.buffer("a", %{}, bank_id: "bank1")

      assert :ok = WriteBuffer.flush()

      reqs = receive_requests(1)
      assert length(reqs) == 1
      assert extract_auth_header(hd(reqs)) == "Bearer local-auth-key"
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _ -> :ok
    end
  end

  defp receive_requests(n, acc \\ []) do
    if length(acc) >= n do
      Enum.take(acc, n)
    else
      receive do
        {:request, req} -> receive_requests(n, [req | acc])
      after
        2000 -> acc
      end
    end
  end

  defp extract_auth_header(req) do
    case Regex.run(~r/authorization:\s*(.+)/i, req) do
      [_, header] -> String.trim(header)
      nil -> nil
    end
  end

  defp start_echo_server do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    parent = self()

    pid =
      spawn(fn ->
        Process.put(:parent, parent)
        accept_loop(socket)
      end)

    {port, pid}
  end

  defp stop_echo_server(pid) do
    Process.exit(pid, :kill)
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket, 500) do
      {:ok, client} ->
        parent = Process.get(:parent)
        spawn(fn -> handle_client(client, parent) end)
        accept_loop(socket)

      {:error, _} ->
        accept_loop(socket)
    end
  end

  defp handle_client(socket, parent) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        req = to_string(data)
        send(parent, {:request, req})

        body = ~s<{"ok":true}>

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end
end
