defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Projects, RuntimeContext, StatusDashboard, Tracker}

  @kanban_states ["Backlog", "Todo", "In Progress", "Human Review", "Done"]

  @spec state_payload(timeout()) :: map()
  def state_payload(snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Projects.aggregate_snapshot(snapshot_timeout_ms) do
      %{} = snapshot ->
        base_payload = %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

        case Enum.map(Map.get(snapshot, :projects, []), &project_payload/1) do
          [] -> base_payload
          projects -> Map.put(base_payload, :projects, projects)
        end

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, snapshot_timeout_ms) when is_binary(issue_identifier) do
    with {:ok, issue_data} <- Projects.find_issue(issue_identifier, snapshot_timeout_ms) do
      {:ok,
       issue_payload_body(
         issue_identifier,
         issue_data.running,
         issue_data.retry,
         issue_data.project
       )}
    end
  end

  @spec kanban_payload(timeout()) :: map()
  def kanban_payload(timeout \\ 15_000) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Projects.projects() do
      [] ->
        empty_kanban_payload(generated_at, [])

      projects ->
        project_payloads = kanban_project_payloads(projects, timeout)

        %{
          generated_at: generated_at,
          states: @kanban_states,
          status: aggregate_kanban_status(project_payloads),
          columns: aggregate_kanban_columns(project_payloads),
          projects: project_payloads
        }
    end
  end

  @spec refresh_payload() :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload do
    case Projects.request_refresh() do
      {:error, :unavailable} ->
        {:error, :unavailable}

      {:ok, payload} ->
        {:ok, refresh_payload_body(payload)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, project) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, project),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
    |> maybe_put(:project_id, project && project.id)
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp kanban_project_payloads(projects, timeout) do
    projects
    |> Task.async_stream(&kanban_project_payload/1,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: max(length(projects), 1)
    )
    |> Enum.zip(projects)
    |> Enum.map(fn
      {{:ok, payload}, _project} -> payload
      {{:exit, _reason}, project} -> unavailable_kanban_project(project, :timeout)
    end)
  end

  defp kanban_project_payload(project) do
    case fetch_project_kanban_issues(project) do
      {:ok, issues} ->
        %{
          project_id: project.id,
          project_slug: Projects.project_slug(project),
          status: "ok",
          columns: build_kanban_columns(issues, project)
        }

      {:error, reason} ->
        unavailable_kanban_project(project, reason)
    end
  end

  defp fetch_project_kanban_issues(project) do
    RuntimeContext.with_context(%{project_id: project.id, workflow_path: project.workflow_path}, fn ->
      with {:ok, _settings} <- Config.settings() do
        Tracker.fetch_issues_by_states(@kanban_states)
      end
    end)
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp build_kanban_columns(issues, project) when is_list(issues) do
    Enum.map(@kanban_states, fn state ->
      state_issues =
        issues
        |> Enum.filter(&(normalize_state(Map.get(&1, :state)) == normalize_state(state)))
        |> Enum.map(&kanban_issue_payload(&1, project))

      %{state: state, count: length(state_issues), issues: state_issues}
    end)
  end

  defp unavailable_kanban_project(project, reason) do
    %{
      project_id: project.id,
      project_slug: Projects.project_slug(project),
      status: "unavailable",
      error: inspect_kanban_error(reason),
      columns: empty_kanban_columns()
    }
  end

  defp empty_kanban_payload(generated_at, projects) do
    %{
      generated_at: generated_at,
      states: @kanban_states,
      status: "unavailable",
      columns: empty_kanban_columns(),
      projects: projects
    }
  end

  defp aggregate_kanban_status(project_payloads) do
    if Enum.any?(project_payloads, &(&1.status == "ok")), do: "ok", else: "unavailable"
  end

  defp aggregate_kanban_columns(project_payloads) do
    Enum.map(@kanban_states, fn state ->
      issues =
        project_payloads
        |> Enum.flat_map(fn project ->
          project.columns
          |> Enum.find(%{issues: []}, &(&1.state == state))
          |> Map.fetch!(:issues)
        end)

      %{state: state, count: length(issues), issues: issues}
    end)
  end

  defp empty_kanban_columns do
    Enum.map(@kanban_states, &%{state: &1, count: 0, issues: []})
  end

  defp kanban_issue_payload(issue, project) do
    %{
      id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title) || Map.get(issue, :identifier) || "Untitled issue",
      url: Map.get(issue, :url),
      priority: Map.get(issue, :priority),
      labels: Map.get(issue, :labels, []),
      updated_at: iso8601(Map.get(issue, :updated_at)),
      project_id: project.id
    }
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp inspect_kanban_error(reason) when is_binary(reason), do: reason
  defp inspect_kanban_error(reason), do: inspect(reason)

  defp project_payload(project) do
    %{
      project_id: project.project_id,
      workflow_path: project.workflow_path,
      project_slug: project.project_slug,
      workspace_root: project.workspace_root,
      status: to_string(project.status),
      counts: %{
        running: project.running_count,
        retrying: project.retrying_count
      },
      codex_totals: project.codex_totals,
      polling: project.polling
    }
  end

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> maybe_put(:project_id, Map.get(entry, :project_id))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> maybe_put(:project_id, Map.get(entry, :project_id))
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> maybe_put(:project_id, Map.get(running, :project_id))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
    |> maybe_put(:project_id, Map.get(retry, :project_id))
  end

  defp workspace_path(issue_identifier, running, retry, project) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      workspace_path_from_project(issue_identifier, project)
  end

  defp refresh_payload_body(payload) when is_map(payload) do
    payload
    |> maybe_update(:requested_at, &DateTime.to_iso8601/1)
    |> maybe_update(:projects, fn projects ->
      Enum.into(projects, %{}, fn {project_id, response} ->
        {project_id, serialize_refresh_response(response)}
      end)
    end)
  end

  defp serialize_refresh_response(%{} = response) do
    maybe_update(response, :requested_at, &DateTime.to_iso8601/1)
  end

  defp serialize_refresh_response(:unavailable), do: %{queued: false, status: "unavailable"}
  defp serialize_refresh_response(other), do: %{queued: false, status: to_string(other)}

  defp workspace_path_from_project(issue_identifier, %{workspace_root: workspace_root}) when is_binary(workspace_root) do
    Path.join(workspace_root, issue_identifier)
  end

  defp workspace_path_from_project(issue_identifier, %{workflow_path: workflow_path}) when is_binary(workflow_path) do
    Path.join(Config.settings!(workflow_path: workflow_path).workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp maybe_put(payload, _key, value) when value in [nil, ""], do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_update(map, key, fun) when is_map(map) and is_atom(key) and is_function(fun, 1) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end
end
