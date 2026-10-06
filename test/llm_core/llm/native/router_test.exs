defmodule LlmCore.LLM.Native.RouterTest do
  use ExUnit.Case, async: false

  alias LlmCore.Config.Store
  alias LlmCore.LLM.Native.Router
  alias LlmCore.Provider.Definition

  # Default [native] config matching llm_core.toml.
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

  # Minimal Definition map keyed by provider id — mirrors what
  # Config.Loader builds from the TOML at app start.
  @providers %{
    "appliance" => %Definition{
      id: "appliance",
      module: LlmCore.LLM.Appliance,
      aliases: ["appliance", "local", "lmstudio"],
      default_model: "qwen3.5-27b-claude-4.6-opus-distilled-mlx"
    },
    "zai" => %Definition{
      id: "zai",
      module: LlmCore.LLM.Zai,
      aliases: ["zai", "z"],
      default_model: "glm-5.1",
      options: %{"base_url" => "https://api.z.ai/api/coding/paas/v4"},
      auth: %{"api_key_env" => "ZAI_API_KEY"}
    },
    "anthropic" => %Definition{
      id: "anthropic",
      module: LlmCore.LLM.Anthropic,
      aliases: ["anthropic", "claude"],
      default_model: "claude-sonnet-4-6",
      auth: %{"api_key_env" => "ANTHROPIC_API_KEY"}
    },
    "openai" => %Definition{
      id: "openai",
      module: LlmCore.LLM.OpenAI,
      aliases: ["openai", "gpt"],
      default_model: "gpt-4o-mini",
      auth: %{"api_key_env" => "OPENAI_API_KEY"}
    }
  }

  setup do
    unless Process.whereis(Store) do
      start_supervised!(Store)
    end

    Store.put(:config, :providers, @providers)

    # Providers declaring an auth credential are only usable when it resolves.
    keys = ["ZAI_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
    saved = for k <- keys, do: {k, System.get_env(k)}
    Enum.each(keys, &System.put_env(&1, "test-key"))

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  # ── resolve/3: nil model (default path) ────────────────────

  describe "resolve/3 with nil model" do
    test "picks first provider in cascade with its default model" do
      assert {:ok, {LlmCore.LLM.Appliance, model, _opts}} = Router.resolve(nil, @default_config)
      assert model == "qwen3.5-27b-claude-4.6-opus-distilled-mlx"
    end

    test "respects cascade order — zai first if configured" do
      config = %{@default_config | cascade: ["zai", "anthropic", "appliance"]}

      assert {:ok, {LlmCore.LLM.Zai, model, _opts}} = Router.resolve(nil, config)
      assert model == "glm-5.1"
    end

    test "respects cascade order — anthropic first if configured" do
      config = %{@default_config | cascade: ["anthropic"]}

      assert {:ok, {LlmCore.LLM.Anthropic, model, _opts}} = Router.resolve(nil, config)
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
      assert {:ok, {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx", _opts}} =
               Router.resolve("qwen3.5-27b-claude-4.6-opus-distilled-mlx", @default_config,
                 appliance_has_model: true
               )
    end

    test "appliance wins even for claude-named models" do
      assert {:ok, {LlmCore.LLM.Appliance, "claude-local-finetune", _opts}} =
               Router.resolve("claude-local-finetune", @default_config, appliance_has_model: true)
    end
  end

  # ── resolve/3: model specified, NOT on appliance ───────────

  describe "resolve/3 with model NOT on appliance" do
    test "routes claude models to anthropic" do
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _opts}} =
               Router.resolve("claude-sonnet-4-6", @default_config, appliance_has_model: false)
    end

    test "routes claude-opus to anthropic" do
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-opus-4-6", _opts}} =
               Router.resolve("claude-opus-4-6", @default_config, appliance_has_model: false)
    end

    test "routes glm models to zai" do
      assert {:ok, {LlmCore.LLM.Zai, "glm-5.1", _opts}} =
               Router.resolve("glm-5.1", @default_config, appliance_has_model: false)
    end

    test "routes gpt models to openai" do
      assert {:ok, {LlmCore.LLM.OpenAI, "gpt-4o", _opts}} =
               Router.resolve("gpt-4o", @default_config, appliance_has_model: false)
    end

    test "routes openai models to openai" do
      assert {:ok, {LlmCore.LLM.OpenAI, "openai-o3", _opts}} =
               Router.resolve("openai-o3", @default_config, appliance_has_model: false)
    end

    test "unknown model falls through to cascade" do
      assert {:ok, {_module, "llama-3.3-70b", _opts}} =
               Router.resolve("llama-3.3-70b", @default_config, appliance_has_model: false)
    end

    test "model name matching is case-insensitive" do
      assert {:ok, {LlmCore.LLM.Anthropic, "CLAUDE-SONNET", _opts}} =
               Router.resolve("CLAUDE-SONNET", @default_config, appliance_has_model: false)
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

  # ── resolve_provider/1 (explicit routing) ─────────────────

  describe "resolve_provider/1" do
    test "resolves known provider id" do
      assert {:ok, {LlmCore.LLM.Zai, "glm-5.1", opts}} = Router.resolve_provider("zai")
      assert opts[:base_url] == "https://api.z.ai/api/coding/paas/v4"
    end

    test "resolves by alias" do
      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _opts}} =
               Router.resolve_provider("claude")
    end

    test "returns error for unknown provider" do
      assert {:error, :no_provider} = Router.resolve_provider("nonexistent")
    end
  end

  # ── candidates/3 (cascade-on-runtime-failure support) ─────

  describe "candidates/3" do
    test "returns primary then remaining cascade entries (nil model)" do
      assert [
               {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx", _},
               {LlmCore.LLM.Zai, "glm-5.1", _},
               {LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _}
             ] = Router.candidates(nil, @default_config)
    end

    test "primary from model routing, fallbacks use their defaults" do
      candidates =
        Router.candidates("claude-sonnet-4-6", @default_config, appliance_has_model: false)

      # Primary first — anthropic matches the claude pattern
      assert [{LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _} | rest] = candidates

      # Fallbacks use each provider's default model, not the claude one
      assert Enum.any?(rest, fn
               {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx", _} -> true
               _ -> false
             end)

      assert Enum.any?(rest, fn
               {LlmCore.LLM.Zai, "glm-5.1", _} -> true
               _ -> false
             end)
    end

    test "appliance-local primary then cloud fallbacks" do
      candidates =
        Router.candidates("qwen3.5-27b-claude-4.6-opus-distilled-mlx", @default_config,
          appliance_has_model: true
        )

      assert [
               {LlmCore.LLM.Appliance, "qwen3.5-27b-claude-4.6-opus-distilled-mlx", _} | rest
             ] = candidates

      modules = Enum.map(rest, fn {mod, _, _} -> mod end)
      assert LlmCore.LLM.Zai in modules
      assert LlmCore.LLM.Anthropic in modules
    end

    test "primary never appears twice" do
      candidates = Router.candidates(nil, @default_config)
      modules = Enum.map(candidates, fn {mod, _, _} -> mod end)
      assert length(modules) == length(Enum.uniq(modules))
    end

    test "returns empty list when nothing resolves" do
      assert [] = Router.candidates(nil, %{})
    end

    test "single-element list when only one provider in cascade" do
      config = %{@default_config | cascade: ["anthropic"]}

      assert [{LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _}] =
               Router.candidates(nil, config)
    end
  end

  # ── Subscription changes (the whole point) ────────────────

  describe "reconfiguring for subscription changes" do
    test "dropping zai from cascade" do
      config = %{@default_config | cascade: ["appliance", "anthropic"]}

      assert {:ok, {LlmCore.LLM.Appliance, _, _}} = Router.resolve(nil, config)
    end

    test "replacing anthropic with openai as cloud fallback" do
      config = %{
        @default_config
        | cascade: ["appliance", "openai"],
          default_models: Map.put(@default_config.default_models, "openai", "gpt-4o")
      }

      assert {:ok, {LlmCore.LLM.Appliance, _, _}} = Router.resolve(nil, config)

      assert {:ok, {LlmCore.LLM.Anthropic, "claude-sonnet-4-6", _}} =
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

      assert {:ok, {LlmCore.LLM.OpenAI, "mistral-large", _}} =
               Router.resolve("mistral-large", config, appliance_has_model: false)
    end
  end

  describe "usability: skipped candidates and the fallback provider" do
    test "a cascade member whose credential is unset is skipped, not attempted" do
      System.delete_env("ANTHROPIC_API_KEY")
      config = %{cascade: ["anthropic", "zai"], default_models: %{}, model_routing: []}

      assert [{LlmCore.LLM.Zai, "glm-5.1", _}] = Router.candidates(nil, config)
      assert [%{provider: "anthropic", reason: :no_credentials}] = Router.skipped(config)
    end

    test "a blank credential counts as unset" do
      System.put_env("ANTHROPIC_API_KEY", "")
      config = %{cascade: ["anthropic"], default_models: %{}, model_routing: []}

      assert [] = Router.candidates(nil, config)
      assert [%{reason: :no_credentials}] = Router.skipped(config)
    end

    test "disabled and unknown providers are skipped with a reason" do
      providers = Map.put(@providers, "zai", %{@providers["zai"] | enabled: false})
      Store.put(:config, :providers, providers)
      config = %{cascade: ["zai", "ghost", "anthropic"], default_models: %{}, model_routing: []}

      assert [{LlmCore.LLM.Anthropic, _, _}] = Router.candidates(nil, config)

      assert [
               %{provider: "zai", reason: :disabled},
               %{provider: "ghost", reason: :no_provider}
             ] = Router.skipped(config)
    end

    test "a CLI provider cannot run the native loop and is skipped" do
      cli = %Definition{
        id: "some_cli",
        module: LlmCore.LLM.CLIProvider,
        provider_kind: :cli,
        aliases: ["some_cli"]
      }

      Store.put(:config, :providers, Map.put(@providers, "some_cli", cli))
      config = %{cascade: ["some_cli", "zai"], default_models: %{}, model_routing: []}

      assert [{LlmCore.LLM.Zai, _, _}] = Router.candidates(nil, config)
      assert [%{provider: "some_cli", reason: :not_native}] = Router.skipped(config)
    end

    test "a model-routing target that is unusable falls through to the cascade" do
      System.delete_env("OPENAI_API_KEY")

      config = %{
        cascade: ["zai"],
        default_models: %{},
        model_routing: [%{"pattern" => "gpt", "provider" => "openai"}]
      }

      assert [{LlmCore.LLM.Zai, "gpt-oss:120b", _} | _] =
               Router.candidates("gpt-oss:120b", config)
    end

    test "an explicitly named provider is returned even without a credential" do
      System.delete_env("ANTHROPIC_API_KEY")
      assert {:ok, {LlmCore.LLM.Anthropic, _, _}} = Router.resolve_provider("anthropic")
    end

    test "no cascade configured: the fallback (routing default) is the only candidate" do
      empty = %{cascade: [], default_models: %{}, model_routing: []}

      assert [{LlmCore.LLM.Zai, "glm-5.1", _}] = Router.candidates(nil, empty, fallback: "zai")
      assert [] = Router.candidates(nil, empty)
      assert [] = Router.candidates(nil, empty, fallback: nil)
    end

    test "a configured cascade wins over the fallback" do
      config = %{cascade: ["anthropic"], default_models: %{}, model_routing: []}

      assert [{LlmCore.LLM.Anthropic, _, _}] = Router.candidates(nil, config, fallback: "zai")
    end

    test "an unusable fallback is reported by skipped/2" do
      System.delete_env("ZAI_API_KEY")
      empty = %{cascade: [], default_models: %{}, model_routing: []}

      assert [] = Router.candidates(nil, empty, fallback: "zai")

      assert [%{provider: "zai", reason: :no_credentials}] =
               Router.skipped(empty, fallback: "zai")
    end
  end
end
