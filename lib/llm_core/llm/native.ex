defmodule LlmCore.LLM.Native do
  @moduledoc """
  In-process agentic provider — runs the agent loop inside the BEAM VM.

    1. Reads the agent .md system prompt
    2. Resolves an LLM API provider (Appliance → Zai → Anthropic)
    3. Calls LlmCore.Agent.Loop.run with LlmToolkit.CodeTools
    4. Returns a standard LlmCore.LLM.Response

  Zero CLI cost. Uses whatever API provider is available.

  ## Provider Resolution Priority

    1. **Appliance** (local, free) — Qwen, etc. on DGX Spark / LM Studio
    2. **Z.ai** (plan-covered) — GLM-5.1, included in coding plan
    3. **Anthropic** (direct API) — Claude models, pay-per-token

  ## Usage

  This provider implements `LlmCore.LLM.Provider` and is selected by
  provider routing when `provider: "native"` is specified or when no
  CLI providers are available.

      {:ok, response} = LlmCore.LLM.Native.send(task,
        system_prompt_file: "/path/to/agent.md",
        cwd: "/path/to/project",
        model: "qwen3-vl-32b-thinking"
      )
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.{Response, Error, Appliance}
  alias LlmCore.Agent.Loop
  alias LlmToolkit.CodeTools

  import Kernel, except: [send: 2]

  @max_iterations 15

  # ── Provider Behaviour ─────────────────────────────────────

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: false,
      passthrough: false,
      tool_use: true,
      native_loop: true,
      models: ["qwen3-vl-32b-thinking", "glm-5.1", "claude-sonnet-4-6"]
    }
  end

  @impl true
  def provider_type, do: :api

  @impl true
  @spec send(String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def send(prompt, opts \\ []) do
    cwd = opts[:cwd] || File.cwd!() || "."
    agent_file = opts[:system_prompt_file]
    model = opts[:model]
    timeout = opts[:timeout]

    start = System.monotonic_time(:millisecond)

    result =
      try do
        do_send(prompt, cwd, agent_file, model, timeout)
      rescue
        e ->
          {:error, "Native dispatch crashed: #{Exception.message(e)}"}
      end

    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, llm_response, _messages} ->
        text = llm_response.content || ""
        {:ok,
         Response.new(
           content: text,
           provider: :native,
           metadata: %{elapsed_ms: elapsed, model: llm_response.model, usage: llm_response.usage}
         )}

      {:error, :max_iterations_reached} ->
        {:error,
         Error.new(:provider_error,
           message: "Iteration limit reached (#{@max_iterations})",
           provider: :native
         )}

      {:error, reason} ->
        {:error,
         Error.new(:provider_error,
           message: "Native dispatch error: #{inspect(reason)}",
           provider: :native
         )}
    end
  end

  @impl true
  def stream(_prompt, _opts \\ []) do
    {:error,
     Error.new(:provider_error,
       message: "Streaming not supported for native dispatch (agentic loop is synchronous)",
       provider: :native
     )}
  end

  # ── Execution ──────────────────────────────────────────────

  defp do_send(prompt, cwd, agent_file, model, _timeout) do
    system_prompt = load_agent_prompt(agent_file)

    {provider, resolved_model} = resolve_provider(model)

    messages = [
      %{role: :system, content: system_prompt},
      %{role: :user, content: prompt}
    ]

    tools = CodeTools.available_tools()
    llm_send = build_llm_send(provider, resolved_model)

    Loop.run(
      messages,
      llm_send,
      tools: tools,
      resolve_tool: &CodeTools.resolve(&1, cwd),
      max_iterations: @max_iterations
    )
  end

  # ── Agent Prompt ───────────────────────────────────────────

  defp load_agent_prompt(nil) do
    "You are a helpful coding assistant. Complete the task accurately."
  end

  defp load_agent_prompt(path) do
    case File.read(path) do
      {:ok, content} ->
        strip_frontmatter(content)

      {:error, reason} ->
        require Logger
        Logger.warning("[Native] Cannot read agent file #{path}: #{inspect(reason)}")
        "You are a helpful coding assistant. Complete the task accurately."
    end
  end

  defp strip_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [_before, _yaml, body] -> String.trim(body)
      _ -> String.trim(content)
    end
  end

  # ── Provider Resolution ────────────────────────────────────
  #
  # Driven by TOML config ([native] section in priv/config/llm_core.toml).
  #
  # Cascade: ordered list of providers to try. First available wins.
  # Model routing: substring patterns → provider name. First match wins.
  # Default models: per-provider fallback when no model specified.
  #
  # All of this is configurable — change the TOML, not the code.

  defp resolve_provider(model) when is_binary(model) do
    lower = String.downcase(model)

    # Always try local appliance first if the model is loaded there,
    # regardless of model name patterns (local = free).
    if appliance_available?() and model_available_on_appliance?(model) do
      {LlmCore.LLM.Appliance, model}
    else
      case route_model(lower) do
        {:ok, provider_alias} ->
          case resolve_alias(provider_alias, model) do
            {:ok, _} = result -> result
            :unavailable -> cascade_fallback(model)
          end

        :no_match ->
          cascade_fallback(model)
      end
    end
  end

  defp resolve_provider(nil) do
    cascade_fallback(nil)
  end

  # Walk the cascade from TOML config. First available provider wins.
  defp cascade_fallback(model) do
    cascade = native_config(:cascade, ["appliance", "zai", "anthropic"])
    defaults = native_config(:default_models, %{})

    case find_available(cascade) do
      {:ok, alias, provider_mod} ->
        resolved_model = model || Map.get(defaults, to_string(alias)) || ""
        {provider_mod, resolved_model}

      :none ->
        raise "no LLM API provider available — check [native] cascade in llm_core.toml"
    end
  end

  defp find_available([]), do: :none

  defp find_available([alias | rest]) do
    case alias_to_module(alias) do
      {:ok, mod} when is_atom(mod) ->
        if mod.available?(), do: {:ok, alias, mod}, else: find_available(rest)

      :unknown ->
        find_available(rest)
    end
  end

  # Match model name against [[native.model_routing]] patterns.
  defp route_model(lower) do
    routing = native_config(:model_routing, [])

    Enum.find_value(routing, :no_match, fn entry ->
      pattern = Map.get(entry, "pattern", "")

      if String.contains?(lower, pattern) do
        {:ok, Map.get(entry, "provider", "")}
      else
        nil
      end
    end)
  end

  # Resolve a TOML alias to a provider module + model.
  defp resolve_alias(alias, model) do
    case alias_to_module(alias) do
      {:ok, mod} ->
        if mod.available?() do
          {:ok, {mod, model}}
        else
          :unavailable
        end

      :unknown ->
        :unavailable
    end
  end

  defp alias_to_module("appliance"), do: {:ok, LlmCore.LLM.Appliance}
  defp alias_to_module("zai"), do: {:ok, LlmCore.LLM.Zai}
  defp alias_to_module("anthropic"), do: {:ok, LlmCore.LLM.Anthropic}
  defp alias_to_module("openai"), do: {:ok, LlmCore.LLM.OpenAI}
  defp alias_to_module(_), do: :unknown

  defp appliance_available?, do: LlmCore.LLM.Appliance.available?()

  # Read a key from the [native] TOML section.
  # Falls back to Application env, then the given default.
  defp native_config(key, default) do
    Application.get_env(:llm_core, :native, %{})
    |> Map.get(key, default)
  end

  # ── LLM Send Function ──────────────────────────────────────

  # Check if a specific model is loaded on the local Appliance.
  # Queries /v1/models directly. Result cached in process dict for 60s.
  defp model_available_on_appliance?(model) do
    now = System.monotonic_time(:second)
    cache = Process.get(:appliance_models_cache)

    models =
      case cache do
        {cached_at, cached_models} when now - cached_at < 60 ->
          cached_models

        _ ->
          ids =
            case Appliance.discover() do
              [{_, %URI{} = uri} | _] ->
                url = String.trim_trailing(URI.to_string(uri), "/") <> "/v1/models"

                case Req.get(url, receive_timeout: 3_000, retry: false) do
                  {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
                    Enum.map(data, & &1["id"])

                  _ ->
                    []
                end

              _ ->
                []
            end

          Process.put(:appliance_models_cache, {now, ids})
          ids
      end

    model in models
  end

  defp build_llm_send(provider, model) do
    fn messages, opts ->
      # Agentic tool-calling needs generous timeouts — thinking models
      # can take 2-3 minutes per iteration with tool calls
      opts = Keyword.put_new(opts, :timeout, 180_000)
      provider.send(messages, Keyword.put(opts, :model, model))
    end
  end
end
