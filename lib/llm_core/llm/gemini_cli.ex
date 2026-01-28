defmodule LlmCore.LLM.GeminiCLI do
  @moduledoc """
  Gemini CLI provider implementing the Provider behaviour.

  This module provides integration with Google's Gemini CLI,
  supporting both direct prompting and pass-through mode for interactive sessions.

  ## Features

  - Execute prompts via `gemini` CLI command
  - Stream responses in real-time using Port-based output capture
  - Pass-through mode for raw CLI commands
  - Automatic availability detection via `which gemini`

  ## Usage

      # Check if Gemini CLI is available
      if GeminiCLI.available?() do
        # Send a prompt and get response
        {:ok, response} = GeminiCLI.send("Explain this code")

        # Stream response in real-time
        {:ok, stream} = GeminiCLI.stream("Write a story")
        Enum.each(stream, fn chunk -> IO.write(chunk) end)

        # Pass-through mode for raw CLI commands
        {:ok, port} = GeminiCLI.passthrough("--help")
      end

  ## Configuration

  The module respects the following options:
    * `:timeout` - Command timeout in milliseconds (default: 120_000)
    * `:model` - Model to use (passed to CLI if supported)

  ## Pattern Reference

  Follows the same patterns as ClaudeCode for consistency across CLI providers.
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, CLIPort, Messages}

  @default_timeout 120_000
  @gemini_command "gemini"

  ## Provider Behaviour Implementation

  @doc """
  Checks if the Gemini CLI is available on the system.

  Uses `which gemini` to detect CLI availability.

  ## Returns

    * `true` - Gemini CLI is installed and in PATH
    * `false` - Gemini CLI is not available

  ## Examples

      iex> GeminiCLI.available?()
      true
  """
  @impl true
  @spec available?() :: boolean()
  def available? do
    case System.find_executable(@gemini_command) do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Returns the provider's capabilities.

  ## Returns

    * `%{streaming: true, passthrough: true}` - Gemini CLI supports streaming and pass-through

  ## Examples

      iex> GeminiCLI.capabilities()
      %{streaming: true, passthrough: true}
  """
  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %{
      streaming: true,
      structured_output: false,
      tool_use: true,
      vision: true,
      models: ["gemini-cli"],
      max_context: nil,
      passthrough: true
    }
  end

  @doc """
  Returns the provider type.

  ## Returns

    * `:cli` - Gemini CLI is a CLI-based provider

  ## Examples

      iex> GeminiCLI.provider_type()
      :cli
  """
  @impl true
  @spec provider_type() :: :cli | :api | :local
  def provider_type, do: :cli

  @doc """
  Sends a prompt to Gemini CLI and returns the response.

  Uses `System.cmd/3` to execute the gemini command and captures the output.

  ## Parameters

    * `prompt` - The prompt string to send
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})
      * `:model` - Model to use (optional)

  ## Returns

    * `{:ok, Response.t()}` - Successful response with content
    * `{:error, Error.t()}` - Error occurred during execution

  ## Examples

      {:ok, response} = GeminiCLI.send("Explain recursion")
      response.content
      #=> "Recursion is a programming concept where..."
  """
  @impl true
  @spec send(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def send(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Gemini CLI not available. Install the Google Cloud CLI with Gemini support.",
         provider: :gemini_cli,
         details: %{reason: :not_installed}
       )}
    else
      execute_prompt(prompt, opts)
    end
  end

  @doc """
  Streams a response from Gemini CLI in real-time.

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

      {:ok, stream} = GeminiCLI.stream("Write a long story")
      Enum.each(stream, fn chunk -> IO.write(chunk) end)
  """
  @impl true
  @spec stream(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(prompt, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Gemini CLI not available",
         provider: :gemini_cli,
         details: %{reason: :not_installed}
       )}
    else
      create_stream(prompt, opts)
    end
  end

  @doc """
  Opens a pass-through session to the Gemini CLI.

  This spawns an interactive `gemini` session where raw commands
  are forwarded verbatim without parsing.

  ## Parameters

    * `command` - Raw command to forward to Gemini CLI
    * `opts` - Options including:
      * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})

  ## Returns

    * `{:ok, port}` - Port handle for the interactive session
    * `{:error, Error.t()}` - Error occurred during spawn

  ## Examples

      {:ok, port} = GeminiCLI.passthrough("--help")
  """
  @spec passthrough(String.t(), keyword()) :: {:ok, port()} | {:error, Error.t()}
  def passthrough(command, opts \\ []) do
    if not available?() do
      {:error,
       Error.new(:provider_error,
         message: "Gemini CLI not available",
         provider: :gemini_cli,
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

    case CLIPort.run(@gemini_command, args, timeout, execution_id) do
      {:ok, output, 0} ->
        {:ok, build_response(IO.iodata_to_binary(output))}

      {:ok, output, exit_code} when is_integer(exit_code) ->
        {:error,
         Error.new(:provider_error,
           message: "Gemini CLI exited with code #{exit_code}",
           provider: :gemini_cli,
           details: %{exit_code: exit_code, output: IO.iodata_to_binary(output)}
         )}

      {:error, :timeout} ->
        {:error,
         Error.new(:timeout,
           message: "Gemini CLI timed out after #{timeout}ms",
           provider: :gemini_cli,
           details: %{timeout: timeout}
         )}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Gemini CLI executable not found",
           provider: :gemini_cli,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Gemini CLI execution error: #{inspect(err)}",
           provider: :gemini_cli,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp build_args(prompt, opts) do
    # Build arguments for gemini CLI
    # The exact syntax depends on the actual Gemini CLI implementation
    # Common patterns: gemini "prompt" or gemini --prompt "prompt"
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
      provider: :gemini_cli,
      model: "gemini-cli",
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

    case CLIPort.stream(@gemini_command, args, timeout, execution_id) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, :not_found} ->
        {:error,
         Error.new(:provider_error,
           message: "Gemini CLI executable not found",
           provider: :gemini_cli,
           details: %{reason: :not_installed}
         )}

      {:error, err} ->
        {:error,
         Error.new(:provider_error,
           message: "Gemini CLI stream error: #{inspect(err)}",
           provider: :gemini_cli,
           details: %{error: inspect(err)}
         )}
    end
  end

  defp spawn_interactive_session(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    execution_id = Keyword.get(opts, :execution_id)

    try do
      args = String.split(command || "", " ", trim: true)

      case CLIPort.spawn(@gemini_command, args, execution_id) do
        {:ok, port} ->
          Process.flag(:trap_exit, true)
          Port.monitor(port)
          {:ok, port}

        {:error, :not_found} ->
          {:error,
           Error.new(:provider_error,
             message: "Gemini CLI not available",
             provider: :gemini_cli,
             details: %{reason: :not_installed, timeout: timeout}
           )}

        {:error, err} ->
          {:error,
           Error.new(:provider_error,
             message: "Failed to spawn interactive Gemini session",
             provider: :gemini_cli,
             details: %{error: inspect(err), timeout: timeout}
           )}
      end
    rescue
      e ->
        {:error,
         Error.new(:provider_error,
           message: "Failed to spawn interactive Gemini session",
           provider: :gemini_cli,
           details: %{error: inspect(e), timeout: timeout}
         )}
    end
  end
end
