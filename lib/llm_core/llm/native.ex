defmodule LlmCore.LLM.Native do
  @moduledoc """
  In-process agentic provider — runs the agent loop inside the BEAM VM.

    1. Reads the agent .md system prompt
    2. Resolves an LLM API provider from configuration
    3. Calls LlmCore.Agent.Loop.run with LlmToolkit.CodeTools
    4. Returns a standard LlmCore.LLM.Response

  Zero CLI cost. Uses whatever API provider your configuration makes available.

  ## Provider Resolution

  llm_core ships no provider order. Configure a `[native] cascade` (see
  `LlmCore.LLM.Native.Config`); providers are tried in that order, skipping any that
  are disabled, cannot run the native loop, or have no credential. With no cascade
  configured, the single provider named by `[routing] default` is used. If nothing is
  usable the call fails with a structured `{:no_native_provider, details}` error; if
  every candidate fails, the error lists every attempt.

  ## Usage

  This provider implements `LlmCore.LLM.Provider` and is selected by
  provider routing when `provider: "native"` is specified or when no
  CLI providers are available.

      {:ok, response} = LlmCore.LLM.Native.send(task,
        system_prompt_file: "/path/to/agent.md",
        cwd: "/path/to/project",
        model: "my-model-id"
      )
  """

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.Config.Store
  alias LlmCore.LLM.{Response, Error}
  alias LlmCore.LLM.Native.Config, as: NativeConfig
  alias LlmCore.LLM.Native.Router

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
      models: NativeConfig.get().default_models |> Map.values() |> Enum.sort()
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
    llm_provider = opts[:llm_provider]

    start = System.monotonic_time(:millisecond)

    result =
      try do
        do_send(prompt, cwd, agent_file, model, timeout, llm_provider)
      rescue
        e ->
          {:error, "Native dispatch crashed: #{Exception.message(e)}"}
      end

    elapsed = System.monotonic_time(:millisecond) - start

    build_send_result(result, elapsed)
  end

  # Maps a Loop.run result to the provider-boundary Response/Error.
  # `@doc false` public for direct testing.
  #
  # Preserves bounded terminal diagnostics: provider metadata
  # (finish reason, request id) survives success, and the typed
  # `{:empty_stop, details}` error carries its iteration/finish-reason
  # context through as Error details instead of collapsing to a generic
  # inspect string.
  @doc false
  @spec build_send_result(term(), integer()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def build_send_result({:ok, llm_response, _messages}, elapsed) do
    text = llm_response.content || ""

    metadata =
      Map.merge(llm_response.metadata || %{}, %{
        elapsed_ms: elapsed,
        model: llm_response.model,
        usage: llm_response.usage
      })

    {:ok, Response.new(content: text, provider: :native, metadata: metadata)}
  end

  def build_send_result({:error, :max_iterations_reached}, _elapsed) do
    {:error,
     Error.new(:provider_error,
       message: "Iteration limit reached (#{@max_iterations})",
       provider: :native
     )}
  end

  def build_send_result({:error, {:empty_stop, details}}, _elapsed)
      when is_map(details) do
    {:error,
     Error.new(:provider_error,
       message:
         "Native dispatch ended with repeated empty stop responses (blank content, no tool calls) " <>
           "after #{Map.get(details, :attempts)} attempts at iteration #{Map.get(details, :iteration)}",
       provider: :native,
       details: details
     )}
  end

  def build_send_result(
        {:error, {:cascade_exhausted, %{last: last, attempts: attempts} = details}},
        _elapsed
      ) do
    tried =
      Enum.map_join(attempts, "; ", fn %{provider: mod, reason: reason} ->
        "#{inspect(mod)}: #{inspect(reason)}"
      end)

    {:error,
     Error.new(:provider_error,
       message:
         "Native dispatch error: #{inspect(last)} " <>
           "(every cascade provider failed — #{tried})",
       provider: :native,
       details: details
     )}
  end

  def build_send_result({:error, {:no_native_provider, %{reason: reason} = details}}, _elapsed) do
    {:error,
     Error.new(:provider_error,
       message:
         "No native provider is usable (#{reason}): configure [native] cascade, " <>
           "or set [routing] default to a provider that can run the native loop" <>
           skipped_note(Map.get(details, :skipped, [])),
       provider: :native,
       details: details
     )}
  end

  def build_send_result({:error, reason}, _elapsed) do
    {:error,
     Error.new(:provider_error,
       message: "Native dispatch error: #{inspect(reason)}",
       provider: :native
     )}
  end

  defp skipped_note([]), do: ""

  defp skipped_note(skipped) do
    " — skipped: " <>
      Enum.map_join(skipped, ", ", fn %{provider: p, reason: r} -> "#{p} (#{r})" end)
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

  defp do_send(prompt, cwd, agent_file, model, timeout, llm_provider)

  defp do_send(prompt, cwd, agent_file, model, _timeout, llm_provider) do
    system_prompt = load_agent_prompt(agent_file)

    with {:ok, candidates} <- resolve_candidates(model, llm_provider) do
      messages = [
        %{role: :system, content: system_prompt},
        %{role: :user, content: prompt}
      ]

      tools = CodeTools.available_tools()

      run_fn = fn {provider, resolved_model, provider_opts} ->
        llm_send = build_llm_send(provider, resolved_model, provider_opts)

        Loop.run(
          messages,
          llm_send,
          tools: tools,
          resolve_tool: &CodeTools.resolve(&1, cwd),
          max_iterations: @max_iterations
        )
      end

      try_cascade(candidates, run_fn)
    end
  end

  @doc """
  Walk a list of `{module, model, opts}` candidates and invoke `run_fn`
  on each until one succeeds.

  - `{:ok, response, messages}` from `run_fn` → returned immediately.
  - `{:error, :max_iterations_reached}` → returned immediately (reasoning
    failure, not a provider outage — retrying elsewhere won't help).
  - Any other `{:error, reason}` (including the typed `{:empty_stop, _}` —
    provider-specific degenerate output may not repeat on another backend)
    → logs and advances to the next candidate.
  - Every candidate failed: a single candidate surfaces its raw error; several
    return `{:error, {:cascade_exhausted, %{last: reason, attempts: attempts}}}`
    where `attempts` lists every candidate's `%{provider: module, reason: term}` in order,
    so the first failure is never masked by the last one.
  - Empty list → `{:error, :no_provider_succeeded}`.

  Exposed for direct testing; production call sites go through `send/2`.
  """
  @spec try_cascade([{module(), String.t(), keyword()}], (tuple() -> term())) ::
          {:ok, LlmCore.LLM.Response.t(), [map()]} | {:error, term()}
  def try_cascade([], _run_fn), do: {:error, :no_provider_succeeded}

  def try_cascade(candidates, run_fn), do: walk_cascade(candidates, run_fn, [])

  defp walk_cascade([candidate | rest], run_fn, attempts) do
    {mod, _, _} = candidate

    case run_fn.(candidate) do
      {:ok, _response, _messages} = ok ->
        ok

      {:error, :max_iterations_reached} = err ->
        err

      {:error, reason} when rest == [] ->
        case [%{provider: mod, reason: reason} | attempts] do
          [_single] -> {:error, reason}
          all -> {:error, {:cascade_exhausted, %{last: reason, attempts: Enum.reverse(all)}}}
        end

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[Native] Provider #{inspect(mod)} failed (#{inspect(reason)}); trying next in cascade"
        )

        walk_cascade(rest, run_fn, [%{provider: mod, reason: reason} | attempts])
    end
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

  # Returns `{:ok, candidates}` — an ordered list of `{mod, model, opts}` — or a
  # structured `{:error, {:no_native_provider, details}}` saying why nothing is usable.
  #
  # Explicit `llm_provider` → single-element list (caller asked for a specific
  # backend; don't silently cascade to a different one).
  # Otherwise → primary + remaining cascade members from `Router.candidates/3`.
  # The cascade comes from `[native]` config (`LlmCore.LLM.Native.Config`); with
  # none configured the only member is the routing default.
  defp resolve_candidates(model, llm_provider) when is_binary(llm_provider) do
    case Router.resolve_provider(llm_provider) do
      {:ok, {mod, resolved_model, opts}} ->
        {:ok, [{mod, model || resolved_model, opts}]}

      {:error, :no_provider} ->
        raise "unknown LLM provider: #{llm_provider}"
    end
  end

  defp resolve_candidates(model, nil) do
    config = NativeConfig.get()
    fallback = routing_default_alias()
    router_opts = [fallback: fallback]

    appliance_has =
      is_binary(model) and appliance_available?() and model_available_on_appliance?(model)

    case Router.candidates(model, config, [appliance_has_model: appliance_has] ++ router_opts) do
      [] -> {:error, {:no_native_provider, no_provider_details(config, fallback, router_opts)}}
      candidates -> {:ok, candidates}
    end
  end

  defp no_provider_details(config, fallback, router_opts) do
    reason =
      cond do
        config.cascade != [] -> :cascade_unusable
        is_nil(fallback) -> :no_routing_default
        true -> :fallback_unusable
      end

    %{reason: reason, fallback: fallback, skipped: Router.skipped(config, router_opts)}
  end

  # The routing default is the fallback provider when no native cascade is configured.
  defp routing_default_alias do
    case Store.get_routing() do
      {:ok, %{default: %{alias: alias}}} when is_binary(alias) -> alias
      _ -> nil
    end
  end

  defp appliance_available?, do: LlmCore.LLM.Appliance.available?()

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
            case LlmCore.LLM.Appliance.discover() do
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

  defp build_llm_send(provider_mod, resolved_model, provider_opts) do
    fn messages, loop_opts ->
      loop_opts =
        loop_opts
        |> Keyword.put_new(:timeout, 180_000)
        |> Keyword.put(:model, resolved_model)
        |> Keyword.merge(provider_opts)

      provider_mod.send(messages, loop_opts)
    end
  end
end
