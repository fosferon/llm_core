defmodule LlmCore.Memory.BackendTest.FakeContext do
  defstruct [:tenant_id, :mode, :bank, :role_name, :prefix, :embedding_dim]
end

defmodule LlmCore.Memory.BackendTest.FakeForesight do
  def retain(context, payload, _opts), do: {:ok, %{"context" => context, "payload" => payload}}

  def recall(context, payload, _opts) do
    {:ok, %{"results" => [%{"query" => payload["query"], "bank" => context.bank}]}}
  end

  def reflect(_context, payload, _opts), do: {:ok, %{"text" => "reflected: #{payload["query"]}"}}
end

defmodule LlmCore.Memory.BackendTest do
  use ExUnit.Case, async: false

  alias LlmCore.Memory
  alias LlmCore.Memory.Backend.{ForesightHTTP, ForesightInProcess, HindsightREST}
  alias LlmCore.Memory.Config
  alias LlmCore.Memory.Hindsight.{Cache, CircuitBreaker, Monitor}
  alias LlmCore.Memory.Hindsight.Config, as: RESTConfig

  setup do
    Config.clear_runtime_override()
    RESTConfig.clear_runtime_override()
    RESTConfig.clear_ui_override()
    RESTConfig.set_discovered_url(nil)

    on_exit(fn ->
      Config.clear_runtime_override()
      RESTConfig.clear_runtime_override()
      RESTConfig.clear_ui_override()
      RESTConfig.set_discovered_url(nil)
    end)

    :ok
  end

  test "defaults to the Hindsight REST backend" do
    assert Config.backend() == :hindsight_rest
    assert Config.backend_module() == HindsightREST
  end

  test "selects configured backend and backend-specific options" do
    Config.set_runtime_override(%{
      "backend" => "foresight_http",
      "foresight_http" => %{"url" => "http://localhost:4001"}
    })

    assert Config.backend_module() == ForesightHTTP
    assert Config.backend_options() == %{url: "http://localhost:4001"}
  end

  test "Foresight HTTP does not inherit legacy Hindsight sources" do
    previous_bank = System.get_env("HINDSIGHT_BANK_ID")
    on_exit(fn -> restore_env("HINDSIGHT_BANK_ID", previous_bank) end)

    System.put_env("HINDSIGHT_BANK_ID", "legacy-bank")
    RESTConfig.set_ui_override("http://legacy-ui.test")
    RESTConfig.set_discovered_url("http://legacy-discovery.test")
    RESTConfig.set_runtime_override(%{url: "http://foresight.test"})
    Config.set_runtime_override(%{backend: :foresight_http})

    assert RESTConfig.effective_url() == "http://foresight.test"
    assert RESTConfig.effective_bank_id() == nil
  end

  test "REST cache keys are isolated by backend" do
    RESTConfig.set_runtime_override(%{url: "http://memory.test"})
    hindsight_key = Cache.recall_key("same query", [])

    Config.set_runtime_override(%{backend: :foresight_http})
    foresight_key = Cache.recall_key("same query", [])

    refute hindsight_key == foresight_key
  end

  test "REST cache keys are isolated by effective bank" do
    RESTConfig.set_runtime_override(%{url: "http://memory.test"})

    first_key = Cache.recall_key("same query", bank_id: "first")
    second_key = Cache.recall_key("same query", bank_id: "second")

    refute first_key == second_key
  end

  test "stale cache refreshes are single-flight per key" do
    Cache.clear()
    key = {:recall, :single_flight}

    assert Cache.claim_refresh(key)
    refute Cache.claim_refresh(key)

    Cache.finish_refresh(key)
    assert Cache.claim_refresh(key)
    Cache.finish_refresh(key)
  end

  test "memory background work remains supervised" do
    assert Process.whereis(Monitor)
    assert Process.whereis(LlmCore.Memory.TaskSupervisor)

    child_pids =
      LlmCore.Memory.Hindsight.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

    assert Process.whereis(Monitor) in child_pids
    assert Process.whereis(LlmCore.Memory.TaskSupervisor) in child_pids
  end

  test "REST circuit breaker keeps independent backend namespaces" do
    RESTConfig.set_runtime_override(%{
      url: "http://memory.test",
      circuit_failure_threshold: 1
    })

    CircuitBreaker.reset()
    CircuitBreaker.report_failure(:unavailable)
    assert CircuitBreaker.status().status == :open

    Config.set_runtime_override(%{backend: :foresight_http})

    assert :ok = CircuitBreaker.allow?()
    assert CircuitBreaker.status().status == :closed

    Config.set_runtime_override(%{backend: :hindsight_rest})

    assert {:error, :circuit_open} = CircuitBreaker.allow?()
    assert CircuitBreaker.status().status == :open
  end

  test "REST circuit breaker allows only one half-open probe" do
    RESTConfig.set_runtime_override(%{
      url: "http://memory.test",
      circuit_failure_threshold: 1,
      circuit_reset_ms: 1
    })

    namespace = {:hindsight_rest, "http://memory.test", "probe"}
    CircuitBreaker.reset()
    CircuitBreaker.report_failure(:unavailable, namespace)
    assert CircuitBreaker.status(namespace).status == :open

    Process.sleep(2)
    assert :ok = CircuitBreaker.allow?(namespace)
    assert {:error, :circuit_open} = CircuitBreaker.allow?(namespace)

    CircuitBreaker.report_success(namespace)
    assert CircuitBreaker.status(namespace).status == :closed
  end

  test "Foresight HTTP shares the Hindsight wire implementation" do
    {port, server} = start_echo_server()
    on_exit(fn -> Process.exit(server, :kill) end)

    Config.set_runtime_override(%{"backend" => "foresight_http"})
    RESTConfig.set_runtime_override(%{enabled: true, url: "http://127.0.0.1:#{port}"})

    assert {:ok, [%{"source" => "foresight"}]} =
             Memory.recall("wire-compatible", bypass_cache: true)

    assert_receive {:request, request}
    assert request =~ "POST /v1/default/banks/default/memories/recall"
    assert request =~ ~s("query":"wire-compatible")
  end

  test "Foresight in-process invokes the configured runtime module directly" do
    Config.set_runtime_override(%{
      backend: :foresight_inprocess,
      foresight_inprocess: %{
        module: LlmCore.Memory.BackendTest.FakeForesight,
        context_module: LlmCore.Memory.BackendTest.FakeContext,
        tenant_id: "tenant-a",
        mode: :mode_b,
        default_bank_id: "knowledge"
      }
    })

    assert Memory.backend() == ForesightInProcess
    assert Memory.available?()

    assert {:ok, %{"context" => context, "payload" => payload}} =
             Memory.retain_sync("fact", %{context: "architecture"})

    assert context.tenant_id == "tenant-a"
    assert context.mode == :mode_b
    assert context.bank == "knowledge"
    assert payload["items"] == [%{"content" => "fact", "context" => "architecture"}]
    refute payload["async"]

    assert {:ok, %{"payload" => string_context_payload}} =
             Memory.retain_sync("fact", %{"context" => "string-context"})

    assert string_context_payload["items"] == [
             %{"content" => "fact", "context" => "string-context"}
           ]

    assert {:ok, [%{"query" => "find it", "bank" => "other"}]} =
             Memory.recall("find it", bank_id: "other")

    assert {:ok, "reflected: What are the key learnings and patterns for this project?"} =
             Memory.reflect(:project_insights)

    assert :ok = Memory.retain("bufferless", %{})
  end

  if Code.ensure_loaded?(Foresight.Supervisor) do
    @tag :foresight_optional
    test "Foresight supervisor can be embedded by a consumer" do
      name = Module.concat(__MODULE__, EmbeddedForesight)

      opts = [
        name: name,
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        mcp: [enabled: false],
        ml: [enabled: false],
        tenancy: [enabled: false],
        file_ingestion: [enabled: false]
      ]

      assert {:ok, supervisor} = apply(Foresight.Supervisor, :start_link, [opts])

      assert Process.alive?(supervisor)
      Supervisor.stop(supervisor)
    end
  end

  defp start_echo_server do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    parent = self()

    pid =
      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(socket)
        {:ok, data} = :gen_tcp.recv(client, 0, 5_000)
        send(parent, {:request, to_string(data)})

        body = ~s({"results":[{"source":"foresight"}]})

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
          )

        :gen_tcp.close(client)
        :gen_tcp.close(socket)
      end)

    {port, pid}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
