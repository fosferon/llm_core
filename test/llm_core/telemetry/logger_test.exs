defmodule LlmCore.Telemetry.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LlmCore.Telemetry.Logger

  setup do
    on_exit(fn -> Logger.uninstall() end)
    :ok
  end

  test "logs stop events" do
    :ok = Logger.install(level: :info, events: [[:llm_core, :demo, :stop]])

    log =
      capture_log(fn ->
        :telemetry.execute([:llm_core, :demo, :stop], %{duration: 10_000}, %{status: :ok})
      end)

    assert log =~ "llm_core demo completed"
  end

  test "logs exception events" do
    :ok = Logger.install(level: :warning, events: [[:llm_core, :demo, :exception]])

    log =
      capture_log(fn ->
        :telemetry.execute([:llm_core, :demo, :exception], %{duration: 5_000}, %{status: :error})
      end)

    assert log =~ "failed"
  end
end
