defmodule Mix.Tasks.LlmCore.Config.Show do
  @moduledoc """
  Displays llm_core configuration loaded from `llm_core.toml` (merged with
  overrides).

  ## Examples

      mix llm_core.config.show --section providers
      mix llm_core.config.show --section routing --json

  Options:

    * `--section` - one of `providers`, `routing`, `memory`, `telemetry`, `raw` (default `summary`)
    * `--provider` - filter providers/aliases when `section=providers`
    * `--json` - emit JSON instead of pretty text
    * `--path` - override config file path (defaults to project config)
  """

  use Mix.Task

  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Provider.Registry
  alias LlmCore.Router

  @shortdoc "Shows llm_core configuration"

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [section: :string, provider: :string, json: :boolean, path: :string],
        aliases: [s: :section]
      )

    path_opts = if opts[:path], do: [path: opts[:path]], else: []
    Loader.reload_providers(path_opts)

    section = opts[:section] |> to_section()
    payload = fetch_section(section, opts)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(payload, pretty: true))
    else
      print_section(section, payload)
    end
  end

  defp to_section(nil), do: :summary

  defp to_section(value) do
    case String.downcase(value) do
      "providers" -> :providers
      "routing" -> :routing
      "memory" -> :memory
      "telemetry" -> :telemetry
      "raw" -> :raw
      _ -> :summary
    end
  end

  defp fetch_section(:providers, opts) do
    providers = Registry.all() |> Map.values()

    providers =
      case opts[:provider] do
        nil -> providers
        name -> Enum.filter(providers, &match_provider?(&1, String.downcase(name)))
      end

    Enum.map(providers, fn definition ->
      base = %{
        id: definition.id,
        kind: definition.provider_kind,
        aliases: definition.aliases,
        available?: definition.available?,
        default_agent: definition.default_agent,
        capabilities: definition.capabilities
      }

      case definition.provider_kind do
        :cli ->
          Map.merge(base, %{
            binary: if(definition.cli_config, do: definition.cli_config.binary, else: nil),
            install_hint:
              if(definition.cli_config, do: definition.cli_config.install_hint, else: nil)
          })

        _ ->
          Map.merge(base, %{
            module: inspect(definition.module),
            options: definition.options,
            auth: Map.drop(definition.auth, ["api_key_present"])
          })
      end
    end)
  end

  defp fetch_section(:routing, _opts) do
    case Router.get_routing_table() do
      nil -> %{}
      table -> %{default: table.default, rules: table.rules}
    end
  end

  defp fetch_section(:memory, _opts) do
    config = HindsightConfig.effective_config()
    Map.from_struct(config)
  end

  defp fetch_section(:telemetry, _opts) do
    case Store.fetch(:config, :telemetry) do
      {:ok, telemetry} -> telemetry
      _ -> %{}
    end
  end

  defp fetch_section(:raw, _opts) do
    case Store.fetch(:config, :raw) do
      {:ok, raw} -> raw
      _ -> %{}
    end
  end

  defp fetch_section(:summary, _opts) do
    %{
      providers: Registry.all() |> map_size(),
      available_providers: Registry.available() |> length(),
      routing_loaded?: match?({:ok, _}, Store.get_routing()),
      memory: Map.from_struct(HindsightConfig.effective_config())
    }
  end

  defp print_section(:providers, list) do
    if list == [] do
      Mix.shell().info("No providers configured")
    else
      Enum.each(list, fn provider ->
        Mix.shell().info("- #{provider.id} (#{provider.module}) -> #{inspect(provider.aliases)}")
      end)
    end
  end

  defp print_section(:routing, payload) do
    Mix.shell().info("Default: #{inspect(payload.default)}")

    Enum.each(payload.rules, fn {task, entry} ->
      Mix.shell().info("  #{task} => #{inspect(entry)}")
    end)
  end

  defp print_section(:summary, payload) do
    Mix.shell().info("Providers: #{payload.providers} (#{payload.available_providers} available)")
    Mix.shell().info("Routing loaded?: #{payload.routing_loaded?}")
    Mix.shell().info("Default bank: #{payload.memory.default_bank_id || "(none)"}")
  end

  defp print_section(_section, payload) do
    Mix.shell().info(inspect(payload, pretty: true, limit: :infinity))
  end

  defp match_provider?(definition, term) do
    Enum.any?(definition.aliases, &(&1 == term)) || definition.id == term
  end
end
