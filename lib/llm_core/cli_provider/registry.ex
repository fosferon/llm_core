defmodule LlmCore.CLIProvider.Registry do
  @moduledoc """
  Query surface for CLI-based LLM providers.

  Merges built-in CLI providers with TOML-configured ones, providing a
  single API for downstream apps to discover, inspect, and resolve CLI
  providers without hard-coding any provider list.

  ## Resolution Order

  1. TOML-configured CLI providers (from `Config.Store`) — override builtins
  2. Built-in providers (from `CLIProvider.@builtins`)

  ## Usage

      # List all known CLI providers
      CLIProvider.Registry.list()

      # Only those with the binary in PATH
      CLIProvider.Registry.available()

      # Fetch by id or alias
      {:ok, entry} = CLIProvider.Registry.fetch(:droid)
      {:ok, entry} = CLIProvider.Registry.fetch("pi")

      # Get a ready-to-use struct
      {:ok, provider} = CLIProvider.Registry.resolve(:droid)

      # Inspect capabilities
      caps = CLIProvider.Registry.capabilities(:droid)
  """

  alias LlmCore.LLM.CLIProvider
  alias LlmCore.LLM.CLIProvider.Config

  @type entry :: %{
          id: atom(),
          aliases: [String.t()],
          binary: String.t(),
          available?: boolean(),
          install_hint: String.t() | nil,
          default_model: String.t() | nil,
          model_resolution: :gc_default | :provider_runtime | :explicit_only,
          capabilities: map(),
          supports_auto_approve?: boolean(),
          supports_sandbox_bypass?: boolean(),
          supports_system_prompt_file?: boolean(),
          supports_cwd?: boolean(),
          supports_add_dir?: boolean(),
          metadata: map()
        }

  @doc """
  Returns all known CLI providers with metadata.
  Runtime-configured providers override builtins with the same name.
  """
  @spec list() :: [entry()]
  def list do
    CLIProvider.list_all_configs()
    |> Enum.map(fn {_name, config} -> build_entry(config) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Returns only CLI providers whose binary is found in PATH.
  """
  @spec available() :: [entry()]
  def available do
    list()
    |> Enum.filter(& &1.available?)
  end

  @doc """
  Fetches a CLI provider entry by id (atom or string) or alias.
  """
  @spec fetch(atom() | String.t()) :: {:ok, entry()} | {:error, :not_found}
  def fetch(name) do
    case CLIProvider.fetch_config(name) do
      {:ok, config} ->
        {:ok, build_entry(config)}

      {:error, :not_found} when is_binary(name) ->
        # Try alias resolution through provider definitions
        case CLIProvider.resolve_id(name) do
          {:ok, id} ->
            case CLIProvider.fetch_config(id) do
              {:ok, config} -> {:ok, build_entry(config)}
              error -> error
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Resolves a CLI provider into a ready-to-use `%CLIProvider{}` struct.
  """
  @spec resolve(atom() | String.t()) :: {:ok, CLIProvider.t()} | {:error, :not_found}
  def resolve(name) do
    CLIProvider.build_provider(name)
  end

  @doc """
  Returns the capability map for a CLI provider.
  """
  @spec capabilities(atom() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def capabilities(name) do
    case resolve(name) do
      {:ok, provider} -> {:ok, CLIProvider.capabilities(provider)}
      error -> error
    end
  end

  # ── Private ───────────────────────────────────────────────

  defp build_entry(%Config{} = config) do
    provider = %CLIProvider{config: config}

    %{
      id: config.name,
      aliases: build_aliases(config),
      binary: config.binary,
      available?: CLIProvider.available?(provider),
      install_hint: config.install_hint,
      default_model: config.default_model,
      model_resolution: config.model_resolution,
      capabilities: CLIProvider.capabilities(provider),
      supports_auto_approve?: config.auto_approve_args != [],
      supports_sandbox_bypass?: config.sandbox_bypass_args != [],
      supports_system_prompt_file?: has_flag?(config, :system_prompt_file),
      supports_cwd?: has_flag?(config, :cwd) or is_binary(config.cwd_flag),
      supports_add_dir?: has_flag?(config, :add_dir) or is_binary(config.add_dir_flag),
      metadata: build_metadata(config)
    }
  end

  defp build_aliases(%Config{name: name}) do
    # Check provider definitions for configured aliases
    case LlmCore.Config.Store.fetch(:config, :providers) do
      {:ok, providers} ->
        name_str = Atom.to_string(name)

        providers
        |> Enum.find(fn {_id, def} ->
          def.provider_kind == :cli and def.cli_config != nil and def.cli_config.name == name
        end)
        |> case do
          {_id, def} -> def.aliases
          nil -> [name_str]
        end

      _ ->
        [Atom.to_string(name)]
    end
  rescue
    ArgumentError -> [Atom.to_string(name)]
  end

  defp build_metadata(%Config{} = config) do
    %{
      subcommand: config.subcommand,
      stdin_hack: config.stdin_hack,
      prompt_position: config.prompt_position,
      output_mode: config.output_mode,
      default_timeout: config.default_timeout
    }
  end

  defp has_flag?(%Config{flags: flags}, key), do: is_binary(Map.get(flags, key))
end
