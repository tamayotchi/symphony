defmodule SymphonyElixirWeb.KanbanLive do
  @moduledoc """
  Live kanban view for the configured Linear project.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Linear.Board
  alias SymphonyElixir.Pi.Transcript

  @refresh_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:board, nil)
      |> assign(:error, nil)
      |> assign(:selected_issue_identifier, nil)
      |> assign(:selected_issue, nil)
      |> assign(:selected_transcript, nil)
      |> assign(:selected_transcript_error, nil)
      |> load_board()

    if connected?(socket) do
      schedule_refresh()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_board, socket) do
    schedule_refresh()
    {:noreply, load_board(socket)}
  end

  @impl true
  def handle_event("select_issue", %{"identifier" => identifier}, socket) do
    {:noreply, select_issue(socket, identifier)}
  end

  def handle_event("clear_issue", _params, socket) do
    {:noreply, clear_selected_issue(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell kanban-shell">
      <header class="hero-card board-hero-card">
        <div class="hero-grid hero-grid-board">
          <div>
            <p class="eyebrow">Linear LiveView</p>
            <h1 class="hero-title">Project Kanban</h1>
            <p class="hero-copy">
              A lightweight board for the configured Linear project, refreshed automatically so status changes show up without leaving Symphony.
            </p>

            <div :if={@board} class="hero-highlights">
              <span class="hero-highlight-pill">
                <span class="hero-highlight-dot"></span>
                <%= @board.project.name || "Configured project" %>
              </span>
              <span class="hero-highlight-pill">Auto-refresh every 5s</span>
              <span class="hero-highlight-pill"> <%= @board.total_issues %> active cards </span>
            </div>
          </div>

          <div class="hero-sidecar board-hero-sidecar">
            <nav class="page-nav" aria-label="Dashboard navigation">
              <a class="nav-chip" href="/">Observability</a>
              <a class="nav-chip nav-chip-active" href="/kanban">Kanban</a>
            </nav>

            <div :if={@board} class="board-live-indicator">
              <span class="status-badge status-badge-live board-live-badge">
                <span class="status-badge-dot"></span>
                Live board
              </span>
              <span class="status-badge status-badge-offline board-live-badge">
                <span class="status-badge-dot"></span>
                Waiting for LiveView
              </span>
              <span class="board-sync-copy">Synced <%= relative_time(@board.fetched_at) %></span>
            </div>
          </div>
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Kanban unavailable</h2>
          <p class="error-copy"><%= format_error(@error) %></p>
        </section>
      <% else %>
        <section :if={@board} class="board-summary-grid board-summary-strip">
          <article class="section-card board-summary-card board-summary-card-primary">
            <div>
              <p class="eyebrow">Project</p>
              <h2 class="section-title"><%= @board.project.name || "Configured project" %></h2>
              <p class="section-copy">
                Team <strong><%= @board.team.name || "Unknown" %></strong>
              </p>
            </div>

            <div class="board-summary-actions">
              <div class="summary-stat">
                <span class="summary-stat-label">Cards</span>
                <strong class="summary-stat-value"><%= @board.total_issues %></strong>
              </div>
              <div class="summary-stat">
                <span class="summary-stat-label">Columns</span>
                <strong class="summary-stat-value"><%= length(@board.columns) %></strong>
              </div>
              <a :if={@board.project.url} class="subtle-link" href={@board.project.url} target="_blank" rel="noreferrer">
                Open in Linear ↗
              </a>
            </div>
          </article>

          <article class="section-card board-summary-card">
            <p class="eyebrow">Board health</p>
            <h2 class="section-title">Always-current project view</h2>
            <p class="section-copy">
              New issues and state changes are pulled into the board automatically without a full page reload.
            </p>
          </article>
        </section>

        <section :if={@board} class="kanban-workspace-grid">
          <section class="kanban-board" aria-label="Linear kanban board">
            <article
              :for={column <- @board.columns}
              class="kanban-column"
              style={column_style(column)}
            >
              <header class="kanban-column-header">
                <div>
                  <div class="kanban-column-heading-row">
                    <span class="kanban-column-swatch"></span>
                    <h2 class="kanban-column-title"><%= column.name %></h2>
                  </div>
                  <p class="kanban-column-meta"><%= format_column_type(column.type) %></p>
                </div>
                <span class="kanban-column-count"><%= length(column.issues) %></span>
              </header>

              <div class="kanban-card-stack">
                <%= if column.issues == [] do %>
                  <div class="kanban-empty">No issues in this state.</div>
                <% else %>
                  <article :for={issue <- column.issues} class={kanban_card_class(issue, @selected_issue_identifier)}>
                    <button
                      type="button"
                      class="kanban-card-select"
                      phx-click="select_issue"
                      phx-value-identifier={issue.identifier}
                      aria-pressed={issue.identifier == @selected_issue_identifier}
                      disabled={is_nil(issue.identifier)}
                    >
                      <div class="kanban-card-topline">
                        <span class="issue-id"><%= issue.identifier %></span>
                        <span :if={issue.priority && issue.priority > 0} class="priority-pill">
                          P<%= issue.priority %>
                        </span>
                      </div>

                      <h3 class="kanban-card-title"><%= issue.title %></h3>

                      <div :if={issue.labels != []} class="label-row">
                        <span :for={label <- issue.labels} class="label-pill">
                          <span :if={label.color} class="label-dot" style={"background: #{label.color};"}></span>
                          <%= label.name %>
                        </span>
                      </div>

                      <div class="kanban-card-footer">
                        <div :if={issue.assignee_name} class="assignee-pill assignee-pill-strong">
                          <span class="assignee-avatar"><%= assignee_initials(issue.assignee_name) %></span>
                          <span><%= issue.assignee_name %></span>
                        </div>

                        <p class="kanban-card-meta">
                          Updated <%= relative_time(issue.updated_at) %>
                        </p>
                      </div>
                    </button>

                    <div class="kanban-card-actions">
                      <a :if={issue.url} class="kanban-card-open-link" href={issue.url} target="_blank" rel="noreferrer">
                        Open Linear ↗
                      </a>
                    </div>
                  </article>
                <% end %>
              </div>
            </article>
          </section>

          <aside class="section-card terminal-card" aria-live="polite">
            <div class="section-header terminal-header">
              <div>
                <p class="eyebrow">Pi RPC</p>
                <h2 class="section-title">Terminal view</h2>
                <p class="section-copy"><%= terminal_intro(@selected_issue, @selected_transcript, @selected_transcript_error) %></p>
              </div>

              <button :if={@selected_issue} type="button" class="subtle-button terminal-clear-button" phx-click="clear_issue">
                Clear
              </button>
            </div>

            <%= cond do %>
              <% is_nil(@selected_issue) -> %>
                <div class="terminal-empty">
                  <p class="terminal-empty-title">Select a task</p>
                  <p>Click any kanban card to inspect the local Pi RPC conversation recorded for that issue workspace.</p>
                </div>

              <% @selected_transcript_error -> %>
                <div class="terminal-empty terminal-empty-warning">
                  <p class="terminal-empty-title"><%= @selected_issue.identifier %></p>
                  <p><%= format_transcript_error(@selected_transcript_error) %></p>
                </div>

              <% true -> %>
                <div class="terminal-meta-row">
                  <span class="terminal-meta-pill"><%= @selected_issue.identifier %></span>
                  <span class="terminal-meta-pill"><%= length(@selected_transcript.events) %> events</span>
                  <span :if={@selected_transcript.session_id} class="terminal-meta-pill">
                    session <%= short_id(@selected_transcript.session_id) %>
                  </span>
                </div>

                <div class="terminal-log" role="log" aria-label={"Pi transcript for #{@selected_issue.identifier}"}>
                  <article :for={event <- @selected_transcript.events} class={terminal_event_class(event)}>
                    <header class="terminal-event-header">
                      <span class="terminal-event-marker"><%= terminal_marker(event) %></span>
                      <span class="terminal-event-title"><%= event.title %></span>
                      <span :if={event.status} class={terminal_status_class(event.status)}><%= event.status %></span>
                      <time :if={event.timestamp} class="terminal-event-time"><%= compact_timestamp(event.timestamp) %></time>
                    </header>

                    <%= if compact_event?(event) do %>
                      <details class="terminal-details" open={event.status == :error}>
                        <summary><%= event.summary || "Show details" %></summary>
                        <pre :if={event.body} class="terminal-body"><%= event.body %></pre>
                      </details>
                    <% else %>
                      <pre :if={event.body} class="terminal-body"><%= event.body %></pre>
                    <% end %>
                  </article>
                </div>
            <% end %>
          </aside>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_board(socket) do
    case Board.fetch_project_board() do
      {:ok, board} ->
        socket
        |> assign(:board, board)
        |> assign(:error, nil)
        |> refresh_selected_issue()

      {:error, reason} ->
        socket
        |> assign(:board, nil)
        |> assign(:error, reason)
        |> clear_selected_issue()
    end
  end

  defp refresh_selected_issue(%{assigns: %{selected_issue_identifier: nil}} = socket), do: socket

  defp refresh_selected_issue(%{assigns: %{selected_issue_identifier: identifier}} = socket) do
    select_issue(socket, identifier)
  end

  defp select_issue(socket, identifier) when is_binary(identifier) and identifier != "" do
    case find_board_issue(socket.assigns.board, identifier) do
      nil ->
        clear_selected_issue(socket)

      issue ->
        case Transcript.fetch_issue(identifier) do
          {:ok, transcript} ->
            socket
            |> assign(:selected_issue_identifier, identifier)
            |> assign(:selected_issue, issue)
            |> assign(:selected_transcript, transcript)
            |> assign(:selected_transcript_error, nil)

          {:error, reason} ->
            socket
            |> assign(:selected_issue_identifier, identifier)
            |> assign(:selected_issue, issue)
            |> assign(:selected_transcript, nil)
            |> assign(:selected_transcript_error, reason)
        end
    end
  end

  defp select_issue(socket, _identifier), do: clear_selected_issue(socket)

  defp clear_selected_issue(socket) do
    socket
    |> assign(:selected_issue_identifier, nil)
    |> assign(:selected_issue, nil)
    |> assign(:selected_transcript, nil)
    |> assign(:selected_transcript_error, nil)
  end

  defp find_board_issue(nil, _identifier), do: nil

  defp find_board_issue(board, identifier) do
    board.columns
    |> Enum.flat_map(& &1.issues)
    |> Enum.find(&(&1.identifier == identifier))
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_board, @refresh_interval_ms)
  end

  defp relative_time(%DateTime{} = datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_datetime), do: "unknown"

  defp format_column_type(nil), do: "State"

  defp format_column_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp assignee_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp assignee_initials(_name), do: "?"

  defp column_style(column) do
    case Map.get(column, :color) do
      color when is_binary(color) and color != "" -> "--column-accent: #{color};"
      _ -> nil
    end
  end

  defp kanban_card_class(issue, selected_identifier) do
    ["kanban-card", issue.identifier == selected_identifier && "kanban-card-selected"]
  end

  defp terminal_intro(nil, _transcript, _error), do: "Click a task to inspect its recorded worker conversation."
  defp terminal_intro(_issue, _transcript, nil), do: "Showing the latest local Pi RPC session for the selected task."
  defp terminal_intro(_issue, _transcript, _error), do: "No local transcript is available for this task yet."

  defp terminal_event_class(event) do
    [
      "terminal-event",
      "terminal-event-#{event.kind}",
      event.status == :error && "terminal-event-error"
    ]
  end

  defp terminal_status_class(:error), do: "terminal-status terminal-status-error"
  defp terminal_status_class(_status), do: "terminal-status terminal-status-ok"

  defp compact_event?(event), do: event.kind in [:thinking, :tool_call, :tool_result, :unknown, :malformed]

  defp terminal_marker(%{kind: :message, role: "user"}), do: "$"
  defp terminal_marker(%{kind: :message, role: "assistant"}), do: "›"
  defp terminal_marker(%{kind: :thinking}), do: "…"
  defp terminal_marker(%{kind: :tool_call}), do: "tool"
  defp terminal_marker(%{kind: :tool_result}), do: "out"
  defp terminal_marker(%{kind: :malformed}), do: "!"
  defp terminal_marker(_event), do: "#"

  defp compact_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> timestamp
    end
  end

  defp compact_timestamp(_timestamp), do: ""

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "unknown"

  defp format_transcript_error(:pi_session_dir_missing),
    do: "No Pi RPC session directory exists in this issue workspace yet."

  defp format_transcript_error(:pi_session_file_missing),
    do: "The Pi RPC session directory exists, but no session JSONL file was found."

  defp format_transcript_error({:pi_session_file_read_failed, reason}),
    do: "Unable to read the Pi RPC session file: #{reason}."

  defp format_transcript_error(reason), do: "Transcript unavailable: #{inspect(reason)}"

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
