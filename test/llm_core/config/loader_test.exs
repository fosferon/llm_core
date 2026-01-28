defmodule LlmCore.Config.LoaderTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.Loader
  alias LlmCore.Config.Store
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Router.RoutingTable
  alias LlmCore.Provider.Registry
  alias LlmCore.Telemetry.Settings, as: TelemetrySettings

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    TelemetrySettings.apply(%{})

    on_exit(fn ->
      HindsightConfig.clear_runtime_override()
    end)

    :ok
  end

  test "load_routing returns error when file missing" do
    assert {:error, :not_found} = Loader.load_routing(path: temp_path("missing.yml"))
  end

  test "reload_routing stores fallback when file missing" do
    assert {:ok, %RoutingTable{} = table} = Loader.reload_routing(path: temp_path("missing.yml"))
    assert %RoutingTable{} = table
    assert {:ok, ^table} = Store.get_routing()
  end

  test "load_routing parses yaml file" do
    path = temp_path("routing.yml")
    on_exit(fn -> File.rm_rf(path) end)

    File.write!(path, """
    default: claude
    coding:
      alias: openai
      mode: passthrough
    """)

    assert {:ok, %RoutingTable{} = table} = Loader.load_routing(path: path)
    assert table.default.alias == "claude"
    assert table.rules["coding"].alias == "openai"
  end

  test "reload_providers merges toml config and tracks availability" do
    config_path = temp_path("llm_core.toml")

    File.write!(
      config_path,
      [
        "[providers.demo]",
        "module = \"LlmCore.TestProviders.Basic\"",
        "type = \"local\"",
        "enabled = true",
        "default_model = \"llama3\"",
        "aliases = [\"demo\"]",
        "",
        "[providers.demo.agent]",
        "name = \"demo\"",
        "config = {model = \"llama3\"}",
        "",
        "[providers.secure]",
        "module = \"LlmCore.LLM.OpenAI\"",
        "type = \"cloud\"",
        "enabled = true",
        "default_model = \"gpt-4o\"",
        "aliases = [\"secure\"]",
        "",
        "[providers.secure.auth]",
        "api_key_env = \"TMP_PROVIDER_KEY\""
      ]
      |> Enum.join("\n")
    )

    System.put_env("LLM_CORE_CONFIG", config_path)

    on_exit(fn ->
      System.delete_env("LLM_CORE_CONFIG")
      System.delete_env("TMP_PROVIDER_KEY")
      File.rm_rf(config_path)
    end)

    assert {:ok, providers} = Loader.reload_providers()
    assert Map.has_key?(providers, "demo")

    {:ok, demo} = Registry.fetch("demo")
    assert demo.available?
    assert demo.agent_config[:model] == "llama3"

    {:ok, secure} = Registry.fetch("secure")
    refute secure.available?

    System.put_env("TMP_PROVIDER_KEY", "secret-token")
    assert {:ok, _} = Loader.reload_providers()
    {:ok, secure_after} = Registry.fetch("secure")
    assert secure_after.available?
  end

  test "reload_providers auto-discovers api key envs from aliases" do
    env_name = "LLM_CORE_DISCOVER_API_KEY"
    System.put_env(env_name, "secret")
    config_path = temp_path("llm_core-auto.toml")

    File.write!(
      config_path,
      [
        "[providers.discover]",
        "module = \"LlmCore.LLM.OpenAI\"",
        "type = \"cloud\"",
        "enabled = true",
        "aliases = [\"discover\"]"
      ]
      |> Enum.join("\n")
    )

    on_exit(fn ->
      System.delete_env(env_name)
      File.rm_rf(config_path)
    end)

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    {:ok, definition} = Registry.fetch("discover")

    assert definition.auth["api_key_env"] == env_name
    assert definition.auth["source"] == {:discovered_env, env_name}
    assert definition.available?
  end

  test "reload_providers applies routing and memory sections" do
    config_path = temp_path("llm_core-routing.toml")

    File.write!(
      config_path,
      [
        "[providers.example]",
        "module = \"LlmCore.LLM.Ollama\"",
        "type = \"local\"",
        "enabled = false",
        "aliases = [\"example\"]",
        "",
        "[routing]",
        "default = \"example\"",
        "",
        "[routing.tasks.coding]",
        "alias = \"example\"",
        "mode = \"passthrough\"",
        "capabilities = { structured_output = true }",
        "",
        "[memory.hindsight]",
        "default_bank_id = \"bank-toml\"",
        "timeout_recall_ms = 1234"
      ]
      |> Enum.join("\n")
    )

    System.put_env("LLM_CORE_CONFIG", config_path)

    on_exit(fn ->
      System.delete_env("LLM_CORE_CONFIG")
      File.rm_rf(config_path)
    end)

    assert {:ok, _} = Loader.reload_providers()

    {:ok, routing_table} = Store.get_routing()
    assert routing_table.default.alias == "example"
    assert routing_table.rules["coding"].mode == :passthrough
    assert routing_table.rules["coding"].capabilities[:structured_output]

    config = HindsightConfig.effective_config()
    assert config.default_bank_id == "bank-toml"
    assert config.timeout_recall_ms == 1234
  end

  test "memory overrides refresh after reload" do
    config_path = temp_path("llm_core-memory.toml")

    File.write!(
      config_path,
      [
        "[memory.hindsight]",
        "default_bank_id = \"first-bank\"",
        "cache_ttl_ms = 5000"
      ]
      |> Enum.join("\n")
    )

    on_exit(fn -> File.rm_rf(config_path) end)

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    assert HindsightConfig.effective_config().default_bank_id == "first-bank"

    File.write!(
      config_path,
      [
        "[memory.hindsight]",
        "default_bank_id = \"second-bank\"",
        "cache_ttl_ms = 9000"
      ]
      |> Enum.join("\n")
    )

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    config = HindsightConfig.effective_config()
    assert config.default_bank_id == "second-bank"
    assert config.cache_ttl_ms == 9000
  end

  test "telemetry config persists into settings" do
    config_path = temp_path("llm_core-telemetry.toml")

    File.write!(
      config_path,
      [
        "[telemetry]",
        "log_pipeline_events = false",
        "log_provider_dispatch = true",
        "sample_rate = 0.25",
        "enable_logger = false"
      ]
      |> Enum.join("\n")
    )

    on_exit(fn -> File.rm_rf(config_path) end)

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    {:ok, telemetry} = Store.fetch(:config, :telemetry)
    assert telemetry["sample_rate"] == 0.25

    settings = TelemetrySettings.current()
    assert settings.sample_rate == 0.25
    refute settings.log_pipeline_events
    assert settings.log_provider_dispatch
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "llm_core_test-#{name}-#{System.unique_integer([:positive])}")
  end
end
