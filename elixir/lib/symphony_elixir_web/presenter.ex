defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Projects, StatusDashboard}
  alias SymphonyElixir.Pi.SessionTranscript

  @terminal_history_limit 12

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
          terminal_history: terminal_history_payload(snapshot.running),
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
      logs:
        %{codex_session_logs: []}
        |> maybe_put(:terminal_transcript, running && session_transcript_payload(running)),
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
    |> maybe_put(:session_file, Map.get(entry, :session_file))
    |> maybe_put(:proof_dir, Map.get(entry, :proof_dir))
    |> maybe_put(:proof_events_path, Map.get(entry, :proof_events_path))
    |> maybe_put(:proof_summary_path, Map.get(entry, :proof_summary_path))
    |> maybe_put(:terminal_transcript, session_transcript_payload(entry))
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
    |> maybe_put(:session_file, Map.get(running, :session_file))
    |> maybe_put(:proof_dir, Map.get(running, :proof_dir))
    |> maybe_put(:proof_events_path, Map.get(running, :proof_events_path))
    |> maybe_put(:proof_summary_path, Map.get(running, :proof_summary_path))
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

  defp session_transcript_payload(running) do
    case Map.get(running, :session_file) do
      session_file when is_binary(session_file) and session_file != "" -> SessionTranscript.read(session_file)
      _ -> nil
    end
  end

  defp terminal_history_payload(running_entries) when is_list(running_entries) do
    running_entries
    |> Enum.flat_map(&terminal_history_entries/1)
    |> Enum.uniq_by(& &1.session_file)
    |> Enum.sort_by(& &1.updated_at_unix, :desc)
    |> Enum.take(@terminal_history_limit)
    |> Enum.map(&Map.delete(&1, :updated_at_unix))
  end

  defp terminal_history_payload(_running_entries), do: []

  defp terminal_history_entries(running) when is_map(running) do
    running
    |> terminal_history_files()
    |> Enum.map(&terminal_history_entry(running, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp terminal_history_entries(_running), do: []

  defp terminal_history_files(running) do
    running
    |> terminal_history_roots()
    |> Enum.flat_map(fn root -> Path.wildcard(Path.join([root, "**", "*.jsonl"])) end)
    |> Kernel.++([Map.get(running, :session_file)])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp terminal_history_roots(running) do
    [Map.get(running, :session_dir), running |> Map.get(:workspace_path) |> terminal_workspace_session_root()]
    |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
  end

  defp terminal_workspace_session_root(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, Config.settings!().pi.session_dir_name)
  end

  defp terminal_workspace_session_root(_workspace_path), do: nil

  defp terminal_history_entry(running, session_file) do
    case File.stat(session_file, time: :posix) do
      {:ok, %{type: :regular, mtime: updated_at_unix}} ->
        transcript = SessionTranscript.read(session_file)

        %{
          issue_id: running.issue_id,
          issue_identifier: running.identifier,
          project_id: Map.get(running, :project_id),
          state: running.state,
          session_id: terminal_history_session_id(session_file),
          session_file: session_file,
          updated_at: DateTime.from_unix!(updated_at_unix) |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          updated_at_unix: updated_at_unix,
          terminal_transcript: transcript
        }

      _ ->
        nil
    end
  end

  defp terminal_history_session_id(session_file) do
    session_file
    |> Path.basename(".jsonl")
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
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
