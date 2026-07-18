defmodule LlmCore.Pipelines.MemoryPipelineTest do
  use ExUnit.Case, async: false

  alias LlmCore.Memory.Hindsight
  alias LlmCore.Memory.Hindsight.{Cache, Config, WriteBuffer}

  setup do
    old_url = System.get_env("HINDSIGHT_URL")
    old_api_key = System.get_env("HINDSIGHT_API_KEY")
    old_bank_id = System.get_env("HINDSIGHT_BANK_ID")
    old_default_bank = System.get_env("HINDSIGHT_DEFAULT_BANK")

    ensure_started(Cache)
    ensure_started(WriteBuffer)
    reset_hindsight_config()
    WriteBuffer.clear_buffer()

    on_exit(fn ->
      put_or_delete_env("HINDSIGHT_URL", old_url)
      put_or_delete_env("HINDSIGHT_API_KEY", old_api_key)
      put_or_delete_env("HINDSIGHT_BANK_ID", old_bank_id)
      put_or_delete_env("HINDSIGHT_DEFAULT_BANK", old_default_bank)

      reset_hindsight_config()
      Cache.clear()
      WriteBuffer.clear_buffer()
    end)

    :ok
  end

  test "retain_async buffers when configured" do
    Config.set_runtime_override(%{enabled: true})
    System.put_env("HINDSIGHT_URL", "http://localhost:9999/mcp")

    assert :ok = Hindsight.retain("hello", %{type: :note})

    # Allow async cast to enqueue
    Process.sleep(10)
    assert WriteBuffer.buffer_size() == 1
  end

  test "retain_async no-ops when Hindsight unavailable" do
    Config.set_runtime_override(%{enabled: false})

    assert :ok = Hindsight.retain("hello", %{})
    assert WriteBuffer.buffer_size() == 0
  end

  test "recall falls back to cache when available" do
    Config.set_runtime_override(%{enabled: true})
    System.put_env("HINDSIGHT_URL", "http://localhost:9999/mcp")

    key = Cache.recall_key("cached-query", [])
    Cache.put(key, [%{"note" => "cached"}], ttl_ms: 60_000)

    assert {:ok, [%{"note" => "cached"}]} = Hindsight.recall("cached-query")
  end

  test "recall degrades gracefully when not configured" do
    Config.set_runtime_override(%{enabled: false})

    assert {:ok, []} = Hindsight.recall("any")
  end

  test "reflect degrades gracefully when not configured" do
    Config.set_runtime_override(%{enabled: false})

    assert {:ok, "Hindsight unavailable"} = Hindsight.reflect("question")
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _ -> :ok
    end
  end

  defp reset_hindsight_config do
    Config.clear_ui_override()
    Config.clear_runtime_override()
    Config.set_discovered_url(nil)
    System.delete_env("HINDSIGHT_URL")
    System.delete_env("HINDSIGHT_API_KEY")
    System.delete_env("HINDSIGHT_BANK_ID")
    System.delete_env("HINDSIGHT_DEFAULT_BANK")
  end

  defp put_or_delete_env(key, nil), do: System.delete_env(key)
  defp put_or_delete_env(key, value), do: System.put_env(key, value)
end
