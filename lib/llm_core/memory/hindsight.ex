defmodule LlmCore.Memory.Hindsight do
  @moduledoc """
  Deprecated compatibility facade for the backend-neutral memory API.

  Use `LlmCore.Memory` for new integrations.
  """

  alias LlmCore.Memory
  alias LlmCore.Memory.Backend.HindsightREST

  @deprecated "Use LlmCore.Memory.available?/0"
  defdelegate available?(), to: Memory

  @deprecated "Use LlmCore.Memory.retain/3"
  def retain(content, metadata \\ %{}, opts \\ []), do: Memory.retain(content, metadata, opts)

  @deprecated "Use LlmCore.Memory.retain_sync/3"
  def retain_sync(content, metadata \\ %{}, opts \\ []) do
    Memory.retain_sync(content, metadata, opts)
  end

  @deprecated "Use LlmCore.Memory.recall/2"
  def recall(query, opts \\ []), do: Memory.recall(query, opts)

  @deprecated "Use LlmCore.Memory.reflect/2"
  def reflect(query, opts \\ []), do: Memory.reflect(query, opts)

  defdelegate url(), to: HindsightREST
  defdelegate health_check(), to: HindsightREST
  def list_banks(opts \\ []), do: HindsightREST.list_banks(opts)
  def create_bank(bank_id, opts \\ []), do: HindsightREST.create_bank(bank_id, opts)
  def delete_bank(bank_id, opts \\ []), do: HindsightREST.delete_bank(bank_id, opts)
  def bank_stats(bank_id, opts \\ []), do: HindsightREST.bank_stats(bank_id, opts)

  @doc false
  defdelegate do_retain(url, content, metadata, opts), to: HindsightREST

  @doc false
  defdelegate do_recall(url, query, opts), to: HindsightREST

  @doc false
  defdelegate do_reflect(url, question, opts), to: HindsightREST

  @doc false
  defdelegate rest_post(base_url, path, body, timeout, opts \\ []), to: HindsightREST

  @doc false
  defdelegate build_headers(api_key \\ nil), to: HindsightREST

  @doc false
  defdelegate report_result(result), to: HindsightREST

  @doc false
  defdelegate resolve_bank_id(opts), to: HindsightREST

  @doc false
  defdelegate normalize_budget(budget), to: HindsightREST

  @doc false
  defdelegate maybe_put(map, key, value), to: HindsightREST

  @doc false
  defdelegate maybe_put_new(map, key, value), to: HindsightREST

  @doc false
  defdelegate enrich_metadata(metadata, opts), to: HindsightREST
end
