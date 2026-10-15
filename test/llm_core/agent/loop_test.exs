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

      assert_receive {:llm_call,
                      [%{role: :user, content: "do work"}, %{role: :user, content: ^nudge}]}

      assert [
               %{role: :user, content: "do work"},
               %{role: :user, content: ^nudge}
             ] = final_messages
    end
  end

  describe "run/3 terminal_required (GC-6279)" do
    test "a text-only reply does not end a required-terminal turn: prose + nudge are appended and the retry completes on the terminal call" do
      parent = self()
      nudge = "Finish your tool calls, then call done."
      args = %{"answer" => "the operator-facing report"}
      terminal_call = %Call{id: "call_done", name: "done", arguments: args}

      llm_send =
        capturing_llm(parent, [
          %Response{
            content: "Let me put that down now.",
            tool_calls: nil,
            metadata: %{finish_reason: "stop"}
          },
          %Response{content: nil, tool_calls: [terminal_call]}
        ])

      assert {:ok, response, final_messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 terminal_nudge: nudge,
                 terminal_content_key: "answer",
                 max_iterations: 3
               )

      assert response.content == "the operator-facing report"
      assert response.metadata.terminal_args == args
      assert response.metadata.terminal_recovery_attempts == 1
      refute Map.has_key?(response.metadata, :blank_stop_retries)

      # The retry carried the model's own prose and the nudge, in that order.
      assert_receive {:llm_call, [%{role: :user, content: "do work"}]}

      assert_receive {:llm_call,
                      [
                        %{role: :user, content: "do work"},
                        %{role: :assistant, content: "Let me put that down now."},
                        %{role: :user, content: ^nudge}
                      ]}

      assert [
               %{role: :user, content: "do work"},
               %{role: :assistant, content: "Let me put that down now."},
               %{role: :user, content: ^nudge}
               | _terminal_transcript
             ] = final_messages
    end

    test "repeated text-only replies terminate with the typed terminal_missing error carrying the last prose" do
      llm_send =
        scripted_llm([
          %Response{
            content: "First prose.",
            tool_calls: nil,
            provider: :openai,
            model: "glm",
            metadata: %{finish_reason: "stop"}
          },
          %Response{
            content: "Second prose.",
            tool_calls: nil,
            provider: :openai,
            model: "glm",
            metadata: %{finish_reason: "stop"}
          },
          %Response{
            content: "Third prose.",
            tool_calls: nil,
            provider: :openai,
            model: "glm",
            metadata: %{finish_reason: "stop"}
          }
        ])

      assert {:error,
              {:terminal_missing,
               %{
                 iteration: 0,
                 attempts: 3,
                 last_content: "Third prose.",
                 finish_reasons: ["stop", "stop", "stop"],
                 terminal_tool: "done",
                 provider: :openai,
                 model: "glm"
               }}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_iterations: 5
               )
    end

    test "max_nonterminal_stops bounds the recovery independently of max_blank_stops" do
      llm_send =
        scripted_llm([
          %Response{content: "Prose.", tool_calls: nil},
          %Response{content: "Prose again.", tool_calls: nil}
        ])

      assert {:error, {:terminal_missing, %{attempts: 1}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_nonterminal_stops: 1,
                 max_blank_stops: 3,
                 max_iterations: 5
               )
    end

    test "a default nudge naming the terminal tool is used when none is configured" do
      parent = self()
      terminal_call = %Call{id: "call_done", name: "done", arguments: %{"answer" => "r"}}

      llm_send =
        capturing_llm(parent, [
          %Response{content: "Prose.", tool_calls: nil},
          %Response{content: nil, tool_calls: [terminal_call]}
        ])

      assert {:ok, _response, _messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_iterations: 3
               )

      assert_receive {:llm_call,
                      [
                        _,
                        %{role: :assistant, content: "Prose."},
                        %{role: :user, content: default_nudge}
                      ]}

      assert default_nudge =~ "done"
    end

    test "terminal_required without terminal_tool is a caller error" do
      assert_raise ArgumentError, ~r/terminal_required/, fn ->
        Loop.run(
          [%{role: :user, content: "do work"}],
          fn _m, _o -> {:ok, %Response{content: "x"}} end,
          tools: [done_tool()],
          resolve_tool: fn _call -> {:ok, "unused"} end,
          terminal_required: true
        )
      end
    end

    test "sibling tool calls in the terminal response are dispatched; the terminal call is not" do
      parent = self()
      sibling = %Call{id: "call_echo", name: "echo", arguments: %{}}
      terminal_call = %Call{id: "call_done", name: "done", arguments: %{"answer" => "report"}}

      llm_send = scripted_llm([%Response{content: nil, tool_calls: [sibling, terminal_call]}])

      resolve_tool = fn call ->
        send(parent, {:resolved, call})
        {:ok, "echoed"}
      end

      assert {:ok, response, final_messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: resolve_tool,
                 terminal_tool: "done",
                 terminal_required: true,
                 terminal_content_key: "answer",
                 max_iterations: 3
               )

      assert response.content == "report"
      assert_receive {:resolved, ^sibling}
      refute_receive {:resolved, ^terminal_call}

      assert Enum.any?(
               final_messages,
               &match?(%{role: :tool, tool_call_id: "call_echo", content: "echoed"}, &1)
             )
    end

    test "sibling dispatch on the last allowed iteration is not a budget error" do
      sibling = %Call{id: "call_echo", name: "echo", arguments: %{}}
      terminal_call = %Call{id: "call_done", name: "done", arguments: %{"answer" => "report"}}

      llm_send = scripted_llm([%Response{content: nil, tool_calls: [sibling, terminal_call]}])

      assert {:ok, %Response{content: "report"}, _messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: fn _call -> {:ok, "echoed"} end,
                 terminal_tool: "done",
                 terminal_content_key: "answer",
                 max_iterations: 1
               )
    end

    test "terminal_content_key makes the terminal argument the reply and keeps the model's prose under metadata" do
      terminal_with_report = %Call{id: "c1", name: "done", arguments: %{"answer" => "report"}}

      assert {:ok, response, _} =
               Loop.run(
                 [%{role: :user, content: "do work"}],
                 scripted_llm([
                   %Response{content: "some prose", tool_calls: [terminal_with_report]}
                 ]),
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_content_key: "answer"
               )

      assert response.content == "report"
      assert response.metadata.terminal_prose == "some prose"
    end

    test "terminal_content_key falls back to the model's prose when the argument is blank" do
      terminal_blank = %Call{id: "c2", name: "done", arguments: %{"answer" => "  "}}

      assert {:ok, response, _} =
               Loop.run(
                 [%{role: :user, content: "do work"}],
                 scripted_llm([
                   %Response{content: "fallback prose", tool_calls: [terminal_blank]}
                 ]),
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_content_key: "answer"
               )

      assert response.content == "fallback prose"
      refute Map.has_key?(response.metadata, :terminal_prose)
    end

    test "working tool calls under terminal_required continue normally without recovery" do
      work = %Call{id: "c1", name: "echo", arguments: %{}}
      terminal_call = %Call{id: "c2", name: "done", arguments: %{"answer" => "report"}}

      llm_send =
        scripted_llm([
          %Response{content: "Working on it.", tool_calls: [work]},
          %Response{content: nil, tool_calls: [terminal_call]}
        ])

      assert {:ok, response, _} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: fn _call -> {:ok, "echoed"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 terminal_content_key: "answer",
                 max_iterations: 3
               )

      assert response.content == "report"
      refute Map.has_key?(response.metadata, :terminal_recovery_attempts)
    end

    test "a blank stop under terminal_required is still a blank stop" do
      llm_send =
        scripted_llm([blank_stop_response(), blank_stop_response(), blank_stop_response()])

      assert {:error, {:empty_stop, %{attempts: 3}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_iterations: 3
               )
    end

    test "opt-off (terminal_required false) still accepts a text-only reply as final" do
      llm_send = scripted_llm([%Response{content: "plain", tool_calls: nil}])

      assert {:ok, %Response{content: "plain"}, _} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: fn _call -> {:ok, "unused"} end,
                 terminal_tool: "done",
                 max_iterations: 3
               )
    end
  end

  describe "run/3 terminal_required — review findings (GC-6283)" do
    test "a duplicated terminal call is never dispatched; the first copy is the terminal" do
      parent = self()
      first = %Call{id: "c1", name: "done", arguments: %{"answer" => "a"}}
      second = %Call{id: "c2", name: "done", arguments: %{"answer" => "b"}}

      llm_send = scripted_llm([%Response{content: nil, tool_calls: [first, second]}])

      resolve_tool = fn call ->
        send(parent, {:resolved, call})
        {:ok, "ran"}
      end

      assert {:ok, response, final_messages} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool()],
                 resolve_tool: resolve_tool,
                 terminal_tool: "done",
                 terminal_content_key: "answer",
                 max_iterations: 3
               )

      assert response.content == "a"
      assert response.metadata.terminal_args == %{"answer" => "a"}
      refute_receive {:resolved, _}
      assert final_messages == [%{role: :user, content: "do work"}]
    end

    test "narrated stops are bounded per run, not per iteration: narrate → tool → narrate cannot reset the budget" do
      echo = %Call{id: "e", name: "echo", arguments: %{}}

      llm_send =
        scripted_llm([
          %Response{content: "Prose one.", tool_calls: nil},
          %Response{content: nil, tool_calls: [echo]},
          %Response{content: "Prose two.", tool_calls: nil},
          %Response{content: nil, tool_calls: [echo]},
          %Response{content: "Prose three.", tool_calls: nil},
          %Response{content: nil, tool_calls: [echo]}
        ])

      assert {:error,
              {:terminal_missing, %{attempts: 3, last_content: "Prose three.", iteration: 2}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_iterations: 10
               )
    end

    test "iteration budget exhausted under terminal_required is a terminal_missing error carrying the last prose" do
      echo = %Call{id: "e", name: "echo", arguments: %{}}

      llm_send =
        scripted_llm([
          %Response{content: "I will keep working.", tool_calls: nil},
          %Response{content: nil, tool_calls: [echo]},
          %Response{content: nil, tool_calls: [echo]},
          %Response{content: nil, tool_calls: [echo]}
        ])

      assert {:error,
              {:terminal_missing,
               %{reason: :max_iterations, attempts: 1, last_content: "I will keep working."}}} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 terminal_tool: "done",
                 terminal_required: true,
                 max_iterations: 3
               )
    end

    test "iteration budget exhausted without terminal_required keeps the classic error" do
      echo = %Call{id: "e", name: "echo", arguments: %{}}
      llm_send = scripted_llm(List.duplicate(%Response{content: nil, tool_calls: [echo]}, 3))

      assert {:error, :budget_exceeded} =
               Loop.run([%{role: :user, content: "do work"}], llm_send,
                 tools: [done_tool(), echo_tool()],
                 resolve_tool: fn _call -> {:ok, "ok"} end,
                 terminal_tool: "done",
                 max_iterations: 2
               )
    end
  end

  defp capturing_llm(parent, responses) do
    pid = start_supervised!({Agent, fn -> responses end})

    fn messages, _opts ->
      send(parent, {:llm_call, messages})

      Agent.get_and_update(pid, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:error, :no_more_responses}, []}
      end)
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
