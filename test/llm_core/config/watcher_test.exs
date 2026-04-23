defmodule LlmCore.Config.WatcherTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.{Loader, Store, Watcher}

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    :ok
  end

  test "watches llm_core.toml and triggers reload" do
    dir = temp_dir()
    file = Path.join(dir, "llm_core.toml")

    File.write!(file, provider_block("demo"))

    {:ok, _} = Loader.reload_providers(path: file)

    handler_id = {:watcher_test, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:llm_core, :config, :reloaded],
      fn _, _, metadata, _ ->
        send(parent, {:config_reloaded, metadata.config})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    watcher_name = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")

    {:ok, watcher_pid} =
      start_supervised(
        {Watcher, [config_dir: dir, files: [file], debounce_ms: 10, name: watcher_name]}
      )

    File.write!(file, provider_block("demo2"))
    send(watcher_pid, {:file_event, self(), {file, []}})

    assert_receive {:config_reloaded, :providers}, 1_000

    {:ok, providers} = Store.fetch(:config, :providers)
    assert Map.has_key?(providers, "demo2")
  end

  defp provider_block(alias) do
    [
      "[providers.#{alias}]",
      "module = \"LlmCore.TestProviders.Basic\"",
      "type = \"local\"",
      "enabled = true",
      "aliases = [\"#{alias}\"]"
    ]
    |> Enum.join("\n")
  end

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "llm_core_watch-#{System.unique_integer([:positive])}")
    File.rm_rf(path)
    File.mkdir_p!(path)
    path
  end
end
