defmodule LlmCore.Memory.Backend.ForesightInProcess do
  @moduledoc """
  Optional in-process adapter for applications that also depend on Foresight.

  All Foresight references are resolved at runtime, so Foresight is not a
  required dependency of `llm_core`.
  """

  @behaviour LlmCore.Memory.Backend

  require Logger

  alias LlmCore.Memory.{Config, Request}

  @impl true
  def available? do
    config = Config.backend_options(:foresight_inprocess)
    {module, context_module} = modules(config)
    available_modules?(module, context_module)
  end

  @impl true
  def retain(content, metadata, opts) do
    payload = Request.retain_payload(content, metadata, true, opts)

    case invoke(:retain, payload, opts) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Foresight in-process retain failed: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def retain_sync(content, metadata, opts) do
    invoke(:retain, Request.retain_payload(content, metadata, false, opts), opts)
  end

  @impl true
  def recall(query, opts) do
    payload = %{
      "query" => query,
      "budget" => Request.normalize_budget(Keyword.get(opts, :budget, :low)),
      "max_tokens" => Keyword.get(opts, :max_tokens, 4_096)
    }

    case invoke(:recall, payload, opts) do
      {:ok, %{"results" => results}} when is_list(results) -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @impl true
  def reflect(question, opts) when is_binary(question) do
    payload = %{
      "query" => question,
      "budget" => Request.normalize_budget(Keyword.get(opts, :budget, :low))
    }

    case invoke(:reflect, payload, opts) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, _other} -> {:ok, "No insights available"}
      error -> error
    end
  end

  defp invoke(function, payload, opts) do
    config = Config.backend_options(:foresight_inprocess)
    {module, context_module} = modules(config)

    if available_modules?(module, context_module) and function_exported?(module, function, 3) do
      apply(module, function, [
        context(opts, context_module, config),
        payload,
        Keyword.get(opts, :foresight_opts, [])
      ])
    else
      {:error, :foresight_unavailable}
    end
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp context(opts, context_module, config) do
    struct(context_module,
      tenant_id: Map.get(config, :tenant_id, "default"),
      mode: normalize_mode(Map.get(config, :mode, :mode_a)),
      bank: Request.resolve_bank_id(opts, Map.get(config, :default_bank_id)),
      role_name: Map.get(config, :role_name),
      prefix: Map.get(config, :prefix),
      embedding_dim: Map.get(config, :embedding_dim)
    )
  end

  defp modules(config) do
    module = Map.get(config, :module, Foresight)
    context_module = Map.get(config, :context_module, Module.concat(module, Context))
    {module, context_module}
  end

  defp available_modules?(module, context_module),
    do: Code.ensure_loaded?(module) and Code.ensure_loaded?(context_module)

  defp normalize_mode(mode) when mode in [:mode_a, :mode_b, :mode_c], do: mode
  defp normalize_mode("mode_a"), do: :mode_a
  defp normalize_mode("mode_b"), do: :mode_b
  defp normalize_mode("mode_c"), do: :mode_c
  defp normalize_mode(_mode), do: :mode_a
end
