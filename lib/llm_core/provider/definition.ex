defmodule LlmCore.Provider.Definition do
  @moduledoc """
  Normalized provider metadata loaded from TOML configuration and runtime discovery.

  These structs are stored in `LlmCore.Config.Store` and consumed by the agent
  registry and routing pipeline for capability-aware decisions.
  """

  use TypedStruct

  typedstruct do
    field(:id, String.t(), enforce: true)
    field(:module, module(), enforce: true)
    field(:type, atom(), default: :api)
    field(:enabled, boolean(), default: true)
    field(:aliases, [String.t()], default: [])
    field(:default_agent, String.t())
    field(:default_model, String.t() | nil)
    field(:agent_config, map(), default: %{})
    field(:options, map(), default: %{})
    field(:capabilities, map(), default: %{})
    field(:auth, map(), default: %{})
    field(:metadata, map(), default: %{})
    field(:available?, boolean(), default: false)
    field(:availability, :ok | {:error, term()}, default: {:error, :unknown})
  end
end
