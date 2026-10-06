defmodule LlmCore.LLM.Native.ConfigTest do
  @moduledoc """
  llm_core ships no native cascade: it is configuration, read from the merged
  TOML layers, and with none configured the Native loop falls back to the
  routing default — or fails with a structured error. Never a silent pick.
  """
  use ExUnit.Case, async: false

  alias LlmCore.Config.{Loader, Store}
  alias LlmCore.LLM.Native
  alias LlmCore.LLM.Native.Config
  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Provider.Definition
  alias LlmCore.Router.RoutingTable

  @lib Path.join([__DIR__, "..", "..", "..", "..", "lib", "llm_core"])
  @bundled Path.join([__DIR__, "..", "..", "..", "..", "priv", "config", "llm_core.toml"])

  setup do
    unless Process.whereis(Store), do: start_supervised!(Store)

    saved_native = Application.get_env(:llm_core, :native)
    Application.delete_env(:llm_core, :native)
    Store.put(:config, :raw, %{})

    on_exit(fn ->
      case saved_native do
        nil -> Application.delete_env(:llm_core, :native)
        v -> Application.put_env(:llm_core, :native, v)
      end
    end)

    :ok
  end

  describe "Config.get/0" do
    test "is empty when nothing is configured — no shipped cascade, models or routing" do
      assert %{cascade: [], default_models: %{}, model_routing: []} = Config.get()
    end

    test "reads [native] from the merged layers' raw config" do
      Store.put(:config, :raw, %{
        "native" => %{
          "cascade" => ["a", "b"],
          "default_models" => %{"b" => "model-b"},
          "model_routing" => [%{"pattern" => "x", "provider" => "b"}]
        }
      })

      assert %{
               cascade: ["a", "b"],
               default_models: %{"b" => "model-b"},
               model_routing: [%{"pattern" => "x", "provider" => "b"}]
             } = Config.get()
    end

    test "explicit Elixir app env beats the layers" do
      Store.put(:config, :raw, %{"native" => %{"cascade" => ["from_layers"]}})
      Application.put_env(:llm_core, :native, %{cascade: ["from_env"]})

      assert %{cascade: ["from_env"]} = Config.get()
    end

    test "normalizes atom or string keys and drops malformed routing entries" do
      assert %{
               cascade: ["a"],
               default_models: %{"a" => "m"},
               model_routing: [%{"pattern" => "p", "provider" => "a"}]
             } =
               Config.normalize(%{
                 cascade: ["a"],
                 default_models: %{a: "m"},
                 model_routing: [
                   %{pattern: "p", provider: "a"},
                   %{"pattern" => "", "provider" => "a"},
                   %{"pattern" => "q"},
                   :junk
                 ]
               })
    end
  end

  describe "layers (project beats bundled, hot reload)" do
    setup do
      home = tmp_dir("home")
      project = tmp_dir("project")
      keys = ["LLM_CORE_HOME", "LLM_CORE_PROJECT_CONFIG", "LLM_CORE_CONFIG"]
      old = for k <- keys, do: {k, System.get_env(k)}
      System.put_env("LLM_CORE_HOME", home)
      System.put_env("LLM_CORE_PROJECT_CONFIG", project)
      System.delete_env("LLM_CORE_CONFIG")

      on_exit(fn ->
        MemoryConfig.clear_runtime_override()
        HindsightConfig.clear_runtime_override()

        Enum.each(old, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        File.rm_rf(home)
        File.rm_rf(project)
      end)

      {:ok, project: project}
    end

    test "the bundled base configures nothing, so layers supply the cascade", %{project: project} do
      {:ok, _} = Loader.reload_providers()
      assert %{cascade: []} = Config.get()

      File.write!(Path.join(project, "llm_core.toml"), """
      [native]
      cascade = ["mine"]

      [native.default_models]
      mine = "my-model"

      [[native.model_routing]]
      pattern = "foo"
      provider = "mine"
      """)

      {:ok, _} = Loader.reload_providers()

      assert %{
               cascade: ["mine"],
               default_models: %{"mine" => "my-model"},
               model_routing: [%{"pattern" => "foo", "provider" => "mine"}]
             } = Config.get()
    end
  end

  describe "Native.send resolution (no cascade configured)" do
    setup do
      cwd = tmp_dir("cwd")
      on_exit(fn -> File.rm_rf(cwd) end)

      Store.put(:config, :providers, %{
        "fake" => %Definition{
          id: "fake",
          module: LlmCore.TestProviders.Basic,
          aliases: ["fake"],
          default_model: "fake-model"
        },
        "a_cli" => %Definition{
          id: "a_cli",
          module: LlmCore.LLM.CLIProvider,
          provider_kind: :cli,
          aliases: ["a_cli"]
        }
      })

      {:ok, cwd: cwd}
    end

    test "falls back to the routing default as the only provider", %{cwd: cwd} do
      :ok = Store.put_routing(RoutingTable.new(%{"default" => "fake"}))

      assert {:ok, response} = Native.send("hello", cwd: cwd)
      assert response.metadata.model == "fake-model"
    end

    test "no routing default: a structured error says what to configure", %{cwd: cwd} do
      :ok = Store.put_routing(RoutingTable.new(%{}))

      assert {:error, %LlmCore.LLM.Error{message: message, details: details}} =
               Native.send("hello", cwd: cwd)

      assert details.reason == :no_routing_default
      assert message =~ "[native] cascade"
      assert message =~ "[routing] default"
    end

    test "a CLI routing default cannot run the native loop and says so", %{cwd: cwd} do
      :ok = Store.put_routing(RoutingTable.new(%{"default" => "a_cli"}))

      assert {:error, %LlmCore.LLM.Error{details: details, message: message}} =
               Native.send("hello", cwd: cwd)

      assert details.reason == :fallback_unusable
      assert details.skipped == [%{provider: "a_cli", reason: :not_native}]
      assert message =~ "a_cli (not_native)"
    end

    test "a configured cascade is used instead of the routing default", %{cwd: cwd} do
      :ok = Store.put_routing(RoutingTable.new(%{"default" => "a_cli"}))
      Application.put_env(:llm_core, :native, %{cascade: ["fake"]})

      assert {:ok, response} = Native.send("hello", cwd: cwd)
      assert response.metadata.model == "fake-model"
    end

    test "a configured but unusable cascade reports cascade_unusable", %{cwd: cwd} do
      :ok = Store.put_routing(RoutingTable.new(%{"default" => "fake"}))
      Application.put_env(:llm_core, :native, %{cascade: ["ghost"]})

      assert {:error, %LlmCore.LLM.Error{details: %{reason: :cascade_unusable}}} =
               Native.send("hello", cwd: cwd)
    end
  end

  describe "pins: nothing consumer-specific is shipped" do
    test "no provider or model literal in the native code paths" do
      for file <- ["llm/native.ex", "llm/native/router.ex", "llm/native/config.ex"] do
        source = File.read!(Path.join(@lib, file))
        refute source =~ "default_native_config", "#{file} still has a hardcoded default config"
        refute source =~ ~r/cascade:\s*\["/, "#{file} hardcodes a cascade"

        for literal <- ~w("anthropic" "zai" "appliance" "openai" claude-sonnet glm-5 qwen3) do
          refute source =~ literal, "#{file} hardcodes #{literal}"
        end
      end
    end

    test "the bundled base config sets no [native] values" do
      toml = File.read!(@bundled)

      refute toml =~ ~r/^\[native\]/m
      refute toml =~ ~r/^\[native\.default_models\]/m
      refute toml =~ ~r/^\[\[native\.model_routing\]\]/m
      refute toml =~ ~r/^cascade\s*=/m
    end
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "gc6030-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
