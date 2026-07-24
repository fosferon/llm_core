defmodule LlmCore.Memory.Backend.ForesightHTTP do
  @moduledoc """
  Foresight's Hindsight-compatible HTTP backend.

  Foresight exposes the same wire protocol, so this backend shares the REST
  pipeline, cache, circuit breaker, retry, and write buffer with Hindsight.
  """

  @behaviour LlmCore.Memory.Backend

  alias LlmCore.Memory.Backend.HindsightREST

  @impl true
  defdelegate available?(), to: HindsightREST

  @impl true
  defdelegate retain(content, metadata, opts), to: HindsightREST

  @impl true
  defdelegate retain_sync(content, metadata, opts), to: HindsightREST

  @impl true
  defdelegate recall(query, opts), to: HindsightREST

  @impl true
  defdelegate reflect(query, opts), to: HindsightREST
end
