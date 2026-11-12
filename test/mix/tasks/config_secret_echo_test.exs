defmodule Mix.Tasks.LlmCore.ConfigSecretEchoTest do
  # config.show and config.set never print a secret value: not an inline one, not one interpolated from
  # `${VAR}`, and not the value just set.
  use ExUnit.Case, async: false

  @synthetic "synthetic-secret-0002"
  @var "LLM_CORE_SYNTHETIC_KEY"

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    previous_var = System.get_env(@var)
    System.put_env(@var, @synthetic)

    dir = Path.join(System.tmp_dir!(), "llm_core_redact_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Mix.shell(previous_shell)
      if previous_var, do: System.put_env(@var, previous_var), else: System.delete_env(@var)
      File.rm_rf(dir)
      LlmCore.Memory.Config.clear_runtime_override()
      LlmCore.Memory.Hindsight.Config.clear_runtime_override()
      LlmCore.Config.Loader.reload_providers()
    end)

    {:ok, dir: dir}
  end

  test "config.show (raw and providers, text and json) prints no secret value", %{dir: dir} do
    file = Path.join(dir, "llm_core.toml")

    File.write!(file, """
    [providers.prov_inline]
    type = "cli"
    enabled = true
    api_key = "#{@synthetic}"

    [providers.prov_inline.cli]
    binary = "echo"

    [providers.prov_env]
    type = "cli"
    enabled = true
    api_key = "${#{@var}}"

    [providers.prov_env.cli]
    binary = "echo"
    """)

    # Positive control: unredacted, the loaded config holds the value both inline and interpolated, so
    # the refutes below test the redaction and not an empty payload.
    {:ok, _} = LlmCore.Config.Loader.reload_providers(path: file)
    {:ok, raw} = LlmCore.Config.Store.fetch(:config, :raw)
    assert get_in(raw, ["providers", "prov_inline", "api_key"]) == @synthetic
    assert get_in(raw, ["providers", "prov_env", "api_key"]) == @synthetic

    for args <- [["--section", "raw"], ["--section", "raw", "--json"], ["--section", "providers"]] do
      Mix.Task.rerun("llm_core.config.show", args ++ ["--path", file])
      out = drain()
      refute out =~ @synthetic, "config.show #{Enum.join(args, " ")} printed a secret value"
    end
  end

  test "config.set does not echo a secret it set, and still echoes others", %{dir: dir} do
    file = Path.join(dir, "llm_core.toml")
    File.write!(file, "")

    Mix.Task.rerun("llm_core.config.set", [
      "--path",
      "providers.prov.api_key",
      "--value",
      @synthetic,
      "--file",
      file,
      "--no-reload"
    ])

    out = drain()
    refute out =~ @synthetic
    assert out =~ ~s(New value: "[redacted]")

    Mix.Task.rerun("llm_core.config.set", [
      "--path",
      "providers.prov.model",
      "--value",
      "m-1",
      "--file",
      file,
      "--no-reload"
    ])

    assert drain() =~ ~s(New value: "m-1")
  end

  defp drain(acc \\ []) do
    receive do
      {:mix_shell, _kind, [msg]} -> drain([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
