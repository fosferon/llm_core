defmodule LlmCore.Provider.Definition do
  @moduledoc """
  Normalized provider metadata loaded from TOML configuration and runtime discovery.

  These structs are stored in `LlmCore.Config.Store` and consumed by the agent
  registry and routing pipeline for capability-aware decisions.

  ## Provider Kinds

    * `:module` — traditional module-based providers implementing `LlmCore.LLM.Provider`
    * `:cli` — CLI-based providers configured via `%CLIProvider.Config{}` structs
  """

  use TypedStruct

  typedstruct do
    field(:id, String.t(), enforce: true)
    field(:module, module() | nil)
    field(:provider_kind, :module | :cli, default: :module)
    field(:type, atom(), default: :api)
    field(:enabled, boolean(), default: true)
    field(:aliases, [String.t()], default: [])
    field(:default_agent, String.t())
    field(:default_model, String.t() | nil)
    field(:model_resolution, :gc_default | :provider_runtime | :explicit_only | nil, default: nil)
    field(:agent_config, map(), default: %{})
    field(:options, map(), default: %{})
    field(:capabilities, map(), default: %{})
    field(:auth, map(), default: %{})
    field(:metadata, map(), default: %{})
    field(:cli_config, struct() | nil, default: nil)
    field(:available?, boolean(), default: false)
    field(:availability, :ok | {:error, term()}, default: {:error, :unknown})
  end
end
