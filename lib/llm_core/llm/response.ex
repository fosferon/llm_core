defmodule LlmCore.LLM.Response do
  @moduledoc """
  Standardized response struct for all LLM providers.

  This struct provides a unified format for responses from any provider,
  whether CLI-based (like Claude Code) or API-based (like OpenAI).

  ## Fields

    * `content` - The main text content of the response
    * `provider` - Atom identifying the provider (e.g., `:claude_code`, `:openai`)
    * `model` - String identifying the model used (e.g., "claude-3-opus", "gpt-4")
    * `usage` - Map with token usage info (prompt_tokens, completion_tokens, total_tokens)
    * `raw` - The raw response from the provider for debugging/passthrough
    * `metadata` - Additional provider-specific metadata (latency, request_id, etc.)
    * `structured` - Parsed/validated structured output (when requested)
    * `tool_calls` - List of tool call requests from the LLM, or nil when no tools were invoked

  ## Example

      response = Response.new(
        content: "Hello! How can I help you?",
        provider: :openai,
        model: "gpt-4",
        usage: %{prompt_tokens: 10, completion_tokens: 8, total_tokens: 18}
      )
  """

  @type t :: %__MODULE__{
          content: String.t() | nil,
          provider: atom() | nil,
          model: String.t() | nil,
          usage: map() | nil,
          raw: map() | nil,
          metadata: map() | nil,
          structured: any() | nil,
          tool_calls: [LlmCore.Tool.Call.t()] | nil
        }

  @enforce_keys []
  defstruct [
    :content,
    :provider,
    :model,
    :usage,
    :raw,
    :metadata,
    :structured,
    :tool_calls
  ]

  @doc """
  Creates a new Response struct from a keyword list.

  ## Parameters

    * `opts` - Keyword list with response fields

  ## Examples

      iex> Response.new(content: "Hello", provider: :openai, model: "gpt-4")
      %Response{content: "Hello", provider: :openai, model: "gpt-4", ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct(__MODULE__, opts)
  end
end
