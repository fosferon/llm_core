defmodule LlmCore.Agent do
  @moduledoc """
  Agent struct representing a registered LLM provider with a human-friendly name.

  Each agent encapsulates:
  - A unique name (alias) for human-friendly identification
  - The provider module implementing the `LlmCore.LLM.Provider` behaviour
  - Provider-specific configuration
  - Registration timestamp for debugging/auditing

  ## Name Validation

  Agent names must be lowercase alphanumeric with dashes or underscores:
  - Valid: "steve", "claude-code", "openai_4o", "agent123"
  - Invalid: "UPPERCASE", "with spaces", "special@chars"

  ## Example

      %Agent{
        name: "steve",
        provider: LlmCore.LLM.ClaudeCode,
        config: %{model: "claude-3-opus", temperature: 0.7},
        registered_at: ~U[2024-01-12 10:30:00Z]
      }

  ## Pattern Reference

  Follows VaultWise `Chat.Agent` schema pattern for name validation,
  using lowercase alphanumeric with dashes/underscores as the `short_name` format.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          provider: module(),
          config: map(),
          registered_at: DateTime.t()
        }

  @enforce_keys [:name, :provider]
  defstruct [
    :name,
    :provider,
    config: %{},
    registered_at: nil
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

      iex> Agent.new("steve", LlmCore.LLM.ClaudeCode, %{model: "claude-3-opus"})
      {:ok, %Agent{name: "steve", provider: LlmCore.LLM.ClaudeCode, ...}}

      iex> Agent.new("INVALID", LlmCore.LLM.ClaudeCode, %{})
      {:error, :invalid_name}
  """
  @spec new(String.t(), module(), map()) :: {:ok, t()} | {:error, :invalid_name}
  def new(name, provider, config \\ %{}) do
    if valid_name?(name) do
      agent = %__MODULE__{
        name: name,
        provider: provider,
        config: config,
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
end
