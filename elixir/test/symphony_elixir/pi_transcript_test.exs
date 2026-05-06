defmodule SymphonyElixir.PiTranscriptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.Transcript

  test "loads the latest Pi RPC session and normalizes terminal events" do
    workspace_root = workspace_root("pi-transcript")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    old_session = Path.join([workspace_root, "TAM-1", ".pi-rpc-sessions", "1", "a.jsonl"])
    new_session = Path.join([workspace_root, "TAM-1", ".pi-rpc-sessions", "2", "z.jsonl"])
    proof_events = Path.join([workspace_root, "TAM-1", ".pi-rpc-sessions", "2", "proof", "events.jsonl"])

    write_jsonl!(old_session, [session_payload("old-session")])
    write_jsonl!(proof_events, [%{type: "proof", timestamp: "2026-05-06T00:00:00Z"}])

    write_jsonl!(new_session, [
      session_payload("new-session"),
      %{
        type: "model_change",
        timestamp: "2026-05-06T10:00:01Z",
        provider: "github-copilot",
        modelId: "gpt-5.4"
      },
      %{
        type: "message",
        timestamp: "2026-05-06T10:00:02Z",
        message: %{role: "user", content: [%{type: "text", text: "Please implement terminal view."}]}
      },
      %{
        type: "message",
        timestamp: "2026-05-06T10:00:03Z",
        message: %{
          role: "assistant",
          content: [
            %{type: "thinking", thinking: "Inspect the kanban LiveView and Pi JSONL session."},
            %{type: "toolCall", id: "call-1", name: "bash", arguments: %{command: "rg kanban"}}
          ]
        }
      },
      %{
        type: "message",
        timestamp: "2026-05-06T10:00:04Z",
        message: %{
          role: "toolResult",
          toolCallId: "call-1",
          toolName: "bash",
          isError: false,
          content: [%{type: "text", text: "lib/symphony_elixir_web/live/kanban_live.ex"}]
        }
      },
      %{
        type: "message",
        timestamp: "2026-05-06T10:00:05Z",
        message: %{role: "assistant", content: [%{type: "text", text: "Terminal view implemented."}]}
      }
    ])

    assert {:ok, transcript} = Transcript.fetch_issue("TAM-1")
    assert transcript.session_id == "new-session"
    assert transcript.session_file == new_session
    assert Enum.map(transcript.events, & &1.kind) == [:session, :meta, :message, :thinking, :tool_call, :tool_result, :message]

    assert Enum.any?(transcript.events, &(&1.title == "User" and &1.body =~ "Please implement"))
    assert Enum.any?(transcript.events, &(&1.title == "Thinking" and &1.summary =~ "Inspect the kanban"))
    assert Enum.any?(transcript.events, &(&1.title == "Tool call · bash" and &1.body =~ "rg kanban"))
    assert Enum.any?(transcript.events, &(&1.title == "Tool result · bash" and &1.status == :ok))
    assert Enum.any?(transcript.events, &(&1.title == "Assistant" and &1.body =~ "Terminal view implemented"))
  end

  test "reports missing Pi session data as a non-fatal transcript error" do
    workspace_root = workspace_root("pi-transcript-missing")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, :pi_session_dir_missing} = Transcript.fetch_issue("TAM-404")
  end

  test "keeps malformed JSONL lines visible in the terminal stream" do
    workspace_root = workspace_root("pi-transcript-malformed")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    session_file = Path.join([workspace_root, "TAM-2", ".pi-rpc-sessions", "1", "session.jsonl"])
    File.mkdir_p!(Path.dirname(session_file))
    File.write!(session_file, Jason.encode!(session_payload("session-with-malformed")) <> "\nnot-json\n")

    assert {:ok, transcript} = Transcript.fetch_issue("TAM-2")
    assert Enum.map(transcript.events, & &1.kind) == [:session, :malformed]
    assert Enum.any?(transcript.events, &(&1.status == :error and &1.body =~ "Invalid JSON"))
  end

  defp workspace_root(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp write_jsonl!(path, payloads) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(payloads, "\n", &Jason.encode!/1) <> "\n")
  end

  defp session_payload(session_id) do
    %{
      type: "session",
      version: 3,
      id: session_id,
      timestamp: "2026-05-06T10:00:00Z",
      cwd: "/workspace/TAM-1"
    }
  end
end
