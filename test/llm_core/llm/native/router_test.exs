defmodule LlmCore.LLM.Native.RouterTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Native.Router

  # Default config matching llm_core.toml
  @default_config %{
    cascade: ["appliance", "zai", "anthropic"],
    default_models: %{
      "appliance" => "qwen3.5-27b-claude-4.6-opus-distilled-mlx",
      "zai" => "glm-5.1",
      "anthropic" => "claude-sonnet-4-6"
    },
    model_routing: [
      %{"pattern" => "claude", "provider" => "anthropic"},
      %{"pattern" => "glm", "provider" => "zai"},
      %{"pattern" => "zai", "provider" => "zai"},
      %{"pattern" => "gpt", "provider" => "openai"},
      %{"pattern" => "openai", "provider" => "openai"}
    ]
  }

  # ── resolve/3: nil model (default path) ────────────────────

  describe "resolve/3 with nil model" do
    test "picks first provider in cascade with its default model" do
      assert {:ok, {LlmCore.LLM.Appliance, model}} = Router.resolve(nil, @default_config)
      assert model == "qwen3.5-27b-claude-4.6-opus-distilled-mlx"
    end

    test "respects cascade order — zai first if configured" do
      config = %{@default_config | cascade: ["zai", "anthropic", "appliance"]}

      assert {:ok, {LlmCore.LLM.Zai, model}} = Router.resolve(nil, config)
      assert model == "glm-5.1"
    end

    test "respects cascade order — anthropic first if configured" do
      config = %{@default_config | cascade: ["anthropic"]}

      assert {:ok, {LlmCore.LLM.Anthropic, model}} = Router.resolve(nil, config)
      assert model == "claude-sonnet-4-6"
    end

    test "returns error on empty cascade" do
      config = %{@default_config | cascade: []}
      assert {:error, :no_provider} = Router.resolve(nil, config)
    end

    test "returns error on empty config" do
      assert {:error, :no_provider} = Router.resolve(nil, %{})
    end
  end

  # ── resolve/3: model specified, appliance has it ───────────

  describe "resolve/3 with model on appliance" do
    test "routes to appliance when appliance_has_model is true" do
      assert {:ok, {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx"}} =
               Router.resolve("qwen3.5-27b-claude-4.6-opus-distilled-mlx", @default_config,
                 appliance_has_model: true
               )
    end

    test "appliance wins even for claude-named models" do
      # A model named "claude-local-finetune" that happens to be on the appliance
      assert {:ok, {LlmCore.LLM.Appliance, "claude-local-finetune"}} =
               Router.resolve("claude-local-finetune", @default_config,
                 appliance_has_model: true
               )
    end
  end

  # ── resolve/3: model specified, NOT on appliance ───────────

  describe "resolve/3 with model NOT on appliance" do
    test "routes claude models to anthropic" do
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6"}} =
               Router.resolve("claude-sonnet-4-6", @default_config,
                 appliance_has_model: false
               )
    end

    test "routes claude-opus to anthropic" do
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-opus-4-6"}} =
               Router.resolve("claude-opus-4-6", @default_config,
                 appliance_has_model: false
               )
    end

    test "routes glm models to zai" do
      assert {:ok, {LlmCore.LLM.Zai, "glm-5.1"}} =
               Router.resolve("glm-5.1", @default_config,
                 appliance_has_model: false
               )
    end

    test "routes gpt models to openai" do
      assert {:ok, {LlmCore.LLM.OpenAI, "gpt-4o"}} =
               Router.resolve("gpt-4o", @default_config,
                 appliance_has_model: false
               )
    end

    test "routes openai models to openai" do
      assert {:ok, {LlmCore.LLM.OpenAI, "openai-o3"}} =
               Router.resolve("openai-o3", @default_config,
                 appliance_has_model: false
               )
    end

    test "unknown model falls through to cascade" do
      # "llama-3.3-70b" doesn't match any routing pattern → cascade
      assert {:ok, {_module, "llama-3.3-70b"}} =
               Router.resolve("llama-3.3-70b", @default_config,
                 appliance_has_model: false
               )
    end

    test "model name matching is case-insensitive" do
      assert {:ok, {LlmCore.LLM.Anthropic, "CLAUDE-SONNET"}} =
               Router.resolve("CLAUDE-SONNET", @default_config,
                 appliance_has_model: false
               )
    end
  end

  # ── route_model/2 ─────────────────────────────────────────

  describe "route_model/2" do
    test "matches first pattern" do
      assert {:ok, "anthropic"} = Router.route_model("claude-sonnet-4-6", @default_config)
    end

    test "matches glm pattern" do
      assert {:ok, "zai"} = Router.route_model("glm-5.1-instruct", @default_config)
    end

    test "returns no_match for unknown model" do
      assert :no_match = Router.route_model("llama-3.3-70b", @default_config)
    end

    test "returns no_match for empty routing" do
      config = %{@default_config | model_routing: []}
      assert :no_match = Router.route_model("claude-sonnet", config)
    end

    test "custom routing patterns work" do
      config = %{
        model_routing: [
          %{"pattern" => "mistral", "provider" => "openai"},
          %{"pattern" => "deepseek", "provider" => "zai"}
        ]
      }

      assert {:ok, "openai"} = Router.route_model("mistral-large", config)
      assert {:ok, "zai"} = Router.route_model("deepseek-v3", config)
    end
  end

  # ── cascade_pick/2 ────────────────────────────────────────

  describe "cascade_pick/2" do
    test "returns first provider in cascade" do
      assert {:ok, {LlmCore.LLM.Appliance, _}} = Router.cascade_pick(@default_config, nil)
    end

    test "preserves given model when walking cascade" do
      assert {:ok, {LlmCore.LLM.Appliance, "custom-model"}} =
               Router.cascade_pick(@default_config, "custom-model")
    end

    test "uses default model when model is nil" do
      assert {:ok, {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx"}} =
               Router.cascade_pick(@default_config, nil)
    end

    test "skips unknown aliases" do
      config = %{@default_config | cascade: ["nonexistent", "anthropic"]}

      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6"}} =
               Router.cascade_pick(config, nil)
    end
  end

  # ── alias_to_module/1 ─────────────────────────────────────

  describe "alias_to_module/1" do
    test "maps known aliases" do
      assert Router.alias_to_module("appliance") == LlmCore.LLM.Appliance
      assert Router.alias_to_module("zai") == LlmCore.LLM.Zai
      assert Router.alias_to_module("anthropic") == LlmCore.LLM.Anthropic
      assert Router.alias_to_module("openai") == LlmCore.LLM.OpenAI
    end

    test "returns nil for unknown alias" do
      assert Router.alias_to_module("nonexistent") == nil
    end
  end

  # ── get_default_model/2 ───────────────────────────────────

  describe "get_default_model/2" do
    test "returns default model for known alias" do
      assert Router.get_default_model("zai", @default_config) == "glm-5.1"
    end

    test "returns nil for unknown alias" do
      assert Router.get_default_model("nonexistent", @default_config) == nil
    end

    test "returns nil when no defaults configured" do
      assert Router.get_default_model("zai", %{}) == nil
    end
  end

  # ── Subscription changes (the whole point) ────────────────

  describe "reconfiguring for subscription changes" do
    test "dropping zai from cascade" do
      config = %{@default_config | cascade: ["appliance", "anthropic"]}

      assert {:ok, {LlmCore.LLM.Appliance, _}} = Router.resolve(nil, config)
      # glm model now falls to cascade since zai removed from routing
      # But glm still matches model_routing → zai alias → zai module
      # This is fine: route_model still returns zai, resolve_alias returns it
      # The cascade only matters for nil-model or no-match paths
    end

    test "replacing anthropic with openai as cloud fallback" do
      config = %{
        @default_config
        | cascade: ["appliance", "openai"],
          default_models: Map.put(@default_config.default_models, "openai", "gpt-4o")
      }

      assert {:ok, {LlmCore.LLM.Appliance, _}} = Router.resolve(nil, config)

      # claude model still routes to anthropic via model_routing
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6"}} =
               Router.resolve("claude-sonnet-4-6", config, appliance_has_model: false)
    end

    test "adding a new provider to the cascade" do
      config = %{
        @default_config
        | cascade: ["appliance", "openai", "zai", "anthropic"],
          default_models: Map.put(@default_config.default_models, "openai", "gpt-4o"),
          model_routing:
            @default_config.model_routing ++
              [%{"pattern" => "mistral", "provider" => "openai"}]
      }

      assert {:ok, {LlmCore.LLM.OpenAI, "mistral-large"}} =
               Router.resolve("mistral-large", config, appliance_has_model: false)
    end
  end
end
