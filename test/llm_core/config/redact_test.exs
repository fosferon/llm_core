defmodule LlmCore.Config.RedactTest do
  use ExUnit.Case, async: true

  alias LlmCore.Config.Redact

  @synthetic "synthetic-secret-0001"

  describe "secret_key?/1" do
    test "names a secret by the whole key or its ending" do
      for key <- [
            :api_key,
            "apikey",
            "openai_api_key",
            "key",
            "access_key",
            "secret_key",
            "aws_secret_access_key",
            :bot_token,
            "client_secret",
            "password",
            :passwd,
            "credentials",
            "credential",
            "private_key",
            "auth",
            "authorization",
            "proxy-authorization",
            "x-api-key",
            "bearer",
            "keys",
            "api_keys",
            "secrets",
            "client_secrets",
            "tokens",
            "API_KEY"
          ] do
        assert Redact.secret_key?(key), "#{inspect(key)} should be secret"
      end
    end

    test "keeps variable names, other keys and non-keys" do
      for key <- [
            :api_key_env,
            "token_env",
            :model,
            "base_url",
            "tokens_per_minute",
            "max_tokens",
            "token_budget",
            "secret_name",
            "password_policy",
            "credential_state",
            "monkey",
            "num_tokens",
            "author",
            nil,
            1
          ] do
        refute Redact.secret_key?(key), "#{inspect(key)} should not be secret"
      end
    end
  end

  describe "config/1, by key" do
    test "redacts nested maps, keyword lists and lists of maps; keeps everything else" do
      input = %{
        "providers" => %{
          "openai" => %{
            "api_key" => @synthetic,
            "api_key_env" => "OPENAI_API_KEY",
            "model" => "m"
          },
          "list" => [%{token: @synthetic, name: "a"}]
        },
        opts: [password: @synthetic, retries: 2],
        empty_key: %{api_key: ""},
        nil_key: %{api_key: nil}
      }

      out = Redact.config(input)

      refute inspect(out, limit: :infinity) =~ @synthetic
      assert out["providers"]["openai"]["api_key"] == "[redacted]"
      assert out["providers"]["openai"]["api_key_env"] == "OPENAI_API_KEY"
      assert out["providers"]["openai"]["model"] == "m"
      assert [%{token: "[redacted]", name: "a"}] = out["providers"]["list"]
      assert out.opts == [password: "[redacted]", retries: 2]
      assert out.empty_key == %{api_key: ""}
      assert out.nil_key == %{api_key: nil}
    end

    test "a secret key holding a map keeps its shape with every scalar redacted, except a variable name" do
      out =
        Redact.config(%{
          credentials: %{user: "u", pass: @synthetic},
          auth: %{"api_key_env" => "PROVIDER_KEY", "scheme" => "bearer"}
        })

      assert out.credentials == %{user: "[redacted]", pass: "[redacted]"}
      assert out.auth == %{"api_key_env" => "PROVIDER_KEY", "scheme" => "[redacted]"}
    end

    test "a table whose name ends in _env is walked like any other" do
      out =
        Redact.config(%{
          "providers" => %{"prov_env" => %{"api_key" => @synthetic, "type" => "cli"}}
        })

      assert out["providers"]["prov_env"] == %{"api_key" => "[redacted]", "type" => "cli"}
    end

    test "an _env key holding something other than a variable name is redacted" do
      out = Redact.config(%{"api_key_env" => @synthetic, "token_env" => "TOKEN_VAR"})
      assert out == %{"api_key_env" => "[redacted]", "token_env" => "TOKEN_VAR"}
    end

    test "header maps: authorization and api-key headers are redacted" do
      out =
        Redact.config(%{
          "headers" => %{
            "authorization" => "Bearer " <> @synthetic,
            "x-api-key" => @synthetic,
            "content-type" => "application/json"
          }
        })

      refute inspect(out) =~ @synthetic
      assert out["headers"]["content-type"] == "application/json"
    end

    test "structs keep their struct tag and have their fields walked" do
      out = Redact.config(%URI{scheme: "https", host: "example.test", userinfo: nil})
      assert %URI{host: "example.test"} = out
    end
  end

  describe "config/1, by value" do
    test "a Bearer token and a URL password are scrubbed under any key" do
      out =
        Redact.config(%{
          "note" => "send Bearer #{@synthetic} please",
          "url" => "https://user:#{@synthetic}@host.test/x",
          "plain" => "https://host.test/x"
        })

      refute inspect(out) =~ @synthetic
      assert out["note"] == "send Bearer [redacted] please"
      assert out["url"] == "https://user:[redacted]@host.test/x"
      assert out["plain"] == "https://host.test/x"
    end

    test "prose containing the word Bearer is left alone" do
      assert Redact.config(%{"hint" => "Bearer token support, uses a bearer scheme"}) ==
               %{"hint" => "Bearer token support, uses a bearer scheme"}
    end
  end

  describe "path_value/2" do
    test "a value set under a secret-named segment is redacted" do
      assert Redact.path_value("providers.openai.api_key", @synthetic) == "[redacted]"

      assert Redact.path_value(["providers", "openai", "credentials", "x"], @synthetic) ==
               "[redacted]"
    end

    test "a variable name set under an _env key is echoed; a secret there is not" do
      assert Redact.path_value("providers.openai.api_key_env", "OPENAI_API_KEY") ==
               "OPENAI_API_KEY"

      assert Redact.path_value("providers.openai.api_key_env", @synthetic) == "[redacted]"
    end

    test "other paths echo the value, with nested secrets redacted" do
      assert Redact.path_value("providers.openai.model", "m") == "m"

      assert Redact.path_value("providers.openai", %{"api_key" => @synthetic, "model" => "m"}) ==
               %{"api_key" => "[redacted]", "model" => "m"}
    end
  end
end
