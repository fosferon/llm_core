defmodule LlmCore.PathsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LlmCore.Paths

  setup do
    :persistent_term.erase({Paths, :legacy_env_warned})

    keys = ["LLM_CORE_HOME", "LLM_CORE_PROJECT_CONFIG", "DEVMAN_HOME", "DEVMAN_CONFIG"]
    saved = for key <- keys, do: {key, System.get_env(key)}
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      :persistent_term.erase({Paths, :legacy_env_warned})

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "DEVMAN_HOME still resolves and warns once per VM" do
    System.put_env("DEVMAN_HOME", "/tmp/legacy-home")

    log = capture_log(fn -> assert Paths.global_home() == "/tmp/legacy-home" end)
    assert log =~ "DEVMAN_HOME is deprecated"

    second_log = capture_log(fn -> assert Paths.global_home() == "/tmp/legacy-home" end)
    refute second_log =~ "deprecated"
  end

  test "DEVMAN_CONFIG still resolves and warns" do
    System.put_env("DEVMAN_CONFIG", "/tmp/legacy-config")

    log = capture_log(fn -> assert Paths.project_config_dir() == "/tmp/legacy-config" end)
    assert log =~ "DEVMAN_CONFIG is deprecated"
  end
end
