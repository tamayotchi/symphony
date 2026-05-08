defmodule SymphonyElixir.BootConfig do
  @moduledoc """
  Loads the top-level Symphony startup manifest.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Manifest.Schema

  @app_env_key :boot_config
  @manifest_file_name "SYMPHONY.md"

  @type project :: %{
          id: String.t(),
          workflow_path: Path.t(),
          workspace_root: Path.t() | nil,
          project_slug: String.t() | nil,
          max_concurrent_agents: pos_integer() | nil,
          orchestrator: GenServer.name() | nil
        }

  @type t :: %{
          manifest_path: Path.t(),
          projects: [project()],
          server: Schema.Server.t(),
          observability: Schema.Observability.t()
        }

  @spec current() :: t() | nil
  def current do
    Application.get_env(:symphony_elixir, @app_env_key)
  end

  @spec put(t()) :: :ok
  def put(config) when is_map(config) do
    Application.put_env(:symphony_elixir, @app_env_key, config)
    :ok
  end

  @manifest_env_key :manifest_file_path

  @spec manifest_file_path() :: Path.t()
  def manifest_file_path do
    Application.get_env(:symphony_elixir, @manifest_env_key) ||
      Path.join(File.cwd!(), @manifest_file_name)
  end

  @spec set_manifest_file_path(Path.t()) :: :ok
  def set_manifest_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, @manifest_env_key, path)
    :ok
  end

  @spec clear_manifest_file_path() :: :ok
  def clear_manifest_file_path do
    Application.delete_env(:symphony_elixir, @manifest_env_key)
    :ok
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ manifest_file_path()) when is_binary(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, manifest} <- Schema.parse(workflow.config),
         projects when is_list(projects) and projects != [] <- manifest.projects,
         {:ok, resolved_projects} <- resolve_projects(manifest.projects, Path.dirname(workflow.path)) do
      {:ok,
       %{
         manifest_path: workflow.path,
         projects: resolved_projects,
         server: manifest.server,
         observability: manifest.observability
       }}
    else
      [] ->
        {:error, {:invalid_project_manifest, "manifest must include a non-empty projects list"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec projects() :: [project()]
  def projects do
    case current() do
      %{projects: projects} when is_list(projects) -> projects
      _ -> []
    end
  end

  @spec server_settings() :: Schema.Server.t()
  def server_settings do
    case current() do
      %{server: server} -> server
      _ -> Schema.default_server()
    end
  end

  @spec observability_settings() :: Schema.Observability.t()
  def observability_settings do
    case current() do
      %{observability: observability} -> observability
      _ -> Schema.default_observability()
    end
  end

  defp resolve_projects(projects, manifest_dir) do
    projects
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, {MapSet.new(), []}}, fn {project, index}, {:ok, {ids, acc}} ->
      case resolve_project(project, manifest_dir) do
        {:ok, %{id: id} = resolved} ->
          if MapSet.member?(ids, id) do
            {:halt, {:error, {:invalid_project_manifest, "projects[#{index}].id must be unique"}}}
          else
            {:cont, {:ok, {MapSet.put(ids, id), [resolved | acc]}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_project_manifest, "projects[#{index}] #{reason}"}}}
      end
    end)
    |> case do
      {:ok, {_ids, resolved_projects}} -> {:ok, Enum.reverse(resolved_projects)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_project(%Schema.Project{} = project, manifest_dir) do
    id = normalize_string(project.id)
    workflow = normalize_string(project.workflow)

    cond do
      is_nil(id) ->
        {:error, "must include a non-empty id"}

      is_nil(workflow) ->
        {:error, "must include a non-empty workflow path"}

      true ->
        workflow_path = Path.expand(workflow, manifest_dir)

        with {:ok, workflow} <- Workflow.load(workflow_path),
             {:ok, settings} <- Config.Schema.parse(workflow.config, workflow_path: workflow_path) do
          {:ok,
           %{
             id: id,
             workflow_path: workflow_path,
             workspace_root: settings.workspace.root,
             project_slug: settings.tracker.project_slug,
             max_concurrent_agents: settings.agent.max_concurrent_agents,
             orchestrator: nil
           }}
        else
          {:error, reason} -> {:error, "workflow #{workflow_path} failed to load: #{inspect(reason)}"}
        end
    end
  end

  defp resolve_project(_project, _manifest_dir), do: {:error, "must be a map"}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
