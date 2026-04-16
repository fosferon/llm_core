defmodule LlmCore.LLM.Provider do
  @moduledoc """
  Behaviour module defining the contract for LLM providers.

  Providers can be API-based, local appliance-based, or CLI wrappers. Each
  provider is responsible for exposing capability metadata so the router and
  inference pipeline can make informed decisions (streaming, structured output,
  tool use, etc.).

  ## Provider Types

    * `:api`    - Remote HTTP APIs (OpenAI, Anthropic, Z.ai)
    * `:local`  - Local GPU / appliance endpoints (Ollama, DGX Spark)
    * `:cli`    - Command-line tools (Claude Code CLI, Gemini CLI)

  ## Prompt Shape

  Providers must accept either a string prompt or a list of chat-style
  messages (%{role: :user | :system | :assistant, content: String.t()}).

  ## Capability Metadata

  `capabilities/0` must return a map containing, at minimum, the keys defined
  in `t:capabilities/0`. This allows llm_core to enforce requirements such as
  streaming or structured output before dispatching to a provider.

  ## Implementing a Provider

      defmodule MyProvider do
        @behaviour LlmCore.LLM.Provider

        @impl true
        def send(prompt, opts \\ []), do: {:ok, %LlmCore.LLM.Response{content: "hi"}}

        @impl true
        def stream(prompt, opts \\ []), do: {:ok, Stream.iterate(1, & &1)}

        @impl true
        def available?, do: true

        @impl true
        def capabilities do
          %{
            streaming: true,
            structured_output: false,
            tool_use: false,
            vision: false,
            models: ["demo"],
            max_context: 16_384
          }
        end

        @impl true
        def provider_type, do: :api
      end
  """

  alias LlmCore.LLM.Response
  alias LlmCore.LLM.Error

  @type role :: :system | :user | :assistant | :tool
  @type message :: %{required(:role) => role(), required(:content) => String.t()}
  @type prompt :: String.t() | [message()]
  @type opts :: keyword()

  @type capabilities :: %{
          streaming: boolean(),
          structured_output: boolean(),
          tool_use: boolean(),
          vision: boolean(),
          models: [String.t()],
          max_context: pos_integer() | nil
        }

  @doc """
  Sends a prompt to the LLM provider and returns the response.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Provider-specific options (e.g., model, temperature, max_tokens)

  ## Returns

    * `{:ok, Response.t()}` - Successful response
    * `{:error, Error.t()}` - Error occurred

  ## Examples

      {:ok, response} = MyProvider.send("Explain this code", model: "gpt-4")
      response.content
      #=> "This code does..."
  """
  @callback send(prompt(), opts()) ::
              {:ok, Response.t()} | {:error, Error.t()}

  @doc """
  Sends a prompt and returns a stream of response chunks.

  Streaming is essential for real-time user feedback, especially
  for long-running completions. The returned enumerable yields
  response chunks as they arrive from the provider.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Provider-specific options

  ## Returns

    * `{:ok, Enumerable.t()}` - Stream of response chunks
    * `{:error, Error.t()}` - Error occurred before streaming started

  ## Examples

      {:ok, stream} = MyProvider.stream("Write a story")
      Enum.each(stream, fn chunk -> IO.write(chunk) end)
  """
  @callback stream(prompt(), opts()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}

  @doc """
  Checks if the provider is available and can accept requests.

  For CLI providers, this typically checks if the CLI executable exists
  (e.g., `which claude`). For API providers, this checks if the required
  API key environment variable is set.

  ## Returns

    * `true` - Provider is available
    * `false` - Provider is not available

  ## Examples

      if MyProvider.available?() do
        MyProvider.send("Hello")
      end
  """
  @callback available?() :: boolean()

  @doc """
  Returns a map describing the provider's capabilities.

  This allows the system to make intelligent decisions about
  which provider to use for specific tasks.

  ## Expected Keys

    * `:streaming` - Boolean indicating streaming support
    * `:passthrough` - Boolean indicating pass-through mode support (CLI providers)
    * `:models` - List of supported models (optional)

  ## Returns

    * `map()` - Capability map

  ## Examples

      MyProvider.capabilities()
      #=> %{streaming: true, passthrough: false, models: ["gpt-4", "gpt-3.5-turbo"]}
  """
  @callback capabilities() :: capabilities()

  @doc """
  Returns the provider type.

  ## Returns

    * `:cli` - CLI-based provider (e.g., Claude Code, Gemini CLI)
    * `:api` - API-based provider (e.g., OpenAI, Z.ai)

  CLI providers support pass-through mode where raw commands can be
  forwarded directly to the underlying CLI.

  ## Examples

      MyProvider.provider_type()
      #=> :api
  """
  @callback provider_type() :: :cli | :api | :local

  # ── Unified Dispatch ──────────────────────────────────────
  #
  # Handles both module-based providers (legacy) and struct-based
  # providers (CLIProvider). Callers should use dispatch/3 instead
  # of calling provider.send/2 directly.

  @doc """
  Dispatches a prompt to the provider, handling both modules and structs.

  Module-based providers: calls `provider.send(prompt, opts)`.
  Struct-based providers (CLIProvider): calls `CLIProvider.send(provider, prompt, opts)`.
  """
  @spec dispatch(module() | struct(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def dispatch(provider, prompt, opts \\ [])

  def dispatch(%LlmCore.LLM.CLIProvider{} = provider, prompt, opts) do
    LlmCore.LLM.CLIProvider.send(provider, prompt, opts)
  end

  def dispatch(%{__struct__: struct_mod} = provider, prompt, opts) do
    struct_mod.send(provider, prompt, opts)
  end

  def dispatch(provider, prompt, opts) when is_atom(provider) do
    provider.send(prompt, opts)
  end

  @doc """
  Checks provider availability, handling both modules and structs.
  """
  @spec dispatch_available?(module() | struct()) :: boolean()
  def dispatch_available?(%LlmCore.LLM.CLIProvider{} = provider) do
    LlmCore.LLM.CLIProvider.available?(provider)
  end

  def dispatch_available?(%{__struct__: struct_mod} = provider) do
    struct_mod.available?(provider)
  end

  def dispatch_available?(provider) when is_atom(provider) do
    provider.available?()
  end
end
