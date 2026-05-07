defmodule SymphonyElixir.MultiProjectTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{BootConfig, Config, Projects}
  alias SymphonyElixir.Config.Schema
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

    write_workflow_file!(backend_workflow, workspace_root: Path.join(root, "backend-workspaces"))
    write_workflow_file!(frontend_workflow, workspace_root: Path.join(root, "frontend-workspaces"))

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

    backend_orchestrator = Module.concat(__MODULE__, :BackendOrchestrator)
    frontend_orchestrator = Module.concat(__MODULE__, :FrontendOrchestrator)

    {:ok, _backend_pid} =
      start_supervised(%{
        id: backend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [[
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
           ]]}
      })

    {:ok, _frontend_pid} =
      start_supervised(%{
        id: frontend_orchestrator,
        start:
          {StaticOrchestrator, :start_link,
           [[
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
           ]]}
      })

    boot_config = %{
      manifest_path: Path.join(root, "SYMPHONY.md"),
      server: %Schema.Server{host: "127.0.0.1", port: 4040},
      observability: %Schema.Observability{dashboard_enabled: true, refresh_ms: 1000, render_interval_ms: 16},
      projects: [
        %{id: "backend", workflow_path: backend_workflow, orchestrator: backend_orchestrator},
        %{id: "frontend", workflow_path: frontend_workflow, orchestrator: frontend_orchestrator}
      ]
    }

    assert :ok = BootConfig.put(boot_config)
    assert Projects.enabled?()

    payload = Presenter.state_payload(nil, 50)

    assert payload.counts == %{running: 1, retrying: 1}
    assert payload.codex_totals.total_tokens == 20
    assert Enum.map(payload.projects, & &1.project_id) == ["backend", "frontend"]
    assert Enum.any?(payload.running, &(&1.project_id == "backend" and &1.issue_identifier == "BE-1"))
    assert Enum.any?(payload.retrying, &(&1.project_id == "frontend" and &1.issue_identifier == "FE-2"))

    assert {:ok, issue_payload} = Presenter.issue_payload("BE-1", nil, 50)
    assert issue_payload.project_id == "backend"
    assert issue_payload.workspace.path == Path.join(Config.settings!(workflow_path: backend_workflow).workspace.root, "BE-1")

    assert {:ok, refresh_payload} = Presenter.refresh_payload(nil)
    assert refresh_payload.queued == true
    assert Map.keys(refresh_payload.projects) == ["backend", "frontend"]

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
