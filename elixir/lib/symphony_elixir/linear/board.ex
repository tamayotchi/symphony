defmodule SymphonyElixir.Linear.Board do
  # TODO: Remove this file once we don't use more linear.app
  @moduledoc """
  Loads a project-level kanban view from Linear.
  """

  alias SymphonyElixir.{Config, Linear.Client}

  @project_query """
  query SymphonyLinearProjectBoardProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        url
        state
        teams(first: 1) {
          nodes {
            id
            name
            states(first: 50) {
              nodes {
                id
                name
                type
                color
                position
              }
            }
          }
        }
      }
    }
  }
  """

  @issues_query """
  query SymphonyLinearProjectBoardIssues($projectSlug: String!, $first: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        url
        priority
        updatedAt
        createdAt
        state {
          id
          name
        }
        labels {
          nodes {
            name
            color
          }
        }
        assignee {
          name
          displayName
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @move_issue_mutation """
  mutation SymphonyLinearProjectBoardMoveIssue($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @issue_page_size 50

  @type board_issue :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          priority: integer() | nil,
          state_id: String.t() | nil,
          state_name: String.t() | nil,
          updated_at: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          assignee_name: String.t() | nil,
          labels: [map()]
        }

  @spec fetch_project_board() :: {:ok, map()} | {:error, term()}
  def fetch_project_board do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, project} <- fetch_project(project_slug),
             {:ok, issues} <- fetch_project_issues(project_slug) do
          {:ok, build_board(project, issues)}
        end
    end
  end

  @spec move_issue_to_state(String.t(), String.t()) :: :ok | {:error, term()}
  def move_issue_to_state(issue_id, state_id) when is_binary(issue_id) and is_binary(state_id) do
    with :ok <- validate_move_input(issue_id, state_id),
         {:ok, response} <- client_module().graphql(@move_issue_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  def move_issue_to_state(_issue_id, _state_id), do: {:error, :invalid_issue_move}

  defp fetch_project(project_slug) do
    with {:ok, response} <- client_module().graphql(@project_query, %{projectSlug: project_slug}),
         %{} = project <- get_in(response, ["data", "projects", "nodes", Access.at(0)]) do
      {:ok, project}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_project_not_found}
    end
  end

  defp fetch_project_issues(project_slug) do
    fetch_project_issues_page(project_slug, nil, [])
  end

  defp fetch_project_issues_page(project_slug, after_cursor, acc_issues) do
    case client_module().graphql(@issues_query, %{projectSlug: project_slug, first: @issue_page_size, after: after_cursor}) do
      {:ok, response} ->
        with %{"nodes" => nodes, "pageInfo" => page_info} <- get_in(response, ["data", "issues"]) do
          issues = Enum.map(nodes, &normalize_issue/1)
          updated_acc = Enum.reverse(issues, acc_issues)

          if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) and page_info["endCursor"] != "" do
            fetch_project_issues_page(project_slug, page_info["endCursor"], updated_acc)
          else
            {:ok, Enum.reverse(updated_acc)}
          end
        else
          _ -> {:error, :linear_unknown_payload}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_board(project, issues) do
    team = get_in(project, ["teams", "nodes", Access.at(0)]) || %{}

    states =
      project
      |> team_states()
      |> Enum.sort_by(&{Map.get(&1, :position) || 9_999, Map.get(&1, :name) || ""})

    issues_by_state = Enum.group_by(issues, & &1.state_name)

    columns =
      states
      |> Enum.reduce([], fn state, acc ->
        column_issues =
          issues_by_state
          |> Map.get(state.name, [])
          |> Enum.sort_by(&issue_sort_key/1)

        if column_issues == [] do
          acc
        else
          [Map.put(state, :issues, column_issues) | acc]
        end
      end)
      |> Enum.reverse()
      |> append_unknown_state_columns(issues_by_state)

    %{
      project: %{
        id: project["id"],
        name: project["name"],
        url: project["url"],
        state: project["state"]
      },
      team: %{
        id: team["id"],
        name: team["name"]
      },
      states: states,
      columns: columns,
      total_issues: length(issues),
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp append_unknown_state_columns(columns, issues_by_state) do
    known_names = MapSet.new(Enum.map(columns, & &1.name))

    extras =
      issues_by_state
      |> Enum.reject(fn {state_name, _issues} -> MapSet.member?(known_names, state_name) end)
      |> Enum.sort_by(fn {state_name, _issues} -> state_name || "" end)
      |> Enum.map(fn {state_name, state_issues} ->
        %{
          id: nil,
          name: state_name || "Unknown",
          type: "unmapped",
          color: nil,
          position: 9_999,
          issues: Enum.sort_by(state_issues, &issue_sort_key/1)
        }
      end)

    columns ++ extras
  end

  defp team_states(project) do
    project
    |> get_in(["teams", "nodes", Access.at(0), "states", "nodes"])
    |> case do
      states when is_list(states) -> Enum.map(states, &normalize_state/1)
      _ -> []
    end
  end

  defp normalize_state(state) do
    %{
      id: state["id"],
      name: state["name"],
      type: state["type"],
      color: state["color"],
      position: state["position"]
    }
  end

  defp normalize_issue(issue) do
    assignee = issue["assignee"] || %{}
    state = issue["state"] || %{}

    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      priority: issue["priority"],
      state_id: state["id"],
      state_name: state["name"],
      updated_at: parse_datetime(issue["updatedAt"]),
      created_at: parse_datetime(issue["createdAt"]),
      assignee_name: assignee["displayName"] || assignee["name"],
      labels: normalize_labels(issue["labels"])
    }
  end

  defp normalize_labels(%{"nodes" => labels}) when is_list(labels) do
    Enum.map(labels, fn label -> %{name: label["name"], color: label["color"]} end)
  end

  defp normalize_labels(_), do: []

  defp validate_move_input(issue_id, state_id) do
    if String.trim(issue_id) == "" or String.trim(state_id) == "" do
      {:error, :invalid_issue_move}
    else
      :ok
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp issue_sort_key(issue) do
    updated_unix = if issue.updated_at, do: -DateTime.to_unix(issue.updated_at, :microsecond), else: 0
    created_unix = if issue.created_at, do: -DateTime.to_unix(issue.created_at, :microsecond), else: 0
    {updated_unix, created_unix, issue.identifier || ""}
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end
