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

    test "buffered writes retain the backend URL active when they were queued" do
      {first_port, first_server} = start_echo_server()
      {second_port, second_server} = start_echo_server()
      on_exit(fn -> stop_echo_server(first_server) end)
      on_exit(fn -> stop_echo_server(second_server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{first_port}")
      WriteBuffer.buffer("first", %{}, bank_id: "bank1")

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{second_port}")
      WriteBuffer.buffer("second", %{}, bank_id: "bank1")

      assert :ok = WriteBuffer.flush()

      requests = receive_requests(2)
      assert Enum.any?(requests, &(&1 =~ "host: 127.0.0.1:#{first_port}"))
      assert Enum.any?(requests, &(&1 =~ "host: 127.0.0.1:#{second_port}"))
    end

    test "buffered writes retain the credential active when they were queued" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      System.put_env("HINDSIGHT_API_KEY", "queued-key")
      WriteBuffer.buffer("queued", %{}, bank_id: "bank1")

      System.put_env("HINDSIGHT_API_KEY", "replacement-key")
      assert :ok = WriteBuffer.flush()

      [request] = receive_requests(1)
      assert extract_auth_header(request) == "Bearer queued-key"
    end

    test "successful groups are removed before a later group fails" do
      {port, server} = start_sequence_server([200, 500, 200])
      on_exit(fn -> stop_echo_server(server) end)

      url = "http://127.0.0.1:#{port}"
      WriteBuffer.buffer("sent-once", %{}, bank_id: "a-success", url: url)
      WriteBuffer.buffer("retry", %{}, bank_id: "z-retry", url: url)

      assert {:error, {:http_error, 500, _body}} = WriteBuffer.flush()
      assert WriteBuffer.buffer_size() == 1

      assert :ok = WriteBuffer.flush()
      assert WriteBuffer.buffer_size() == 0

      requests = receive_requests(3)

      assert Enum.count(requests, &(&1 =~ "/banks/a-success/memories")) == 1
      assert Enum.count(requests, &(&1 =~ "/banks/z-retry/memories")) == 2
    end

    test "restored nil credentials do not fall back to a rotated environment key" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_API_KEY", "replacement-key")

      legacy_item = %{
        "content" => "legacy",
        "metadata" => %{},
        "timestamp" => "2026-01-01T00:00:00Z",
        "bank_id" => "legacy",
        "api_key" => nil,
        "url" => "http://127.0.0.1:#{port}"
      }

      :sys.replace_state(WriteBuffer, fn state ->
        %{state | buffer: [legacy_item], buffer_size: 1}
      end)

      assert :ok = WriteBuffer.flush()

      [request] = receive_requests(1)
      assert extract_auth_header(request) == nil
    end
  end

  test "shutdown persistence redacts credentials and restricts file permissions" do
    previous_home = System.get_env("LLM_CORE_HOME")
    temp_home = Path.join(System.tmp_dir!(), "llm-core-buffer-#{System.unique_integer()}")
    supervisor = LlmCore.Memory.Hindsight.Supervisor

    on_exit(fn ->
      :sys.resume(supervisor)
      wait_until(fn -> Process.whereis(WriteBuffer) end)
      WriteBuffer.clear_buffer()
      File.rm_rf(temp_home)

      if previous_home,
        do: System.put_env("LLM_CORE_HOME", previous_home),
        else: System.delete_env("LLM_CORE_HOME")
    end)

    System.put_env("LLM_CORE_HOME", temp_home)
    WriteBuffer.buffer("secret", %{}, bank_id: "bank1", api_key: "do-not-persist")

    :sys.suspend(supervisor)
    GenServer.stop(WriteBuffer, :shutdown)

    path = Path.join([temp_home, "memory", "hindsight_buffer.jsonl"])
    content = File.read!(path)
    {:ok, stat} = File.stat(path)

    refute content =~ "do-not-persist"
    assert Bitwise.band(stat.mode, 0o777) == 0o600
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

  defp start_sequence_server(statuses) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    parent = self()

    pid = spawn(fn -> sequence_accept_loop(socket, parent, statuses) end)

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

  defp sequence_accept_loop(socket, _parent, []), do: :gen_tcp.close(socket)

  defp sequence_accept_loop(socket, parent, [status | statuses]) do
    {:ok, client} = :gen_tcp.accept(socket, 5_000)
    {:ok, data} = :gen_tcp.recv(client, 0, 5_000)
    send(parent, {:request, to_string(data)})

    body = ~s<{"ok":#{status < 400}}>
    reason = if status < 400, do: "OK", else: "Internal Server Error"

    :ok =
      :gen_tcp.send(
        client,
        "HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
      )

    :gen_tcp.close(client)
    sequence_accept_loop(socket, parent, statuses)
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

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp wait_until(fun, attempts) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
