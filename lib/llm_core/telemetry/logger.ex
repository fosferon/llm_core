defmodule LlmCore.Telemetry.Logger do
  @moduledoc """
  Simple telemetry handler that logs llm_core pipeline events.
  """

  require Logger

  @handler_id :llm_core_logger
  @default_events [
    [:llm_core, :routing_pipeline, :stop],
    [:llm_core, :inference_pipeline, :stop],
    [:llm_core, :provider_dispatch, :stop],
    [:llm_core, :routing_pipeline, :exception],
    [:llm_core, :inference_pipeline, :exception],
    [:llm_core, :provider_dispatch, :exception]
  ]

  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) do
    events = Keyword.get(opts, :events, @default_events)
    level = Keyword.get(opts, :level, :info)

    :telemetry.attach_many(
      @handler_id,
      events,
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @spec uninstall() :: :ok | {:error, :not_found}
  def uninstall do
    :telemetry.detach(@handler_id)
  end

  def handle_event([:llm_core, _name, :start], _measurements, _metadata, _config), do: :ok

  def handle_event([:llm_core, name, :stop], measurements, metadata, %{level: level}) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(level, fn ->
      "llm_core #{name} completed in #{duration_ms}ms #{format_metadata(metadata)}"
    end)
  end

  def handle_event([:llm_core, name, :exception], measurements, metadata, %{level: level}) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(level, fn ->
      "llm_core #{name} failed in #{duration_ms}ms #{format_metadata(metadata)}"
    end)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp format_metadata(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
    |> case do
      "" -> ""
      text -> "(#{text})"
    end
  end
end
