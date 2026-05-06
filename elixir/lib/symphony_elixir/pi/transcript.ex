defmodule SymphonyElixir.Pi.Transcript do
  @moduledoc """
  Loads and normalizes local Pi RPC JSONL session transcripts for kanban inspection.
  """

  alias SymphonyElixir.{Config, Workspace}

  @type event_kind :: :session | :meta | :message | :thinking | :tool_call | :tool_result | :unknown | :malformed
  @type event_status :: :ok | :error | nil

  @type event :: %{
          kind: event_kind(),
          title: String.t(),
          body: String.t() | nil,
          summary: String.t() | nil,
          timestamp: String.t() | nil,
          status: event_status(),
          role: String.t() | nil,
          tool_name: String.t() | nil,
          metadata: map()
        }

  @type transcript :: %{
          issue_identifier: String.t(),
          workspace_path: Path.t(),
          session_file: Path.t(),
          session_id: String.t() | nil,
          started_at: String.t() | nil,
          events: [event()]
        }

  @spec fetch_issue(String.t()) :: {:ok, transcript()} | {:error, term()}
  def fetch_issue(identifier) when is_binary(identifier) do
    with {:ok, workspace} <- Workspace.path_for_issue(identifier),
         {:ok, session_file} <- latest_session_file(workspace),
         {:ok, events} <- read_events(session_file) do
      session_event = Enum.find(events, &(&1.kind == :session))

      {:ok,
       %{
         issue_identifier: identifier,
         workspace_path: workspace,
         session_file: session_file,
         session_id: metadata_value(session_event, :session_id),
         started_at: session_event && session_event.timestamp,
         events: events
       }}
    end
  end

  def fetch_issue(_identifier), do: {:error, :invalid_issue_identifier}

  @spec latest_session_file(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def latest_session_file(workspace) when is_binary(workspace) do
    session_root = Path.join(workspace, Config.settings!().pi.session_dir_name)

    if File.dir?(session_root) do
      session_root
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&proof_event_file?/1)
      |> Enum.sort_by(&file_sort_key/1, :desc)
      |> case do
        [session_file | _] -> {:ok, session_file}
        [] -> {:error, :pi_session_file_missing}
      end
    else
      {:error, :pi_session_dir_missing}
    end
  end

  def latest_session_file(_workspace), do: {:error, :invalid_workspace_path}

  @spec read_events(Path.t()) :: {:ok, [event()]} | {:error, term()}
  def read_events(session_file) when is_binary(session_file) do
    case File.read(session_file) do
      {:ok, content} ->
        events =
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, line_number} -> decode_line(line, line_number) end)

        {:ok, events}

      {:error, reason} ->
        {:error, {:pi_session_file_read_failed, reason}}
    end
  end

  def read_events(_session_file), do: {:error, :invalid_session_file}

  defp proof_event_file?(path) do
    path
    |> Path.split()
    |> Enum.member?("proof")
  end

  defp file_sort_key(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.mtime, path}
      {:error, _reason} -> {0, path}
    end
  end

  defp decode_line(line, line_number) do
    trimmed = String.trim(line)

    if trimmed == "" do
      []
    else
      case Jason.decode(trimmed) do
        {:ok, %{} = payload} -> normalize_payload(payload, line_number)
        {:ok, payload} -> [malformed_event(line_number, "Unexpected JSON payload: #{inspect(payload)}")]
        {:error, reason} -> [malformed_event(line_number, "Invalid JSON: #{Exception.message(reason)}")]
      end
    end
  end

  defp normalize_payload(%{"type" => "session"} = payload, line_number) do
    body =
      [
        labeled_value("session", payload["id"]),
        labeled_value("cwd", payload["cwd"]),
        labeled_value("version", payload["version"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    [
      event(:session, "Session started", body, payload["timestamp"], %{
        line_number: line_number,
        session_id: payload["id"]
      })
    ]
  end

  defp normalize_payload(%{"type" => "model_change"} = payload, line_number) do
    provider = payload["provider"] || "provider unknown"
    model = payload["modelId"] || "model unknown"

    [
      event(:meta, "Model", "#{provider} / #{model}", payload["timestamp"], %{
        line_number: line_number
      })
    ]
  end

  defp normalize_payload(%{"type" => "thinking_level_change"} = payload, line_number) do
    [
      event(:meta, "Thinking level", to_string(payload["thinkingLevel"] || "unknown"), payload["timestamp"], %{
        line_number: line_number
      })
    ]
  end

  defp normalize_payload(%{"type" => "session_info"} = payload, line_number) do
    [
      event(:meta, "Session name", to_string(payload["name"] || "Unnamed session"), payload["timestamp"], %{
        line_number: line_number
      })
    ]
  end

  defp normalize_payload(%{"type" => "message", "message" => %{} = message} = payload, line_number) do
    normalize_message(message, payload["timestamp"], line_number)
  end

  defp normalize_payload(payload, line_number) do
    [
      event(:unknown, "#{payload["type"] || "Unknown"} event", format_value(payload), payload["timestamp"], %{
        line_number: line_number
      })
    ]
  end

  defp normalize_message(%{"role" => "assistant", "content" => content} = message, timestamp, line_number)
       when is_list(content) do
    events =
      content
      |> Enum.flat_map(&assistant_content_event(&1, timestamp, line_number))

    case events do
      [] -> [message_event("assistant", content_to_text(content), timestamp, line_number, message)]
      _ -> events
    end
  end

  defp normalize_message(%{"role" => "toolResult"} = message, timestamp, line_number) do
    tool_name = message["toolName"] || "tool"
    body = content_to_text(message["content"] || [])
    status = if truthy?(message["isError"]), do: :error, else: :ok

    [
      event(:tool_result, "Tool result · #{tool_name}", body, timestamp, %{
        line_number: line_number,
        tool_call_id: message["toolCallId"],
        tool_name: tool_name,
        status: status
      })
    ]
  end

  defp normalize_message(%{"role" => role, "content" => content} = message, timestamp, line_number)
       when is_list(content) do
    [message_event(role, content_to_text(content), timestamp, line_number, message)]
  end

  defp normalize_message(message, timestamp, line_number) do
    [
      event(:unknown, "Message", format_value(message), timestamp, %{
        line_number: line_number
      })
    ]
  end

  defp assistant_content_event(%{"type" => "thinking"} = content, timestamp, line_number) do
    body = content["thinking"] || content["text"] || ""

    if blank?(body) do
      []
    else
      [
        event(:thinking, "Thinking", body, timestamp, %{
          line_number: line_number
        })
      ]
    end
  end

  defp assistant_content_event(%{"type" => "toolCall"} = content, timestamp, line_number) do
    tool_name = content["name"] || "tool"
    body = format_value(content["arguments"] || %{})

    [
      event(:tool_call, "Tool call · #{tool_name}", body, timestamp, %{
        line_number: line_number,
        tool_call_id: content["id"],
        tool_name: tool_name
      })
    ]
  end

  defp assistant_content_event(%{"type" => "text"} = content, timestamp, line_number) do
    body = content["text"] || ""

    if blank?(body) do
      []
    else
      [message_event("assistant", body, timestamp, line_number, %{})]
    end
  end

  defp assistant_content_event(content, timestamp, line_number) do
    [
      event(:unknown, "Assistant content", format_value(content), timestamp, %{
        line_number: line_number
      })
    ]
  end

  defp message_event(role, body, timestamp, line_number, message) do
    event(:message, role_title(role), body, timestamp, %{
      line_number: line_number,
      role: role,
      message_id: message["id"]
    })
  end

  defp malformed_event(line_number, body) do
    event(:malformed, "Malformed JSONL line", body, nil, %{line_number: line_number, status: :error})
  end

  defp event(kind, title, body, timestamp, metadata) do
    status = Map.get(metadata, :status)
    role = Map.get(metadata, :role)
    tool_name = Map.get(metadata, :tool_name)

    %{
      kind: kind,
      title: title,
      body: normalize_body(body),
      summary: summarize(body),
      timestamp: timestamp,
      status: status,
      role: role,
      tool_name: tool_name,
      metadata: metadata
    }
  end

  defp role_title("user"), do: "User"
  defp role_title("assistant"), do: "Assistant"
  defp role_title(role) when is_binary(role), do: String.capitalize(role)
  defp role_title(_role), do: "Message"

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map(&content_piece_to_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp content_to_text(content), do: content_piece_to_text(content)

  defp content_piece_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_piece_to_text(%{"type" => "thinking", "thinking" => text}) when is_binary(text), do: text
  defp content_piece_to_text(%{"text" => text}) when is_binary(text), do: text
  defp content_piece_to_text(text) when is_binary(text), do: text
  defp content_piece_to_text(value), do: format_value(value)

  defp format_value(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value, pretty: true)
    end
  end

  defp labeled_value(_label, nil), do: nil
  defp labeled_value(label, value), do: "#{label}: #{value}"

  defp normalize_body(nil), do: nil
  defp normalize_body(body) when is_binary(body), do: String.trim(body)
  defp normalize_body(body), do: body |> to_string() |> String.trim()

  defp summarize(nil), do: nil

  defp summarize(body) do
    body
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(180)
  end

  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    text
    |> String.slice(0, max_length)
    |> Kernel.<>("…")
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_value), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp metadata_value(nil, _key), do: nil
  defp metadata_value(%{metadata: metadata}, key), do: Map.get(metadata, key)
end
