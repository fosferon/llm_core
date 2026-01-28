defmodule LlmCore.Telemetry do
  @moduledoc """
  Helper utilities for emitting telemetry events from llm_core.
  """

  alias LlmCore.Telemetry.Settings

  @type metadata :: map()

  @doc """
  Executes the provided function within a telemetry span.

  Emits `[:llm_core, name, :start]` and `[:llm_core, name, :stop]` events with
  duration measurements in native units. If `fun` raises, an `:exception`
  event is emitted with the error details.
  """
  @spec span(atom(), metadata(), (-> {term(), metadata()})) :: term()
  def span(name, metadata, fun) when is_function(fun, 0) do
    if Settings.enabled?(name) and Settings.sample?() do
      emit_span(name, metadata, fun)
    else
      {result, _} = fun.()
      result
    end
  end

  defp emit_span(name, metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute([:llm_core, name, :start], %{system_time: System.system_time()}, metadata)

    try do
      {result, result_metadata} = fun.()
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [
          :llm_core,
          name,
          :stop
        ],
        %{duration: duration},
        Map.merge(metadata, result_metadata || %{})
      )

      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [
            :llm_core,
            name,
            :exception
          ],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: exception})
        )

        reraise exception, stacktrace
    end
  end
end
