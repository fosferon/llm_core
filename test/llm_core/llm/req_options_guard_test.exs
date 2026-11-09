defmodule LlmCore.LLM.ReqOptionsGuardTest do
  # Structural guard for the Req 0.6.1 change: decompression is opt-in, so every
  # non-streaming Req call in lib/ must pass `compressed: true` (or use a shared
  # options helper that does). Streaming calls (`into:`) are exempt by design.
  # http_compression_test.exs proves the behaviour on one provider; this test
  # stops any other call site from silently dropping the option.
  use ExUnit.Case, async: true

  @verbs [:get, :post, :put, :delete, :request]
  @option_helpers [:probe_options]

  test "every non-streaming Req call sets compressed: true" do
    offenders =
      Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__))
      |> Enum.flat_map(&offending_calls/1)

    assert offenders == [], "Req calls without compressed: true:\n" <> Enum.join(offenders, "\n")
  end

  test "the guard sees the call sites (not vacuous)" do
    count =
      Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__))
      |> Enum.map(&(&1 |> req_calls() |> length()))
      |> Enum.sum()

    assert count >= 12
  end

  test "the shared probe options request decompression" do
    assert LlmCore.LLM.Appliance.probe_options(1_000)[:compressed] == true
  end

  defp offending_calls(file) do
    file
    |> req_calls()
    |> Enum.reject(fn {_line, opts} -> compliant?(opts) end)
    |> Enum.map(fn {line, _} -> "#{Path.relative_to_cwd(file)}:#{line}" end)
  end

  defp req_calls(file) do
    {_ast, acc} =
      file
      |> File.read!()
      |> Code.string_to_quoted!(columns: false)
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, [:Req]}, verb]}, meta, args} = node, acc
        when verb in @verbs and is_list(args) ->
          {node, [{meta[:line], Enum.at(args, 1)} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp compliant?(opts) when is_list(opts) do
    Keyword.has_key?(opts, :into) or Keyword.get(opts, :compressed) == true
  end

  defp compliant?({helper, _, _}) when helper in @option_helpers, do: true
  defp compliant?(_), do: false
end
