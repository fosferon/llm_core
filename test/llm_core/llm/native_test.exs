defmodule LlmCore.LLM.NativeTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.Native

  # try_cascade/2 is the runtime-failure walker used by Native.send
  # to iterate through candidates on provider error. We test it with a
  # stubbed runner function so the behavior is exercised without real
  # HTTP calls.

  describe "try_cascade/2" do
    test "returns first candidate's success without calling the rest" do
      calls = :counters.new(1, [])

      run = fn
        {Mod1, _, _} ->
          :counters.add(calls, 1, 1)
          {:ok, %{content: "ok1"}, [:msg]}

        _ ->
          flunk("second candidate should not be called")
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:ok, %{content: "ok1"}, [:msg]} = Native.try_cascade(candidates, run)
      assert :counters.get(calls, 1) == 1
    end

    test "falls through to next candidate on transient error" do
      run = fn
        {Mod1, _, _} -> {:error, :econnrefused}
        {Mod2, _, _} -> {:ok, %{content: "fallback ok"}, [:msg]}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:ok, %{content: "fallback ok"}, [:msg]} = Native.try_cascade(candidates, run)
    end

    test "walks multiple failures before succeeding" do
      run = fn
        {Mod1, _, _} -> {:error, :timeout}
        {Mod2, _, _} -> {:error, {:http, 502}}
        {Mod3, _, _} -> {:ok, %{content: "third time lucky"}, [:msg]}
      end

      candidates = [
        {Mod1, "m1", []},
        {Mod2, "m2", []},
        {Mod3, "m3", []}
      ]

      assert {:ok, %{content: "third time lucky"}, [:msg]} =
               Native.try_cascade(candidates, run)
    end

    test "returns last error when every candidate fails" do
      run = fn
        {Mod1, _, _} -> {:error, :timeout}
        {Mod2, _, _} -> {:error, :auth_failed}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:error, :auth_failed} = Native.try_cascade(candidates, run)
    end

    test ":max_iterations_reached stops cascade immediately" do
      # Hitting the iteration budget is a reasoning/budget failure, not a
      # provider outage — don't retry the same question on another model.
      calls = :counters.new(1, [])

      run = fn
        {Mod1, _, _} ->
          :counters.add(calls, 1, 1)
          {:error, :max_iterations_reached}

        _ ->
          flunk("cascade should halt on max_iterations_reached")
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:error, :max_iterations_reached} = Native.try_cascade(candidates, run)
      assert :counters.get(calls, 1) == 1
    end

    test "empty candidate list returns a clear error" do
      run = fn _ -> flunk("runner should not be called with empty list") end

      assert {:error, :no_provider_succeeded} = Native.try_cascade([], run)
    end

    test "single candidate failure surfaces the raw error" do
      run = fn _ -> {:error, :econnrefused} end
      assert {:error, :econnrefused} = Native.try_cascade([{Mod1, "m1", []}], run)
    end
  end
end
