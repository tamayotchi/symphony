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

    write_workflow_file!(backend_workflow, workspace_root: Path.join(root, "backend-workspaces"), tracker_project_slug: "backend-project")
    write_workflow_file!(frontend_workflow, workspace_root: Path.join(root, "frontend-workspaces"), tracker_project_slug: "frontend-project")

    backend_workspace = Path.join(root, "backend-workspaces/BE-1")
    backend_session_dir = Path.join([backend_workspace, ".pi-rpc-sessions", "history"])
    backend_session_file = Path.join(backend_session_dir, "session.jsonl")
    backend_proof_dir = Path.join(backend_session_dir, "proof")
    frontend_history_dir = Path.join([root, "frontend-workspaces", "FE-OLD", ".pi-rpc-sessions", "history"])
    frontend_history_file = Path.join(frontend_history_dir, "archived-session.jsonl")
    File.mkdir_p!(backend_session_dir)
    File.mkdir_p!(frontend_history_dir)

    File.write!(
      backend_session_file,
      Jason.encode!(%{"type" => "message", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "backend transcript"}]}}) <> "\n"
    )

    File.write!(
      frontend_history_file,
      Jason.encode!(%{"type" => "message", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "frontend archived transcript"}]}}) <> "\n"
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
                     started_at: DateTime.utc_now(),
                     workspace_path: backend_workspace,
                     session_file: backend_session_file,
                     proof_dir: backend_proof_dir,
                     proof_events_path: Path.join(backend_proof_dir, "events.jsonl"),
                     proof_summary_path: Path.join(backend_proof_dir, "summary.json")
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

    running_entry = Enum.find(payload.running, &(&1.issue_identifier == "BE-1"))
    assert running_entry.session_file == backend_session_file
    assert running_entry.proof_dir == backend_proof_dir
    assert running_entry.proof_events_path == Path.join(backend_proof_dir, "events.jsonl")
    assert running_entry.proof_summary_path == Path.join(backend_proof_dir, "summary.json")

    assert length(payload.terminal_history) == 2
    history_by_issue = Map.new(payload.terminal_history, &{&1.issue_identifier, &1})

    assert history_entry = history_by_issue["BE-1"]
    assert history_entry.session_file == backend_session_file
    assert history_entry.terminal_transcript.available == true
    assert [%{text: "backend transcript"}] = history_entry.terminal_transcript.entries

    assert frontend_history_entry = history_by_issue["FE-OLD"]
    assert frontend_history_entry.project_id == "frontend"
    assert frontend_history_entry.session_file == frontend_history_file
    assert frontend_history_entry.state == "Terminal history"
    assert [%{text: "frontend archived transcript"}] = frontend_history_entry.terminal_transcript.entries

    assert {:ok, issue_payload} = Presenter.issue_payload("BE-1", 50)
    assert issue_payload.project_id == "backend"
    assert issue_payload.workspace.path == Path.join(Path.join(root, "backend-workspaces"), "BE-1")
    assert issue_payload.running.session_file == backend_session_file
    assert issue_payload.running.proof_dir == backend_proof_dir
    assert issue_payload.running.proof_events_path == Path.join(backend_proof_dir, "events.jsonl")
    assert issue_payload.running.proof_summary_path == Path.join(backend_proof_dir, "summary.json")

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
