defmodule SymphonyElixirWeb.KanbanLive do
  @moduledoc """
  Live kanban view for the configured Linear project.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Linear.Board

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:board, nil)
      |> assign(:error, nil)
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
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell kanban-shell">
      <header class="hero-card">
        <div class="hero-grid hero-grid-board">
          <div>
            <p class="eyebrow">Linear LiveView</p>
            <h1 class="hero-title">Project Kanban</h1>
            <p class="hero-copy">
              A lightweight board for the configured Linear project, refreshed automatically so status changes show up without leaving Symphony.
            </p>
          </div>

          <nav class="page-nav" aria-label="Dashboard navigation">
            <a class="nav-chip" href="/">Observability</a>
            <a class="nav-chip nav-chip-active" href="/kanban">Kanban</a>
          </nav>
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Kanban unavailable</h2>
          <p class="error-copy"><%= format_error(@error) %></p>
        </section>
      <% else %>
        <section :if={@board} class="section-card board-summary-card">
          <div class="board-summary-grid">
            <div>
              <p class="eyebrow">Project</p>
              <h2 class="section-title"><%= @board.project.name || "Configured project" %></h2>
              <p class="section-copy">
                Team <strong><%= @board.team.name || "Unknown" %></strong>
                · <span class="mono"><%= @board.total_issues %></span> issues
                · synced <%= relative_time(@board.fetched_at) %>
              </p>
            </div>

            <a :if={@board.project.url} class="subtle-link" href={@board.project.url} target="_blank" rel="noreferrer">
              Open in Linear ↗
            </a>
          </div>
        </section>

        <section :if={@board} class="kanban-board" aria-label="Linear kanban board">
          <article :for={column <- @board.columns} class="kanban-column">
            <header class="kanban-column-header">
              <div>
                <h2 class="kanban-column-title"><%= column.name %></h2>
                <p class="kanban-column-meta"><%= column.type || "state" %></p>
              </div>
              <span class="kanban-column-count"><%= length(column.issues) %></span>
            </header>

            <div class="kanban-card-stack">
              <%= if column.issues == [] do %>
                <div class="kanban-empty">No issues in this state.</div>
              <% else %>
                <a :for={issue <- column.issues} class="kanban-card" href={issue.url} target="_blank" rel="noreferrer">
                  <div class="kanban-card-topline">
                    <span class="issue-id"><%= issue.identifier %></span>
                    <span :if={issue.assignee_name} class="assignee-pill"><%= issue.assignee_name %></span>
                  </div>

                  <h3 class="kanban-card-title"><%= issue.title %></h3>

                  <div :if={issue.labels != []} class="label-row">
                    <span :for={label <- issue.labels} class="label-pill">
                      <span :if={label.color} class="label-dot" style={"background: #{label.color};"}></span>
                      <%= label.name %>
                    </span>
                  </div>

                  <p class="kanban-card-meta">
                    Updated <%= relative_time(issue.updated_at) %>
                  </p>
                </a>
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

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
