defmodule LlmCore.Agent do
  @moduledoc """
  Agent struct representing a registered LLM provider with a human-friendly name.

  Each agent encapsulates:

    * A name/alias for routing lookups
    * The underlying provider module or CLI config
    * Default configuration (model, temperature, etc.)

  Agents are registered by the config loader from TOML `[providers.*]` blocks.
  They are keyed by the provider's aliases, not by `agent.name`.

  ## Accessing Agents

      # By alias (from TOML or runtime)
      {:ok, agent} = LlmCore.Agent.Registry.get("claude")

      # Get the dispatchable provider
      provider = LlmCore.Agent.dispatch_provider(agent)

  """

  @type t :: %__MODULE__{
          name: String.t(),
          provider: module() | struct(),
          config: map(),
          registered_at: DateTime.t()
        }

  @enforce_keys [:name, :provider]
  defstruct [
    :name,
    :provider,
    config: %{},
    registered_at: nil,
    provider_struct: nil
  ]

  @name_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc """
  Creates a new Agent struct with validation.

  ## Parameters

    * `name` - Human-friendly alias (lowercase alphanumeric with dashes/underscores)
    * `provider` - Module implementing `LlmCore.LLM.Provider` behaviour
    * `config` - Provider-specific configuration map (default: %{})

  ## Returns

    * `{:ok, Agent.t()}` - Valid agent
    * `{:error, :invalid_name}` - Invalid name format

  ## Examples

      iex> Agent.new("steve", LlmCore.LLM.CLIProvider, %{model: "claude-3-opus"})
      {:ok, %Agent{name: "steve", provider: LlmCore.LLM.CLIProvider, ...}}

      iex> Agent.new("INVALID", LlmCore.LLM.CLIProvider, %{})
      {:error, :invalid_name}
  """
  @spec new(String.t(), module(), map()) :: {:ok, t()} | {:error, :invalid_name}
  def new(name, provider, config \\ %{}) do
    if valid_name?(name) do
      provider_value = resolve_provider_value(provider, config)

      agent = %__MODULE__{
        name: name,
        provider: provider,
        config: config,
        provider_struct: provider_value,
        registered_at: DateTime.utc_now()
      }

      {:ok, agent}
    else
      {:error, :invalid_name}
    end
  end

  @doc """
  Validates an agent name format.

  Valid names must:
  - Start with lowercase letter or number
  - Contain only lowercase letters, numbers, dashes, and underscores
  - Not be empty

  ## Examples

      iex> Agent.valid_name?("steve")
      true

      iex> Agent.valid_name?("claude-code")
      true

      iex> Agent.valid_name?("UPPERCASE")
      false

      iex> Agent.valid_name?("")
      false
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    String.length(name) > 0 and Regex.match?(@name_regex, name)
  end

  def valid_name?(_), do: false

  @doc """
  Returns the dispatchable provider value.

  For struct-based providers (CLIProvider, Appliance), returns the struct.
  For module-based providers, returns the module atom.
  """
  @spec dispatch_provider(t()) :: module() | struct()
  def dispatch_provider(%__MODULE__{provider_struct: %_{} = ps}), do: ps
  def dispatch_provider(%__MODULE__{provider: provider}), do: provider

  defp resolve_provider_value(%LlmCore.LLM.CLIProvider{} = p, _config), do: p

  defp resolve_provider_value(module, config) when is_atom(module) do
    if module == LlmCore.LLM.CLIProvider or function_exported?(module, :__struct__, 0) do
      build_provider_struct(module, config)
    else
      nil
    end
  end

  defp resolve_provider_value(_, _), do: nil

  defp build_provider_struct(LlmCore.LLM.CLIProvider, config) do
    cli_name = config[:cli_provider] || config["cli_provider"]

    if cli_name do
      LlmCore.LLM.CLIProvider.from_config(cli_name)
    else
      nil
    end
  end

  defp build_provider_struct(_module, _config), do: nil
end
