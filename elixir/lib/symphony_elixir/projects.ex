defmodule SymphonyElixir.Projects do
  @moduledoc """
  Helpers for multi-project orchestration and observability aggregation.
  """

  alias SymphonyElixir.{BootConfig, Orchestrator}

  @spec enabled?() :: boolean()
  def enabled? do
    projects() != []
  end

  @spec projects() :: [map()]
  def projects do
    BootConfig.projects()
  end

  @spec project(String.t()) :: map() | nil
  def project(project_id) when is_binary(project_id) do
    Enum.find(projects(), &(Map.get(&1, :id) == project_id))
  end

  @spec orchestrator_name(map() | String.t()) :: GenServer.name()
  def orchestrator_name(%{orchestrator: orchestrator}) when not is_nil(orchestrator), do: orchestrator

  def orchestrator_name(%{id: project_id}), do: orchestrator_name(project_id)

  def orchestrator_name(project_id) when is_binary(project_id) do
    {:via, Registry, {SymphonyElixir.ProjectRegistry, {:orchestrator, project_id}}}
  end

  @spec aggregate_snapshot(timeout()) :: map() | :unavailable
  def aggregate_snapshot(timeout) do
    case projects() do
      [] ->
        :unavailable

      projects ->
        snapshots = concurrent_project_entries(projects, timeout, &project_snapshot_entry/2)

        %{
          running: Enum.flat_map(snapshots, &Map.get(&1, :running, [])),
          retrying: Enum.flat_map(snapshots, &Map.get(&1, :retrying, [])),
          codex_totals: Enum.reduce(snapshots, empty_totals(), &sum_totals/2),
          rate_limits: aggregate_rate_limits(snapshots),
          polling: %{
            checking?: Enum.any?(snapshots, &get_in(&1, [:polling, :checking?])),
            next_poll_in_ms: min_poll_in_ms(snapshots),
            projects: Enum.map(snapshots, &Map.take(&1, [:project_id, :polling]))
          },
          projects: snapshots
        }
    end
  end

  @spec request_refresh() :: {:ok, map()} | {:error, :unavailable}
  def request_refresh do
    case projects() do
      [] ->
        {:error, :unavailable}

      projects ->
        responses =
          Enum.map(projects, fn project ->
            orchestrator = orchestrator_name(project)
            {project.id, Orchestrator.request_refresh(orchestrator)}
          end)

        queued_responses = Enum.reject(responses, fn {_project_id, response} -> response == :unavailable end)

        if queued_responses == [] do
          {:error, :unavailable}
        else
          {:ok,
           %{
             queued: true,
             coalesced: Enum.all?(queued_responses, fn {_id, response} -> response.coalesced end),
             requested_at: DateTime.utc_now(),
             operations: ["poll", "reconcile"],
             projects: Enum.into(responses, %{}, fn {project_id, response} -> {project_id, response} end)
           }}
        end
    end
  end

  @spec find_issue(String.t(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def find_issue(issue_identifier, timeout) when is_binary(issue_identifier) do
    projects()
    |> Enum.find_value(fn project ->
      snapshot = Orchestrator.snapshot(orchestrator_name(project), timeout)

      case snapshot do
        %{running: running, retrying: retrying} ->
          running_entry = Enum.find(running, &(&1.identifier == issue_identifier))
          retry_entry = Enum.find(retrying, &(&1.identifier == issue_identifier))

          if is_nil(running_entry) and is_nil(retry_entry) do
            nil
          else
            {:ok,
             %{
               project: project,
               snapshot: snapshot,
               running: running_entry,
               retry: retry_entry
             }}
          end

        _ ->
          nil
      end
    end) || {:error, :issue_not_found}
  end

  @spec workspace_root(map()) :: Path.t() | nil
  def workspace_root(%{workspace_root: workspace_root}) when is_binary(workspace_root), do: workspace_root
  def workspace_root(_project), do: nil

  @spec project_slug(map()) :: String.t() | nil
  def project_slug(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  def project_slug(_project), do: nil

  @spec max_concurrent_agents(map()) :: pos_integer() | nil
  def max_concurrent_agents(%{max_concurrent_agents: max_agents}) when is_integer(max_agents) and max_agents > 0,
    do: max_agents

  def max_concurrent_agents(_project), do: nil

  defp project_snapshot_entry(project, timeout) do
    project_id = project.id
    snapshot = Orchestrator.snapshot(orchestrator_name(project), timeout)
    workspace_root = workspace_root(project)
    project_slug = project_slug(project)

    case snapshot do
      %{running: running, retrying: retrying, codex_totals: codex_totals} = payload ->
        %{
          project_id: project_id,
          workflow_path: project.workflow_path,
          project_slug: project_slug,
          workspace_root: workspace_root,
          status: :ok,
          running_count: length(running),
          retrying_count: length(retrying),
          running: Enum.map(running, &Map.put(&1, :project_id, project_id)),
          retrying: Enum.map(retrying, &Map.put(&1, :project_id, project_id)),
          codex_totals: codex_totals,
          rate_limits: Map.get(payload, :rate_limits),
          polling: Map.get(payload, :polling)
        }

      :timeout ->
        unavailable_project(project_id, project, workspace_root, project_slug, :timeout)

      :unavailable ->
        unavailable_project(project_id, project, workspace_root, project_slug, :unavailable)

      _ ->
        unavailable_project(project_id, project, workspace_root, project_slug, :unavailable)
    end
  end

  defp unavailable_project(project_id, project, workspace_root, project_slug, status) do
    %{
      project_id: project_id,
      workflow_path: project.workflow_path,
      project_slug: project_slug,
      workspace_root: workspace_root,
      status: status,
      running_count: 0,
      retrying_count: 0,
      running: [],
      retrying: [],
      codex_totals: empty_totals(),
      rate_limits: nil,
      polling: nil
    }
  end

  defp empty_totals do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
  end

  defp sum_totals(%{codex_totals: totals}, acc), do: sum_totals(totals, acc)

  defp sum_totals(totals, acc) when is_map(totals) do
    %{
      input_tokens: Map.get(acc, :input_tokens, 0) + Map.get(totals, :input_tokens, 0),
      output_tokens: Map.get(acc, :output_tokens, 0) + Map.get(totals, :output_tokens, 0),
      total_tokens: Map.get(acc, :total_tokens, 0) + Map.get(totals, :total_tokens, 0),
      seconds_running: Map.get(acc, :seconds_running, 0) + Map.get(totals, :seconds_running, 0)
    }
  end

  defp min_poll_in_ms(snapshots) do
    snapshots
    |> Enum.flat_map(fn snapshot ->
      case get_in(snapshot, [:polling, :next_poll_in_ms]) do
        value when is_integer(value) -> [value]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  defp aggregate_rate_limits([]), do: nil

  defp aggregate_rate_limits([snapshot]) do
    Map.get(snapshot, :rate_limits)
  end

  defp aggregate_rate_limits(snapshots) do
    Map.new(snapshots, &{&1.project_id, &1.rate_limits})
  end

  defp concurrent_project_entries(projects, timeout, fun) when is_list(projects) and is_function(fun, 2) do
    max_concurrency = max(length(projects), 1)

    projects
    |> Task.async_stream(fn project -> fun.(project, timeout) end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: max_concurrency
    )
    |> Enum.zip(projects)
    |> Enum.map(fn
      {{:ok, entry}, _project} ->
        entry

      {{:exit, _reason}, project} ->
        unavailable_project(project.id, project, workspace_root(project), project_slug(project), :timeout)
    end)
  end
end
