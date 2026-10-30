defmodule LlmCore.LLM.NativeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LlmCore.LLM.Error
  alias LlmCore.LLM.Native
  alias LlmCore.LLM.Response

  # try_cascade/2 is the runtime-failure walker used by Native.send
  # to iterate through candidates on provider error. We test it with a
  # stubbed runner function so the behavior is exercised without real
  # HTTP calls.

  # build_send_result/2 maps a Loop.run result to the provider boundary,
  # preserving bounded terminal diagnostics (GC-5523).

  describe "build_send_result/2" do
    test "success preserves provider metadata including finish_reason" do
      llm_response = %Response{
        content: "audit complete",
        provider: :appliance,
        model: "gpt-oss:120b",
        usage: %{total_tokens: 5},
        metadata: %{finish_reason: "stop", id: "req_1"}
      }

      assert {:ok, native} = Native.build_send_result({:ok, llm_response, []}, 42)

      assert native.content == "audit complete"
      assert native.provider == :native
      assert native.metadata.finish_reason == "stop"
      assert native.metadata.id == "req_1"
      assert native.metadata.model == "gpt-oss:120b"
      assert native.metadata.elapsed_ms == 42
      assert native.metadata.usage == %{total_tokens: 5}
    end

    test "success preserves blank-stop recovery marker" do
      llm_response = %Response{content: "ok", metadata: %{blank_stop_retries: 1}}

      assert {:ok, native} = Native.build_send_result({:ok, llm_response, []}, 1)

      assert native.metadata.blank_stop_retries == 1
    end

    test "typed empty_stop error preserves iteration and finish-reason context" do
      details = %{
        iteration: 2,
        attempts: 3,
        finish_reasons: ["stop", "stop", "stop"],
        provider: :appliance,
        model: "gpt-oss:120b"
      }

      assert {:error, %Error{} = error} =
               Native.build_send_result({:error, {:empty_stop, details}}, 5)

      assert error.type == :provider_error
      assert error.provider == :native
      assert error.details == details
      assert error.message =~ "empty stop"
      assert error.message =~ "3 attempts"
      assert error.message =~ "iteration 2"
    end

    test "max_iterations_reached keeps its dedicated message" do
      assert {:error, %Error{} = error} =
               Native.build_send_result({:error, :max_iterations_reached}, 5)

      assert error.message =~ "Iteration limit reached"
    end

    test "generic errors keep the inspect fallback" do
      assert {:error, %Error{} = error} =
               Native.build_send_result({:error, :econnrefused}, 5)

      assert error.message =~ ":econnrefused"
      assert error.details == nil
    end

    test "a candidate crash becomes a structured provider error (GC-5857)" do
      details = %{provider: Mod1, exception: "boom", kind: :error}

      assert {:error, %Error{} = error} =
               Native.build_send_result({:error, {:crashed, details}}, 5)

      assert error.type == :provider_error
      assert error.provider == :native
      assert error.details == details
      assert error.message =~ "Mod1"
      assert error.message =~ "boom"
      refute error.message =~ "Native dispatch error:"
    end
  end

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

    test "every candidate failing returns every attempt, not just the last error" do
      run = fn
        {Mod1, _, _} -> {:error, :timeout}
        {Mod2, _, _} -> {:error, :auth_failed}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:error,
              {:cascade_exhausted,
               %{
                 last: :auth_failed,
                 attempts: [
                   %{provider: Mod1, reason: :timeout},
                   %{provider: Mod2, reason: :auth_failed}
                 ]
               }}} = Native.try_cascade(candidates, run)
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

    test "empty_stop advances the cascade to the next provider (GC-5523)" do
      # A degenerate backend (blank stop after blank stop) is provider-specific
      # behavior — another backend may complete the same task.
      run = fn
        {Mod1, _, _} -> {:error, {:empty_stop, %{iteration: 2, attempts: 3}}}
        {Mod2, _, _} -> {:ok, %{content: "completed on fallback"}, []}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:ok, %{content: "completed on fallback"}, []} =
               Native.try_cascade(candidates, run)
    end

    test "a crashing candidate is isolated and the cascade advances (GC-5857)" do
      calls = :counters.new(1, [])

      run = fn
        {Mod1, _, _} ->
          :counters.add(calls, 1, 1)
          raise CaseClauseError, term: {:status, make_ref(), 200}

        {Mod2, _, _} ->
          :counters.add(calls, 1, 1)
          {:ok, %{content: "recovered on fallback"}, [:msg]}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      log =
        capture_log(fn ->
          assert {:ok, %{content: "recovered on fallback"}, [:msg]} =
                   Native.try_cascade(candidates, run)
        end)

      assert :counters.get(calls, 1) == 2
      assert log =~ "Mod1"
    end

    test "a crashing candidate exit is isolated too (GC-5857)" do
      run = fn
        {Mod1, _, _} -> exit(:stale_pooled_socket)
        {Mod2, _, _} -> {:ok, %{content: "survived exit"}, []}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:ok, %{content: "survived exit"}, []} = Native.try_cascade(candidates, run)
    end

    test "crashes are recorded in cascade exhaustion (GC-5857)" do
      run = fn
        {Mod1, _, _} -> raise "boom-1"
        {Mod2, _, _} -> {:error, :timeout}
      end

      candidates = [{Mod1, "m1", []}, {Mod2, "m2", []}]

      assert {:error,
              {:cascade_exhausted,
               %{
                 last: :timeout,
                 attempts: [
                   %{
                     provider: Mod1,
                     reason: {:crashed, %{provider: Mod1, exception: "boom-1", kind: :error}}
                   },
                   %{provider: Mod2, reason: :timeout}
                 ]
               }}} = Native.try_cascade(candidates, run)
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

  describe "build_send_result/2 structured resolution errors" do
    test "cascade_exhausted names every attempt so the first failure is visible" do
      details = %{
        last: :auth_failed,
        attempts: [%{provider: Mod1, reason: :timeout}, %{provider: Mod2, reason: :auth_failed}]
      }

      assert {:error, %LlmCore.LLM.Error{message: message, details: ^details}} =
               Native.build_send_result({:error, {:cascade_exhausted, details}}, 5)

      assert message =~ "Mod1"
      assert message =~ ":timeout"
      assert message =~ ":auth_failed"
    end

    test "no_native_provider explains what to configure and what was skipped" do
      details = %{
        reason: :cascade_unusable,
        fallback: nil,
        skipped: [%{provider: "x", reason: :no_credentials}]
      }

      assert {:error, %LlmCore.LLM.Error{message: message, details: ^details}} =
               Native.build_send_result({:error, {:no_native_provider, details}}, 5)

      assert message =~ "[native] cascade"
      assert message =~ "[routing] default"
      assert message =~ "x (no_credentials)"
    end
  end

  describe "probe connection isolation (GC-5857)" do
    test "model availability probe sends connection: close" do
      model = "probe-model-#{System.unique_integer([:positive])}"
      body = ~s({"data":[{"id":"#{model}"}]})
      {port, request_task} = start_probe_server(body)

      assert Native.model_available_on_appliance?(model,
               endpoint_url: "http://127.0.0.1:#{port}"
             )

      request = Task.await(request_task, 5_000)

      assert request =~ "GET /v1/models"
      assert String.downcase(request) =~ "connection: close"
    end

    test "probe options isolate the request and bound the pool wait" do
      opts = Native.probe_options()

      assert opts[:headers] == [{"connection", "close"}]
      assert opts[:pool_timeout] == 3_000
      assert opts[:receive_timeout] == 3_000
      assert opts[:retry] == false
    end
  end

  defp start_probe_server(body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        request = recv_request_headers(socket, "")

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        request
      end)

    {port, task}
  end

  defp recv_request_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> recv_request_headers(socket, acc <> chunk)
        {:error, _} -> acc
      end
    end
  end
end
