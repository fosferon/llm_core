defmodule LlmCore.CLIProvider.RegistryTest do
  use ExUnit.Case, async: false

  alias LlmCore.CLIProvider.Registry
  alias LlmCore.Config.{Loader, Store}

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    # Load the default TOML config so CLI providers are available.
    # Since @builtins is empty, CLI providers come from priv/config/llm_core.toml.
    Loader.reload_providers([])

    :ok
  end

  describe "list/0" do
    test "returns built-in CLI providers" do
      entries = Registry.list()
      ids = Enum.map(entries, & &1.id)

      assert :claude_code in ids
      assert :droid in ids
      assert :pi_cli in ids
      assert :kimi_cli in ids
      assert :codex_cli in ids
      assert :gemini_cli in ids
    end

    test "includes runtime-configured CLI providers" do
      config_path = temp_path("reg_list.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.custom_cli]
      type = "cli"
      enabled = true
      aliases = ["custom"]

      [providers.custom_cli.cli]
      binary = "echo"
      default_model = "custom-v1"
      """)

      {:ok, _} = Loader.reload_providers(path: config_path)

      entries = Registry.list()
      ids = Enum.map(entries, & &1.id)

      assert :custom_cli in ids

      custom = Enum.find(entries, &(&1.id == :custom_cli))
      assert custom.binary == "echo"
      assert custom.default_model == "custom-v1"
      assert custom.model_resolution == :gc_default
    end

    test "entries have expected metadata fields" do
      entries = Registry.list()
      entry = Enum.find(entries, &(&1.id == :droid))

      assert is_boolean(entry.available?)
      assert is_binary(entry.binary)
      assert entry.model_resolution in [:gc_default, :provider_runtime, :explicit_only]
      assert is_map(entry.capabilities)
      assert is_boolean(entry.supports_auto_approve?)
      assert is_boolean(entry.supports_sandbox_bypass?)
      assert is_boolean(entry.supports_system_prompt_file?)
      assert is_boolean(entry.supports_cwd?)
      assert is_boolean(entry.supports_add_dir?)
      assert is_map(entry.metadata)
    end
  end

  describe "available/0" do
    test "filters to only providers with binary in PATH" do
      entries = Registry.available()

      Enum.each(entries, fn entry ->
        assert entry.available? == true
      end)
    end
  end

  describe "fetch/1" do
    test "fetches built-in by atom id" do
      assert {:ok, entry} = Registry.fetch(:claude_code)
      assert entry.id == :claude_code
      assert entry.binary == "claude"
    end

    test "fetches built-in by string id" do
      assert {:ok, entry} = Registry.fetch("droid")
      assert entry.id == :droid
    end

    test "returns error for unknown provider" do
      assert {:error, :not_found} = Registry.fetch(:nonexistent_xyz)
    end

    test "fetches runtime-configured provider" do
      config_path = temp_path("reg_fetch.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.fetch_test]
      type = "cli"
      enabled = true

      [providers.fetch_test.cli]
      binary = "echo"
      """)

      {:ok, _} = Loader.reload_providers(path: config_path)

      assert {:ok, entry} = Registry.fetch(:fetch_test)
      assert entry.id == :fetch_test
      assert entry.binary == "echo"
    end
  end

  describe "resolve/1" do
    test "resolves built-in to CLIProvider struct" do
      assert {:ok, %LlmCore.LLM.CLIProvider{} = provider} = Registry.resolve(:claude_code)
      assert provider.config.name == :claude_code
      assert provider.config.binary == "claude"
    end

    test "resolves string name" do
      assert {:ok, %LlmCore.LLM.CLIProvider{} = provider} = Registry.resolve("droid")
      assert provider.config.name == :droid
    end

    test "returns error for unknown" do
      assert {:error, :not_found} = Registry.resolve(:nonexistent_xyz)
    end
  end

  describe "capabilities/1" do
    test "returns capability map for known provider" do
      assert {:ok, caps} = Registry.capabilities(:codex_cli)
      assert is_map(caps)
      assert Map.has_key?(caps, :streaming)
      assert Map.has_key?(caps, :workspace)
      assert Map.has_key?(caps, :automation)
    end

    test "returns error for unknown" do
      assert {:error, :not_found} = Registry.capabilities(:nonexistent_xyz)
    end
  end

  describe "runtime override of builtins" do
    test "TOML-defined provider with same name overrides builtin" do
      config_path = temp_path("reg_override.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.gemini_cli]
      type = "cli"
      enabled = true
      aliases = ["gemini", "custom-gemini"]

      [providers.gemini_cli.cli]
      binary = "echo"
      default_model = "overridden-gemini"
      install_hint = "Custom install"
      prefix_args = ["--custom"]
      """)

      {:ok, _} = Loader.reload_providers(path: config_path)

      assert {:ok, entry} = Registry.fetch(:gemini_cli)
      assert entry.default_model == "overridden-gemini"
      assert entry.model_resolution == :gc_default
      assert entry.binary == "echo"

      assert {:ok, provider} = Registry.resolve(:gemini_cli)
      assert provider.config.default_model == "overridden-gemini"
      assert provider.config.prefix_args == ["--custom"]
    end
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm_core_cli_reg_test-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
