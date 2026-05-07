defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.{RuntimeContext, WorkflowStore}

  @workflow_file_name "WORKFLOW.md"

  @spec workflow_file_path(keyword()) :: Path.t()
  def workflow_file_path(opts \\ []) do
    Keyword.get(opts, :workflow_path) ||
      RuntimeContext.workflow_path() ||
      Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          path: Path.t(),
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current(keyword()) :: {:ok, loaded_workflow()} | {:error, term()}
  def current(opts \\ []) do
    case workflow_store(opts) do
      nil ->
        load(workflow_file_path(opts))

      store ->
        case GenServer.whereis(store) do
          pid when is_pid(pid) -> WorkflowStore.current(store)
          _ -> load(workflow_file_path(opts))
        end
    end
  end

  @spec load(keyword()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(opts) when is_list(opts) do
    load(workflow_file_path(opts))
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content, path)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  defp parse(content, path) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           path: Path.expand(path),
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end

  defp workflow_store(opts) do
    cond do
      Keyword.has_key?(opts, :workflow_store) -> Keyword.get(opts, :workflow_store)
      Keyword.has_key?(opts, :workflow_path) -> nil
      RuntimeContext.workflow_path() -> nil
      true -> WorkflowStore
    end
  end
end
