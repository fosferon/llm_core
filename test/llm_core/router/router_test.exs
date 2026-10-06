defmodule LlmCore.Router.SafeDefaultTest do
  @moduledoc """
  The routing default is configuration, never code.

  When no layer (project, home, bundled base) supplies `[routing] default`,
  resolution fails loudly with `{:error, {:no_routing_default, meta}}` and an
  unconditional `[:llm_core, :routing, :error]` telemetry event. Silently
  routing to an arbitrary provider hides misconfiguration for hours.
  """
  use ExUnit.Case, async: false

  alias LlmCore.Config.Loader
  alias LlmCore.Config.Store
  alias LlmCore.Memory.Config, as: MemoryConfig
  alias LlmCore.Memory.Hindsight.Config, as: HindsightConfig
  alias LlmCore.Pipelines.{InferencePipeline, RoutingPipeline}
  alias LlmCore.Router.RoutingTable

  @lib Path.join([__DIR__, "..", "..", "..", "lib", "llm_core"])

  setup do
    unless Process.whereis(Store), do: start_supervised!(Store)
    :ok
  end

  describe "table without a default" do
    test "RoutingTable.new/1 has no default unless config supplies one" do
      assert %RoutingTable{default: nil} = RoutingTable.new(%{})
      assert %RoutingTable{default: nil} = RoutingTable.new(%{"default" => nil})
      assert RoutingTable.new(%{"default" => "example"}).default.alias == "example"
    end

    test "unmatched task with no default fails loudly" do
      table = RoutingTable.new(%{})

      assert {:error, {:no_routing_default, %{task_type: "coding", table_source: :provided}}} =
               RoutingPipeline.route("coding", routing_table: table)
    end

    test "emits [:llm_core, :routing, :error] with the caller_ref, bypassing sampling" do
      ref = make_ref()
      id = "gc6006-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:llm_core, :routing, :error],
        fn _event, measurements, meta, pid -> send(pid, {:routing_error, measurements, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, {:no_routing_default, _}} =
               RoutingPipeline.route("coding",
                 routing_table: RoutingTable.new(%{}),
                 caller_ref: ref
               )

      assert_receive {:routing_error, %{}, meta}
      assert meta.reason == :no_routing_default
      assert meta.task_type == "coding"
      assert meta.caller_ref == ref
      assert %{table_source: :provided} = meta.detail
    end
  end

  describe "caller_ref on the inference path" do
    test "send/stream forward :caller_ref so the routing error is correlatable" do
      ref = make_ref()
      id = "gc6006-inference-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:llm_core, :routing, :error],
        fn _event, _m, meta, pid -> send(pid, {:routing_error, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, {:no_routing_default, _}} =
               InferencePipeline.execute(:send, "hi", "coding",
                 routing_table: RoutingTable.new(%{}),
                 caller_ref: ref
               )

      assert_receive {:routing_error, %{caller_ref: ^ref}}
    end
  end

  describe "layer precedence (no default anywhere => loud failure)" do
    setup do
      home = tmp_dir("home")
      project = tmp_dir("project")

      old =
        for k <- ["LLM_CORE_HOME", "LLM_CORE_PROJECT_CONFIG", "LLM_CORE_CONFIG"],
            do: {k, System.get_env(k)}

      System.put_env("LLM_CORE_HOME", home)
      System.put_env("LLM_CORE_PROJECT_CONFIG", project)
      System.delete_env("LLM_CORE_CONFIG")

      on_exit(fn ->
        # reload_providers (via the validate task) applies memory config;
        # clear it so later tests don't inherit the isolated layers.
        MemoryConfig.clear_runtime_override()
        HindsightConfig.clear_runtime_override()

        Enum.each(old, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        File.rm_rf(home)
        File.rm_rf(project)
      end)

      {:ok, home: home, project: project}
    end

    test "the bundled base ships no routing default" do
      assert {:ok, config} = Loader.load_config(path: nil)
      refute get_in(config, ["routing", "default"])
    end

    test "mix llm_core.config.validate reports a missing default instead of crashing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.LlmCore.Config.Validate.run([])
        end)

      assert output =~ "Routing default: (none"
    end

    test "a routing.yml without a default keeps the layered default, explicit rules win",
         %{project: project} do
      write_layer(project, ~s|[routing]\ndefault = "layered"\n|)
      yml = Path.join(project, "routing.yml")
      File.write!(yml, "coding: yml_coder\n")
      :ets.delete(:llm_core_config, {:config, :routing})

      assert {:ok, table} = Loader.reload_routing(path: yml)
      assert table.default.alias == "layered"
      assert table.rules["coding"].alias == "yml_coder"
    end

    test "no layer supplies a default: table has none", _ctx do
      assert {:ok, %RoutingTable{default: nil}} = Loader.routing_from_layers()
    end

    test "home layer supplies the default", %{home: home} do
      write_layer(Path.join(home, "config"), ~s|[routing]\ndefault = "home_alias"\n|)
      assert {:ok, table} = Loader.routing_from_layers()
      assert table.default.alias == "home_alias"
    end

    test "project layer beats home layer", %{home: home, project: project} do
      write_layer(Path.join(home, "config"), ~s|[routing]\ndefault = "home_alias"\n|)
      write_layer(project, ~s|[routing]\ndefault = "project_alias"\n|)
      assert {:ok, table} = Loader.routing_from_layers()
      assert table.default.alias == "project_alias"
    end

    test "reload_routing with an empty Store installs the layered table, not a literal" do
      :ets.delete(:llm_core_config, {:config, :routing})

      assert {:ok, %RoutingTable{default: nil} = table} =
               Loader.reload_routing(path: tmp_dir("missing") <> "/routing.yml")

      assert {:ok, ^table} = Store.get_routing()
    end
  end

  describe "source pins: no provider alias hardcoded in routing code paths" do
    for file <- [
          "router/router.ex",
          "router/structs.ex",
          "config/loader.ex",
          "pipelines/routing_pipeline.ex"
        ] do
      test "#{file} carries no alias literal as a routing default" do
        source = File.read!(Path.join(@lib, unquote(file)))
        refute source =~ ~r/"default"\s*=>\s*"/
        refute source =~ ~r/alias:\s*"(claude|kimi|openai|anthropic)"/
      end
    end
  end

  defp write_layer(dir, toml) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "llm_core.toml"), toml)
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "gc6006-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
