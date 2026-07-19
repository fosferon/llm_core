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

  defp scripted_llm(responses) do
    pid = start_supervised!({Agent, fn -> responses end})

    fn _messages, _opts ->
      Agent.get_and_update(pid, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:error, :no_more_responses}, []}
      end)
    end
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
end
