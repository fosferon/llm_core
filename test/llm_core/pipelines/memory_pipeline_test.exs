defmodule LlmCore.Pipelines.MemoryPipelineTest do
  use ExUnit.Case, async: false

  alias LlmCore.Memory.Hindsight
  alias LlmCore.Memory.Hindsight.{Cache, WriteBuffer}

  setup do
    ensure_started(Cache)
    ensure_started(WriteBuffer)
    WriteBuffer.clear_buffer()

    on_exit(fn ->
      System.delete_env("HINDSIGHT_URL")
      Cache.clear()
      WriteBuffer.clear_buffer()
    end)

    :ok
  end

  test "retain_async buffers when configured" do
    System.put_env("HINDSIGHT_URL", "http://localhost:9999/mcp")

    assert :ok = Hindsight.retain("hello", %{type: :note})

    # Allow async cast to enqueue
    Process.sleep(10)
    assert WriteBuffer.buffer_size() == 1
  end

  test "retain_async no-ops when Hindsight unavailable" do
    assert :ok = Hindsight.retain("hello", %{})
    assert WriteBuffer.buffer_size() == 0
  end

  test "recall falls back to cache when available" do
    System.put_env("HINDSIGHT_URL", "http://localhost:9999/mcp")

    key = Cache.recall_key("cached-query", [])
    Cache.put(key, [%{"note" => "cached"}], ttl_ms: 60_000)

    assert {:ok, [%{"note" => "cached"}]} = Hindsight.recall("cached-query")
  end

  test "recall degrades gracefully when not configured" do
    assert {:ok, []} = Hindsight.recall("any")
  end

  test "reflect degrades gracefully when not configured" do
    assert {:ok, "Hindsight unavailable"} = Hindsight.reflect("question")
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _ -> :ok
    end
  end
end
