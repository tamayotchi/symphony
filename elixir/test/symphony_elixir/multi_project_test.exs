defmodule SymphonyElixir.MultiProjectTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{BootConfig, Projects, RuntimeContext, Workflow, WorkflowStore}
  alias SymphonyElixir.Manifest.Schema
  alias SymphonyElixirWeb.Presenter

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      if delay_ms = Keyword.get(state, :snapshot_delay_ms) do
        Process.sleep(delay_ms)
      end

      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    original_boot_config = Application.get_env(:symphony_elixir, :boot_config)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      if is_nil(original_boot_config) do
        Application.delete_env(:symphony_elixir, :boot_config)
      else
        Application.put_env(:symphony_elixir, :boot_config, original_boot_config)
      end

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "boot config loads a multi-project manifest with relative workflow paths" do
    root = Path.join(System.tmp_dir!(), "symphony-multi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    backend_workflow = Path.join(root, "backend/WORKFLOW.md")
    frontend_workflow = Path.join(root, "frontend/WORKFLOW.md")
    File.mkdir_p!(Path.dirname(backend_workflow))
    File.mkdir_p!(Path.dirname(frontend_workflow))

    write_workflow_file!(backend_workflow, workspace_root: "./backend-workspaces")
    write_workflow_file!(frontend_workflow, workspace_root: "./frontend-workspaces")

    manifest = Path.join(root, "SYMPHONY.md")

    File.write!(manifest, """
    ---
    server:
      host: 127.0.0.1
      port: 4040
    observability:
      dashboard_enabled: true
      refresh_ms: 250
      render_interval_ms: 30
    projects:
      - id: backend
        workflow: ./backend/WORKFLOW.md
      - id: frontend
        workflow: ./frontend/WORKFLOW.md
    ---
    Multi-project Symphony manifest.
    """)

    assert {:ok, %{manifest_path: ^manifest, projects: projects, server: server, observability: observability}} =
             BootConfig.load(manifest)

    assert Enum.map(projects, & &1.id) == ["backend", "frontend"]
    assert Enum.map(projects, & &1.workflow_path) == [backend_workflow, frontend_workflow]
    assert Enum.map(projects, & &1.workspace_root) == [Path.join(root, "backend/backend-workspaces"), Path.join(root, "frontend/frontend-workspaces")]
    assert server.host == "127.0.0.1"
    assert server.port == 4040
    assert observability.refresh_ms == 250
    assert observability.render_interval_ms == 30
  end

  test "presenter and dashboard aggregate multiple projects into one view" do
    root = Path.join(System.tmp_dir!(), "symphony-project-view-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    backend_workflow = Path.join(root, "backend/WORKFLOW.md")
    frontend_workflow = Path.join(root, "frontend/WORKFLOW.md")
    File.mkdir_p!(Path.dirname(backend_workflow))
    File.mkdir_p!(Path.dirname(frontend_workflow))

    write_workflow_file!(backend_workflow,
      workspace_root: Path.join(root, "backend-workspaces"),
      tracker_kind: "memory",
      tracker_project_slug: "backend-project"
    )

    write_workflow_file!(frontend_workflow,
      workspace_root: Path.join(root, "frontend-workspaces"),
      tracker_kind: "memory",
      tracker_project_slug: "frontend-project"
    )

    backend_orchestrator = Module.concat(__MODULE__, :BackendOrchestrator)
    frontend_orchestrator = Module.concat(__MODULE__, :FrontendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: backend_orchestrator,
               snapshot: %{
                 running: [
                   %{
                     issue_id: "backend-1",
                     identifier: "BE-1",
                     state: "In Progress",
                     session_id: "session-backend",
                     turn_count: 3,
                     codex_app_server_pid: nil,
                     last_codex_message: "editing backend",
                     last_codex_timestamp: nil,
                     last_codex_event: :notification,
                     codex_input_tokens: 10,
                     codex_output_tokens: 5,
                     codex_total_tokens: 15,
                     started_at: DateTime.utc_now()
                   }
                 ],
                 retrying: [],
                 codex_totals: %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 12.0},
                 rate_limits: %{"primary" => %{"remaining" => 8}},
                 polling: %{checking?: false, next_poll_in_ms: 1_000, poll_interval_ms: 5_000}
               },
               refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}
             ]
           ]}
      })

    {:ok, _frontend_pid} =
      start_supervised(%{
        id: frontend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: frontend_orchestrator,
               snapshot: %{
                 running: [],
                 retrying: [
                   %{
                     issue_id: "frontend-1",
                     identifier: "FE-2",
                     attempt: 2,
                     due_in_ms: 3_000,
                     error: "needs retry"
                   }
                 ],
                 codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 4.0},
                 rate_limits: %{"primary" => %{"remaining" => 3}},
                 polling: %{checking?: true, next_poll_in_ms: 500, poll_interval_ms: 5_000}
               },
               refresh: %{queued: true, coalesced: true, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}
             ]
           ]}
      })

    boot_config = %{
      manifest_path: Path.join(root, "SYMPHONY.md"),
      server: %Schema.Server{host: "127.0.0.1", port: 4040},
      observability: %Schema.Observability{dashboard_enabled: true, refresh_ms: 1000, render_interval_ms: 16},
      projects: [
        %{
          id: "backend",
          workflow_path: backend_workflow,
          workspace_root: Path.join(root, "backend-workspaces"),
          project_slug: "backend-project",
          max_concurrent_agents: 10,
          orchestrator: backend_orchestrator
        },
        %{
          id: "frontend",
          workflow_path: frontend_workflow,
          workspace_root: Path.join(root, "frontend-workspaces"),
          project_slug: "frontend-project",
          max_concurrent_agents: 10,
          orchestrator: frontend_orchestrator
        }
      ]
    }

    assert :ok = BootConfig.put(boot_config)
    assert Enum.map(Projects.projects(), & &1.id) == ["backend", "frontend"]

    payload = Presenter.state_payload(50)

    assert payload.counts == %{running: 1, retrying: 1}
    assert payload.codex_totals.total_tokens == 20
    assert Enum.map(payload.projects, & &1.project_id) == ["backend", "frontend"]
    assert Enum.any?(payload.running, &(&1.project_id == "backend" and &1.issue_identifier == "BE-1"))
    assert Enum.any?(payload.retrying, &(&1.project_id == "frontend" and &1.issue_identifier == "FE-2"))

    assert {:ok, issue_payload} = Presenter.issue_payload("BE-1", 50)
    assert issue_payload.project_id == "backend"
    assert issue_payload.workspace.path == Path.join(Path.join(root, "backend-workspaces"), "BE-1")

    assert {:ok, refresh_payload} = Presenter.refresh_payload()
    assert refresh_payload.queued == true
    assert Map.keys(refresh_payload.projects) == ["backend", "frontend"]
    assert is_binary(refresh_payload.requested_at)
    assert is_binary(refresh_payload.projects["backend"].requested_at)
    assert is_binary(refresh_payload.projects["frontend"].requested_at)

    start_test_endpoint(orchestrator: nil, snapshot_timeout_ms: 50)

    assert %{"counts" => %{"running" => 1, "retrying" => 1}, "projects" => projects} =
             json_response(get(build_conn(), "/api/v1/state"), 200)

    assert Enum.map(projects, & &1["project_id"]) == ["backend", "frontend"]

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "backend"
    assert html =~ "frontend"
    assert html =~ "BE-1"
    assert html =~ "FE-2"
  end

  test "kanban payload groups tracker issues by Linear workflow state and dashboard refreshes automatically" do
    root = Path.join(System.tmp_dir!(), "symphony-kanban-view-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    workflow_path = Path.join(root, "WORKFLOW.md")
    write_workflow_file!(workflow_path, tracker_kind: "memory", workspace_root: Path.join(root, "workspaces"))

    now = DateTime.utc_now()

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      kanban_issue("TAM-1", "Backlog card", "Backlog", now, priority: 1, labels: ["scope"]),
      kanban_issue("TAM-2", "Todo card", "Todo", now, priority: 2),
      kanban_issue("TAM-3", "Progress card", "In Progress", now, priority: 3),
      kanban_issue("TAM-4", "Review card", "Human Review", now, priority: 4, labels: ["qa"]),
      kanban_issue("TAM-5", "Done card", "Done", now)
    ])

    assert :ok =
             BootConfig.put(%{
               manifest_path: Path.join(root, "SYMPHONY.md"),
               server: %Schema.Server{host: "127.0.0.1", port: 4040},
               observability: %Schema.Observability{dashboard_enabled: true},
               projects: [
                 %{
                   id: "tam",
                   workflow_path: workflow_path,
                   workspace_root: Path.join(root, "workspaces"),
                   project_slug: "tam-project",
                   max_concurrent_agents: 10,
                   orchestrator: Module.concat(__MODULE__, :KanbanOrchestrator)
                 }
               ]
             })

    payload = Presenter.kanban_payload(50)

    assert payload.status == "ok"
    assert payload.states == ["Backlog", "Todo", "In Progress", "Human Review", "Done"]
    assert Enum.map(payload.columns, & &1.state) == payload.states
    assert Enum.map(payload.columns, & &1.count) == [1, 1, 1, 1, 1]

    assert %{"Backlog" => ["TAM-1"], "Human Review" => ["TAM-4"], "Done" => ["TAM-5"]} =
             payload.columns
             |> Map.new(fn column -> {column.state, Enum.map(column.issues, & &1.issue_identifier)} end)
             |> Map.take(["Backlog", "Human Review", "Done"])

    kanban_orchestrator = Module.concat(__MODULE__, :KanbanOrchestrator)

    {:ok, _pid} =
      start_supervised(%{
        id: kanban_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: kanban_orchestrator,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    start_test_endpoint(orchestrator: nil, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Linear Kanban Board"

    for state <- ["Backlog", "Todo", "In Progress", "Human Review", "Done"] do
      assert html =~ state
    end

    assert html =~ ~r/data-state="Backlog"[\s\S]*data-issue-id="TAM-1"[\s\S]*data-state="Todo"/
    assert html =~ ~r/data-state="Human Review"[\s\S]*data-issue-id="TAM-4"[\s\S]*data-state="Done"/

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      kanban_issue("TAM-1", "Backlog card", "Done", now, priority: 1, labels: ["scope"]),
      kanban_issue("TAM-2", "Todo card", "Todo", now, priority: 2),
      kanban_issue("TAM-3", "Progress card", "In Progress", now, priority: 3),
      kanban_issue("TAM-4", "Review card", "Human Review", now, priority: 4, labels: ["qa"]),
      kanban_issue("TAM-5", "Done card", "Done", now)
    ])

    send(view.pid, :kanban_refresh)
    refreshed_html = render(view)

    refute refreshed_html =~ ~r/data-state="Backlog"[\s\S]*data-issue-id="TAM-1"[\s\S]*data-state="Todo"/
    assert refreshed_html =~ ~r/data-state="Done"[\s\S]*data-issue-id="TAM-1"/
  end

  test "runtime context uses the per-project workflow store cache" do
    root = Path.join(System.tmp_dir!(), "symphony-project-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    workflow_path = Path.join(root, "backend/WORKFLOW.md")
    File.mkdir_p!(Path.dirname(workflow_path))
    write_workflow_file!(workflow_path, prompt: "cached prompt")

    store_name = WorkflowStore.project_store_name("backend")
    {:ok, _pid} = start_supervised({WorkflowStore, name: store_name, workflow_path: workflow_path})

    File.write!(workflow_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload(store_name)

    assert {:ok, %{prompt: "cached prompt"}} =
             RuntimeContext.with_context(%{project_id: "backend", workflow_path: workflow_path}, fn ->
               Workflow.current()
             end)
  end

  test "aggregate snapshot runs project snapshots within one timeout window" do
    backend_orchestrator = Module.concat(__MODULE__, :TimeoutBackendOrchestrator)
    frontend_orchestrator = Module.concat(__MODULE__, :TimeoutFrontendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: backend_orchestrator,
               snapshot_delay_ms: 80,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    {:ok, _frontend_pid} =
      start_supervised(%{
        id: frontend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: frontend_orchestrator,
               snapshot_delay_ms: 80,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    assert :ok =
             BootConfig.put(%{
               manifest_path: "/tmp/SYMPHONY.md",
               server: %Schema.Server{},
               observability: %Schema.Observability{},
               projects: [
                 %{id: "backend", workflow_path: "/tmp/backend/WORKFLOW.md", orchestrator: backend_orchestrator},
                 %{id: "frontend", workflow_path: "/tmp/frontend/WORKFLOW.md", orchestrator: frontend_orchestrator}
               ]
             })

    {elapsed_us, snapshot} = :timer.tc(fn -> Projects.aggregate_snapshot(100) end)

    assert snapshot != :unavailable
    assert elapsed_us < 150_000
  end

  test "issue lookup runs project snapshots within one timeout window" do
    backend_orchestrator = Module.concat(__MODULE__, :IssueLookupBackendOrchestrator)
    frontend_orchestrator = Module.concat(__MODULE__, :IssueLookupFrontendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: backend_orchestrator,
               snapshot_delay_ms: 80,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    {:ok, _frontend_pid} =
      start_supervised(%{
        id: frontend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: frontend_orchestrator,
               snapshot_delay_ms: 80,
               snapshot: %{
                 running: [%{issue_id: "frontend-1", identifier: "FE-9", state: "In Progress"}],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    assert :ok =
             BootConfig.put(%{
               manifest_path: "/tmp/SYMPHONY.md",
               server: %Schema.Server{},
               observability: %Schema.Observability{},
               projects: [
                 %{
                   id: "backend",
                   workflow_path: "/tmp/backend/WORKFLOW.md",
                   workspace_root: "/tmp/backend-workspaces",
                   project_slug: "backend",
                   max_concurrent_agents: 10,
                   orchestrator: backend_orchestrator
                 },
                 %{
                   id: "frontend",
                   workflow_path: "/tmp/frontend/WORKFLOW.md",
                   workspace_root: "/tmp/frontend-workspaces",
                   project_slug: "frontend",
                   max_concurrent_agents: 10,
                   orchestrator: frontend_orchestrator
                 }
               ]
             })

    {elapsed_us, result} = :timer.tc(fn -> Projects.find_issue("FE-9", 100) end)

    assert {:ok, %{project: %{id: "frontend"}}} = result
    assert elapsed_us < 150_000
  end

  test "issue payload uses cached project workspace metadata when workflow becomes invalid" do
    backend_orchestrator = Module.concat(__MODULE__, :IssuePayloadBackendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: backend_orchestrator,
               snapshot: %{
                 running: [
                   %{
                     issue_id: "backend-1",
                     identifier: "BE-77",
                     state: "In Progress",
                     workspace_path: nil,
                     session_id: "session-backend-77",
                     started_at: DateTime.utc_now(),
                     last_codex_event: nil,
                     last_codex_message: nil,
                     last_codex_timestamp: nil,
                     codex_input_tokens: 0,
                     codex_output_tokens: 0,
                     codex_total_tokens: 0
                   }
                 ],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
                 rate_limits: nil,
                 polling: nil
               }
             ]
           ]}
      })

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-project-fallback-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    workflow_path = Path.join(root, "backend/WORKFLOW.md")
    File.mkdir_p!(Path.dirname(workflow_path))
    write_workflow_file!(workflow_path, workspace_root: "./backend-workspaces")

    assert :ok =
             BootConfig.put(%{
               manifest_path: "/tmp/SYMPHONY.md",
               server: %Schema.Server{},
               observability: %Schema.Observability{},
               projects: [
                 %{
                   id: "backend",
                   workflow_path: workflow_path,
                   workspace_root: Path.join(root, "backend/backend-workspaces"),
                   project_slug: "backend",
                   max_concurrent_agents: 10,
                   orchestrator: backend_orchestrator
                 }
               ]
             })

    File.write!(workflow_path, "---\ntracker: [\n---\nBroken prompt\n")

    assert {:ok, issue_payload} = Presenter.issue_payload("BE-77", 50)
    assert issue_payload.workspace.path == Path.join(root, "backend/backend-workspaces/BE-77")
  end

  test "aggregate refresh returns unavailable when no project refresh was queued" do
    backend_orchestrator = Module.concat(__MODULE__, :RefreshBackendOrchestrator)
    frontend_orchestrator = Module.concat(__MODULE__, :RefreshFrontendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: backend_orchestrator,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
               },
               refresh: :unavailable
             ]
           ]}
      })

    {:ok, _frontend_pid} =
      start_supervised(%{
        id: frontend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [
             [
               name: frontend_orchestrator,
               snapshot: %{
                 running: [],
                 retrying: [],
                 codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
               },
               refresh: :unavailable
             ]
           ]}
      })

    assert :ok =
             BootConfig.put(%{
               manifest_path: "/tmp/SYMPHONY.md",
               server: %Schema.Server{},
               observability: %Schema.Observability{},
               projects: [
                 %{id: "backend", workflow_path: "/tmp/backend/WORKFLOW.md", orchestrator: backend_orchestrator},
                 %{id: "frontend", workflow_path: "/tmp/frontend/WORKFLOW.md", orchestrator: frontend_orchestrator}
               ]
             })

    assert {:error, :unavailable} = Projects.request_refresh()
    assert {:error, :unavailable} = Presenter.refresh_payload()
  end

  defp kanban_issue(identifier, title, state, updated_at, opts \\ []) do
    %Issue{
      id: "issue-#{String.downcase(identifier)}",
      identifier: identifier,
      title: title,
      state: state,
      priority: Keyword.get(opts, :priority),
      url: "https://linear.app/tam/issue/#{identifier}",
      labels: Keyword.get(opts, :labels, []),
      updated_at: updated_at
    }
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
