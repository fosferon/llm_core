defmodule Mix.Tasks.LlmCore.Bench do
  use Mix.Task

  @shortdoc "Runs a lightweight inference benchmark using the test provider"

  alias LlmCore.Agent
  alias LlmCore.Agent.Registry
  alias LlmCore.Config.Store
  alias LlmCore.Router
  alias LlmCore.Router.RoutingTable

  @iterations 50

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    load_test_provider()
    ensure_routing()

    {microseconds, _} =
      :timer.tc(fn ->
        Enum.each(1..@iterations, fn _ ->
          {:ok, _} = Router.send("bench", :default, response_format: {:json_schema, %{}})
        end)
      end)

    total_ms = microseconds / 1_000
    avg_ms = total_ms / @iterations

    Mix.shell().info(
      "llm_core bench: #{@iterations} calls in #{Float.round(total_ms, 2)} ms (avg #{Float.round(avg_ms, 2)} ms)"
    )
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
