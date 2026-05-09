defmodule LlmCore.Config.LoaderCLITest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.Provider.Registry

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    :ok
  end

  describe "CLI provider loading from TOML" do
    test "loads a CLI provider with type=cli" do
      config_path = temp_path("cli_basic.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.echo_test]
      type = "cli"
      enabled = true
      aliases = ["echo", "echo-test"]

      [providers.echo_test.cli]
      binary = "echo"
      default_model = "echo-v1"
      prompt_position = "last"
      stdin_hack = false

      [providers.echo_test.cli.flags]
      model = "--model"

      [providers.echo_test.capabilities]
      streaming = true
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "echo_test")

      definition = providers["echo_test"]
      assert definition.provider_kind == :cli
      assert definition.type == :cli
      assert definition.module == nil
      assert definition.cli_config != nil
      assert definition.cli_config.binary == "echo"
      assert definition.cli_config.name == :echo_test
      assert definition.cli_config.default_model == "echo-v1"
      assert definition.cli_config.model_resolution == :gc_default
      assert definition.cli_config.flags == %{model: "--model"}
      assert definition.aliases == ["echo", "echo-test"]
      assert definition.available? == true
    end

    test "CLI provider with flagged prompt requires prompt_flag" do
      config_path = temp_path("cli_flagged.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.bad_flagged]
      type = "cli"
      enabled = true

      [providers.bad_flagged.cli]
      binary = "echo"
      prompt_position = "flagged"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      refute Map.has_key?(providers, "bad_flagged")
    end

    test "CLI provider with valid flagged prompt position" do
      config_path = temp_path("cli_flagged_ok.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.flagged_ok]
      type = "cli"
      enabled = true

      [providers.flagged_ok.cli]
      binary = "echo"
      prompt_position = "flagged"
      prompt_flag = "-p"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "flagged_ok")
      assert providers["flagged_ok"].cli_config.prompt_position == :flagged
      assert providers["flagged_ok"].cli_config.prompt_flag == "-p"
    end

    test "CLI provider rejects invalid enum values" do
      config_path = temp_path("cli_bad_enum.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.bad_enum]
      type = "cli"
      enabled = true

      [providers.bad_enum.cli]
      binary = "echo"
      output_mode = "xml"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      refute Map.has_key?(providers, "bad_enum")
    end

    test "CLI provider requires binary field" do
      config_path = temp_path("cli_no_binary.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.no_binary]
      type = "cli"
      enabled = true

      [providers.no_binary.cli]
      default_model = "v1"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      refute Map.has_key?(providers, "no_binary")
    end

    test "disabled CLI provider is marked unavailable" do
      config_path = temp_path("cli_disabled.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.disabled_cli]
      type = "cli"
      enabled = false

      [providers.disabled_cli.cli]
      binary = "echo"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "disabled_cli")
      refute providers["disabled_cli"].available?
      assert providers["disabled_cli"].availability == {:error, :disabled}
    end

    test "CLI provider with missing binary is marked unavailable" do
      config_path = temp_path("cli_missing_bin.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.missing_bin]
      type = "cli"
      enabled = true

      [providers.missing_bin.cli]
      binary = "nonexistent_binary_xyz_12345"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "missing_bin")
      refute providers["missing_bin"].available?
      assert providers["missing_bin"].availability == {:error, :binary_not_found}
    end

    test "CLI provider stores cli_config in config store" do
      config_path = temp_path("cli_store.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.store_test]
      type = "cli"
      enabled = true

      [providers.store_test.cli]
      binary = "echo"
      default_model = "stored-v1"
      """)

      assert {:ok, _} = Loader.reload_providers(path: config_path)

      assert {:ok, cli_configs} = Store.fetch(:config, :cli_providers)
      assert Map.has_key?(cli_configs, :store_test)
      assert cli_configs[:store_test].binary == "echo"
      assert cli_configs[:store_test].model_resolution == :gc_default
    end

    test "CLI and module providers coexist" do
      config_path = temp_path("cli_mixed.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.demo_api]
      module = "LlmCore.TestProviders.Basic"
      type = "local"
      enabled = true
      aliases = ["demo"]

      [providers.demo_cli]
      type = "cli"
      enabled = true
      aliases = ["my-cli"]

      [providers.demo_cli.cli]
      binary = "echo"
      default_model = "echo-v1"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "demo_api")
      assert Map.has_key?(providers, "demo_cli")
      assert providers["demo_api"].provider_kind == :module
      assert providers["demo_cli"].provider_kind == :cli
    end

    test "CLI provider with rich config" do
      config_path = temp_path("cli_rich.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.rich_cli]
      type = "cli"
      enabled = true
      aliases = ["rich", "rc"]
      default_model = "rich-v2"

      [providers.rich_cli.cli]
      binary = "echo"
      subcommand = "exec"
      default_timeout = 60000
      default_model = "rich-v1"
      prompt_position = "flagged"
      prompt_flag = "-p"
      prompt_transport = "flagged"
      system_prompt_transport = "file_flag"
      cwd_flag = "--cwd"
      add_dir_flag = "--add-dir"
      output_mode = "stdout_text"
      stdin_hack = true
      install_hint = "Install rich-cli"
      prefix_args = ["--print", "--no-interactive"]
      auto_approve_args = ["--auto"]
      sandbox_bypass_args = ["--yolo"]
      non_interactive_args = ["--batch"]

      [providers.rich_cli.cli.flags]
      model = "--model"
      cwd = "--cwd"
      add_dir = "--add-dir"
      system_prompt_file = "--agent-file"

      [providers.rich_cli.cli.preflight]
      help_args = ["--help"]
      expect_in_help = ["--model"]

      [providers.rich_cli.capabilities]
      streaming = true
      passthrough = true

      [providers.rich_cli.metadata]
      cost_tier = "cli"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "rich_cli")

      def = providers["rich_cli"]
      cfg = def.cli_config

      assert cfg.binary == "echo"
      assert cfg.subcommand == "exec"
      assert cfg.default_timeout == 60000
      assert cfg.prompt_position == :flagged
      assert cfg.prompt_flag == "-p"
      assert cfg.prompt_transport == :flagged
      assert cfg.system_prompt_transport == :file_flag
      assert cfg.cwd_flag == "--cwd"
      assert cfg.add_dir_flag == "--add-dir"
      assert cfg.output_mode == :stdout_text
      assert cfg.stdin_hack == true
      assert cfg.install_hint == "Install rich-cli"
      assert cfg.prefix_args == ["--print", "--no-interactive"]
      assert cfg.auto_approve_args == ["--auto"]
      assert cfg.sandbox_bypass_args == ["--yolo"]
      assert cfg.non_interactive_args == ["--batch"]
      assert cfg.flags[:model] == "--model"
      assert cfg.flags[:system_prompt_file] == "--agent-file"
      assert cfg.preflight == %{help_args: ["--help"], expect_in_help: ["--model"]}
      assert cfg.model_resolution == :gc_default

      # default_model from provider level overrides cli level
      assert def.default_model == "rich-v2"
      assert def.capabilities[:streaming] == true
      assert def.metadata["cost_tier"] == "cli"
    end

    test "provider_kind defaults to :module for non-CLI providers" do
      config_path = temp_path("cli_module_default.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.basic_mod]
      module = "LlmCore.TestProviders.Basic"
      type = "local"
      enabled = true
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert providers["basic_mod"].provider_kind == :module
      assert providers["basic_mod"].cli_config == nil
    end

    test "CLI provider rejects placeholder default_model values" do
      config_path = temp_path("cli_placeholder_default.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.kimi_cli]
      type = "cli"
      enabled = true

      [providers.kimi_cli.cli]
      binary = "echo"
      default_model = "kimi-cli"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      refute Map.has_key?(providers, "kimi_cli")
    end
  end

  describe "CLI provider contract extensions" do
    test "loads system_prompt_file_transform from TOML" do
      config_path = temp_path("cli_transform.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.transform_test]
      type = "cli"
      enabled = true

      [providers.transform_test.cli]
      binary = "echo"
      system_prompt_file_transform = "agent_spec_yaml"
      system_prompt_transport = "file_flag"

      [providers.transform_test.cli.flags]
      system_prompt_file = "--agent-file"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "transform_test")

      assert providers["transform_test"].cli_config.system_prompt_file_transform ==
               :agent_spec_yaml
    end

    test "rejects invalid system_prompt_file_transform" do
      config_path = temp_path("cli_bad_transform.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.bad_transform]
      type = "cli"
      enabled = true

      [providers.bad_transform.cli]
      binary = "echo"
      system_prompt_file_transform = "invalid_transform"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      refute Map.has_key?(providers, "bad_transform")
    end

    test "loads output_file_flag from TOML" do
      config_path = temp_path("cli_output_file.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.output_file_test]
      type = "cli"
      enabled = true

      [providers.output_file_test.cli]
      binary = "echo"
      output_file_flag = "--output-last-message"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "output_file_test")

      assert providers["output_file_test"].cli_config.output_file_flag ==
               "--output-last-message"
    end

    test "loads output_strip_patterns from TOML" do
      config_path = temp_path("cli_strip.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.strip_test]
      type = "cli"
      enabled = true

      [providers.strip_test.cli]
      binary = "echo"
      output_strip_patterns = ["^Session.*$", "^\\\\[INFO\\\\].*$"]
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "strip_test")
      assert length(providers["strip_test"].cli_config.output_strip_patterns) == 2
    end

    test "new fields default to nil/empty when not specified" do
      config_path = temp_path("cli_defaults.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.defaults_test]
      type = "cli"
      enabled = true

      [providers.defaults_test.cli]
      binary = "echo"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      cfg = providers["defaults_test"].cli_config
      assert cfg.system_prompt_file_transform == nil
      assert cfg.file_transform_defaults == %{}
      assert cfg.output_file_flag == nil
      assert cfg.output_strip_patterns == []
    end

    test "loads file_transform_defaults from TOML" do
      config_path = temp_path("cli_ftd.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.ftd_test]
      type = "cli"
      enabled = true

      [providers.ftd_test.cli]
      binary = "echo"
      system_prompt_file_transform = "agent_spec_yaml"

      [providers.ftd_test.cli.file_transform_defaults]
      version = 1
      extend = "default"
      name = "my-agent"
      """)

      assert {:ok, providers} = Loader.reload_providers(path: config_path)
      assert Map.has_key?(providers, "ftd_test")
      ftd = providers["ftd_test"].cli_config.file_transform_defaults
      assert ftd["version"] == 1
      assert ftd["extend"] == "default"
      assert ftd["name"] == "my-agent"
    end
  end

  describe "CLI provider visibility in Provider.Registry" do
    test "CLI providers appear in Provider.Registry.all/0" do
      config_path = temp_path("cli_registry.toml")
      on_exit(fn -> File.rm_rf(config_path) end)

      File.write!(config_path, """
      [providers.reg_cli]
      type = "cli"
      enabled = true
      aliases = ["reg-cli"]

      [providers.reg_cli.cli]
      binary = "echo"
      """)

      assert {:ok, _} = Loader.reload_providers(path: config_path)

      all = Registry.all()
      assert Map.has_key?(all, "reg_cli")
      assert all["reg_cli"].provider_kind == :cli
    end
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm_core_cli_test-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
