defmodule LlmCore.Memory.Hindsight.RetryTest do
  use ExUnit.Case, async: true

  alias LlmCore.Memory.Hindsight.Retry

  test "retries three-element server errors but not client errors" do
    assert Retry.should_retry?({:http_error, 503, %{"error" => "unavailable"}})
    refute Retry.should_retry?({:http_error, 401, %{"error" => "unauthorized"}})
  end
end
