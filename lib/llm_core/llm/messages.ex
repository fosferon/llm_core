defmodule LlmCore.LLM.Messages do
  @moduledoc """
  Normalizes prompts into the chat message format used by API providers.

  Handles standard roles (`:system`, `:user`, `:assistant`) and the `:tool`
  role natively — tool messages are preserved with their `tool_call_id` rather
  than being collapsed into `:user` messages. Provider adapters are responsible
  for any further format translation (e.g. Anthropic wraps tool results in
  `user` role with `tool_result` content blocks).
  """

  @doc """
  Normalizes prompts into the chat message format used by API providers.

  Accepts a string, a list of message maps (atom or string keys), or any
  term that implements `String.Chars`. Tool-role messages retain their
  `tool_call_id` field when present.
  """
  @spec normalize_chat(String.t() | [map()] | any()) :: [map()]
  def normalize_chat(prompt) when is_list(prompt) do
    prompt
    |> Enum.filter(&valid_message?/1)
    |> Enum.map(&normalize_message/1)
    |> case do
      [] -> normalize_chat("")
      messages -> messages
    end
  end

  def normalize_chat(prompt) when is_binary(prompt) do
    [%{"role" => "user", "content" => prompt}]
  end

  def normalize_chat(prompt) do
    [%{"role" => "user", "content" => to_string(prompt)}]
  end

  @doc """
  Renders prompts for CLI providers.
  """
  @spec render_cli_prompt(String.t() | [map()] | any()) :: String.t()
  def render_cli_prompt(prompt) when is_binary(prompt), do: prompt

  def render_cli_prompt(prompt) when is_list(prompt) do
    prompt
    |> Enum.filter(&valid_message?/1)
    |> Enum.map(&render_cli_message/1)
    |> Enum.join("\n")
  end

  def render_cli_prompt(prompt), do: to_string(prompt)

  # ---------------------------------------------------------------------------
  # Message normalization
  # ---------------------------------------------------------------------------

  defp normalize_message(%{role: :tool, content: content} = msg) do
    base = %{"role" => "tool", "content" => content}
    tool_call_id = Map.get(msg, :tool_call_id)
    maybe_put_tool_call_id(base, tool_call_id)
  end

  defp normalize_message(%{"role" => "tool", "content" => content} = msg) do
    base = %{"role" => "tool", "content" => content}
    tool_call_id = Map.get(msg, "tool_call_id")
    maybe_put_tool_call_id(base, tool_call_id)
  end

  # Assistant message carrying tool calls — preserve them in OpenAI wire shape.
  # The generic role/content clause below ALSO matches this map (extra keys are
  # ignored) and would silently DROP `tool_calls`, orphaning the following
  # tool-result message (a tool_result with no preceding tool_use) so providers
  # reject the whole conversation. Tool calls MUST round-trip on the assistant
  # message that made them.
  defp normalize_message(%{role: :assistant, tool_calls: tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    %{"role" => "assistant", "content" => normalize_assistant_content(Map.get(msg, :content))}
    |> Map.put("tool_calls", normalize_tool_calls(tool_calls))
  end

  defp normalize_message(%{"role" => "assistant", "tool_calls" => tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    %{"role" => "assistant", "content" => normalize_assistant_content(Map.get(msg, "content"))}
    |> Map.put("tool_calls", normalize_tool_calls(tool_calls))
  end

  defp normalize_message(%{role: role, content: content}) do
    %{"role" => role_to_string(role), "content" => content}
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{"role" => role_to_string(role), "content" => content}
  end

  defp maybe_put_tool_call_id(msg, nil), do: msg
  defp maybe_put_tool_call_id(msg, id), do: Map.put(msg, "tool_call_id", id)

  # OpenAI allows `content: null` on an assistant message that carries
  # tool_calls; normalize a missing/nil content to "" for gateway compatibility.
  defp normalize_assistant_content(content) when is_binary(content), do: content
  defp normalize_assistant_content(_), do: ""

  defp normalize_tool_calls(calls), do: Enum.map(calls, &normalize_tool_call/1)

  # Already in OpenAI wire shape — pass through untouched.
  defp normalize_tool_call(%{"type" => "function", "function" => _} = call), do: call

  # `LlmToolkit.Tool.Call` structs and generic id/name/arguments maps (atom or
  # string keys) — both are plain maps here. OpenAI expects `function.arguments`
  # as a JSON-encoded STRING; the internal Tool.Call carries a decoded map.
  defp normalize_tool_call(call) when is_map(call) do
    id = Map.get(call, :id) || Map.get(call, "id")
    name = Map.get(call, :name) || Map.get(call, "name")
    arguments = Map.get(call, :arguments) || Map.get(call, "arguments") || %{}

    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => encode_tool_arguments(arguments)}
    }
  end

  defp encode_tool_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_tool_arguments(arguments), do: Jason.encode!(arguments)

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the given map looks like a valid chat message.

  Accepts both atom-keyed (`%{role: :user, content: "..."}`) and
  string-keyed (`%{"role" => "user", "content" => "..."}`) maps.
  Tool-role messages are accepted with or without a `tool_call_id`.
  """
  @spec valid_message?(map()) :: boolean()
  # An assistant message carrying tool calls is valid even when its content is
  # nil/absent (a pure tool-call turn) — it must survive the filter so its
  # tool_calls reach the wire.
  def valid_message?(%{role: :assistant, tool_calls: tool_calls})
      when is_list(tool_calls) and tool_calls != [],
      do: true

  def valid_message?(%{"role" => "assistant", "tool_calls" => tool_calls})
      when is_list(tool_calls) and tool_calls != [],
      do: true

  def valid_message?(%{role: role, content: content})
      when role in [:system, :user, :assistant, :tool] and is_binary(content),
      do: true

  def valid_message?(%{"role" => role, "content" => content}) when is_binary(content) do
    role in ["system", "user", "assistant", "tool"]
  end

  def valid_message?(_), do: false

  defp render_cli_message(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"] || ""
    tool_call_id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")

    base =
      case {role_to_string(role), tool_call_id} do
        {"tool", id} when is_binary(id) -> "[tool id=#{id}] #{content}"
        {role_name, _} -> "[#{role_name}] #{content}"
      end

    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      calls when is_list(calls) and calls != [] ->
        payload =
          Enum.map(calls, fn call ->
            %{
              "id" => Map.get(call, :id) || Map.get(call, "id"),
              "name" => Map.get(call, :name) || Map.get(call, "name"),
              "arguments" => Map.get(call, :arguments) || Map.get(call, "arguments") || %{}
            }
          end)

        base <>
          "\n```llm_core_tool_calls\n" <>
          Jason.encode!(%{"tool_calls" => payload}) <>
          "\n```"

      _ ->
        base
    end
  end

  defp role_to_string(role) when role in [:system, :user, :assistant, :tool],
    do: Atom.to_string(role)

  defp role_to_string(role) when is_binary(role), do: role
  defp role_to_string(_), do: "user"
end
