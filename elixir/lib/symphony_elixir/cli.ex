defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit manifest path.
  """

  alias SymphonyElixir.{BootConfig, LogFile}

  @switches [logs_root: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_manifest_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps) do
          run(Path.expand("SYMPHONY.md"), deps)
        end

      {opts, [manifest_path], []} ->
        with :ok <- maybe_set_logs_root(opts, deps) do
          run(manifest_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(manifest_path, deps) do
    expanded_path = Path.expand(manifest_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_manifest_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with manifest #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Manifest file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [path-to-SYMPHONY.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_manifest_file_path: &BootConfig.set_manifest_file_path/1,
      set_logs_root: &set_logs_root/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
