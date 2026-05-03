defmodule LlmCore.Memory.HindsightTest do
  use ExUnit.Case, async: false

  alias LlmCore.Memory.Hindsight

  describe "build_headers/2" do
    setup do
      old_env = System.get_env("HINDSIGHT_API_KEY")

      on_exit(fn ->
        if old_env do
          System.put_env("HINDSIGHT_API_KEY", old_env)
        else
          System.delete_env("HINDSIGHT_API_KEY")
        end
      end)

      :ok
    end

    test "returns no auth header when no key is configured and no api_key is passed" do
      System.delete_env("HINDSIGHT_API_KEY")
      assert Hindsight.build_headers(nil) == [{"content-type", "application/json"}]
    end

    test "uses global env key when api_key is nil" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      assert [{"authorization", "Bearer global-key"}, {"content-type", "application/json"}] ==
               Hindsight.build_headers(nil)
    end

    test "uses passed api_key over global env key" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      assert [{"authorization", "Bearer per-call-key"}, {"content-type", "application/json"}] ==
               Hindsight.build_headers("per-call-key")
    end

    test "falls back to global when api_key is empty string" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")

      assert [{"authorization", "Bearer global-key"}, {"content-type", "application/json"}] ==
               Hindsight.build_headers("")
    end

    test "passed api_key takes precedence even when empty string" do
      System.delete_env("HINDSIGHT_API_KEY")
      assert Hindsight.build_headers("") == [{"content-type", "application/json"}]
    end
  end

  describe "sync path with :api_key opt" do
    setup do
      old_env = System.get_env("HINDSIGHT_API_KEY")

      on_exit(fn ->
        if old_env do
          System.put_env("HINDSIGHT_API_KEY", old_env)
        else
          System.delete_env("HINDSIGHT_API_KEY")
        end
      end)

      :ok
    end

    test "do_retain passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      Hindsight.do_retain("http://127.0.0.1:#{port}", "content", %{}, api_key: "tenant-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer tenant-key")
    end

    test "do_retain falls back to global key when api_key is absent" do
      System.put_env("HINDSIGHT_API_KEY", "global-key")
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      Hindsight.do_retain("http://127.0.0.1:#{port}", "content", %{}, [])

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer global-key")
    end

    test "do_recall passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      Hindsight.do_recall("http://127.0.0.1:#{port}", "query", api_key: "recall-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer recall-key")
    end

    test "do_reflect passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      Hindsight.do_reflect("http://127.0.0.1:#{port}", "question", api_key: "reflect-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer reflect-key")
    end
  end

  describe "bank management with :api_key opt" do
    setup do
      old_env = System.get_env("HINDSIGHT_API_KEY")

      on_exit(fn ->
        if old_env do
          System.put_env("HINDSIGHT_API_KEY", old_env)
        else
          System.delete_env("HINDSIGHT_API_KEY")
        end
      end)

      :ok
    end

    test "create_bank passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      Hindsight.create_bank("test-bank", api_key: "bank-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer bank-key")
    end

    test "delete_bank passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      Hindsight.delete_bank("test-bank", api_key: "delete-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer delete-key")
    end

    test "list_banks passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      Hindsight.list_banks(api_key: "list-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer list-key")
    end

    test "bank_stats passes api_key through to headers" do
      {port, server} = start_echo_server()
      on_exit(fn -> stop_echo_server(server) end)

      System.put_env("HINDSIGHT_URL", "http://127.0.0.1:#{port}")
      Hindsight.bank_stats("test-bank", api_key: "stats-key")

      last_req = receive_request()
      assert last_req != nil
      assert String.contains?(last_req, "authorization: Bearer stats-key")
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp receive_request do
    receive do
      {:request, req} -> req
    after
      2000 -> nil
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

        body = ~s<{"ok":true,"results":[],"text":"insight","banks":[]}>

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end
end
