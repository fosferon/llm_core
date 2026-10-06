defmodule LlmCore.Router.SafeDefaultTest do
  @moduledoc """
  GC-5985: the degraded-mode fallback default MUST be a keyed, working route.

  When the daemon boots without its routing config (observed 2026-10-05:
  'No routing config found, using safe default' every minute; every
  spawn-time dispatch needing routing resolution died with NO trace), the
  safe default is the ONLY route anything resolves against. A default with
  no key (anthropic) or a retired model (claude) makes degraded mode a
  total outage. The default is kimi: keyed, cheap, proven under the
  fosferon workload.
  """
  use ExUnit.Case, async: false

  alias LlmCore.Router.RoutingTable

  test "the safe default routing table resolves to the keyed kimi route" do
    table = RoutingTable.new(%{"default" => "kimi"})
    assert table.default.alias == "kimi"
  end

  test "router source pins the default (falsify: a claude default reds this)" do
    source =
      File.read!(Path.join([__DIR__, "..", "..", "..", "lib", "llm_core", "router", "router.ex"]))

    assert source =~ ~s|%{"default" => "kimi"}|
    refute source =~ ~s|%{"default" => "claude"}|
  end
end
