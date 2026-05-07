defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.{BootConfig, Orchestrator, Projects, WorkflowStore}

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    with {:ok, boot_config} <- BootConfig.load() do
      :ok = BootConfig.put(boot_config)

      Supervisor.start_link(
        children_for(boot_config),
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp children_for(%{projects: projects}) do
    [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      WorkflowStore,
      {Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry}
    ] ++
      Enum.map(projects, fn project ->
        %{
          id: {:orchestrator, project.id},
          start:
            {Orchestrator, :start_link,
             [[
               name: Projects.orchestrator_name(project),
               project_id: project.id,
               workflow_path: project.workflow_path
             ]]}
        }
      end) ++ [
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]
  end
end
