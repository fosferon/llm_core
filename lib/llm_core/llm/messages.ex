defmodule LlmCore.LLM.Messages do
  @moduledoc false

  @doc """
  Normalizes prompts into the chat message format used by API providers.
  """
  @spec normalize_chat(String.t() | [map()] | any()) :: [map()]
  def normalize_chat(prompt) when is_list(prompt) do
    prompt
    |> Enum.filter(&valid_message?/1)
    |> Enum.map(fn %{role: role, content: content} ->
      %{"role" => role_to_string(role), "content" => content}
    end)
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
    |> Enum.map(fn %{role: role, content: content} ->
      "[#{role_to_string(role)}] #{content}"
    end)
    |> Enum.join("\n")
  end

  def render_cli_prompt(prompt), do: to_string(prompt)

  defp valid_message?(%{role: role, content: content})
       when role in [:system, :user, :assistant, :tool] and is_binary(content),
       do: true

  defp valid_message?(%{"role" => role, "content" => content}) when is_binary(content) do
    role in ["system", "user", "assistant", "tool"]
  end

  defp valid_message?(_), do: false

  defp role_to_string(role) when role in [:system, :user, :assistant, :tool],
    do: Atom.to_string(role)

  defp role_to_string(role) when is_binary(role), do: role
  defp role_to_string(_), do: "user"
end
