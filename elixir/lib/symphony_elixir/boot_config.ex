defmodule SymphonyElixir.BootConfig do
  @moduledoc """
  Loads the top-level Symphony startup manifest.
  """

  import Ecto.Changeset, only: [apply_action: 2]

  alias SymphonyElixir.{Config.Schema, Workflow}

  @app_env_key :boot_config
  @manifest_file_name "SYMPHONY.md"

  @type project :: %{
          id: String.t(),
          workflow_path: Path.t(),
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

  @spec manifest_file_path() :: Path.t()
  def manifest_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @manifest_file_name)
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ manifest_file_path()) when is_binary(path) do
    with {:ok, workflow} <- Workflow.load(path) do
      config = normalize_keys(workflow.config)
      projects = Map.get(config, "projects")

      if is_list(projects) and projects != [] do
        load_manifest(workflow.path, config, projects)
      else
        {:error, {:invalid_project_manifest, "manifest must include a non-empty projects list"}}
      end
    end
  end

  @spec projects() :: [project()]
  def projects do
    case current() do
      %{projects: projects} when is_list(projects) -> projects
      _ -> []
    end
  end

  @spec server_settings() :: Schema.Server.t() | nil
  def server_settings do
    case current() do
      %{server: server} -> server
      _ -> nil
    end
  end

  @spec observability_settings() :: Schema.Observability.t() | nil
  def observability_settings do
    case current() do
      %{observability: observability} -> observability
      _ -> nil
    end
  end

  defp load_manifest(manifest_path, config, projects) do
    manifest_dir = Path.dirname(manifest_path)

    with {:ok, server} <- parse_embedded(Schema.Server, Map.get(config, "server", %{})),
         {:ok, observability} <-
           parse_embedded(Schema.Observability, Map.get(config, "observability", %{})),
         {:ok, resolved_projects} <- resolve_projects(projects, manifest_dir) do
      {:ok,
       %{
         manifest_path: manifest_path,
         projects: resolved_projects,
         server: server,
         observability: observability
       }}
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
            {:cont, {:ok, {MapSet.put(ids, id), acc ++ [resolved]}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_project_manifest, "projects[#{index}] #{reason}"}}}
      end
    end)
    |> case do
      {:ok, {_ids, resolved_projects}} -> {:ok, resolved_projects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_project(%{} = project, manifest_dir) do
    project = normalize_keys(project)
    id = project |> Map.get("id") |> normalize_string()
    workflow = project |> Map.get("workflow") |> normalize_string()

    cond do
      is_nil(id) ->
        {:error, "must include a non-empty id"}

      is_nil(workflow) ->
        {:error, "must include a non-empty workflow path"}

      true ->
        workflow_path = Path.expand(workflow, manifest_dir)

        case Workflow.load(workflow_path) do
          {:ok, _workflow} -> {:ok, %{id: id, workflow_path: workflow_path, orchestrator: nil}}
          {:error, reason} -> {:error, "workflow #{workflow_path} failed to load: #{inspect(reason)}"}
        end
    end
  end

  defp resolve_project(_project, _manifest_dir), do: {:error, "must be a map"}

  defp parse_embedded(module, attrs) do
    module
    |> struct()
    |> module.changeset(normalize_embedded_attrs(attrs))
    |> apply_action(:validate)
    |> case do
      {:ok, settings} -> {:ok, settings}
      {:error, changeset} -> {:error, {:invalid_project_manifest, inspect(changeset.errors)}}
    end
  end

  defp normalize_embedded_attrs(nil), do: %{}
  defp normalize_embedded_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_embedded_attrs(_attrs), do: %{}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, to_string(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value
end
