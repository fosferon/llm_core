defmodule LlmCore.LLM.ClaudeCode do
  @moduledoc """
  Claude Code CLI provider implementing the Provider behaviour.

  This module provides integration with Anthropic's Claude Code CLI,
  supporting both direct prompting and pass-through mode for interactive sessions.

  ## Features

  - Execute prompts via `claude --print -p "prompt"` command
  - Stream responses in real-time using Port-based output capture
  - Pass-through mode for raw CLI commands
  - Automatic availability detection via `which claude`

  ## Usage

      # Check if Claude CLI is available
      if ClaudeCode.available?() do
        # Send a prompt and get response
        {:ok, response} = ClaudeCode.send("Explain this code")

        # Stream response in real-time
        {:ok, stream} = ClaudeCode.stream("Write a story")
        Enum.each(stream, fn chunk -> IO.write(chunk) end)

        # Pass-through mode for raw CLI commands
        {:ok, port} = ClaudeCode.passthrough("/doctor")
      end

  ## Configuration

  The module respects the following options:
    * `:timeout` - Command timeout in milliseconds (default: 120_000)
    * `:model` - Model to use (passed to CLI if supported)

  ## Pattern Reference

  Follows the Provider behaviour pattern with standardized return types
  ({:ok, Response.t()} | {:error, Error.t()}) for all operations.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, CLIPort, Messages}

  @default_timeout 120_000
  @claude_command "claude"

  ## Provider Behaviour Implementation

  @doc """
  Checks if the Claude Code CLI is available on the system.

  Uses `which claude` to detect CLI availability.

  ## Returns

    * `true` - Claude CLI is installed and in PATH
    * `false` - Claude CLI is not available

  ## Examples

      iex> ClaudeCode.available?()
      true
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    case System.find_executable(@claude_command) do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Returns the provider's capabilities.

  ## Returns

    * `%{streaming: true, passthrough: true}` - Claude Code supports streaming and pass-through

  ## Examples

      iex> ClaudeCode.capabilities()
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
      models: ["claude-code-cli"],
      max_context: nil,
      passthrough: true
    }
  end

  @doc """
  Returns the provider type.

  ## Returns

    * `:cli` - Claude Code is a CLI-based provider

  ## Examples

      iex> ClaudeCode.provider_type()
      :cli
  """
  @impl true
  @spec provider_type() :: :cli | :api | :local
  def provider_type, do: :cli

  @doc """
  Sends a prompt to Claude Code CLI and returns the response.

  Uses `System.cmd/3` to execute `claude --print -p "prompt"` and
  captures the output.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})
      * `:model` - Model to use (optional)

  ## Returns

    * `{:ok, Response.t()}` - Successful response with content
    * `{:error, Error.t()}` - Error occurred during execution

  ## Examples

      {:ok, response} = ClaudeCode.send("Explain recursion")
      response.content
      #=> "Recursion is a programming concept where..."
  """
  @impl true
  @spec send(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def send(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Claude CLI not available. Install with: npm install -g @anthropic/claude-code",
         provider: :claude_code,
         details: %{reason: :not_installed}
       )}
    else
      execute_prompt(prompt, opts)
    end
  end

  @doc """
  Streams a response from Claude Code CLI in real-time.

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

      {:ok, stream} = ClaudeCode.stream("Write a long story")
      Enum.each(stream, fn chunk -> IO.write(chunk) end)
  """
  @impl true
  @spec stream(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Claude CLI not available",
         provider: :claude_code,
         details: %{reason: :not_installed}
       )}
    else
      create_stream(prompt, opts)
    end
  end

  @doc """
  Opens a pass-through session to the Claude CLI.

  This spawns an interactive `claude` session where raw commands
  are forwarded verbatim without parsing. Used for native CLI features
  like `/doctor`, `/config`, etc.

  ## Parameters

    * `command` - Raw command to forward to Claude CLI
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})

  ## Returns

    * `{:ok, port}` - Port handle for the interactive session
    * `{:error, Error.t()}` - Error occurred during spawn

  ## Examples

      {:ok, port} = ClaudeCode.passthrough("/doctor")
      # Interact with the port directly
  """
  @spec passthrough(String.t(), keyword()) :: {:ok, port()} | {:error, Error.t()}
  def passthrough(command, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Claude CLI not available",
         provider: :claude_code,
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

    case CLIPort.run(@claude_command, args, timeout, execution_id) do
      {:ok, output, 0} ->
        {:ok, build_response(IO.iodata_to_binary(output))}

      {:ok, output, exit_code} when is_integer(exit_code) ->
        {:error,
         Error.new(:provider_error,
           message: "Claude CLI exited with code #{exit_code}",
           provider: :claude_code,
           details: %{exit_code: exit_code, output: IO.iodata_to_binary(output)}
         )}

      {:error, :timeout} ->
        {:error,
         Error.new(:timeout,
           message: "Claude CLI timed out after #{timeout}ms",
           provider: :claude_code,
           details: %{timeout: timeout}
         )}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Claude CLI executable not found",
           provider: :claude_code,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Claude CLI execution error: #{inspect(err)}",
           provider: :claude_code,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp build_args(prompt, _opts) do
    ["--print", "-p", Messages.render_cli_prompt(prompt)]
  end

  defp build_response(output) do
    Response.new(
      content: String.trim(output),
      provider: :claude_code,
      model: "claude-code-cli",
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

    case CLIPort.stream(@claude_command, args, timeout, execution_id) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Claude CLI executable not found",
           provider: :claude_code,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Claude CLI stream error: #{inspect(err)}",
           provider: :claude_code,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp spawn_interactive_session(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    execution_id = Keyword.get(opts, :execution_id)

    try do
      args =
        if String.starts_with?(command, "/") do
          [command]
        else
          []
        end

      case CLIPort.spawn(@claude_command, args, execution_id) do
        {:ok, port} ->
          Process.flag(:trap_exit, true)
          Port.monitor(port)
          {:ok, port}

        {:error, :not_found} ->
          {:error,
           Error.new(:provider_error,
             message: "Claude CLI not available",
             provider: :claude_code,
             details: %{reason: :not_installed, timeout: timeout}
           )}

        {:error, err} ->
          {:error,
           Error.new(:provider_error,
             message: "Failed to spawn interactive Claude session",
             provider: :claude_code,
             details: %{error: inspect(err), timeout: timeout}
           )}
      end
    rescue
      e ->
        {:error,
         Error.new(:provider_error,
           message: "Failed to spawn interactive Claude session",
           provider: :claude_code,
           details: %{error: inspect(e), timeout: timeout}
         )}
    end
  end
end
