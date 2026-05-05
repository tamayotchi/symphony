defmodule SymphonyElixir.KanbanLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeBoardLinearClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def graphql(_query, _variables) do
      Agent.get_and_update(SymphonyElixir.KanbanLiveTest.LinearResponses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :no_fake_linear_response}, []}
      end)
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    start_supervised!(%{
      id: __MODULE__.LinearResponses,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.LinearResponses]]}
    })

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeBoardLinearClient)

    :ok
  end

  test "kanban liveview renders project columns and refreshes issue cards" do
    queue_linear_responses([
      {:ok, project_response()},
      {:ok, issues_response([issue("TAM-1", "Todo", "Set up board", "2026-05-05T10:00:00Z")])},
      {:ok, project_response()},
      {:ok, issues_response([issue("TAM-1", "Todo", "Set up board", "2026-05-05T10:00:00Z")])},
      {:ok, project_response()},
      {:ok,
       issues_response([
         issue("TAM-1", "In Progress", "Set up board", "2026-05-05T11:00:00Z"),
         issue("TAM-2", "Todo", "Follow-up polish", "2026-05-05T11:05:00Z")
       ])}
    ])

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/kanban")
    assert html =~ "Project Kanban"
    assert html =~ "Demo Project"
    assert html =~ "Auto-refresh every 5s"
    assert html =~ "Always-current project view"
    assert html =~ "Todo"
    assert html =~ "In Progress"
    assert html =~ "Set up board"
    assert html =~ "No issues in this state."

    send(view.pid, :refresh_board)

    refreshed_html = render(view)
    assert refreshed_html =~ "Follow-up polish"
    assert refreshed_html =~ "Updated "
  end

  test "kanban liveview renders a friendly error state when Linear data fails" do
    queue_linear_responses([{:error, :missing_linear_api_token}, {:error, :missing_linear_api_token}])

    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/kanban")
    assert html =~ "Kanban unavailable"
    assert html =~ "missing_linear_api_token"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp queue_linear_responses(responses) do
    Agent.update(__MODULE__.LinearResponses, fn _ -> responses end)
  end

  defp project_response do
    %{
      "data" => %{
        "projects" => %{
          "nodes" => [
            %{
              "id" => "project-1",
              "name" => "Demo Project",
              "url" => "https://linear.app/demo/project/demo-project",
              "state" => "started",
              "teams" => %{
                "nodes" => [
                  %{
                    "id" => "team-1",
                    "name" => "Demo Team",
                    "states" => %{
                      "nodes" => [
                        %{"id" => "todo", "name" => "Todo", "type" => "unstarted", "color" => "#8892a0", "position" => 1},
                        %{"id" => "progress", "name" => "In Progress", "type" => "started", "color" => "#f2c94c", "position" => 2},
                        %{"id" => "done", "name" => "Done", "type" => "completed", "color" => "#4caf50", "position" => 3}
                      ]
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    }
  end

  defp issues_response(issues) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => issues,
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  defp issue(identifier, state_name, title, updated_at) do
    %{
      "id" => String.downcase(identifier),
      "identifier" => identifier,
      "title" => title,
      "url" => "https://linear.app/demo/issue/#{String.downcase(identifier)}/#{identifier}",
      "priority" => 0,
      "updatedAt" => updated_at,
      "createdAt" => updated_at,
      "state" => %{"id" => String.downcase(String.replace(state_name, " ", "-")), "name" => state_name},
      "labels" => %{"nodes" => [%{"name" => "backend", "color" => "#6c5ce7"}]},
      "assignee" => %{"name" => "Juan", "displayName" => "tamayotchi26"}
    }
  end
end
