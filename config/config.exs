import Config

if config_env() == :test do
  # Keep the suite hermetic: never read the developer's real ~/.llm_core or
  # project config. The project layer is created by the watcher on boot.
  test_root = Path.expand("../tmp/test_isolation", __DIR__)
  File.rm_rf!(test_root)
  File.mkdir_p!(Path.join(test_root, "home"))
  File.mkdir_p!(Path.join(test_root, "project"))

  System.put_env("LLM_CORE_HOME", Path.join(test_root, "home"))
  System.put_env("LLM_CORE_PROJECT_ROOT", Path.join(test_root, "project"))
  System.delete_env("LLM_CORE_CONFIG")
  System.delete_env("LLM_CORE_PROJECT_CONFIG")
  System.delete_env("DEVMAN_HOME")
  System.delete_env("DEVMAN_CONFIG")

  # Do not probe a developer's local Hindsight server during tests.
  System.put_env("HINDSIGHT_URL", "http://127.0.0.1:1")
  System.put_env("HINDSIGHT_DEFAULT_BANK", "test-bank")

  # ALF normally defaults to a 10 s wait. Tests lower it so a slow sub-call
  # can prove that DispatchTools passes an explicit per-call timeout.
  config :alf, default_timeout: 150
end
