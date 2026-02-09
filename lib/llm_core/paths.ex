defmodule LlmCore.Paths do
  @moduledoc """
  Cross-project path helpers for llm_core.

  The module centralizes how we resolve global and project-specific
  directories so consuming applications can
  override locations through environment variables without patching the
  library.
  """

  @doc """
  Returns the root directory for shared llm_core state.

  Precedence:
    * `LLM_CORE_HOME`
    * `DEVMAN_HOME` (legacy compatibility)
    * `~/.llm_core`
  """
  @spec global_home() :: String.t()
  def global_home do
    System.get_env("LLM_CORE_HOME") ||
      System.get_env("DEVMAN_HOME") ||
      Path.expand("~/.llm_core")
  end

  @doc """
  Returns the directory that stores global configuration files.
  """
  @spec global_config_dir() :: String.t()
  def global_config_dir do
    Path.join(global_home(), "config")
  end

  @doc """
  Returns the directory for global memory assets (cache, buffers, etc.).
  """
  @spec global_memory_dir() :: String.t()
  def global_memory_dir do
    Path.join(global_home(), "memory")
  end

  @doc """
  Returns the project configuration directory.

  Precedence:
    * `LLM_CORE_PROJECT_CONFIG`
    * `DEVMAN_CONFIG` (legacy compatibility)
    * `<project_root>/.llm_core`
  """
  @spec project_config_dir() :: String.t()
  def project_config_dir do
    System.get_env("LLM_CORE_PROJECT_CONFIG") ||
      System.get_env("DEVMAN_CONFIG") ||
      Path.join(project_root(), ".llm_core")
  end

  @doc """
  Returns the root of the current project workspace.

  Precedence:
    * `LLM_CORE_PROJECT_ROOT`
    * `File.cwd!/0`
  """
  @spec project_root() :: String.t()
  def project_root do
    System.get_env("LLM_CORE_PROJECT_ROOT") || File.cwd!()
  end

  @doc """
  Ensures the given directory exists.
  """
  @spec ensure_dir!(String.t()) :: :ok
  def ensure_dir!(path) do
    File.mkdir_p!(path)
    :ok
  end
end
