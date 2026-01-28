defmodule LlmCore.Structured.JsonMode do
  @moduledoc """
  Helpers for working with providers that support JSON-mode outputs.

  The helpers exposed here are intentionally lightweight so they can be used
  from providers, pipelines, and tests without introducing new dependencies.
  """

  alias LlmCore.LLM.Response

  @type decoded :: map() | list()

  @doc """
  Decodes the response content into a map/list.

  When the content is already a map or list (for example, the provider returns
  parsed JSON), it is returned as-is.
  """
  @spec decode(Response.t() | binary() | decoded()) :: {:ok, decoded()} | {:error, term()}
  def decode(%Response{content: content}), do: decode(content)

  def decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  def decode(content) when is_map(content) or is_list(content), do: {:ok, content}
  def decode(_), do: {:error, :missing_content}

  @doc """
  Ensures the options passed to a provider request include JSON formatting.

  Providers that already set `:format` or `:response_format` are left untouched.
  """
  @spec enforce(keyword()) :: keyword()
  def enforce(opts) when is_list(opts) do
    format = Keyword.get(opts, :format) || Keyword.get(opts, :response_format)

    if format in [:json, "json", :json_schema] do
      opts
    else
      Keyword.put(opts, :format, "json")
    end
  end
end
