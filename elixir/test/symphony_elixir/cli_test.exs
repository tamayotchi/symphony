defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  test "defaults to SYMPHONY.md when manifest path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "SYMPHONY.md" end,
      set_manifest_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([], deps)
  end

  test "uses an explicit manifest path override when provided" do
    parent = self()
    manifest_path = "tmp/custom/SYMPHONY.md"
    expanded_path = Path.expand(manifest_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:manifest_checked, path})
        path == expanded_path
      end,
      set_manifest_file_path: fn path ->
        send(parent, {:manifest_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([manifest_path], deps)
    assert_received {:manifest_checked, ^expanded_path}
    assert_received {:manifest_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_manifest_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs", "SYMPHONY.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when manifest file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_manifest_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["SYMPHONY.md"], deps)
    assert message =~ "Manifest file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_manifest_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate(["SYMPHONY.md"], deps)
    assert message =~ "Failed to start Symphony with manifest"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_manifest_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["SYMPHONY.md"], deps)
  end
end
