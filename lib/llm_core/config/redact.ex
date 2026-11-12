defmodule LlmCore.Config.Redact do
  @moduledoc """
  Redacts secret values from configuration before it is printed or echoed.

  ## By key

  A key names a secret when it is, or ends in (after `_` or `-`), one of: `api_key`, `api_keys`, `apikey`, `apikeys`, `key`,
  `keys`, `token`, `secret`, `secrets`, `password`, `passwd`, `credential`, `credentials`, `auth`,
  `authorization` or `bearer`; `tokens` counts only as the whole key. So `openai_api_key`, `access_key`,
  `aws_secret_access_key`, `bot_token`, `client_secret`, `x-api-key` and `proxy-authorization` are
  secret, while `max_tokens`, `tokens_per_minute`, `secret_name` and `credential_state` are not.

  Keys are matched wherever they appear, so a table whose own NAME ends in one of these words (a provider
  called `my_key`, a routing task called `auth`) is shown with its values redacted. Name such tables
  otherwise if their values are needed in `mix llm_core.config.show` output.

  A secret key holding a scalar is shown as `"[redacted]"`. One holding a map or list (an `auth` table, a
  `credentials` map) is walked with every scalar inside it redacted, so its shape stays visible.

  Keys ending in `_env` hold the NAME of an environment variable and are shown, but only while the value
  looks like one (`OPENAI_API_KEY`). A value that does not (for example a secret interpolated from
  `${VAR}`) is redacted.

  ## By value

  Every string is also scrubbed, whatever its key: a token after `Bearer ` (16 or more token characters,
  so prose such as "Bearer token support" is left alone) and the password in a URL's userinfo
  (`https://user:password@host`) are replaced with `[redacted]`.
  """

  @redacted "[redacted]"
  @secret ~r/(^|[_-])(api_?keys?|keys?|token|secrets?|password|passwd|credentials?|auth|authorization|bearer)$/i
  # A bare `tokens` is a credential list only as the whole key: `max_tokens` and `num_tokens` are counts.
  @secret_whole ~r/^tokens$/i
  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  # A token, not prose: at least 16 token characters after `Bearer `.
  @bearer ~r/\b(Bearer\s+)[A-Za-z0-9._~+\/=-]{16,}/i
  @userinfo ~r{(://[^/\s:@]*:)[^/\s@]+@}

  @doc "Whether `key` names a secret value (an `_env` key names a variable, so it does not)."
  @spec secret_key?(term()) :: boolean()
  def secret_key?(key) when is_atom(key) and not is_nil(key), do: secret_key?(Atom.to_string(key))

  def secret_key?(key) when is_binary(key) do
    not env_key?(key) and (Regex.match?(@secret, key) or Regex.match?(@secret_whole, key))
  end

  def secret_key?(_), do: false

  @doc "`term` with every secret value redacted (see the module documentation)."
  @spec config(term()) :: term()
  def config(term), do: walk(term, false)

  @doc "The redacted form of a value set under `path` (a dotted path or its segments)."
  @spec path_value([String.t()] | String.t(), term()) :: term()
  def path_value(path, value) when is_binary(path),
    do: path_value(String.split(path, ".", trim: true), value)

  def path_value(segments, value) when is_list(segments) do
    last = List.last(segments)

    cond do
      env_key?(last) -> walk_entry(last, value, Enum.any?(segments, &secret_key?/1))
      Enum.any?(segments, &secret_key?/1) -> walk(value, true)
      true -> walk(value, false)
    end
  end

  # `inside` is true below a secret key: every scalar is redacted except a variable name under `_env`.
  # A struct is walked field by field; its `__struct__` tag is kept (see `walk_entry/3`).
  defp walk(%{} = map, inside) do
    :maps.map(fn k, v -> walk_entry(k, v, inside) end, map)
  end

  defp walk(list, inside) when is_list(list) do
    Enum.map(list, fn
      {k, v} when is_atom(k) or is_binary(k) -> {k, walk_entry(k, v, inside)}
      other -> walk(other, inside)
    end)
  end

  defp walk(value, true) when is_nil(value) or value == "", do: value
  defp walk(value, true) when is_binary(value) or is_number(value), do: @redacted
  defp walk(value, _inside) when is_binary(value), do: scrub_string(value)
  defp walk(value, _inside), do: value

  defp walk_entry(:__struct__, v, _inside), do: v

  # The `_env` rule applies to a string value only: a table whose name ends in `_env` (a provider called
  # `foo_env`) is walked like any other.
  defp walk_entry(k, v, inside) do
    cond do
      env_key?(k) and is_binary(v) -> if Regex.match?(@env_name, v), do: v, else: @redacted
      secret_key?(k) -> walk(v, true)
      true -> walk(v, inside)
    end
  end

  defp env_key?(k) when is_atom(k) and not is_nil(k), do: env_key?(Atom.to_string(k))
  defp env_key?(k) when is_binary(k), do: String.ends_with?(String.downcase(k), "_env")
  defp env_key?(_), do: false

  defp scrub_string(value) do
    value
    |> then(&Regex.replace(@bearer, &1, "\\1" <> @redacted))
    |> then(&Regex.replace(@userinfo, &1, "\\1" <> @redacted <> "@"))
  end
end
