defmodule LlmCore.Telemetry.Settings do
  @moduledoc false

  alias LlmCore.Telemetry.Logger

  @default %{
    log_pipeline_events: true,
    log_provider_dispatch: true,
    sample_rate: 1.0,
    enable_logger: true,
    logger_level: :info
  }

  @persistent_key {:llm_core, :telemetry_settings}

  @doc false
  @spec apply(map()) :: :ok
  def apply(config) when is_map(config) do
    normalized = normalize(config)
    :persistent_term.put(@persistent_key, normalized)
    configure_logger(normalized)
    :ok
  end

  @doc false
  @spec current() :: map()
  def current do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        apply(%{})
        :persistent_term.get(@persistent_key)

      settings ->
        settings
    end
  end

  @doc false
  @spec enabled?(atom()) :: boolean()
  def enabled?(name) do
    settings = current()

    case name do
      :routing_pipeline -> settings.log_pipeline_events
      :inference_pipeline -> settings.log_pipeline_events
      :provider_dispatch -> settings.log_provider_dispatch
      _ -> true
    end
  end

  @doc false
  @spec sample?() :: boolean()
  def sample? do
    %{sample_rate: rate} = current()
    rate >= 1.0 or :rand.uniform() <= rate
  end

  defp normalize(config) do
    merged = Map.merge(@default, symbolize_keys(config))

    %{
      log_pipeline_events: truthy?(Map.get(merged, :log_pipeline_events)),
      log_provider_dispatch: truthy?(Map.get(merged, :log_provider_dispatch)),
      sample_rate: clamp_float(Map.get(merged, :sample_rate, 1.0)),
      enable_logger: truthy?(Map.get(merged, :enable_logger, true)),
      logger_level: normalize_level(Map.get(merged, :logger_level, :info))
    }
  end

  defp symbolize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      entry -> entry
    end)
  end

  defp truthy?(value) when is_binary(value) do
    value not in ["false", "0", ""]
  end

  defp truthy?(value), do: value not in [false, nil, 0]

  defp clamp_float(value) when is_float(value) do
    value |> max(0.0) |> min(1.0)
  end

  defp clamp_float(value) when is_integer(value), do: clamp_float(value * 1.0)
  defp clamp_float(_), do: 1.0

  defp normalize_level(value) when is_binary(value) do
    value |> String.downcase() |> String.to_atom()
  rescue
    ArgumentError -> :info
  end

  defp normalize_level(value) when value in [:debug, :info, :warning, :error], do: value
  defp normalize_level(_), do: :info

  defp configure_logger(%{enable_logger: true, logger_level: level}) do
    Logger.uninstall()
    Logger.install(level: level)
  end

  defp configure_logger(%{enable_logger: false}) do
    Logger.uninstall()
  end
end
