defmodule Mix.Tasks.LlmCore.Config.Set do
  @moduledoc """
  Mutates `llm_core.toml` entries and reloads the runtime configuration.

  ## Examples

      mix llm_core.config.set --path memory.hindsight.default_bank_id --value dev-bank
      mix llm_core.config.set --path routing.tasks.coding.alias --value openai
      mix llm_core.config.set --path providers.auto.enabled --value false --type boolean

  Options:

    * `--path` (required) - dot-separated key path (e.g. `routing.tasks.coding.alias`)
    * `--value` - string value (interpreted via `--type`)
    * `--json` - raw JSON payload for the value (overrides `--value`)
    * `--type` - `string` (default), `integer`, `float`, `boolean`
    * `--file` - alternate path to `llm_core.toml`
    * `--reload` - reload config after writing (default true)
  """

  use Mix.Task

  alias LlmCore.Config.{Editor, Loader}

  @shortdoc "Updates llm_core configuration"

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          path: :string,
          value: :string,
          type: :string,
          json: :string,
          file: :string,
          reload: :boolean
        ],
        aliases: [p: :path]
      )

    path = opts[:path] || Mix.raise("--path is required")
    value = decode_value(opts)
    file = opts[:file] || Editor.default_path()

    {:ok, new_config} =
      Editor.update(
        fn config ->
          segments = path |> String.split(".", trim: true)
          Editor.put_path(config, segments, value)
        end,
        file
      )

    Mix.shell().info("Updated #{path} in #{file}")

    if Map.get(opts, :reload, true) do
      Loader.reload_providers(path: file)
    end

    Mix.shell().info("New value: #{inspect(get_in(new_config, path_segments(path)))}")
  end

  defp decode_value(opts) do
    cond do
      opts[:json] -> Jason.decode!(opts[:json])
      true -> coerce_value(opts[:value], opts[:type])
    end
  end

  defp coerce_value(nil, _type), do: Mix.raise("--value or --json is required")

  defp coerce_value(value, nil), do: value

  defp coerce_value(value, type) do
    case String.downcase(type) do
      "string" -> value
      "integer" -> String.to_integer(value)
      "int" -> String.to_integer(value)
      "float" -> String.to_float(value)
      "boolean" -> parse_boolean(value)
      "bool" -> parse_boolean(value)
      other -> Mix.raise("Unsupported --type #{other}")
    end
  end

  defp parse_boolean(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> Mix.raise("Boolean value must be true/false")
    end
  end

  defp path_segments(path) do
    path |> String.split(".", trim: true)
  end
end
