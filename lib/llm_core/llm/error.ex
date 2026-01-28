defmodule LlmCore.LLM.Error do
  @moduledoc """
  Standardized error struct for all LLM providers.

  This struct provides a unified format for errors from any provider,
  with support for standard error types and preservation of provider-specific details.

  ## Error Types

    * `:connection` - Network connectivity issues
    * `:authentication` - API key or auth token problems
    * `:rate_limit` - Rate limiting/quota exceeded
    * `:timeout` - Request timeout
    * `:provider_error` - Provider-specific errors (preserved in details)

  ## Fields

    * `type` - One of the standard error types above
    * `message` - Human-readable error message
    * `provider` - Atom identifying the provider that raised the error
    * `details` - Map with provider-specific error details
    * `timestamp` - DateTime when the error occurred

  ## Example

      error = Error.new(:rate_limit,
        message: "Rate limit exceeded",
        provider: :openai,
        details: %{retry_after: 60}
      )
  """

  @type error_type :: :connection | :authentication | :rate_limit | :timeout | :provider_error

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t() | nil,
          provider: atom() | nil,
          details: map() | nil,
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :timestamp]
  defstruct [
    :type,
    :message,
    :provider,
    :details,
    :timestamp
  ]

  @valid_types [:connection, :authentication, :rate_limit, :timeout, :provider_error]

  @doc """
  Creates a new Error struct with the given type and options.

  ## Parameters

    * `type` - One of: `:connection`, `:authentication`, `:rate_limit`, `:timeout`, `:provider_error`
    * `opts` - Keyword list with optional fields: `:message`, `:provider`, `:details`

  ## Examples

      iex> Error.new(:connection, message: "Connection refused")
      %Error{type: :connection, message: "Connection refused", ...}

      iex> Error.new(:rate_limit, message: "Too many requests", provider: :openai, details: %{retry_after: 60})
      %Error{type: :rate_limit, ...}
  """
  @spec new(error_type(), keyword()) :: t()
  def new(type, opts \\ []) when type in @valid_types and is_list(opts) do
    struct(__MODULE__, [
      {:type, type},
      {:timestamp, DateTime.utc_now()}
      | opts
    ])
  end

  @doc """
  Wraps a provider-specific error into a standardized Error struct.

  This is useful for preserving the original error details while
  presenting a standardized interface to the rest of the system.

  ## Parameters

    * `type` - The error type to assign
    * `original_error` - The original error from the provider (stored in details)
    * `opts` - Additional options like `:message` and `:provider`

  ## Examples

      iex> original = %{code: "insufficient_quota", message: "Quota exceeded"}
      iex> Error.wrap(:provider_error, original, message: "Provider error", provider: :openai)
      %Error{type: :provider_error, details: %{code: "insufficient_quota", ...}, ...}
  """
  @spec wrap(error_type(), term(), keyword()) :: t()
  def wrap(type, original_error, opts \\ []) when type in @valid_types do
    new(type, Keyword.put(opts, :details, original_error))
  end
end
