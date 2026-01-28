defmodule LlmCore.Router.RouteEntry do
  @moduledoc """
  Represents a routing rule entry mapping a task type to an agent alias.
  """

  @capability_keys [
    :streaming,
    :structured_output,
    :tool_use,
    :vision,
    :reasoning,
    :attachment,
    :attachments,
    :temperature,
    :models,
    :max_context
  ]

  @type t :: %__MODULE__{
          alias: String.t(),
          mode: :abstracted | :passthrough,
          capabilities: map()
        }

  @enforce_keys [:alias]
  defstruct [:alias, mode: :abstracted, capabilities: %{}]

  @doc """
  Builds a route entry from YAML (string, list, or map).
  """
  @spec from_config(term()) :: t() | nil
  def from_config(str) when is_binary(str),
    do: %__MODULE__{alias: str, mode: :abstracted, capabilities: %{}}

  def from_config([alias, mode]) when is_binary(alias) do
    %__MODULE__{alias: alias, mode: normalize_mode(mode), capabilities: %{}}
  end

  def from_config(%{"alias" => alias} = map) when is_binary(alias) do
    %__MODULE__{
      alias: alias,
      mode: normalize_mode(Map.get(map, "mode")),
      capabilities: normalize_capabilities(Map.get(map, "capabilities"))
    }
  end

  def from_config(%{alias: alias} = map) when is_binary(alias) do
    %__MODULE__{
      alias: alias,
      mode: normalize_mode(Map.get(map, :mode)),
      capabilities: normalize_capabilities(Map.get(map, :capabilities))
    }
  end

  def from_config(_), do: nil

  defp normalize_mode(mode) when mode in ["passthrough", :passthrough], do: :passthrough
  defp normalize_mode(_), do: :abstracted

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    Map.new(capabilities, fn
      {key, value} when is_binary(key) ->
        atom_key =
          key
          |> String.replace("-", "_")
          |> String.downcase()
          |> find_capability_atom()

        {atom_key || key, value}

      pair ->
        pair
    end)
  end

  defp normalize_capabilities(_), do: %{}

  defp find_capability_atom(name) do
    Enum.find(@capability_keys, fn atom -> Atom.to_string(atom) == name end)
  end
end

defmodule LlmCore.Router.RoutingTable do
  @moduledoc """
  In-memory representation of the routing rules loaded from YAML.
  """

  alias LlmCore.Router.RouteEntry

  @type t :: %__MODULE__{
          default: RouteEntry.t(),
          rules: %{optional(String.t()) => RouteEntry.t()},
          loaded_at: DateTime.t()
        }

  @enforce_keys [:default]
  defstruct [:default, rules: %{}, loaded_at: nil]

  @spec new(map()) :: t()
  def new(map) when is_map(map) do
    default =
      map
      |> Map.get("default")
      |> RouteEntry.from_config()
      |> default_or_fallback()

    rules =
      map
      |> Map.delete("default")
      |> Enum.reduce(%{}, fn {task, value}, acc ->
        case RouteEntry.from_config(value) do
          nil -> acc
          entry -> Map.put(acc, task, entry)
        end
      end)

    %__MODULE__{default: default, rules: rules, loaded_at: DateTime.utc_now()}
  end

  defp default_or_fallback(nil), do: %RouteEntry{alias: "claude", mode: :abstracted}
  defp default_or_fallback(entry), do: entry
end

defmodule LlmCore.Router.ResolvedRoute do
  @moduledoc """
  Fully-realized routing decision containing the agent metadata.
  """

  @type t :: %__MODULE__{
          alias: String.t(),
          mode: :abstracted | :passthrough,
          agent: any()
        }

  defstruct [:alias, :mode, :agent]

  @spec new(String.t(), :abstracted | :passthrough, any()) :: t()
  def new(alias, mode, agent) do
    %__MODULE__{alias: alias, mode: mode, agent: agent}
  end
end
