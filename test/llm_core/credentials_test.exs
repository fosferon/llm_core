defmodule LlmCore.CredentialsTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.Credentials
  alias LlmCore.LLM.{Anthropic, Native, OpenAI}
  alias LlmCore.LLM.Native.Router
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Provider.{Definition, Registry}

  # A host-side credential store: values live in an Agent, never in the OS environment.
  defmodule FakeStore do
    def fetch(name, agent), do: Agent.get(agent, &Map.get(&1, name))
  end

  setup do
    unless Process.whereis(Store), do: start_supervised!(Store)

    previous = Application.get_env(:llm_core, :key_resolver)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:llm_core, :key_resolver, previous),
        else: Application.delete_env(:llm_core, :key_resolver)
    end)

    :ok
  end

  defp use_store(values) do
    agent = start_supervised!({Agent, fn -> values end})
    Application.put_env(:llm_core, :key_resolver, {FakeStore, :fetch, [agent]})
  end

  # Runs `fun` with `names` absent from the OS environment, restoring them after.
  defp without_os_env(names, fun) do
    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "lookup/1" do
    test "defaults to the OS environment, as earlier releases did" do
      Application.delete_env(:llm_core, :key_resolver)
      System.put_env("LLM_CORE_CREDENTIALS_TEST_DEFAULT", "from-os")
      on_exit(fn -> System.delete_env("LLM_CORE_CREDENTIALS_TEST_DEFAULT") end)

      assert Credentials.lookup("LLM_CORE_CREDENTIALS_TEST_DEFAULT") == "from-os"
      assert Credentials.resolver() == {System, :get_env, []}
    end

    test "a configured resolver is used instead of the OS environment" do
      System.put_env("LLM_CORE_CREDENTIALS_TEST_BOTH", "from-os")
      on_exit(fn -> System.delete_env("LLM_CORE_CREDENTIALS_TEST_BOTH") end)
      use_store(%{"LLM_CORE_CREDENTIALS_TEST_BOTH" => "from-store"})

      assert Credentials.lookup("LLM_CORE_CREDENTIALS_TEST_BOTH") == "from-store"
    end

    test "a blank name, or a non-binary answer, is nil" do
      use_store(%{"NUMERIC" => 42})

      assert Credentials.lookup(nil) == nil
      assert Credentials.lookup("") == nil
      assert Credentials.lookup("NUMERIC") == nil
      assert Credentials.lookup("ABSENT") == nil
    end

    test "a malformed resolver configuration raises, naming the expected shape" do
      Application.put_env(:llm_core, :key_resolver, :not_an_mfa)
      assert_raise ArgumentError, ~r/key_resolver must be/, fn -> Credentials.lookup("ANY") end
    end
  end

  describe "every credential read goes through the resolver" do
    test "the native router passes the resolved key in the provider's options" do
      use_store(%{"LLM_CORE_CREDENTIALS_TEST_ROUTER" => "router-key"})

      without_os_env(["LLM_CORE_CREDENTIALS_TEST_ROUTER"], fn ->
        definition = %Definition{
          id: "keyed",
          module: OpenAI,
          aliases: ["keyed"],
          default_model: "m-keyed",
          auth: %{"api_key_env" => "LLM_CORE_CREDENTIALS_TEST_ROUTER", "api_key_present" => true}
        }

        Store.put(:config, :providers, %{"keyed" => definition})
        config = %{cascade: ["keyed"], default_models: %{}, model_routing: []}

        assert [{OpenAI, "m-keyed", opts}] = Router.candidates(nil, config)
        assert opts[:api_key] == "router-key"
      end)
    end

    test "the loader's presence check follows the resolver" do
      env = "LLM_CORE_CREDENTIALS_TEST_LOADER"

      path =
        Path.join(
          System.tmp_dir!(),
          "llm_core-credentials-#{System.unique_integer([:positive])}.toml"
        )

      File.write!(path, """
      [providers.storekeyed]
      module = "LlmCore.LLM.OpenAI"
      type = "cloud"
      enabled = true
      aliases = ["storekeyed"]

      [providers.storekeyed.auth]
      api_key_env = "#{env}"
      """)

      on_exit(fn -> File.rm_rf(path) end)

      without_os_env([env], fn ->
        Application.delete_env(:llm_core, :key_resolver)
        assert {:ok, _} = Loader.reload_providers(path: path)
        {:ok, before} = Registry.fetch("storekeyed")
        refute before.available?

        use_store(%{env => "loader-key"})
        assert {:ok, _} = Loader.reload_providers(path: path)
        {:ok, after_store} = Registry.fetch("storekeyed")
        assert after_store.available?
      end)
    end

    test "${VAR} interpolation in configuration still reads the OS environment, never the resolver" do
      env = "LLM_CORE_CREDENTIALS_TEST_INTERP"

      path =
        Path.join(System.tmp_dir!(), "llm_core-interp-#{System.unique_integer([:positive])}.toml")

      File.write!(path, """
      [providers.interp]
      module = "LlmCore.LLM.OpenAI"
      type = "cloud"
      enabled = true
      aliases = ["interp"]
      default_model = "${#{env}:fallback-model}"
      """)

      on_exit(fn -> File.rm_rf(path) end)

      without_os_env([env], fn ->
        use_store(%{env => "store-value"})
        assert {:ok, _} = Loader.reload_providers(path: path)
        {:ok, definition} = Registry.fetch("interp")
        assert definition.default_model == "fallback-model"
      end)
    end

    test "OpenAI's availability check uses the resolver" do
      previous = Application.get_env(:llm_core, :openai_api_key)
      Application.delete_env(:llm_core, :openai_api_key)

      on_exit(fn ->
        if previous, do: Application.put_env(:llm_core, :openai_api_key, previous)
      end)

      without_os_env(["OPENAI_API_KEY"], fn ->
        Application.delete_env(:llm_core, :key_resolver)
        refute OpenAI.available?()

        use_store(%{"OPENAI_API_KEY" => "openai-key"})
        assert OpenAI.available?()
      end)
    end

    test "Anthropic's key uses the resolver" do
      previous = Application.get_env(:llm_core, :anthropic_api_key)
      Application.delete_env(:llm_core, :anthropic_api_key)

      on_exit(fn ->
        if previous, do: Application.put_env(:llm_core, :anthropic_api_key, previous)
      end)

      without_os_env(["ANTHROPIC_API_KEY"], fn ->
        Application.delete_env(:llm_core, :key_resolver)
        refute Anthropic.available?()

        use_store(%{"ANTHROPIC_API_KEY" => "anthropic-key"})
        assert Anthropic.available?()
      end)
    end

    test "the Hindsight client's key uses the resolver" do
      env = HindsightConfig.effective_config().api_key_env

      without_os_env([env], fn ->
        use_store(%{env => "hindsight-key"})
        assert HindsightConfig.get_api_key() == "hindsight-key"
      end)
    end
  end

  describe "Native.send/2's tool executor" do
    test "a caller-supplied resolve_tool replaces the default executor" do
      executor = fn _call -> {:ok, "ran by the host"} end
      opts = Native.loop_options([], "/tmp", executor)

      assert opts[:resolve_tool] == executor
    end

    test "without one, the default executor runs the code tools in cwd" do
      opts = Native.loop_options([], "/tmp", nil)

      assert is_function(opts[:resolve_tool], 1)
      assert Keyword.has_key?(opts, :max_iterations)
    end
  end
end
