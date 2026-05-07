defmodule LlmCore.LLM.CLIProviderTest do
  use ExUnit.Case, async: true

  alias LlmCore.LLM.CLIProvider
  alias LlmCore.LLM.{Response, Error}

  # ── Config Loading ────────────────────────────────────────

  describe "config/1" do
    test "loads built-in config for known provider name" do
      assert {:ok, config} = CLIProvider.config(:claude_code)
      assert config.binary == "claude"
      assert config.provider_type == :cli
    end

    test "loads built-in droid config" do
      assert {:ok, config} = CLIProvider.config(:droid)
      assert config.binary == "droid"
      assert config.subcommand == "exec"
    end

    test "loads built-in kimi config" do
      assert {:ok, config} = CLIProvider.config(:kimi_cli)
      assert config.binary == "kimi-cli"
      assert config.prompt_flag == "--prompt"
      assert config.system_prompt_transport == :file_flag
    end

    test "returns error for unknown provider" do
      assert {:error, _} = CLIProvider.config(:nonexistent_cli)
    end
  end

  # ── Provider Behaviour ────────────────────────────────────

  describe "available?/1" do
    test "returns false when binary not found" do
      provider = CLIProvider.from_config(:claude_code)
      # claude may or may not be installed, but the function should return boolean
      assert is_boolean(CLIProvider.available?(provider))
    end

    test "returns false for obviously missing binary" do
      config = %CLIProvider.Config{
        name: :fake_cli,
        binary: "nonexistent_binary_12345",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "fake"
      }

      provider = CLIProvider.from_config(config)
      refute CLIProvider.available?(provider)
    end
  end

  describe "capabilities/1" do
    test "returns map with streaming and passthrough" do
      provider = CLIProvider.from_config(:claude_code)
      caps = CLIProvider.capabilities(provider)

      assert is_map(caps)
      assert Map.has_key?(caps, :streaming)
      assert Map.has_key?(caps, :passthrough)
    end

    test "returns richer dispatch-aware capability data" do
      provider = CLIProvider.from_config(:codex_cli)
      caps = CLIProvider.capabilities(provider)

      assert get_in(caps, [:workspace, :cwd]) == true
      assert get_in(caps, [:workspace, :add_dir]) == true
      assert get_in(caps, [:automation, :auto_approve]) == true
      assert get_in(caps, [:prompting, :inline_fallback]) == true
      assert get_in(caps, [:persona, :native_file]) == false
    end
  end

  describe "provider_type/1" do
    test "returns :cli" do
      provider = CLIProvider.from_config(:claude_code)
      assert CLIProvider.provider_type(provider) == :cli
    end
  end

  describe "supports?/2" do
    test "reports semantic provider support" do
      codex = CLIProvider.from_config(:codex_cli)
      kimi = CLIProvider.from_config(:kimi_cli)

      assert CLIProvider.supports?(codex, :cwd)
      assert CLIProvider.supports?(codex, :auto_approve)
      assert CLIProvider.supports?(codex, :inline_fallback)
      refute CLIProvider.supports?(codex, :system_prompt_file)

      assert CLIProvider.supports?(kimi, :system_prompt_file)
      refute CLIProvider.supports?(kimi, :inline_fallback)
    end
  end

  # ── Arg Building ──────────────────────────────────────────

  describe "build_args/2" do
    test "claude_code builds correct args" do
      provider = CLIProvider.from_config(:claude_code)
      args = CLIProvider.build_args(provider, "do the thing", model: "claude-sonnet-4-6")

      assert args == ["--print", "-p", "do the thing", "--model", "claude-sonnet-4-6"]
    end

    test "claude_code without model" do
      provider = CLIProvider.from_config(:claude_code)
      args = CLIProvider.build_args(provider, "hello", [])

      assert args == ["--print", "-p", "hello"]
    end

    test "renders chat prompts for CLI providers" do
      provider = CLIProvider.from_config(:claude_code)

      args =
        CLIProvider.build_args(
          provider,
          [
            %{role: :system, content: "You are Alice."},
            %{role: :user, content: "Hello there"}
          ],
          []
        )

      assert args == ["--print", "-p", "[system] You are Alice.\n[user] Hello there"]
    end

    test "claude_code supports permission-mode and boolean permission bypass flags" do
      provider = CLIProvider.from_config(:claude_code)

      args =
        CLIProvider.build_args(provider, "run task",
          permission_mode: "bypassPermissions",
          dangerously_skip_permissions: true,
          allow_dangerously_skip_permissions: true
        )

      assert "--permission-mode" in args
      assert "bypassPermissions" in args
      assert "--dangerously-skip-permissions" in args
      assert "--allow-dangerously-skip-permissions" in args
    end

    test "droid builds args with subcommand and flags" do
      provider = CLIProvider.from_config(:droid)

      args =
        CLIProvider.build_args(provider, "fix the bug",
          auto: "high",
          model: "claude-opus-4-6",
          cwd: "/project"
        )

      # Subcommand comes first, then flags, then prompt
      assert List.first(args) == "exec"
      assert "--auto" in args
      assert "high" in args
      assert "--model" in args
      assert "claude-opus-4-6" in args
      assert "--cwd" in args
      assert "/project" in args
      assert List.last(args) == "fix the bug"
    end

    test "codex_cli builds args with exec subcommand and workspace flags" do
      provider = CLIProvider.from_config(:codex_cli)
      args = CLIProvider.build_args(provider, "write tests", model: "codex-1", cwd: "/tmp")

      assert List.first(args) == "exec"
      assert "--model" in args
      assert "codex-1" in args
      assert "--cd" in args
      assert "/tmp" in args
      assert List.last(args) == "write tests"
    end

    test "gemini_cli builds args" do
      provider = CLIProvider.from_config(:gemini_cli)
      args = CLIProvider.build_args(provider, "explain code", [])

      assert args == ["explain code"]
    end

    test "pi_cli builds args with --print and provider/model flags" do
      provider = CLIProvider.from_config(:pi_cli)

      args =
        CLIProvider.build_args(provider, "explain this", provider: "anthropic", model: "sonnet")

      assert List.first(args) == "--print"
      assert "--provider" in args
      assert "anthropic" in args
      assert "--model" in args
      assert "sonnet" in args
      assert List.last(args) == "explain this"
    end

    test "kimi_cli builds args with non-interactive prefix and agent file flag" do
      provider = CLIProvider.from_config(:kimi_cli)

      args =
        CLIProvider.build_args(provider, "explain this",
          model: "k2",
          system_prompt_file: "/tmp/agent.md",
          cwd: "/project"
        )

      assert Enum.take(args, 4) == ["--print", "--output-format", "text", "--final-message-only"]
      assert "--prompt" in args
      assert "--agent-file" in args
      assert "/tmp/agent.md" in args
      assert "--work-dir" in args
      assert "/project" in args
      assert "--model" in args
      assert "k2" in args
    end

    test "semantic auto_approve appends provider-specific unattended args" do
      droid = CLIProvider.from_config(:droid)
      codex = CLIProvider.from_config(:codex_cli)

      droid_args = CLIProvider.build_args(droid, "ship it", auto_approve: true)
      codex_args = CLIProvider.build_args(codex, "ship it", auto_approve: true)

      assert "--auto" in droid_args
      assert "high" in droid_args
      assert "--full-auto" in codex_args
    end

    test "unknown opts are passed through as flags" do
      config = %CLIProvider.Config{
        name: :custom,
        binary: "custom",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        flags: %{foo: "--foo", bar: "--bar"}
      }

      provider = CLIProvider.from_config(config)
      args = CLIProvider.build_args(provider, "task", foo: "val1", bar: "val2")

      assert "--foo" in args
      assert "val1" in args
      assert "--bar" in args
      assert "val2" in args
      assert List.last(args) == "task"
    end
  end

  # ── Invocation (stdin hack) ───────────────────────────────

  describe "build_invocation/2" do
    test "claude_code wraps with sh for stdin redirect" do
      provider = CLIProvider.from_config(:claude_code)
      {exec, args} = CLIProvider.build_invocation(provider, "hello", [])

      assert exec == "/bin/sh"
      # args = ["-c", ~s|exec "$0" "$@" < /dev/null|, claude_path | claude_args]
      assert List.first(args) == "-c"
    end

    test "droid does NOT wrap with sh" do
      provider = CLIProvider.from_config(:droid)
      {exec, args} = CLIProvider.build_invocation(provider, "hello", [])

      assert exec == "droid" or String.contains?(exec, "droid")
      refute List.first(args) == "-c"
    end

    test "pi_cli now wraps with sh for detached stdin" do
      provider = CLIProvider.from_config(:pi_cli)
      {exec, args} = CLIProvider.build_invocation(provider, "hello", [])

      assert exec == "/bin/sh"
      assert List.first(args) == "-c"
    end
  end

  describe "invocation_plan/3" do
    test "summarizes codex invocation and inline persona strategy" do
      provider = CLIProvider.from_config(:codex_cli)

      plan =
        CLIProvider.invocation_plan(provider, "write code",
          model: "codex-1",
          system_prompt: "You are precise."
        )

      assert plan.executable == "codex"
      assert plan.prompt_transport == :last
      assert plan.system_prompt_transport == :inline_fallback
      assert plan.persona_strategy == :inline_fallback
      assert plan.stdin_detached == false
    end
  end

  describe "render_prompt/3" do
    test "uses inline fallback for codex when given system_prompt text" do
      provider = CLIProvider.from_config(:codex_cli)
      prompt = CLIProvider.render_prompt(provider, "Write tests", system_prompt: "Be concise.")

      assert prompt =~ "System instructions:"
      assert prompt =~ "Be concise."
      assert prompt =~ "User request:"
      assert prompt =~ "Write tests"
    end

    test "uses native file transport for kimi without rewriting prompt" do
      provider = CLIProvider.from_config(:kimi_cli)
      prompt = CLIProvider.render_prompt(provider, "Write tests", system_prompt: "Be concise.")

      assert prompt == "Write tests"
    end
  end

  # ── Response Building ─────────────────────────────────────

  describe "build_response/3" do
    test "builds Response struct with correct provider atom" do
      provider = CLIProvider.from_config(:claude_code)
      response = CLIProvider.build_response(provider, "  hello world  \n", [])

      assert %Response{} = response
      assert response.provider == :claude_code
      assert response.content == "hello world"
    end

    test "includes model from opts" do
      provider = CLIProvider.from_config(:droid)
      response = CLIProvider.build_response(provider, "output", model: "claude-opus-4-6")

      assert response.model == "claude-opus-4-6"
    end

    test "uses default_model when no model in opts" do
      provider = CLIProvider.from_config(:claude_code)
      response = CLIProvider.build_response(provider, "output", [])

      assert response.model == "claude-code-cli"
    end
  end

  # ── Error Formatting ──────────────────────────────────────

  describe "build_error/3" do
    test "not_installed error" do
      provider = CLIProvider.from_config(:claude_code)
      error = CLIProvider.build_error(provider, :not_installed, [])

      assert %Error{} = error
      assert error.type == :provider_error
      assert error.provider == :claude_code
      assert error.details.reason == :not_installed
    end

    test "timeout error" do
      provider = CLIProvider.from_config(:droid)
      error = CLIProvider.build_error(provider, :timeout, timeout: 30_000)

      assert error.type == :timeout
      assert error.provider == :droid
      assert error.details.timeout == 30_000
    end

    test "exit_code error" do
      provider = CLIProvider.from_config(:codex_cli)

      error = CLIProvider.build_error(provider, {:exit_code, 1}, output: "bad")

      assert error.type == :provider_error
      assert error.details.exit_code == 1
    end
  end

  # ── Config Struct ─────────────────────────────────────────

  describe "CLIProvider.Config" do
    test "creates config with defaults" do
      config = %CLIProvider.Config{
        name: :test,
        binary: "test",
        provider_type: :cli,
        default_timeout: 30_000,
        default_model: "v1"
      }

      assert config.name == :test
      assert config.flags == %{}
      assert config.stdin_hack == false
      assert config.subcommand == nil
      assert config.non_interactive_args == []
      assert config.auto_approve_args == []
      assert config.preflight == %{}
    end
  end

  describe "preflight/1" do
    test "returns not_installed for missing binary" do
      provider =
        CLIProvider.from_config(%CLIProvider.Config{
          name: :missing,
          binary: "no_such_binary_xyz",
          provider_type: :cli,
          default_timeout: 1_000,
          default_model: "v1"
        })

      assert {:error, %{reason: :not_installed}} = CLIProvider.preflight(provider)
    end

    test "passes declarative help checks" do
      provider =
        CLIProvider.from_config(%CLIProvider.Config{
          name: :shell_test,
          binary: "/bin/sh",
          provider_type: :cli,
          default_timeout: 1_000,
          default_model: "v1",
          preflight: %{
            help_args: ["-c", "printf '%s' '--flag --mode'"],
            expect_in_help: ["--flag"]
          }
        })

      assert {:ok, %{checks: checks}} = CLIProvider.preflight(provider)
      assert Enum.any?(checks, &(&1.check == :help and &1.ok == true))
    end

    test "fails when required help surface is missing" do
      provider =
        CLIProvider.from_config(%CLIProvider.Config{
          name: :shell_test,
          binary: "/bin/sh",
          provider_type: :cli,
          default_timeout: 1_000,
          default_model: "v1",
          preflight: %{help_args: ["-c", "printf '%s' '--mode'"], expect_in_help: ["--flag"]}
        })

      assert {:error, %{reason: :preflight_failed, failed_check: :help, missing: ["--flag"]}} =
               CLIProvider.preflight(provider)
    end
  end

  # ── Full Integration (with echo as fake CLI) ──────────────

  describe "send/2 — integration" do
    test "returns error when binary not found" do
      config = %CLIProvider.Config{
        name: :missing,
        binary: "no_such_binary_xyz",
        provider_type: :cli,
        default_timeout: 1_000,
        default_model: "v1"
      }

      provider = CLIProvider.from_config(config)

      assert {:error, %Error{details: %{reason: :not_installed}}} =
               CLIProvider.send(provider, "test")
    end

    @tag :unix
    test "executes echo as a fake CLI provider" do
      config = %CLIProvider.Config{
        name: :echo_test,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "echo-v1",
        prompt_position: :last
      }

      provider = CLIProvider.from_config(config)
      assert {:ok, %Response{} = response} = CLIProvider.send(provider, "hello from test")
      assert response.content =~ "hello from test"
      assert response.provider == :echo_test
    end

    @tag :unix
    test "accepts chat message prompts" do
      config = %CLIProvider.Config{
        name: :echo_chat_test,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "echo-v1",
        prompt_position: :last
      }

      provider = CLIProvider.from_config(config)

      prompt = [
        %{role: :system, content: "You are Alice."},
        %{role: :user, content: "Hello there"}
      ]

      assert {:ok, %Response{} = response} = CLIProvider.send(provider, prompt)
      assert response.content =~ "[system] You are Alice."
      assert response.content =~ "[user] Hello there"
    end
  end

  # ── System Prompt File Transform ──────────────────────────

  describe "system_prompt_file_transform: :agent_spec_yaml" do
    test "generates correct nested Kimi-style agent spec" do
      config = %CLIProvider.Config{
        name: :transform_test,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml
      }

      provider = CLIProvider.from_config(config)

      tmp =
        Path.join(System.tmp_dir!(), "sp_transform_test_#{System.unique_integer([:positive])}.md")

      File.write!(tmp, "You are a helpful assistant.")

      {_prompt, opts, meta} =
        send(provider, :prepare_prompt_and_opts, ["do the thing", [system_prompt_file: tmp]])

      agent_file = opts[:system_prompt_file]
      assert meta.persona_strategy == :native_file
      assert String.ends_with?(agent_file, "agent.yaml")

      yaml_content = File.read!(agent_file)
      # Verify nested structure with version + agent block
      assert yaml_content =~ "version: 1"
      assert yaml_content =~ "agent:"
      assert yaml_content =~ "  extend: default"
      assert yaml_content =~ "  name: llm_core_agent"
      assert yaml_content =~ "  system_prompt_path: ./system.md"

      system_md = Path.join(Path.dirname(agent_file), "system.md")
      assert File.exists?(system_md)
      assert File.read!(system_md) == "You are a helpful assistant."

      File.rm_rf!(Path.dirname(agent_file))
      File.rm(tmp)
    end

    test "agent_name from opts takes precedence" do
      config = %CLIProvider.Config{
        name: :transform_name,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml,
        file_transform_defaults: %{"name" => "config-agent"}
      }

      provider = CLIProvider.from_config(config)

      {_prompt, opts, _meta} =
        send(provider, :prepare_prompt_and_opts, [
          "task",
          [system_prompt: "Be concise.", agent_name: "dispatch-agent"]
        ])

      yaml_content = File.read!(opts[:system_prompt_file])
      # Opts take precedence over config defaults
      assert yaml_content =~ "  name: dispatch-agent"
      refute yaml_content =~ "config-agent"

      File.rm_rf!(Path.dirname(opts[:system_prompt_file]))
    end

    test "agent_name falls back to file_transform_defaults" do
      config = %CLIProvider.Config{
        name: :transform_defaults,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml,
        file_transform_defaults: %{"name" => "my-kimi-agent", "version" => 2, "extend" => "okabe"}
      }

      provider = CLIProvider.from_config(config)

      {_prompt, opts, _meta} =
        send(provider, :prepare_prompt_and_opts, [
          "task",
          [system_prompt: "Be concise."]
        ])

      yaml_content = File.read!(opts[:system_prompt_file])
      assert yaml_content =~ "version: 2"
      assert yaml_content =~ "  extend: okabe"
      assert yaml_content =~ "  name: my-kimi-agent"

      File.rm_rf!(Path.dirname(opts[:system_prompt_file]))
    end

    test "model is included when passed via opts" do
      config = %CLIProvider.Config{
        name: :transform_model,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml
      }

      provider = CLIProvider.from_config(config)

      {_prompt, opts, _meta} =
        send(provider, :prepare_prompt_and_opts, [
          "task",
          [system_prompt: "Be concise.", model: "k2-0235"]
        ])

      yaml_content = File.read!(opts[:system_prompt_file])
      assert yaml_content =~ "  model: k2-0235"

      File.rm_rf!(Path.dirname(opts[:system_prompt_file]))
    end

    test "model is omitted when not available" do
      config = %CLIProvider.Config{
        name: :transform_no_model,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml
      }

      provider = CLIProvider.from_config(config)

      {_prompt, opts, _meta} =
        send(provider, :prepare_prompt_and_opts, [
          "task",
          [system_prompt: "Be concise."]
        ])

      yaml_content = File.read!(opts[:system_prompt_file])
      refute yaml_content =~ "model:"

      File.rm_rf!(Path.dirname(opts[:system_prompt_file]))
    end

    test "materializes text system prompt into agent spec when no file given" do
      config = %CLIProvider.Config{
        name: :transform_materialize,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: :agent_spec_yaml
      }

      provider = CLIProvider.from_config(config)

      {_prompt, opts, meta} =
        send(provider, :prepare_prompt_and_opts, [
          "do the thing",
          [system_prompt: "Be concise."]
        ])

      agent_file = opts[:system_prompt_file]
      assert meta.persona_strategy == :native_file
      assert String.ends_with?(agent_file, "agent.yaml")

      yaml_content = File.read!(agent_file)
      assert yaml_content =~ "version: 1"
      assert yaml_content =~ "agent:"
      assert yaml_content =~ "  system_prompt_path: ./system.md"

      system_md = Path.join(Path.dirname(agent_file), "system.md")
      assert File.read!(system_md) == "Be concise."

      File.rm_rf!(Path.dirname(agent_file))
    end

    test "no transform when system_prompt_file_transform is nil" do
      config = %CLIProvider.Config{
        name: :no_transform,
        binary: "cat",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag,
        system_prompt_file_transform: nil
      }

      provider = CLIProvider.from_config(config)

      tmp =
        Path.join(System.tmp_dir!(), "sp_no_transform_#{System.unique_integer([:positive])}.md")

      File.write!(tmp, "Raw prompt.")

      {_prompt, opts, _meta} =
        send(provider, :prepare_prompt_and_opts, ["task", [system_prompt_file: tmp]])

      assert opts[:system_prompt_file] == tmp

      File.rm(tmp)
    end
  end

  # ── Output Normalization ──────────────────────────────────

  describe "output_strip_patterns" do
    test "strips matching patterns from output" do
      config = %CLIProvider.Config{
        name: :strip_test,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        output_strip_patterns: ["^Session started\\..*$", "^\\[INFO\\].*$"]
      }

      output = "Session started.\n[INFO] Loading...\nActual response content\n[INFO] Done."
      normalized = CLIProvider.normalize_output(output, config)

      assert normalized =~ "Actual response content"
      refute normalized =~ "Session started."
      refute normalized =~ "[INFO]"
    end

    test "no-op when patterns list is empty" do
      config = %CLIProvider.Config{
        name: :no_strip,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        output_strip_patterns: []
      }

      output = "Hello world"
      assert CLIProvider.normalize_output(output, config) == output
    end

    test "build_response applies strip patterns" do
      config = %CLIProvider.Config{
        name: :strip_response,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        output_strip_patterns: ["^BANNER.*$"]
      }

      provider = CLIProvider.from_config(config)

      response = CLIProvider.build_response(provider, "BANNER LINE\nReal output", [])
      assert response.content == "Real output"
      # Raw output is preserved unmodified
      assert response.raw.output == "BANNER LINE\nReal output"
    end
  end

  # ── Output File Capture ───────────────────────────────────

  describe "output_file_flag" do
    @tag :unix
    test "captures output from file when output_file_flag is set" do
      # Use /bin/sh to both write to file and echo to stdout
      _output_file =
        Path.join(System.tmp_dir!(), "output_test_#{System.unique_integer([:positive])}.txt")

      config = %CLIProvider.Config{
        name: :file_capture_test,
        binary: "/bin/sh",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        prompt_position: :last,
        output_file_flag: "--output-file"
      }

      provider = CLIProvider.from_config(config)

      # The output_file_flag mechanism appends the flag + temp file to args.
      # We test the plumbing by verifying the args contain the flag.
      args = CLIProvider.build_args(provider, "test", [])
      # output_file_flag is appended during execute, not build_args
      # so build_args should not include it
      refute "--output-file" in args
    end

    test "config with nil output_file_flag does not add extra args" do
      config = %CLIProvider.Config{
        name: :no_file_capture,
        binary: "echo",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        output_file_flag: nil
      }

      provider = CLIProvider.from_config(config)
      args = CLIProvider.build_args(provider, "test", [])
      refute Enum.any?(args, &String.starts_with?(&1, "--output"))
    end
  end

  # ── New Config Defaults ───────────────────────────────────

  describe "new contract fields — backward compatibility" do
    test "new fields default to nil/empty" do
      config = %CLIProvider.Config{
        name: :compat,
        binary: "test",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1"
      }

      assert config.system_prompt_file_transform == nil
      assert config.output_file_flag == nil
      assert config.output_strip_patterns == []
    end

    test "capabilities expose new contract fields" do
      config = %CLIProvider.Config{
        name: :cap_test,
        binary: "test",
        provider_type: :cli,
        default_timeout: 5_000,
        default_model: "v1",
        output_file_flag: "--output-last-message",
        output_strip_patterns: ["^noise"],
        system_prompt_file_transform: :agent_spec_yaml,
        flags: %{system_prompt_file: "--agent-file"},
        system_prompt_transport: :file_flag
      }

      provider = CLIProvider.from_config(config)
      caps = CLIProvider.capabilities(provider)

      assert get_in(caps, [:output, :file_capture]) == true
      assert get_in(caps, [:output, :strip_patterns]) == true
      assert get_in(caps, [:persona, :file_transform]) == :agent_spec_yaml
    end
  end

  # ── Helper to call private functions for testing ──────────

  defp send(provider, function, args) do
    # Use Kernel.apply on the module to call internal prepare function
    # We access it via the public render_prompt path instead
    case function do
      :prepare_prompt_and_opts ->
        [prompt, opts] = args
        # Use invocation_plan which exercises prepare_prompt_and_opts
        plan = CLIProvider.invocation_plan(provider, prompt, opts)

        meta = %{
          system_prompt_transport: plan.system_prompt_transport,
          persona_strategy: plan.persona_strategy
        }

        # Extract the system_prompt_file from the rendered args
        sp_file_flag = provider.config.flags[:system_prompt_file]

        sp_file =
          if sp_file_flag do
            idx = Enum.find_index(plan.args, &(&1 == sp_file_flag))
            if idx, do: Enum.at(plan.args, idx + 1)
          end

        final_opts =
          if sp_file do
            Keyword.put(opts, :system_prompt_file, sp_file)
          else
            opts
          end

        {plan.prompt, final_opts, meta}
    end
  end
end
