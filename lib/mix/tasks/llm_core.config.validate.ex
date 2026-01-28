defmodule Mix.Tasks.LlmCore.Config.Validate do
  use Mix.Task

  @shortdoc "Validates llm_core TOML configuration"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: [path: :string])

    case LlmCore.Config.Loader.reload_providers(opts) do
      {:ok, providers} ->
        print_summary(providers)

      {:error, reason} ->
        Mix.raise("Failed to load configuration: #{inspect(reason)}")
    end
  end

  defp print_summary(providers) do
    IO.puts("Loaded #{map_size(providers)} providers:\n")

    providers
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.each(fn {id, definition} ->
      status = if definition.available?, do: "available", else: "unavailable"
      aliases = Enum.join(definition.aliases, ", ")
      IO.puts("- #{id} (#{inspect(definition.module)}) -> #{status} [aliases: #{aliases}]")
    end)

    case LlmCore.Config.Store.get_routing() do
      {:ok, table} ->
        IO.puts("\nRouting default: #{table.default.alias}")

        Enum.each(table.rules, fn {task, entry} ->
          IO.puts("  #{task} => #{entry.alias} (#{entry.mode})")
        end)

      _ ->
        IO.puts("\nNo routing table loaded")
    end
  end
end
