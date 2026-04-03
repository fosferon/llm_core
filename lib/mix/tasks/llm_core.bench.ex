unless Code.ensure_loaded?(CommBus.Protocol.Packet) do
  defmodule CommBus.Protocol.Packet do
    @moduledoc false

    defstruct conversation: nil,
              messages: [],
              metadata: %{},
              sections: %{},
              included_entries: [],
              excluded_entries: [],
              token_usage: %{}
  end
end

defmodule Mix.Tasks.LlmCore.Bench do
  @moduledoc """
  Runs ALF routing and inference pipeline benchmarks.

  Registers a lightweight test provider, configures a routing table pointing at
  it, then fires `iterations` calls through the inference pipeline with
  configurable parallelism. Reports total time, average latency, and throughput.

  ## Examples

      mix llm_core.bench
      mix llm_core.bench --iterations 500 --parallel 8
      mix llm_core.bench --mode packet
  """
  use Mix.Task

  @shortdoc "Runs ALF routing/inference benchmarks with configurable modes"

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Router
  alias LlmCore.Router.RoutingTable

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")
    load_test_provider()
    ensure_routing()

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [iterations: :integer, parallel: :integer, mode: :string],
        aliases: [i: :iterations, p: :parallel]
      )

    iterations = opts[:iterations] || 200
    parallel = opts[:parallel] || System.schedulers_online()
    mode = opts[:mode] |> normalize_mode()

    {microseconds, _} = :timer.tc(fn -> execute(iterations, parallel, mode) end)

    total_ms = microseconds / 1_000
    avg_ms = total_ms / iterations
    throughput = iterations / (total_ms / 1_000)

    Mix.shell().info(
      "llm_core bench #{mode}: #{iterations} calls in #{Float.round(total_ms, 2)} ms " <>
        "(avg #{Float.round(avg_ms, 2)} ms, #{Float.round(throughput, 1)} req/s, parallel=#{parallel})"
    )
  end

  defp execute(iterations, parallel, mode) do
    chunks =
      1..iterations
      |> Enum.chunk_every(max(div(iterations, parallel), 1))

    chunks
    |> Enum.map(fn chunk ->
      Task.async(fn -> Enum.each(chunk, fn _ -> run_iteration(mode) end) end)
    end)
    |> Enum.each(&Task.await(&1, :infinity))
  end

  defp run_iteration(:packet) do
    packet = %CommBus.Protocol.Packet{
      messages: [
        %{role: :system, content: "assistant for coding", metadata: %{}},
        %{role: :user, content: "bench request", metadata: %{language: "elixir"}}
      ],
      metadata: %{task_type: "coding", conversation_id: "bench"}
    }

    {:ok, _} = Router.send_packet(packet, task: :default)
  end

  defp run_iteration(:prompt) do
    {:ok, _} = Router.send("bench", :default, response_format: {:json_schema, %{}})
  end

  defp normalize_mode(nil), do: :prompt

  defp normalize_mode(value) do
    case String.downcase(value) do
      "packet" -> :packet
      _ -> :prompt
    end
  end

  defp load_test_provider do
    path = Path.join([File.cwd!(), "test", "support", "test_providers.exs"])

    if File.exists?(path) do
      Code.require_file(path)
    else
      Mix.raise("Cannot locate test provider helper at #{path}")
    end
  end

  defp ensure_routing do
    :ok = ensure_store()
    :ok = ensure_registry()
    :ok = ensure_router()

    {:ok, agent} = Agent.new("bench-basic", LlmCore.TestProviders.Basic, %{})
    Registry.unregister("bench-basic")
    :ok = Registry.register("bench-basic", LlmCore.TestProviders.Basic, agent.config)

    table = RoutingTable.new(%{"default" => "bench-basic"})
    :ok = Store.put_routing(table)
  end

  defp ensure_store do
    if Process.whereis(Store) do
      :ok
    else
      case Store.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
        other -> other
      end
    end
  end

  defp ensure_registry do
    if Process.whereis(Registry) do
      :ok
    else
      case Registry.start_link(auto_discover: false) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
        other -> other
      end
    end
  end

  defp ensure_router do
    if Process.whereis(Router) do
      :ok
    else
      case Router.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
        other -> other
      end
    end
  end
end
