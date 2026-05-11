defmodule SymphonyElixirWeb.DashboardLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SymphonyElixirWeb.DashboardLive

  test "renders terminal transcript disclosure for running sessions" do
    html =
      %{
        payload: %{
          counts: %{running: 1, retrying: 0},
          running: [
            %{
              project_id: "symphony",
              issue_identifier: "TAM-19",
              state: "In Progress",
              session_id: "thread-1-turn-1",
              turn_count: 1,
              started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
              last_event: :notification,
              last_message: "agent message streaming",
              last_event_at: nil,
              tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
              session_file: "/tmp/pi-session.jsonl",
              terminal_transcript: %{
                available: true,
                source: "/tmp/pi-session.jsonl",
                truncated: false,
                entries: [
                  %{kind: "user", label: "user", text: "Open Running Sessions", compact: true},
                  %{kind: "thinking", label: "thinking", text: "Inspect task", compact: true},
                  %{kind: "tool", label: "tool call", text: "bash git status", compact: true},
                  %{kind: "assistant", label: "assistant", text: "Terminal view is ready", compact: false}
                ]
              }
            }
          ],
          retrying: [],
          codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 0},
          rate_limits: nil
        },
        now: DateTime.utc_now()
      }
      |> DashboardLive.render()
      |> rendered_to_string()

    assert html =~ "Terminal view for"
    assert html =~ "TAM-19"
    assert html =~ "Pi RPC transcript"
    assert html =~ "Open Running Sessions"
    assert html =~ "Inspect task"
    assert html =~ "bash git status"
    assert html =~ "Terminal view is ready"
  end

  test "does not render a terminal disclosure for non-Pi sessions" do
    html =
      %{
        payload: %{
          counts: %{running: 1, retrying: 0},
          running: [
            %{
              project_id: "symphony",
              issue_identifier: "TAM-20",
              state: "In Progress",
              session_id: "thread-1-turn-1",
              turn_count: 1,
              started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
              last_event: :notification,
              last_message: "agent message streaming",
              last_event_at: nil,
              tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
            }
          ],
          retrying: [],
          codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 0},
          rate_limits: nil
        },
        now: DateTime.utc_now()
      }
      |> DashboardLive.render()
      |> rendered_to_string()

    refute html =~ "Terminal view for"
    refute html =~ "waiting for Pi RPC session"
  end
end
