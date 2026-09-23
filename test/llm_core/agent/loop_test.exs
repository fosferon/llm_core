defmodule LlmCore.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias LlmCore.Agent.Loop
  alias LlmCore.LLM.Response
  alias LlmToolkit.Tool
  alias LlmToolkit.Tool.Call

  describe "run/3 terminal_tool" do
    test "opt-off keeps a same-named tool on the normal dispatch path" do
      parent = self()
      args = %{"answer" => "done", "memory_ids" => ["m1"]}
      terminal_call = %Call{id: "call_done", name: "done", arguments: args}

      llm_send =
        scripted_llm([
          %Response{content: nil, tool_calls: [terminal_call]},
          %Response{content: "final text", tool_calls: nil}
        ])

      resolve_tool = fn call ->
        send(parent, {:resolved, call})
        {:ok, "executed #{call.name}"}
      end

      assert {:ok, response, final_messages} =
               Loop.run([%{role: :user, content: "finish"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: resolve_tool,
                 max_iterations: 3
               )

      assert response.content == "final text"
      assert response.metadata == nil
      assert_receive {:resolved, ^terminal_call}

      assert [
               %{role: :user, content: "finish"},
               %{role: :assistant, content: nil, tool_calls: [^terminal_call]},
               %{role: :tool, tool_call_id: "call_done", content: "executed done"}
             ] = final_messages
    end

    test "opt-on terminal tool halts with raw args and is not dispatched" do
      parent = self()

      args = %{
        "answer" => "synthesized answer",
        "memory_ids" => ["m1"],
        "observation_ids" => ["o1"],
        "mental_model_ids" => ["mm1"]
      }

      terminal_call = %Call{id: "call_done", name: "done", arguments: args}

      llm_send =
        scripted_llm([
          %Response{
            content: nil,
            metadata: %{request_id: "req_1"},
            tool_calls: [terminal_call]
          }
        ])

      resolve_tool = fn call ->
        send(parent, {:resolved, call})
        {:ok, "should not run"}
      end

      initial_messages = [%{role: :user, content: "reflect"}]

      assert {:ok, response, ^initial_messages} =
               Loop.run(initial_messages, llm_send,
                 tools: [done_tool()],
                 resolve_tool: resolve_tool,
                 terminal_tool: "done",
                 max_iterations: 3
               )

      assert response.metadata.request_id == "req_1"
      assert response.metadata.terminal_tool == "done"
      assert response.metadata.terminal_args == args
      assert response.metadata.terminal_tool_call == terminal_call
      refute_receive {:resolved, ^terminal_call}
    end

    test "opt-on still terminates normally when the model returns plain text" do
      llm_send =
        scripted_llm([
          %Response{content: "plain final answer", tool_calls: nil}
        ])

      initial_messages = [%{role: :user, content: "answer directly"}]

      assert {:ok, response, ^initial_messages} =
               Loop.run(initial_messages, llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 max_iterations: 3
               )

      assert response.content == "plain final answer"
      assert response.metadata == nil
    end
  end

  describe "run/3 blank-stop recovery (GC-5523)" do
    test "transient blank stop recovers and completes with recovery marker" do
      llm_send =
        scripted_llm([
          blank_stop_response(),
          %Response{content: "recovered final text", tool_calls: nil}
        ])

      assert {:ok, response, _messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 max_iterations: 5
               )

      assert response.content == "recovered final text"
      assert response.metadata.blank_stop_retries == 1
    end

    test "repeated blank stops terminate with typed empty_stop error" do
      llm_send =
        scripted_llm([
          blank_stop_response(),
          blank_stop_response(),
          blank_stop_response()
        ])

      assert {:error,
              {
                :empty_stop,
                %{
                  iteration: 0,
                  attempts: 3,
                  finish_reasons: ["stop", "stop", "stop"],
                  provider: :appliance,
                  model: "gpt-oss:120b"
                }
              }} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 max_iterations: 5
               )
    end

    test "custom max_blank_stops: 1 terminates on the first blank" do
      llm_send = scripted_llm([blank_stop_response()])

      assert {:error, {:empty_stop, %{attempts: 1}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 max_iterations: 5,
                 max_blank_stops: 1
               )
    end

    test "blank stop during a tool-driven task reports the failing iteration" do
      call = %Call{id: "c1", name: "echo", arguments: %{}}

      llm_send =
        scripted_llm([
          %Response{content: nil, tool_calls: [call]},
          blank_stop_response(),
          blank_stop_response(),
          blank_stop_response()
        ])

      assert {:error, {:empty_stop, %{iteration: 1, attempts: 3}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 max_iterations: 5
               )
    end

    test "blank-stop nudge is appended to messages before the retry" do
      parent = self()

      capture_llm = fn responses ->
        pid = start_supervised!({Agent, fn -> responses end})

        fn messages, _opts ->
          send(parent, {:llm_call, messages})

          Agent.get_and_update(pid, fn
            [next | rest] -> {{:ok, next}, rest}
            [] -> {{:error, :no_more_responses}, []}
          end)
        end
      end

      nudge = "Your previous response was empty. Call a tool or answer."

      llm_send =
        capture_llm.([
          blank_stop_response(),
          %Response{content: "final after nudge", tool_calls: nil}
        ])

      assert {:ok, response, final_messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 max_iterations: 5,
                 blank_stop_nudge: nudge
               )

      assert response.content == "final after nudge"

      # First call: original messages. Retry: nudge appended.
      assert_receive {:llm_call, [%{role: :user, content: "do work"}]}
      assert_receive {:llm_call, [%{role: :user, content: "do work"}, %{role: :user, content: ^nudge}]}

      assert [
               %{role: :user, content: "do work"},
               %{role: :user, content: ^nudge}
             ] = final_messages
    end
  end

  defp scripted_llm(responses) do
    pid = start_supervised!({Agent, fn -> responses end})

    fn _messages, _opts ->
      Agent.get_and_update(pid, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:error, :no_more_responses}, []}
      end)
    end
  end

  defp blank_stop_response do
    %Response{
      content: "",
      tool_calls: nil,
      provider: :appliance,
      model: "gpt-oss:120b",
      metadata: %{finish_reason: "stop"}
    }
  end

  defp done_tool do
    %Tool{
      name: "done",
      description: "Finish with selected citations",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "answer" => %{"type" => "string"},
          "memory_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "observation_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "mental_model_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["answer"]
      }
    }
  end

  defp echo_tool do
    %Tool{
      name: "echo",
      description: "Echo tool for tests",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []}
    }
  end
end
