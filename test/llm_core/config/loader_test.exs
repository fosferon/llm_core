defmodule LlmCore.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias LlmCore.Config.Loader
  alias LlmCore.Config.Store
  alias LlmCore.Router.RoutingTable

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

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "llm_core_test-#{name}-#{System.unique_integer([:positive])}")
  end
end
