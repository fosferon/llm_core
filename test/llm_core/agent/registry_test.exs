defmodule LlmCore.Agent.RegistryTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent.Registry
  alias LlmCore.Config.{Loader, Store}

  @config_path Path.join(System.tmp_dir!(), "llm_core_registry_test.toml")

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    {:ok, _pid} = Registry.start_link(name: :registry_test, auto_discover: false)

    on_exit(fn ->
      System.delete_env("LLM_CORE_CONFIG")
      File.rm_rf(@config_path)
    end)

    :ok
  end

  test "sync_with_providers registers agents from TOML config" do
    File.write!(
      @config_path,
      [
        "[providers.auto]",
        "module = \"LlmCore.LLM.Ollama\"",
        "type = \"local\"",
        "enabled = true",
        "default_model = \"llama3\"",
        "aliases = [\"auto\", \"helper\"]",
        "",
        "[providers.auto.agent]",
        "name = \"auto\"",
        "config = {model = \"llama3\"}"
      ]
      |> Enum.join("\n")
    )

    System.put_env("LLM_CORE_CONFIG", @config_path)

    assert {:ok, _} = Loader.reload_providers()
    :ok = Registry.sync_with_providers(:registry_test)
    :sys.get_state(:registry_test)

    assert {:ok, agent} = Registry.get(:registry_test, "auto")
    assert agent.provider == LlmCore.LLM.Ollama
    assert agent.config[:model] == "llama3"

    assert {:ok, helper_agent} = Registry.get(:registry_test, "helper")
    assert helper_agent.provider == LlmCore.LLM.Ollama
  end

  describe "GC-760 regression: agent.config wins over provider.options on key collision" do
    test "agent.config fields override provider.options fields with the same key" do
      # Ensure the target atom exists at runtime so normalize_agent_config can
      # convert the string-keyed options entry. `:base_url` is used throughout
      # llm_core so this is effectively a no-op in practice, but we do it
      # explicitly to keep the test self-contained.
      _ = :base_url

      File.write!(
        @config_path,
        [
          "[providers.collision]",
          "module = \"LlmCore.LLM.Ollama\"",
          "type = \"local\"",
          "enabled = true",
          "default_model = \"llama3\"",
          "aliases = [\"collision\"]",
          "",
          "[providers.collision.options]",
          "base_url = \"http://base.example.com\"",
          "",
          "[providers.collision.agent]",
          "name = \"collision\"",
          "config = { base_url = \"http://override.example.com\", model = \"qwen2.5-coder:32b\" }"
        ]
        |> Enum.join("\n")
      )

      System.put_env("LLM_CORE_CONFIG", @config_path)

      assert {:ok, _} = Loader.reload_providers()
      :ok = Registry.sync_with_providers(:registry_test)
      :sys.get_state(:registry_test)

      assert {:ok, agent} = Registry.get(:registry_test, "collision")

      assert agent.config[:base_url] == "http://override.example.com",
             "agent.config.base_url (project override) was clobbered by provider.options.base_url (GC-760)"

      assert agent.config[:model] == "qwen2.5-coder:32b",
             "agent.config.model override did not survive (GC-760)"

      # And there must be no stray string-keyed entry for the same logical key.
      refute Map.has_key?(agent.config, "base_url"),
             "merged agent config still contains a string-keyed 'base_url' alongside the atom key (GC-760)"
    end
  end
end
