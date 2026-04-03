if Code.ensure_loaded?(Instructor.Adapter) do
  defmodule LlmCore.Structured.InstructorAdapter do
    @moduledoc """
    Instructor adapter that routes requests through `llm_core`.

    The adapter keeps the Instructor workflow intact (validation, retries,
    streaming) while delegating the actual completions to `LlmCore.Router`.

    ## Supported Options

      * `:task_type` - Router task type (default: "default")
      * `:messages`  - Chat messages in the Instructor format
      * `:prompt`    - Raw string prompt (fallback when `:messages` missing)
      * `:llm_opts`  - Options forwarded to the inference pipeline
      * `:router_opts` - Additional router options (merged with `:llm_opts`)
      * `:routing_table` - Override routing table for deterministic tests
    """

    @behaviour Instructor.Adapter

    alias LlmCore.LLM.Response

    @doc """
    Routes an Instructor completion request through the llm_core router.
    """
    @impl true
    @spec chat_completion(keyword(), term()) :: {:ok, term(), String.t()} | {:error, String.t()} | Enumerable.t()
    def chat_completion(params, _config) do
      task_type = Keyword.get(params, :task_type, "default")
      stream? = Keyword.get(params, :stream, false)

      with {:ok, prompt} <- build_prompt(params) do
        opts = build_router_opts(params)

        if stream? do
          stream_response(prompt, task_type, opts)
        else
          send_response(prompt, task_type, opts)
        end
      end
    end

    @doc """
    Returns an empty list — llm_core does not generate re-ask messages.
    """
    @impl true
    @spec reask_messages(term(), keyword(), term()) :: []
    def reask_messages(_raw_response, _params, _config), do: []

    @doc false
    @spec available?() :: true
    def available?, do: true

    defp build_prompt(params) do
      cond do
        Keyword.has_key?(params, :messages) ->
          messages = Keyword.get(params, :messages, [])
          {:ok, Enum.map(messages, &normalize_message/1)}

        prompt = Keyword.get(params, :prompt) ->
          {:ok, prompt}

        true ->
          {:error, "Instructor adapter expects :messages or :prompt"}
      end
    end

    defp build_router_opts(params) do
      llm_opts = Keyword.get(params, :llm_opts, [])
      router_opts = Keyword.get(params, :router_opts, [])

      (router_opts ++ llm_opts)
      |> maybe_put(:routing_table, Keyword.get(params, :routing_table))
    end

    defp send_response(prompt, task_type, opts) do
      case LlmCore.Router.send(prompt, task_type, opts) do
        {:ok, %Response{} = response} -> {:ok, response, response.content}
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end

    defp stream_response(prompt, task_type, opts) do
      case LlmCore.Router.stream(prompt, task_type, opts) do
        {:ok, stream} -> Stream.map(stream, &to_chunk/1)
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end

    defp normalize_message(%{role: role, content: content} = message) do
      role_atom =
        case role do
          r when r in [:system, :user, :assistant, :tool] -> r
          r when is_binary(r) -> normalize_role_string(r)
          _ -> :user
        end

      %{
        role: role_atom,
        content: Map.get(message, :content, Map.get(message, "content", content))
      }
    end

    defp normalize_message(message) when is_map(message) do
      role = Map.get(message, :role) || Map.get(message, "role") || :user
      content = Map.get(message, :content) || Map.get(message, "content") || ""
      normalize_message(%{role: role, content: content})
    end

    defp normalize_message(other), do: other

    defp normalize_role_string(role) do
      case String.downcase(role) do
        "system" -> :system
        "assistant" -> :assistant
        "tool" -> :tool
        _ -> :user
      end
    end

    defp to_chunk(chunk) when is_binary(chunk), do: chunk
    defp to_chunk(chunk), do: to_string(chunk)

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

    defp format_reason(%struct{} = reason), do: inspect(struct)
    defp format_reason(reason), do: inspect(reason)
  end
else
  defmodule LlmCore.Structured.InstructorAdapter do
    @moduledoc """
    Placeholder adapter returned when the optional `Instructor` dependency
    is not available.
    """

    @doc false
    @spec available?() :: false
    def available?, do: false

    @doc false
    @spec chat_completion(keyword(), term()) :: {:error, String.t()}
    def chat_completion(_params, _config), do: {:error, "Instructor dependency not available"}

    @doc false
    @spec reask_messages(term(), keyword(), term()) :: []
    def reask_messages(_raw_response, _params, _config), do: []
  end
end
