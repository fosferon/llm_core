defmodule LlmCore.Config.LoaderTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.Loader
  alias LlmCore.Config.Store
  alias LlmCore.Memory.Config, as: MemoryConfig
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
      MemoryConfig.clear_runtime_override()
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

  test "memory backend selection applies per-backend HTTP options" do
    config_path = temp_path("llm_core-memory-backend.toml")

    File.write!(
      config_path,
      [
        "[memory]",
        "backend = \"foresight_http\"",
        "",
        "[memory.foresight_http]",
        "url = \"http://foresight.test:4100\"",
        "default_bank_id = \"foresight-bank\""
      ]
      |> Enum.join("\n")
    )

    on_exit(fn -> File.rm_rf(config_path) end)

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    assert MemoryConfig.backend() == :foresight_http
    assert HindsightConfig.effective_url() == "http://foresight.test:4100"
    assert HindsightConfig.effective_bank_id() == "foresight-bank"
  end

  test "Foresight HTTP uses its default port when URL is omitted" do
    config_path = temp_path("llm_core-memory-default-url.toml")

    File.write!(
      config_path,
      [
        "[memory]",
        "backend = \"foresight_http\"",
        "",
        "[memory.foresight_http]",
        "default_bank_id = \"default\""
      ]
      |> Enum.join("\n")
    )

    on_exit(fn -> File.rm_rf(config_path) end)

    assert {:ok, _} = Loader.reload_providers(path: config_path)
    assert HindsightConfig.effective_url() == "http://localhost:4012"
  end

  test "invalid memory backend is rejected instead of falling back" do
    config_path = temp_path("llm_core-memory-invalid-backend.toml")

    File.write!(
      config_path,
      [
        "[memory]",
        "backend = \"foresight_htp\""
      ]
      |> Enum.join("\n")
    )

    on_exit(fn -> File.rm_rf(config_path) end)

    assert {:error, {:invalid_memory_backend, "foresight_htp"}} =
             Loader.reload_providers(path: config_path)
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

  describe "GC-758 regression: reload_routing must not clobber TOML-configured routing" do
    test "reload_routing preserves routing loaded from TOML when routing.yml is missing" do
      # Simulate the Application.start/2 sequence: reload_providers (which parses
      # TOML [routing.tasks.*] and writes to Store) is called first, then
      # reload_routing is called. If routing.yml is missing (as it is for any
      # TOML-only consumer), reload_routing must NOT overwrite the Store with
      # the "default => claude" fallback.
      config_path = temp_path("llm_core-gc758-routing.toml")

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
          "[routing.tasks.help_draft]",
          "alias = \"example\"",
          "mode = \"passthrough\""
        ]
        |> Enum.join("\n")
      )

      on_exit(fn -> File.rm_rf(config_path) end)

      # Step 1: reload_providers parses TOML routing and writes it to Store.
      assert {:ok, _} = Loader.reload_providers(path: config_path)
      {:ok, routing_after_providers} = Store.get_routing()
      assert routing_after_providers.default.alias == "example"
      assert routing_after_providers.rules["help_draft"].alias == "example"
      assert routing_after_providers.rules["help_draft"].mode == :passthrough

      # Step 2: reload_routing with a missing YAML file must leave the
      # TOML-configured routing table intact.
      missing_yml = temp_path("missing-gc758.yml")
      assert {:ok, _} = Loader.reload_routing(path: missing_yml)

      {:ok, routing_after_reload} = Store.get_routing()

      assert routing_after_reload.default.alias == "example",
             "reload_routing clobbered TOML default routing with fallback (GC-758 Bug 1)"

      assert Map.has_key?(routing_after_reload.rules, "help_draft"),
             "reload_routing erased TOML-configured task routing rules (GC-758 Bug 1)"

      assert routing_after_reload.rules["help_draft"].alias == "example"
      assert routing_after_reload.rules["help_draft"].mode == :passthrough
    end

    test "reload_routing still installs fallback when Store has no routing at all" do
      # Edge case: if nothing has written routing to the Store yet (no TOML
      # with [routing], no prior load), reload_routing with a missing YAML
      # should still install the safe default so the Router has something
      # to resolve against.
      :ets.delete(:llm_core_config, {:config, :routing})

      missing_yml = temp_path("missing-gc758-fallback.yml")
      assert {:ok, %RoutingTable{} = table} = Loader.reload_routing(path: missing_yml)
      assert table.default.alias == "claude"
      assert {:ok, ^table} = Store.get_routing()
    end
  end

  describe "GC-758 regression: base llm_core.toml must be accessible at runtime" do
    test "load_config loads providers defined in the library's bundled base TOML" do
      # The library ships config/llm_core.toml with sensible defaults for
      # anthropic/openai/ollama. Prior to GC-758 Bug 2, default_config_path/0
      # resolved to `_build/<env>/lib/llm_core/config/llm_core.toml`, a path
      # that Mix does not populate, so the bundled defaults were never loaded.
      #
      # We isolate from any project/global config by pointing LLM_CORE_PROJECT_ROOT
      # and LLM_CORE_HOME at an empty tmp dir, then assert load_config still
      # returns the base providers.
      tmp_root = temp_dir("llm_core_gc758_isolated_root")
      tmp_home = temp_dir("llm_core_gc758_isolated_home")

      prev_env = %{
        "LLM_CORE_CONFIG" => System.get_env("LLM_CORE_CONFIG"),
        "LLM_CORE_PROJECT_ROOT" => System.get_env("LLM_CORE_PROJECT_ROOT"),
        "LLM_CORE_PROJECT_CONFIG" => System.get_env("LLM_CORE_PROJECT_CONFIG"),
        "LLM_CORE_HOME" => System.get_env("LLM_CORE_HOME"),
        "DEVMAN_CONFIG" => System.get_env("DEVMAN_CONFIG"),
        "DEVMAN_HOME" => System.get_env("DEVMAN_HOME")
      }

      System.delete_env("LLM_CORE_CONFIG")
      System.delete_env("LLM_CORE_PROJECT_CONFIG")
      System.delete_env("DEVMAN_CONFIG")
      System.delete_env("DEVMAN_HOME")
      System.put_env("LLM_CORE_PROJECT_ROOT", tmp_root)
      System.put_env("LLM_CORE_HOME", tmp_home)

      on_exit(fn ->
        File.rm_rf(tmp_root)
        File.rm_rf(tmp_home)

        Enum.each(prev_env, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      {:ok, config} = Loader.load_config([])

      providers = Map.get(config, "providers", %{})

      assert Map.has_key?(providers, "anthropic"),
             "bundled base config did not load — anthropic provider missing (GC-758 Bug 2)"

      assert get_in(providers, ["anthropic", "module"]) == "LlmCore.LLM.Anthropic"
      assert get_in(providers, ["openai", "module"]) == "LlmCore.LLM.OpenAI"
      assert get_in(providers, ["ollama", "module"]) == "LlmCore.LLM.Ollama"
    end
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "llm_core_test-#{name}-#{System.unique_integer([:positive])}")
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
