defmodule SymphonyElixir.Pi.SessionTranscriptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Pi.SessionTranscript

  test "reads Pi RPC message JSONL as terminal entries" do
    session_file =
      write_session_file!([
        %{"type" => "message", "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => "implement terminal view"}]}},
        %{
          "type" => "message",
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "thinking", "thinking" => "inspect running sessions"},
              %{"type" => "toolCall", "name" => "bash", "arguments" => %{"command" => "git status"}},
              %{"type" => "text", "text" => "Done."}
            ]
          }
        },
        %{"type" => "message", "message" => %{"role" => "toolResult", "content" => [%{"type" => "text", "text" => "## main"}]}}
      ])

    assert %{
             available: true,
             source: ^session_file,
             truncated: false,
             entries: [user, thinking, tool_call, assistant, tool_result]
           } = SessionTranscript.read(session_file)

    assert user == %{kind: "user", label: "user", text: "implement terminal view", compact: true}
    assert thinking == %{kind: "thinking", label: "thinking", text: "inspect running sessions", compact: true}
    assert tool_call.kind == "tool"
    assert tool_call.label == "tool call"
    assert tool_call.compact == true
    assert tool_call.text =~ "bash"
    assert tool_call.text =~ "git status"
    assert assistant == %{kind: "assistant", label: "assistant", text: "Done.", compact: false}
    assert tool_result == %{kind: "tool", label: "tool", text: "## main", compact: true}
  end

  test "reads RPC events for streaming thinking, tool, and assistant text" do
    session_file =
      write_session_file!([
        %{
          "method" => "codex/event/agent_reasoning",
          "params" => %{"msg" => %{"payload" => %{"summaryText" => "compare transcript parsers"}}}
        },
        %{
          "method" => "codex/event/exec_command_begin",
          "params" => %{"msg" => %{"command" => "mix test"}}
        },
        %{
          "method" => "codex/event/agent_message_delta",
          "params" => %{"msg" => %{"payload" => %{"delta" => "Rendered terminal panel"}}}
        }
      ])

    assert %{entries: [thinking, tool, assistant]} = SessionTranscript.read(session_file)
    assert thinking.kind == "thinking"
    assert thinking.text == "compare transcript parsers"
    assert tool.kind == "tool"
    assert tool.text == "mix test"
    assert assistant.kind == "assistant"
    assert assistant.text == "Rendered terminal panel"
  end

  test "keeps turn_end tool results and retains the most recent capped entries" do
    session_file =
      write_session_file!(
        Enum.map(1..205, fn index ->
          %{
            "type" => "turn_end",
            "toolResults" => [%{"toolName" => "bash", "output" => "result-#{index}"}],
            "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "assistant-#{index}"}]}
          }
        end)
      )

    assert %{truncated: true, entries: entries} = SessionTranscript.read(session_file)
    assert length(entries) == 200

    [first | _] = entries
    last = List.last(entries)

    assert first == %{kind: "tool", label: "bash", text: "result-106", compact: true}
    assert last == %{kind: "assistant", label: "assistant", text: "assistant-205", compact: false}
  end

  test "caps oversized entry text" do
    session_file =
      write_session_file!([
        %{"type" => "message", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => String.duplicate("a", 4_100)}]}}
      ])

    assert %{entries: [%{text: text}]} = SessionTranscript.read(session_file)
    assert String.length(text) < 4_120
    assert String.ends_with?(text, "\n…[truncated]")
  end

  test "reports unavailable transcript when the session file is missing" do
    missing = Path.join(System.tmp_dir!(), "missing-pi-session-#{System.unique_integer([:positive])}.jsonl")

    assert SessionTranscript.read(missing) == %{available: false, source: missing, entries: [], truncated: false}
    assert SessionTranscript.read(nil) == %{available: false, source: nil, entries: [], truncated: false}
  end

  defp write_session_file!(events) do
    path = Path.join(System.tmp_dir!(), "pi-session-#{System.unique_integer([:positive])}.jsonl")

    body = Enum.map_join(events, "\n", &Jason.encode!/1)

    File.write!(path, body <> "\n")

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
