defmodule LlmCore.Tool.CodecTest do
  # GC-12: some OpenAI-compatible backends (kimi's coding endpoint) omit "id"
  # on tool calls. The decode must synthesize a unique id so the assistant
  # message and its tool result agree — the missing id round-tripped as an
  # empty "tool_call_id" and the backend rejected the follow-up with
  # "tool_call_id  is not found".
  use ExUnit.Case, async: true

  alias LlmCore.Tool.Codec
  alias LlmToolkit.Tool.Call

  @openai_body %{
    "choices" => [
      %{
        "message" => %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => "call_abc",
              "function" => %{"name" => "read_file", "arguments" => ~s({"path":"x"})}
            }
          ]
        }
      }
    ]
  }

  describe "decode_tool_calls/2 :openai" do
    test "preserves provided ids verbatim" do
      [%Call{id: "call_abc", name: "read_file"}] = Codec.decode_tool_calls(@openai_body, :openai)
    end

    test "synthesizes a unique id when the backend omits it, keeping the name" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"function" => %{"name" => "gc_ticker", "arguments" => "{}"}}
              ]
            }
          }
        ]
      }

      [%Call{id: id, name: "gc_ticker", arguments: %{}}] = Codec.decode_tool_calls(body, :openai)
      assert is_binary(id) and id != ""
      assert String.starts_with?(id, "call_")
    end

    test "synthesized ids are unique per call" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"function" => %{"name" => "a", "arguments" => "{}"}},
                %{"function" => %{"name" => "b", "arguments" => "{}"}}
              ]
            }
          }
        ]
      }

      [first, second] = Codec.decode_tool_calls(body, :openai)
      assert first.id != second.id
    end

    test "a blank-string id is treated as missing and synthesized" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"id" => "", "function" => %{"name" => "bash", "arguments" => "{}"}}
              ]
            }
          }
        ]
      }

      [%Call{id: id, name: "bash"}] = Codec.decode_tool_calls(body, :openai)
      assert String.starts_with?(id, "call_")
    end

    test "a malformed entry without a function map stays the unknown fallback" do
      body = %{"choices" => [%{"message" => %{"tool_calls" => [%{"garbage" => true}]}}]}

      [%Call{id: nil, name: "unknown"}] = Codec.decode_tool_calls(body, :openai)
    end

    test "the synthesized id survives encode_result as the tool_call_id" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"function" => %{"name" => "gc_notify", "arguments" => "{}"}}
              ]
            }
          }
        ]
      }

      [%Call{id: id} = call] = Codec.decode_tool_calls(body, :openai)
      result = %LlmToolkit.Tool.Result{tool_call_id: call.id, name: call.name, content: "ok"}

      encoded = Codec.encode_result(result, :openai)
      assert encoded["tool_call_id"] == id
    end
  end
end
