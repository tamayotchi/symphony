defmodule SymphonyElixir.Pi.SessionTranscript do
  @moduledoc """
  Builds a terminal-friendly transcript from a Pi RPC session JSONL file.
  """

  @max_entries 200
  @max_entry_text_chars 4_000

  @type entry :: %{
          kind: String.t(),
          label: String.t(),
          text: String.t(),
          compact: boolean()
        }

  @spec read(String.t() | nil) :: map()
  def read(session_file) when is_binary(session_file) do
    if File.regular?(session_file) do
      {count, entries} =
        session_file
        |> File.stream!([], :line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.flat_map(&line_to_entries/1)
        |> retain_recent_entries()

      %{
        available: true,
        source: session_file,
        entries: entries,
        truncated: count > @max_entries
      }
    else
      unavailable(session_file)
    end
  end

  def read(_session_file), do: unavailable(nil)

  defp unavailable(source), do: %{available: false, source: source, entries: [], truncated: false}

  defp retain_recent_entries(stream) do
    {count, queue} =
      Enum.reduce(stream, {0, :queue.new()}, fn entry, {count, queue} ->
        queue = :queue.in(entry, queue)

        queue =
          if :queue.len(queue) > @max_entries do
            {_dropped, queue} = :queue.out(queue)
            queue
          else
            queue
          end

        {count + 1, queue}
      end)

    {count, :queue.to_list(queue)}
  end

  defp line_to_entries(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> payload_to_entries(payload)
      _ -> maybe_entry("system", "raw", line, false)
    end
  end

  defp payload_to_entries(%{"type" => "turn_end"} = payload), do: turn_end_entries(payload)
  defp payload_to_entries(%{"messages" => messages}) when is_list(messages), do: Enum.flat_map(messages, &message_to_entries/1)
  defp payload_to_entries(%{"message" => message}) when is_map(message), do: message_to_entries(message)
  defp payload_to_entries(%{"method" => _} = payload), do: rpc_event_to_entries(payload)
  defp payload_to_entries(%{"type" => type} = payload) when is_binary(type), do: generic_type_entry(type, payload)
  defp payload_to_entries(payload), do: generic_payload_entry(payload)

  defp turn_end_entries(payload) do
    entries =
      tool_results_to_entries(payload["toolResults"] || payload["tool_results"]) ++
        maybe_message_entries(payload["message"])

    if entries == [] do
      generic_type_entry("turn_end", payload)
    else
      entries
    end
  end

  defp maybe_message_entries(%{} = message), do: message_to_entries(message)
  defp maybe_message_entries(_message), do: []

  defp tool_results_to_entries(results) when is_list(results), do: Enum.flat_map(results, &tool_result_to_entries/1)
  defp tool_results_to_entries(_results), do: []

  defp tool_result_to_entries(%{} = result) do
    maybe_entry("tool", tool_result_label(result), tool_result_text(result), true)
  end

  defp tool_result_to_entries(_result), do: []

  defp tool_result_label(result) do
    extract_first_text(result, [["toolName"], ["name"], ["tool"]]) || "tool result"
  end

  defp tool_result_text(result) do
    extract_first_text(result, [["text"], ["output"], ["result"], ["content", "text"]]) ||
      flatten_content(result["content"]) || compact_json(result)
  end

  defp message_to_entries(%{"role" => role, "content" => content} = message) when is_list(content) do
    entries =
      content
      |> Enum.flat_map(&content_item_to_entries(&1, role))
      |> Enum.reject(&(&1.text == ""))

    if entries == [] do
      fallback_message_entry(role, message)
    else
      entries
    end
  end

  defp message_to_entries(%{"role" => role} = message), do: fallback_message_entry(role, message)
  defp message_to_entries(_message), do: []

  defp content_item_to_entries(%{"type" => "thinking"} = item, _role) do
    maybe_entry("thinking", "thinking", item["thinking"] || item["text"] || item["summaryText"], true)
  end

  defp content_item_to_entries(%{"type" => "toolCall"} = item, _role) do
    text =
      [item["name"], arguments_text(item["arguments"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.trim()

    maybe_entry("tool", "tool call", text, true)
  end

  defp content_item_to_entries(%{"type" => "toolResult"} = item, _role) do
    maybe_entry("tool", "tool result", flatten_content(item["content"]) || compact_json(item), true)
  end

  defp content_item_to_entries(%{"type" => "text", "text" => text}, role) when is_binary(text) do
    message_text_entry(normalize_role(role), text)
  end

  defp content_item_to_entries(%{"text" => text}, role) when is_binary(text), do: message_text_entry(normalize_role(role), text)

  defp content_item_to_entries(%{"content" => nested}, role) do
    maybe_entry(normalize_role(role), normalize_role(role), flatten_content(nested), compact_role?(role))
  end

  defp content_item_to_entries(%{} = item, role) do
    maybe_entry(normalize_role(role), normalize_role(role), compact_json(item), compact_role?(role))
  end

  defp content_item_to_entries(text, role) when is_binary(text) do
    message_text_entry(normalize_role(role), text)
  end

  defp content_item_to_entries(_item, _role), do: []

  defp fallback_message_entry(role, message) when role in ["user", "assistant", "system", "tool", "toolResult"] do
    maybe_entry(normalize_role(role), normalize_role(role), content_text(message), compact_role?(role))
  end

  defp fallback_message_entry(_role, _message), do: []

  defp message_text_entry(role, text) do
    maybe_entry(role, role, text, compact_role?(role))
  end

  defp rpc_event_to_entries(%{"method" => method} = payload) do
    cond do
      thinking_method?(method) ->
        maybe_entry("thinking", terminal_label(method, "thinking"), event_text(payload), true)

      tool_method?(method) ->
        maybe_entry("tool", terminal_label(method, "tool"), event_text(payload), true)

      user_method?(method) ->
        maybe_entry("user", terminal_label(method, "user"), event_text(payload), false)

      assistant_method?(method) ->
        maybe_entry("assistant", terminal_label(method, "assistant"), event_text(payload), false)

      true ->
        maybe_entry("system", terminal_label(method, method), event_text(payload), true)
    end
  end

  defp generic_type_entry(type, payload) do
    maybe_entry("system", type, compact_json(payload), true)
  end

  defp generic_payload_entry(payload) do
    maybe_entry("system", "event", compact_json(payload), true)
  end

  defp maybe_entry(kind, label, text, compact) when is_binary(text) and text != "" do
    [
      %{
        kind: kind,
        label: label,
        text: clamp_text(text),
        compact: compact
      }
    ]
  end

  defp maybe_entry(_kind, _label, _text, _compact), do: []

  defp clamp_text(text) when is_binary(text) do
    if String.length(text) > @max_entry_text_chars do
      String.slice(text, 0, @max_entry_text_chars) <> "\n…[truncated]"
    else
      text
    end
  end

  defp normalize_role("toolResult"), do: "tool"
  defp normalize_role("tool"), do: "tool"
  defp normalize_role("user"), do: "user"
  defp normalize_role("assistant"), do: "assistant"
  defp normalize_role("system"), do: "system"
  defp normalize_role(_role), do: "system"

  defp compact_role?(role) when role in ["assistant"], do: false
  defp compact_role?(_role), do: true

  defp thinking_method?(method) do
    String.contains?(method, ["reasoning", "thinking"])
  end

  defp tool_method?(method) do
    String.contains?(method, ["tool", "exec_command", "mcp_tool_call"])
  end

  defp user_method?(method), do: String.ends_with?(method, "user_message") or String.contains?(method, ["user_message"])

  defp assistant_method?(method) do
    String.contains?(method, ["agent_message", "assistant_message"])
  end

  defp terminal_label(method, fallback) do
    method
    |> String.split("/")
    |> List.last()
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp event_text(%{"params" => %{"msg" => %{"payload" => %{} = payload}}}), do: text_from_payload_map(payload)
  defp event_text(%{"params" => %{"msg" => %{} = payload}}), do: text_from_payload_map(payload)
  defp event_text(%{"params" => %{} = payload}), do: text_from_payload_map(payload)
  defp event_text(%{"message" => %{} = message}), do: content_text(message)
  defp event_text(payload), do: compact_json(payload)

  defp text_from_payload_map(payload) do
    extract_first_text(payload, [
      ["delta"],
      ["content"],
      ["text"],
      ["textDelta"],
      ["summaryText"],
      ["command"],
      ["parsedCmd"],
      ["question"],
      ["tool"],
      ["name"],
      ["title"]
    ]) || compact_json(payload)
  end

  defp extract_first_text(payload, [path | rest]) do
    case get_in(payload, path) do
      value when is_binary(value) and value != "" -> value
      _ -> extract_first_text(payload, rest)
    end
  end

  defp extract_first_text(_payload, []), do: nil

  defp content_text(%{"content" => content}), do: flatten_content(content)
  defp content_text(%{"text" => text}) when is_binary(text) and text != "", do: text
  defp content_text(_message), do: nil

  defp flatten_content(content) when is_binary(content), do: content

  defp flatten_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      %{"content" => nested} -> List.wrap(flatten_content(nested))
      _ -> []
    end)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp flatten_content(_content), do: nil

  defp arguments_text(arguments) when is_map(arguments) and map_size(arguments) == 0, do: nil
  defp arguments_text(arguments) when is_map(arguments), do: compact_json(arguments)
  defp arguments_text(arguments) when is_binary(arguments) and arguments != "", do: arguments
  defp arguments_text(_arguments), do: nil

  defp compact_json(payload) do
    payload
    |> Jason.encode!(pretty: true)
    |> String.trim()
  rescue
    _ -> inspect(payload, pretty: true, limit: 20)
  end
end
