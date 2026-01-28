defmodule LlmCore.Pipelines.InferencePipeline.Context do
  @moduledoc """
  Carries inference data through the ALF inference pipeline.
  """

  defstruct prompt: nil,
            task_type: nil,
            mode: :send,
            opts: [],
            route: nil,
            agent: nil,
            provider_opts: [],
            response_format: nil,
            result: nil
end

defmodule LlmCore.Pipelines.InferencePipeline do
  @moduledoc """
  ALF pipeline that normalizes a request, resolves routing, and dispatches it
  to the selected provider using either blocking or streaming mode.
  """

  use ALF.DSL

  alias ALF.Manager
  alias LlmCore.Agent
  alias LlmCore.Pipelines.InferencePipeline.Context
  alias LlmCore.Pipelines.RoutingPipeline
  alias LlmCore.Router.ResolvedRoute
  alias LlmCore.Structured
  alias LlmCore.Telemetry

  @components [
    stage(:normalize_request),
    stage(:extract_response_format),
    stage(:resolve_route),
    stage(:prepare_provider_opts),
    stage(:ensure_streaming_capable),
    stage(:ensure_structured_output_capable),
    stage(:dispatch_provider),
    stage(:maybe_apply_structured_output),
    stage(:finalize_result)
  ]

  @spec execute(:send | :stream, String.t(), String.t() | atom(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(mode, prompt, task_type, opts \\ []) when mode in [:send, :stream] do
    ensure_started()

    context = %Context{mode: mode, prompt: prompt, task_type: task_type, opts: opts}

    Telemetry.span(:inference_pipeline, %{task_type: task_type, mode: mode}, fn ->
      result = Manager.call(context, __MODULE__, sync: true)
      {result, telemetry_result(result)}
    end)
  end

  # --- Stage callbacks ----------------------------------------------------

  def normalize_request(%Context{prompt: prompt, task_type: task_type} = ctx, _opts) do
    with {:ok, normalized_prompt} <- normalize_prompt(prompt) do
      %{ctx | prompt: normalized_prompt, task_type: normalize_task_type(task_type)}
    else
      {:error, reason} -> %{ctx | result: {:error, reason}}
    end
  end

  def resolve_route(%Context{result: {:error, _}} = ctx, _opts), do: ctx

  def resolve_route(%Context{task_type: task_type, opts: opts} = ctx, _opts) do
    routing_opts = Keyword.take(opts, [:routing_table])

    case RoutingPipeline.route(task_type, routing_opts) do
      {:ok, %ResolvedRoute{} = route} -> %{ctx | route: route, agent: route.agent}
      {:error, reason} -> %{ctx | result: {:error, reason}}
    end
  end

  def prepare_provider_opts(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def prepare_provider_opts(%Context{agent: nil} = ctx, _opts), do: ctx

  def prepare_provider_opts(
        %Context{agent: %Agent{} = agent, opts: opts, response_format: format} = ctx,
        _opts
      ) do
    defaults =
      agent.config
      |> normalize_config()
      |> Enum.map(&normalize_kv/1)
      |> Enum.reject(&is_nil/1)

    provider_opts =
      defaults
      |> Keyword.merge(opts)
      |> maybe_attach_response_format(format)

    %{ctx | provider_opts: provider_opts}
  end

  def ensure_streaming_capable(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def ensure_streaming_capable(%Context{mode: :send} = ctx, _opts), do: ctx

  def ensure_streaming_capable(%Context{mode: :stream, agent: %Agent{} = agent} = ctx, _opts) do
    capabilities = safe_capabilities(agent.provider)

    if Map.get(capabilities, :streaming, false) do
      ctx
    else
      %{ctx | result: {:error, :streaming_not_supported}}
    end
  end

  def ensure_streaming_capable(%Context{} = ctx, _opts), do: ctx

  def ensure_structured_output_capable(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def ensure_structured_output_capable(%Context{response_format: nil} = ctx, _opts), do: ctx

  def ensure_structured_output_capable(%Context{mode: :stream} = ctx, _opts) do
    %{ctx | result: {:error, :structured_output_not_supported_in_streaming}}
  end

  def ensure_structured_output_capable(%Context{agent: %Agent{} = agent} = ctx, _opts) do
    capabilities = safe_capabilities(agent.provider)

    if Map.get(capabilities, :structured_output, false) do
      ctx
    else
      %{ctx | result: {:error, :structured_output_not_supported}}
    end
  end

  def ensure_structured_output_capable(%Context{} = ctx, _opts), do: ctx

  def dispatch_provider(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def dispatch_provider(%Context{agent: nil} = ctx, _opts), do: ctx

  def dispatch_provider(
        %Context{mode: mode, prompt: prompt, provider_opts: opts, route: route} = ctx,
        _opts
      ) do
    provider = route.agent.provider

    result =
      Telemetry.span(:provider_dispatch, %{provider: provider, mode: mode}, fn ->
        dispatch_result =
          case mode do
            :stream -> safe_apply(provider, :stream, [prompt, opts])
            :send -> safe_apply(provider, :send, [prompt, opts])
          end

        measurement =
          case dispatch_result do
            {:ok, %LlmCore.LLM.Response{} = response} ->
              %{status: :ok, provider: response.provider, model: response.model}

            {:ok, _} ->
              %{status: :ok}

            {:error, reason} ->
              %{status: :error, error: reason}
          end

        {dispatch_result, measurement}
      end)

    %{ctx | result: result}
  end

  def maybe_apply_structured_output(%Context{result: {:ok, _}} = ctx, _opts) do
    result = Structured.process(ctx.result, ctx.response_format)
    %{ctx | result: result}
  end

  def maybe_apply_structured_output(%Context{} = ctx, _opts), do: ctx

  def finalize_result(%Context{result: result}, _opts) when not is_nil(result), do: result
  def finalize_result(_ctx, _opts), do: {:error, :inference_failed}

  defp telemetry_result({:ok, %LlmCore.LLM.Response{} = response}),
    do: %{status: :ok, provider: response.provider, model: response.model}

  defp telemetry_result({:ok, _}), do: %{status: :ok}
  defp telemetry_result({:error, reason}), do: %{status: :error, error: reason}

  defp telemetry_result(%ALF.ErrorIP{error: {kind, reason, stacktrace}}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp telemetry_result(%ALF.ErrorIP{error: reason}) do
    %{status: :error, error: reason}
  end

  # --- Helpers ------------------------------------------------------------

  defp normalize_prompt(prompt) when is_binary(prompt), do: {:ok, prompt}

  defp normalize_prompt(prompt) when is_list(prompt) do
    if Enum.all?(prompt, &valid_message?/1) do
      {:ok, prompt}
    else
      {:error, :invalid_messages}
    end
  end

  defp normalize_prompt(prompt) do
    try do
      {:ok, to_string(prompt)}
    rescue
      _ -> {:error, :invalid_prompt}
    end
  end

  defp valid_message?(%{role: role, content: content})
       when role in [:system, :user, :assistant, :tool] and is_binary(content),
       do: true

  defp valid_message?(_), do: false

  defp normalize_task_type(task_type) when is_atom(task_type), do: Atom.to_string(task_type)
  defp normalize_task_type(task_type) when is_binary(task_type), do: String.trim(task_type)
  defp normalize_task_type(_), do: "default"

  defp normalize_config(nil), do: []
  defp normalize_config(map) when is_map(map), do: Map.to_list(map)
  defp normalize_config(list) when is_list(list), do: list
  defp normalize_config(_), do: []

  defp normalize_kv({key, value}) when is_atom(key), do: {key, value}

  defp normalize_kv({key, value}) when is_binary(key) do
    try do
      {String.to_existing_atom(key), value}
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_kv(_), do: nil

  defp maybe_attach_response_format(opts, nil), do: opts
  defp maybe_attach_response_format(opts, format), do: Keyword.put(opts, :response_format, format)

  defp safe_capabilities(provider) do
    provider.capabilities()
  rescue
    _e -> %{}
  end

  defp safe_apply(provider, fun, args) do
    apply(provider, fun, args)
  rescue
    exception -> {:error, {:provider_crash, exception}}
  end

  defp ensure_started do
    unless Manager.started?(__MODULE__) do
      :ok = Manager.start(__MODULE__, sync: true)
    end
  end

  def extract_response_format(%Context{opts: opts} = ctx, _opts) do
    {response_format, remaining_opts} = Keyword.pop(opts, :response_format)
    %{ctx | response_format: response_format, opts: remaining_opts}
  end
end
