defmodule LlmCore.Pipelines.InferencePipeline.Context do
  @moduledoc """
  Carries inference data through the ALF inference pipeline.
  """

  defstruct prompt: nil,
            packet: nil,
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

  @doc """
  Executes the inference pipeline for the given mode (`:send` or `:stream`).

  Normalizes the request, resolves routing, dispatches to the provider, and
  optionally applies structured output extraction.
  """
  @spec execute(
          :send | :stream,
          String.t() | [map()] | map(),
          String.t() | atom() | nil,
          keyword()
        ) ::
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

  @doc false
  @spec normalize_request(Context.t(), keyword()) :: Context.t()
  def normalize_request(
        %Context{
          prompt: %{__struct__: CommBus.Protocol.Packet} = packet,
          task_type: task_type,
          opts: opts
        } = ctx,
        _opts
      ) do
    with {:ok, messages} <- normalize_packet_messages(packet) do
      derived_task_type = packet_task_type(packet) || task_type

      %{
        ctx
        | prompt: messages,
          packet: packet,
          task_type: normalize_task_type(derived_task_type),
          opts: attach_commbus_context(opts, packet)
      }
    else
      {:error, reason} -> %{ctx | result: {:error, reason}}
    end
  end

  def normalize_request(%Context{prompt: prompt, task_type: task_type} = ctx, _opts) do
    with {:ok, normalized_prompt} <- normalize_prompt(prompt) do
      %{ctx | prompt: normalized_prompt, task_type: normalize_task_type(task_type)}
    else
      {:error, reason} -> %{ctx | result: {:error, reason}}
    end
  end

  @doc false
  @spec resolve_route(Context.t(), keyword()) :: Context.t()
  def resolve_route(%Context{result: {:error, _}} = ctx, _opts), do: ctx

  def resolve_route(%Context{task_type: task_type, opts: opts} = ctx, _opts) do
    routing_opts = Keyword.take(opts, [:routing_table])

    case RoutingPipeline.route(task_type, routing_opts) do
      {:ok, %ResolvedRoute{} = route} -> %{ctx | route: route, agent: route.agent}
      {:error, reason} -> %{ctx | result: {:error, reason}}
    end
  end

  @doc false
  @spec prepare_provider_opts(Context.t(), keyword()) :: Context.t()
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

  @doc false
  @spec ensure_streaming_capable(Context.t(), keyword()) :: Context.t()
  def ensure_streaming_capable(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def ensure_streaming_capable(%Context{mode: :send} = ctx, _opts), do: ctx

  def ensure_streaming_capable(%Context{mode: :stream, agent: %Agent{} = agent} = ctx, _opts) do
    capabilities = safe_capabilities(agent)

    if Map.get(capabilities, :streaming, false) do
      ctx
    else
      %{ctx | result: {:error, :streaming_not_supported}}
    end
  end

  def ensure_streaming_capable(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec ensure_structured_output_capable(Context.t(), keyword()) :: Context.t()
  def ensure_structured_output_capable(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def ensure_structured_output_capable(%Context{response_format: nil} = ctx, _opts), do: ctx

  def ensure_structured_output_capable(%Context{mode: :stream} = ctx, _opts) do
    %{ctx | result: {:error, :structured_output_not_supported_in_streaming}}
  end

  def ensure_structured_output_capable(%Context{agent: %Agent{} = agent} = ctx, _opts) do
    capabilities = safe_capabilities(agent)

    if Map.get(capabilities, :structured_output, false) do
      ctx
    else
      %{ctx | result: {:error, :structured_output_not_supported}}
    end
  end

  def ensure_structured_output_capable(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec dispatch_provider(Context.t(), keyword()) :: Context.t()
  def dispatch_provider(%Context{result: {:error, _}} = ctx, _opts), do: ctx
  def dispatch_provider(%Context{agent: nil} = ctx, _opts), do: ctx

  def dispatch_provider(
        %Context{mode: mode, prompt: prompt, provider_opts: opts, route: route} = ctx,
        _opts
      ) do
    provider = Agent.dispatch_provider(route.agent)

    result =
      Telemetry.span(:provider_dispatch, %{provider: provider, mode: mode}, fn ->
        dispatch_result =
          case mode do
            :stream -> LlmCore.LLM.Provider.dispatch_stream(provider, prompt, opts)
            :send -> LlmCore.LLM.Provider.dispatch(provider, prompt, opts)
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

  @doc false
  @spec maybe_apply_structured_output(Context.t(), keyword()) :: Context.t()
  def maybe_apply_structured_output(%Context{result: {:ok, _}} = ctx, _opts) do
    result = Structured.process(ctx.result, ctx.response_format)
    %{ctx | result: result}
  end

  def maybe_apply_structured_output(%Context{} = ctx, _opts), do: ctx

  @doc false
  @spec finalize_result(Context.t(), keyword()) :: {:ok, term()} | {:error, term()}
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
    prompt
    |> Enum.reduce_while([], fn message, acc ->
      case normalize_message(message) do
        {:ok, normalized} -> {:cont, [normalized | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_messages}
      normalized -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp normalize_prompt(prompt) do
    try do
      {:ok, to_string(prompt)}
    rescue
      _ -> {:error, :invalid_prompt}
    end
  end

  defp normalize_message(%{role: role, content: content} = message)
       when is_binary(content) do
    with {:ok, normalized_role} <- normalize_message_role(role) do
      metadata = Map.get(message, :metadata) || Map.get(message, "metadata") || %{}

      {:ok,
       %{
         role: normalized_role,
         content: content,
         metadata: metadata
       }}
    else
      :error -> :error
    end
  end

  defp normalize_message(%{"role" => role, "content" => content} = message)
       when is_binary(content) do
    with {:ok, normalized_role} <- normalize_message_role(role) do
      metadata = Map.get(message, "metadata") || %{}

      {:ok,
       %{
         role: normalized_role,
         content: content,
         metadata: metadata
       }}
    else
      :error -> :error
    end
  end

  defp normalize_message(_), do: :error

  defp normalize_message_role(role) when role in [:system, :user, :assistant, :tool],
    do: {:ok, role}

  defp normalize_message_role(role) when is_binary(role) do
    case role |> String.trim() |> String.downcase() do
      "system" -> {:ok, :system}
      "assistant" -> {:ok, :assistant}
      "tool" -> {:ok, :tool}
      "function" -> {:ok, :tool}
      "user" -> {:ok, :user}
      _ -> :error
    end
  end

  defp normalize_message_role(_), do: :error

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

  defp safe_capabilities(agent) do
    provider = Agent.dispatch_provider(agent)

    case provider do
      %LlmCore.LLM.CLIProvider{} -> LlmCore.LLM.CLIProvider.capabilities(provider)
      mod when is_atom(mod) -> mod.capabilities()
      %{__struct__: mod} -> mod.capabilities(provider)
    end
  rescue
    _e -> %{}
  end

  defp ensure_started do
    unless Manager.started?(__MODULE__) do
      :ok = Manager.start(__MODULE__, sync: true)
    end
  end

  defp normalize_packet_messages(packet) do
    messages =
      packet
      |> Map.get(:messages, [])
      |> Enum.map(&normalize_packet_message/1)
      |> Enum.filter(& &1)

    if messages == [] do
      {:error, :empty_packet_messages}
    else
      {:ok, messages}
    end
  end

  defp normalize_packet_message(%{content: content} = message) when is_binary(content) do
    metadata =
      message
      |> Map.get(:metadata) ||
        Map.get(message, "metadata") ||
        %{}

    %{
      role: normalize_packet_role(Map.get(message, :role) || Map.get(message, "role")),
      content: content,
      metadata: metadata
    }
  end

  defp normalize_packet_message(_), do: nil

  defp normalize_packet_role(role) when role in [:system, :user, :assistant, :tool], do: role
  defp normalize_packet_role(:function), do: :tool

  defp normalize_packet_role(role) when is_binary(role) do
    case String.downcase(String.trim(role)) do
      "system" -> :system
      "assistant" -> :assistant
      "tool" -> :tool
      "function" -> :tool
      _ -> :user
    end
  end

  defp normalize_packet_role(_), do: :user

  defp packet_task_type(packet) do
    metadata = Map.get(packet, :metadata, %{})

    fetch_indifferent(metadata, :task_type) ||
      fetch_indifferent(metadata, "task")
  end

  defp fetch_indifferent(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_indifferent(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end

  defp fetch_indifferent(_, _), do: nil

  defp attach_commbus_context(opts, packet) do
    context =
      %{
        packet: packet,
        conversation: Map.get(packet, :conversation),
        sections: Map.get(packet, :sections, %{}),
        included_entries: Map.get(packet, :included_entries, []),
        excluded_entries: Map.get(packet, :excluded_entries, []),
        token_usage: Map.get(packet, :token_usage, %{}),
        metadata: Map.get(packet, :metadata, %{})
      }

    Keyword.update(opts, :commbus_packet, context, &Map.merge(&1, context))
  end

  @doc false
  @spec extract_response_format(Context.t(), keyword()) :: Context.t()
  def extract_response_format(%Context{opts: opts} = ctx, _opts) do
    {response_format, remaining_opts} = Keyword.pop(opts, :response_format)
    %{ctx | response_format: response_format, opts: remaining_opts}
  end
end
