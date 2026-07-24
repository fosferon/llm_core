defmodule LlmCore.Memory.Request do
  @moduledoc false

  @default_bank "default"

  @spec normalize_budget(atom() | String.t() | nil) :: String.t()
  def normalize_budget(nil), do: "low"

  def normalize_budget(budget) when is_atom(budget),
    do: budget |> Atom.to_string() |> String.downcase()

  def normalize_budget(budget) when is_binary(budget), do: String.downcase(budget)
  def normalize_budget(_budget), do: "low"

  @spec structured_question(atom(), keyword()) :: String.t()
  def structured_question(:workflow_effectiveness, opts) do
    workflow = Keyword.get(opts, :workflow, "default")

    "What is the effectiveness of the #{workflow} workflow? Include success rate and average duration."
  end

  def structured_question(:common_failures, _opts) do
    "What are the most common failure patterns? List the top 5 with frequency."
  end

  def structured_question(:project_insights, _opts) do
    "What are the key learnings and patterns for this project?"
  end

  def structured_question(:cross_project, _opts) do
    "What patterns have been successful across multiple projects?"
  end

  @spec resolve_bank_id(keyword(), String.t() | nil) :: String.t()
  def resolve_bank_id(opts, default_bank_id \\ nil) do
    opts[:target_bank] || opts[:bank_id] || default_bank_id || @default_bank
  end

  @spec context(map(), keyword()) :: String.t()
  def context(metadata, opts) do
    Keyword.get(opts, :context) || metadata[:context] || metadata["context"] || "general"
  end

  @spec retain_payload(String.t(), map(), boolean(), keyword()) :: map()
  def retain_payload(content, metadata, async?, opts) do
    %{
      "items" => [%{"content" => content, "context" => context(metadata, opts)}],
      "async" => async?
    }
  end
end
