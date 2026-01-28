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
end
