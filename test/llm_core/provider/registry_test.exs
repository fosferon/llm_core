defmodule LlmCore.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.Store
  alias LlmCore.Provider.Definition
  alias LlmCore.Provider.Registry

  setup do
    start_store()
    :ets.delete_all_objects(:llm_core_config)
    :ok
  end

  describe "lookup_by_alias/1" do
    test "returns the definition whose aliases include the given string" do
      put_providers(%{
        "anthropic" => build_definition("anthropic", AnthropicMod, ["anthropic", "claude"])
      })

      assert {:ok, %Definition{id: "anthropic"}} = Registry.lookup_by_alias("claude")
    end

    test "normalizes whitespace and case" do
      put_providers(%{
        "anthropic" => build_definition("anthropic", AnthropicMod, ["anthropic", "claude"])
      })

      assert {:ok, %Definition{id: "anthropic"}} = Registry.lookup_by_alias("  Claude  ")
      assert {:ok, %Definition{id: "anthropic"}} = Registry.lookup_by_alias("CLAUDE")
    end

    test "disambiguates when multiple definitions share a backing module" do
      shared = SameMod

      put_providers(%{
        "weak" => build_definition("weak", shared, ["weak"], %{streaming: true}),
        "strong" =>
          build_definition("strong", shared, ["strong"], %{streaming: true, reasoning: true})
      })

      assert {:ok, %Definition{id: "weak", capabilities: %{streaming: true} = caps_weak}} =
               Registry.lookup_by_alias("weak")

      refute Map.get(caps_weak, :reasoning)

      assert {:ok, %Definition{id: "strong", capabilities: %{reasoning: true}}} =
               Registry.lookup_by_alias("strong")
    end

    test "returns {:error, :not_found} for an unknown alias" do
      put_providers(%{
        "anthropic" => build_definition("anthropic", AnthropicMod, ["anthropic", "claude"])
      })

      assert {:error, :not_found} = Registry.lookup_by_alias("ghost")
    end
  end

  defp start_store do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end
  end

  defp put_providers(providers) when is_map(providers) do
    :ok = Store.put(:config, :providers, providers)
  end

  defp build_definition(id, module, aliases, capabilities \\ %{}) do
    %Definition{
      id: id,
      module: module,
      aliases: aliases,
      capabilities: capabilities,
      available?: true
    }
  end
end
