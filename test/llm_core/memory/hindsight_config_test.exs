defmodule LlmCore.Memory.Hindsight.ConfigTest do
  use ExUnit.Case, async: true

  alias LlmCore.Memory.Hindsight.Config

  setup do
    previous_bank = System.get_env("HINDSIGHT_BANK_ID")
    previous_default = System.get_env("HINDSIGHT_DEFAULT_BANK")

    on_exit(fn ->
      put_env("HINDSIGHT_BANK_ID", previous_bank)
      put_env("HINDSIGHT_DEFAULT_BANK", previous_default)
    end)

    :ok
  end

  test "effective_bank_id prefers explicit env override" do
    System.put_env("HINDSIGHT_BANK_ID", "env-bank")
    System.put_env("HINDSIGHT_DEFAULT_BANK", "fallback-bank")

    assert Config.effective_bank_id() == "env-bank"
  end

  test "effective_bank_id uses default env when primary unset" do
    System.delete_env("HINDSIGHT_BANK_ID")
    System.put_env("HINDSIGHT_DEFAULT_BANK", "shared-bank")

    assert Config.effective_bank_id() == "shared-bank"
  end

  defp put_env(key, nil), do: System.delete_env(key)
  defp put_env(key, value), do: System.put_env(key, value)
end
