defmodule LlmCore.LLM.CodexCLI do
  @moduledoc """
  Codex CLI provider implementing the Provider behaviour.

  This module provides integration with OpenAI's Codex CLI,
  supporting both direct prompting and pass-through mode for interactive sessions.

  ## Features

  - Execute prompts via `codex` CLI command
  - Stream responses in real-time using Port-based output capture
  - Pass-through mode for raw CLI commands
  - Automatic availability detection via `which codex`

  ## Usage

      # Check if Codex CLI is available
      if CodexCLI.available?() do
        # Send a prompt and get response
        {:ok, response} = CodexCLI.send("Explain this code")

        # Stream response in real-time
        {:ok, stream} = CodexCLI.stream("Write a function")
        Enum.each(stream, fn chunk -> IO.write(chunk) end)

        # Pass-through mode for raw CLI commands
        {:ok, port} = CodexCLI.passthrough("--help")
      end

  ## Configuration

  The module respects the following options:
    * `:timeout` - Command timeout in milliseconds (default: 120_000)
    * `:model` - Model to use (passed to CLI if supported)

  ## Pattern Reference

  Follows the same patterns as ClaudeCode and GeminiCLI for consistency
  across CLI providers.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, CLIPort, Messages}

  @default_timeout 120_000
  @codex_command "codex"

  ## Provider Behaviour Implementation

  @doc """
  Checks if the Codex CLI is available on the system.

  Uses `which codex` to detect CLI availability.

  ## Returns

    * `true` - Codex CLI is installed and in PATH
    * `false` - Codex CLI is not available

  ## Examples

      iex> CodexCLI.available?()
      true
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    case System.find_executable(@codex_command) do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Returns the provider's capabilities.

  ## Returns

    * `%{streaming: true, passthrough: true}` - Codex CLI supports streaming and pass-through

  ## Examples

      iex> CodexCLI.capabilities()
      %{streaming: true, passthrough: true}
  """
  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %{
      streaming: true,
      structured_output: false,
      tool_use: true,
      vision: false,
      models: ["codex-cli"],
      max_context: nil,
      passthrough: true
    }
  end

  @doc """
  Returns the provider type.

  ## Returns

    * `:cli` - Codex CLI is a CLI-based provider

  ## Examples

      iex> CodexCLI.provider_type()
      :cli
  """
  @impl true
  @spec provider_type() :: :cli | :api | :local
  def provider_type, do: :cli

  @doc """
  Sends a prompt to Codex CLI and returns the response.

  Uses `System.cmd/3` to execute the codex command and captures the output.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})
      * `:model` - Model to use (optional)

  ## Returns

    * `{:ok, Response.t()}` - Successful response with content
    * `{:error, Error.t()}` - Error occurred during execution

  ## Examples

      {:ok, response} = CodexCLI.send("Write a sorting function")
      response.content
      #=> "def sort(arr):\\n    ..."
  """
  @impl true
  @spec send(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def send(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Codex CLI not available. Install with: npm install -g @openai/codex",
         provider: :codex_cli,
         details: %{reason: :not_installed}
       )}
    else
      execute_prompt(prompt, opts)
    end
  end

  @doc """
  Streams a response from Codex CLI in real-time.

  Uses `Port.open/2` to capture output as it arrives, returning
  a lazy Stream of response chunks.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})

  ## Returns

    * `{:ok, Enumerable.t()}` - Stream of response chunks
    * `{:error, Error.t()}` - Error occurred before streaming started

  ## Examples

      {:ok, stream} = CodexCLI.stream("Write a complex algorithm")
      Enum.each(stream, fn chunk -> IO.write(chunk) end)
  """
  @impl true
  @spec stream(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Codex CLI not available",
         provider: :codex_cli,
         details: %{reason: :not_installed}
       )}
    else
      create_stream(prompt, opts)
    end
  end

  @doc """
  Opens a pass-through session to the Codex CLI.

  This spawns an interactive `codex` session where raw commands
  are forwarded verbatim without parsing.

  ## Parameters

    * `command` - Raw command to forward to Codex CLI
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})

  ## Returns

    * `{:ok, port}` - Port handle for the interactive session
    * `{:error, Error.t()}` - Error occurred during spawn

  ## Examples

      {:ok, port} = CodexCLI.passthrough("--help")
  """
  @spec passthrough(String.t(), keyword()) :: {:ok, port()} | {:error, Error.t()}
  def passthrough(command, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Codex CLI not available",
         provider: :codex_cli,
         details: %{reason: :not_installed}
       )}
    else
      spawn_interactive_session(command, opts)
    end
  end

  ## Private Functions

  defp execute_prompt(prompt, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    args = build_args(prompt, opts)
    execution_id = Keyword.get(opts, :execution_id)

    case CLIPort.run(@codex_command, args, timeout, execution_id) do
      {:ok, output, 0} ->
        {:ok, build_response(IO.iodata_to_binary(output))}

      {:ok, output, exit_code} when is_integer(exit_code) ->
        {:error,
         Error.new(:provider_error,
           message: "Codex CLI exited with code #{exit_code}",
           provider: :codex_cli,
           details: %{exit_code: exit_code, output: IO.iodata_to_binary(output)}
         )}

      {:error, :timeout} ->
        {:error,
         Error.new(:timeout,
           message: "Codex CLI timed out after #{timeout}ms",
           provider: :codex_cli,
           details: %{timeout: timeout}
         )}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Codex CLI executable not found",
           provider: :codex_cli,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Codex CLI execution error: #{inspect(err)}",
           provider: :codex_cli,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp build_args(prompt, opts) do
    # Build arguments for codex CLI
    # The exact syntax depends on the actual Codex CLI implementation
    # Common patterns: codex "prompt" or codex -p "prompt"
    model = Keyword.get(opts, :model)

    args = [Messages.render_cli_prompt(prompt)]

    if model do
      ["--model", model | args]
    else
      args
    end
  end

  defp build_response(output) do
    Response.new(
      content: String.trim(output),
      provider: :codex_cli,
      model: "codex-cli",
      raw: %{output: output},
      metadata: %{
        executed_at: DateTime.utc_now()
      }
    )
  end

  defp create_stream(prompt, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    args = build_args(prompt, opts)
    execution_id = Keyword.get(opts, :execution_id)

    case CLIPort.stream(@codex_command, args, timeout, execution_id) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Codex CLI executable not found",
           provider: :codex_cli,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Codex CLI stream error: #{inspect(err)}",
           provider: :codex_cli,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp spawn_interactive_session(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    execution_id = Keyword.get(opts, :execution_id)

    try do
      args = String.split(command || "", " ", trim: true)

      case CLIPort.spawn(@codex_command, args, execution_id) do
        {:ok, port} ->
          Process.flag(:trap_exit, true)
          Port.monitor(port)
          {:ok, port}

        {:error, :not_found} ->
          {:error,
           Error.new(:provider_error,
             message: "Codex CLI not available",
             provider: :codex_cli,
             details: %{reason: :not_installed, timeout: timeout}
           )}

        {:error, err} ->
          {:error,
           Error.new(:provider_error,
             message: "Failed to spawn interactive Codex session",
             provider: :codex_cli,
             details: %{error: inspect(err), timeout: timeout}
           )}
      end
    rescue
      e ->
        {:error,
         Error.new(:provider_error,
           message: "Failed to spawn interactive Codex session",
           provider: :codex_cli,
           details: %{error: inspect(e), timeout: timeout}
         )}
    end
  end
end
