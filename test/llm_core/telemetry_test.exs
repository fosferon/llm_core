defmodule LlmCore.TelemetryTest do
  use ExUnit.Case, async: true

  alias LlmCore.Telemetry

  test "span emits start and stop events" do
    test_pid = self()

    :telemetry.attach_many(
      "llm-core-telemetry-span",
      [[:llm_core, :demo, :start], [:llm_core, :demo, :stop]],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:event, event_name, measurements, metadata})
      end,
      []
    )

    result =
      Telemetry.span(:demo, %{foo: :bar}, fn ->
        :timer.sleep(5)
        {:ok, %{status: :ok}}
      end)

    assert result == :ok

    assert_receive {:event, [:llm_core, :demo, :start], %{system_time: _}, %{foo: :bar}}

    assert_receive {:event, [:llm_core, :demo, :stop], %{duration: duration},
                    %{foo: :bar, status: :ok}}

    assert is_integer(duration)
  after
    :telemetry.detach("llm-core-telemetry-span")
  end

  test "span emits exception event" do
    test_pid = self()

    :telemetry.attach(
      "llm-core-telemetry-exception",
      [:llm_core, :boom, :exception],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:event, event_name, measurements, metadata})
      end,
      []
    )

    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span(:boom, %{}, fn -> raise "boom" end)
    end

    assert_receive {
      :event,
      [:llm_core, :boom, :exception],
      %{duration: duration},
      %{kind: :error, reason: %RuntimeError{message: "boom"}}
    }

    assert is_integer(duration)
  after
    :telemetry.detach("llm-core-telemetry-exception")
  end
end
