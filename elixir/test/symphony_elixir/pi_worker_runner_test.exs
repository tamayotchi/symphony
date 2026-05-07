defmodule SymphonyElixir.PiWorkerRunnerTest do
  use SymphonyElixir.TestSupport

  test "agent runner can switch to the Pi runtime via worker.runtime" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pi-worker-runner-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace_root)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl"}}'
              ;;
            2)
              printf '%s\\n' '{"type":"response","id":2,"command":"set_session_name","success":true}'
              ;;
            3)
              printf '%s\\n' '{"type":"response","id":3,"command":"set_auto_retry","success":true}'
              ;;
            4)
              printf '%s\\n' '{"type":"response","id":4,"command":"set_auto_compaction","success":true}'
              ;;
            5)
              printf '%s\\n' '{"type":"response","id":5,"command":"prompt","success":true}'
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"turn_start"}'
              printf '%s\\n' '{"type":"turn_end","message":{"role":"assistant","usage":{"input":12,"output":4,"totalTokens":16}},"toolResults":[]}'
              printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant","usage":{"input":12,"output":4,"totalTokens":16}}]}'
              ;;
            6)
              printf '%s\\n' '{"type":"response","id":99,"command":"abort","success":true}'
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_response_timeout_ms: 1_000,
        pi_session_dir_name: ".pi-rpc-sessions"
      )

      issue = %Issue{
        id: "issue-pi-runtime",
        identifier: "PI-101",
        title: "Run with Pi",
        description: "Exercise the Pi worker adapter",
        state: "In Progress",
        url: "https://example.org/issues/PI-101",
        labels: ["backend"]
      }

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, "PI-101"))

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:worker_runtime_info, "issue-pi-runtime", %{worker_host: nil, workspace_path: ^expected_workspace}},
                     1_000

      assert_receive {:worker_runtime_info, "issue-pi-runtime",
                      %{
                        session_file: "/tmp/pi-session.jsonl",
                        session_dir: session_dir,
                        proof_dir: "/tmp/proof",
                        proof_events_path: "/tmp/proof/events.jsonl",
                        proof_summary_path: "/tmp/proof/summary.json"
                      }},
                     1_000

      assert String.starts_with?(session_dir, expected_workspace <> "/.pi-rpc-sessions/")

      assert_receive {:codex_worker_update, "issue-pi-runtime", %{event: :session_started, session_id: "pi-session-turn-1", timestamp: %DateTime{}}},
                     1_000

      assert_receive {:codex_worker_update, "issue-pi-runtime", %{event: :turn_completed, usage: %{"input" => 12, "output" => 4, "totalTokens" => 16}}},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "pi worker runner loads explicit extension paths while discovery stays disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pi-worker-extensions-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_PI_TRACE")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")
      workflow_root = Workflow.workflow_file_path() |> Path.dirname()
      extension_dir = Path.join(workflow_root, "extensions")
      workspace_guard = Path.join(extension_dir, "workspace-guard.ts")
      proof = Path.join(extension_dir, "proof.ts")
      linear_graphql = Path.join(extension_dir, "linear-graphql.ts")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(extension_dir)
      File.write!(workspace_guard, "export default function () {}\n")
      File.write!(proof, "export default function () {}\n")
      File.write!(linear_graphql, "export default function () {}\n")
      System.put_env("SYMP_TEST_PI_TRACE", trace_file)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_PI_TRACE:-/tmp/pi.trace}"
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"
        printf 'ENV:%s|%s|%s\\n' "${PI_SYMPHONY_TRACKER_KIND:-}" "${PI_SYMPHONY_LINEAR_ENDPOINT:-}" "${PI_SYMPHONY_LINEAR_API_KEY:-}" >> "$trace_file"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl"}}'
              ;;
            2)
              printf '%s\\n' '{"type":"response","id":2,"command":"set_session_name","success":true}'
              ;;
            3)
              printf '%s\\n' '{"type":"response","id":3,"command":"set_auto_retry","success":true}'
              ;;
            4)
              printf '%s\\n' '{"type":"response","id":4,"command":"set_auto_compaction","success":true}'
              ;;
            5)
              printf '%s\\n' '{"type":"response","id":5,"command":"prompt","success":true}'
              printf '%s\\n' '{"type":"agent_end","messages":[]}'
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_extension_paths: [
          "extensions/workspace-guard.ts",
          "./extensions/proof.ts",
          "extensions/linear-graphql.ts"
        ]
      )

      issue = %Issue{
        id: "issue-pi-extensions",
        identifier: "PI-102",
        title: "Load extensions",
        description: "Verify explicit worker extension loading",
        state: "Done",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      trace = File.read!(trace_file)
      assert trace =~ "--no-extensions"
      assert trace =~ "--no-themes"
      assert trace =~ "--extension #{workspace_guard}"
      assert trace =~ "--extension #{proof}"
      assert trace =~ "--extension #{linear_graphql}"
      assert trace =~ "ENV:linear|https://api.linear.app/graphql|token"
    after
      restore_env("SYMP_TEST_PI_TRACE", previous_trace)
      File.rm_rf(test_root)
    end
  end

  test "pi worker runner applies configured model and thinking level before prompting" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pi-worker-model-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_PI_TRACE")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")

      File.mkdir_p!(workspace_root)
      System.put_env("SYMP_TEST_PI_TRACE", trace_file)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_PI_TRACE:-/tmp/pi.trace}"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"

          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl"}}'
              ;;
            2)
              printf '%s\\n' '{"type":"response","id":2,"command":"set_session_name","success":true}'
              ;;
            3)
              printf '%s\\n' '{"type":"response","id":3,"command":"set_auto_retry","success":true}'
              ;;
            4)
              printf '%s\\n' '{"type":"response","id":4,"command":"set_auto_compaction","success":true}'
              ;;
            5)
              printf '%s\\n' '{"type":"response","id":97,"command":"set_model","success":true}'
              ;;
            6)
              printf '%s\\n' '{"type":"response","id":98,"command":"set_thinking_level","success":true}'
              ;;
            7)
              printf '%s\\n' '{"type":"response","id":5,"command":"prompt","success":true}'
              printf '%s\\n' '{"type":"agent_end","messages":[]}'
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_model_provider: "anthropic",
        pi_model_id: "claude-sonnet-4-5",
        pi_thinking_level: "high"
      )

      issue = %Issue{
        id: "issue-pi-model",
        identifier: "PI-103",
        title: "Configure model",
        description: "Verify model setup commands",
        state: "Done",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      trace = File.read!(trace_file)
      assert trace =~ ~s("type":"set_model")
      assert trace =~ ~s("provider":"anthropic")
      assert trace =~ ~s("modelId":"claude-sonnet-4-5")
      assert trace =~ ~s("id":97)
      assert trace =~ ~s("type":"set_thinking_level")
      assert trace =~ ~s("level":"high")
      assert trace =~ ~s("id":98)
      assert trace =~ ~s("type":"prompt")
      assert trace =~ ~s("message":"You are an agent for this repository.")
    after
      restore_env("SYMP_TEST_PI_TRACE", previous_trace)
      File.rm_rf(test_root)
    end
  end

  test "pi worker runner can pass an intentionally blank append system prompt" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pi-append-system-prompt-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_PI_TRACE")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_pi = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")

      File.mkdir_p!(workspace_root)
      System.put_env("SYMP_TEST_PI_TRACE", trace_file)

      File.write!(
        fake_pi,
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_PI_TRACE:-/tmp/pi.trace}"
        index=0
        for arg in "$@"; do
          index=$((index + 1))
          printf 'ARG:%s:%s\n' "$index" "$arg" >> "$trace_file"
        done

        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\n' '{"type":"response","id":1,"command":"get_state","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl"}}'
              ;;
            2)
              printf '%s\n' '{"type":"response","id":2,"command":"set_session_name","success":true}'
              ;;
            3)
              printf '%s\n' '{"type":"response","id":3,"command":"set_auto_retry","success":true}'
              ;;
            4)
              printf '%s\n' '{"type":"response","id":4,"command":"set_auto_compaction","success":true}'
              ;;
            5)
              printf '%s\n' '{"type":"response","id":5,"command":"prompt","success":true}'
              printf '%s\n' '{"type":"agent_end","messages":[]}'
              ;;
          esac
        done
        """
      )

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_runtime: "pi",
        pi_command: fake_pi,
        pi_append_system_prompt: ""
      )

      issue = %Issue{
        id: "issue-pi-append-system-prompt",
        identifier: "PI-104",
        title: "Suppress append system prompt discovery",
        description: "Verify blank append system prompt flag",
        state: "Done",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      args =
        trace_file
        |> File.read!()
        |> String.split("\n")
        |> Enum.flat_map(fn
          "ARG:" <> rest ->
            [_index, arg] = String.split(rest, ":", parts: 2)
            [arg]

          _line ->
            []
        end)

      append_index = Enum.find_index(args, &(&1 == "--append-system-prompt"))

      assert is_integer(append_index)
      assert Enum.at(args, append_index + 1) == ""
    after
      restore_env("SYMP_TEST_PI_TRACE", previous_trace)
      File.rm_rf(test_root)
    end
  end
end
