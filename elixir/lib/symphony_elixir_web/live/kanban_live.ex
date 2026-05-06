defmodule SymphonyElixirWeb.KanbanLive do
  @moduledoc """
  Live kanban view for the configured Linear project.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Linear.Board

  @refresh_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:board, nil)
      |> assign(:error, nil)
      |> assign(:move_notice, nil)
      |> assign(:move_error, nil)
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
  def handle_event("move_issue", %{"issue_id" => issue_id, "state_id" => state_id}, socket) do
    case validate_move(socket.assigns.board, issue_id, state_id) do
      {:ok, issue, state} ->
        case Board.move_issue_to_state(issue.id, state.id) do
          :ok ->
            {:noreply, reload_board_after_move(socket, "Moved #{issue.identifier} to #{state.name}.")}

          {:error, reason} ->
            {:noreply, assign_move_error(socket, "Could not move #{issue.identifier}: #{format_error(reason)}")}
        end

      {:error, message} ->
        {:noreply, assign_move_error(socket, message)}
    end
  end

  def handle_event("move_issue", _params, socket) do
    {:noreply, assign_move_error(socket, "Choose a valid issue and target state.")}
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

      <section :if={@move_notice} class="kanban-feedback kanban-feedback-success" role="status">
        <strong>Move complete.</strong>
        <span><%= @move_notice %></span>
      </section>

      <section :if={@move_error} class="kanban-feedback kanban-feedback-error" role="alert">
        <strong>Move failed.</strong>
        <span><%= @move_error %></span>
      </section>

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

        <section :if={@board} class="kanban-board" aria-label="Linear kanban board">
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
                <article :for={issue <- column.issues} class="kanban-card" id={"kanban-card-#{issue_dom_id(issue)}"}>
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

                  <div class="kanban-card-actions">
                    <a :if={issue.url} class="kanban-card-open-link" href={issue.url} target="_blank" rel="noreferrer">
                      Open in Linear ↗
                    </a>

                    <form id={"move-issue-#{issue_dom_id(issue)}"} class="issue-move-form" phx-submit="move_issue">
                      <input type="hidden" name="issue_id" value={issue.id} />
                      <label class="issue-move-label" for={"move-state-#{issue_dom_id(issue)}"}>Move to</label>
                      <select
                        id={"move-state-#{issue_dom_id(issue)}"}
                        class="issue-move-select"
                        name="state_id"
                        required
                        disabled={available_move_states(@board.states, issue) == []}
                      >
                        <option value="">Choose state…</option>
                        <option :for={state <- available_move_states(@board.states, issue)} value={state.id}>
                          <%= state.name %>
                        </option>
                      </select>
                      <button
                        type="submit"
                        class="issue-move-button"
                        disabled={available_move_states(@board.states, issue) == []}
                        phx-disable-with="Moving…"
                      >
                        Move
                      </button>
                    </form>
                  </div>
                </article>
              <% end %>
            </div>
          </article>
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

      {:error, reason} ->
        socket
        |> assign(:board, nil)
        |> assign(:error, reason)
    end
  end

  defp reload_board_after_move(socket, notice) do
    case Board.fetch_project_board() do
      {:ok, board} ->
        socket
        |> assign(:board, board)
        |> assign(:error, nil)
        |> assign(:move_notice, notice)
        |> assign(:move_error, nil)

      {:error, reason} ->
        assign_move_error(socket, "Issue moved, but the board could not refresh: #{format_error(reason)}")
    end
  end

  defp validate_move(nil, _issue_id, _state_id), do: {:error, "Board data is not loaded yet."}

  defp validate_move(board, issue_id, state_id) do
    with %{} = issue <- find_issue(board, issue_id),
         %{} = state <- find_state(board, state_id),
         :ok <- ensure_state_changed(issue, state) do
      {:ok, issue, state}
    else
      :same_state -> {:error, "Choose a different target state."}
      _ -> {:error, "Choose a valid issue and target state."}
    end
  end

  defp find_issue(board, issue_id) when is_binary(issue_id) do
    board.columns
    |> Enum.flat_map(& &1.issues)
    |> Enum.find(&(&1.id == issue_id))
  end

  defp find_issue(_board, _issue_id), do: nil

  defp find_state(board, state_id) when is_binary(state_id) do
    Enum.find(board.states || [], &(&1.id == state_id))
  end

  defp find_state(_board, _state_id), do: nil

  defp ensure_state_changed(issue, state) do
    if issue.state_id == state.id or issue.state_name == state.name do
      :same_state
    else
      :ok
    end
  end

  defp assign_move_error(socket, message) do
    socket
    |> assign(:move_notice, nil)
    |> assign(:move_error, message)
  end

  defp available_move_states(states, issue) do
    Enum.reject(states || [], fn state ->
      is_nil(state.id) or state.id == issue.state_id or state.name == issue.state_name
    end)
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

  defp issue_dom_id(issue) do
    issue
    |> Map.get(:id, Map.get(issue, :identifier, "unknown"))
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp column_style(column) do
    case Map.get(column, :color) do
      color when is_binary(color) and color != "" -> "--column-accent: #{color};"
      _ -> nil
    end
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
