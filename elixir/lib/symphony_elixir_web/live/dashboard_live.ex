defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <%= if Map.get(@payload, :projects, []) != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Projects</h2>
                <p class="section-copy">All project runtimes managed by this Symphony node.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Status</th>
                    <th>Running</th>
                    <th>Retrying</th>
                    <th>Tokens</th>
                    <th>Workflow</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- Map.get(@payload, :projects, [])}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project_id %></span>
                        <span class="muted"><%= project.project_slug || "n/a" %></span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(project.status)}><%= project.status %></span>
                    </td>
                    <td class="numeric"><%= project.counts.running %></td>
                    <td class="numeric"><%= project.counts.retrying %></td>
                    <td class="numeric"><%= format_int(project.codex_totals.total_tokens) %></td>
                    <td class="mono"><%= project.workflow_path %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 9rem;" />
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody :for={entry <- @payload.running}>
                  <tr>
                    <td>
                      <span class="issue-id"><%= entry.project_id %></span>
                    </td>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if terminal_visible?(entry) do %>
                          <button
                            type="button"
                            class="terminal-popout-button"
                            data-popout-target={terminal_popout_id(entry)}
                            data-popout-title={terminal_popout_title(entry)}
                            onclick="const template = document.getElementById(this.dataset.popoutTarget); const popup = window.open('', this.dataset.popoutTarget, 'popup=yes,width=980,height=720,resizable=yes,scrollbars=yes'); if (popup && template) { popup.document.open(); popup.document.write(template.innerHTML); popup.document.close(); popup.focus(); }"
                          >
                            Open live terminal
                          </button>
                          <.terminal_popout_template entry={entry} id={terminal_popout_id(entry)} />
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>

          <.terminal_history_panel payload={@payload} />
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td><%= entry.project_id %></td>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(snapshot_timeout_ms())
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp terminal_history_panel(assigns) do
    ~H"""
    <section class="terminal-history" aria-label="Terminal history">
      <div>
        <h3 class="terminal-history-title">Terminal history</h3>
        <p class="terminal-history-copy">Recent Pi RPC terminal transcripts found in project workspaces. Open any entry to keep watching it live while the session file changes.</p>
      </div>
      <%= if terminal_history(@payload) == [] do %>
        <p class="terminal-history-empty">No terminal history found yet. Pi RPC transcripts will appear here after a session writes JSONL files under a project workspace's <span class="mono">.pi-rpc-sessions</span> directory.</p>
      <% else %>
        <div class="terminal-history-grid">
          <article :for={entry <- terminal_history(@payload)} class="terminal-history-card">
            <div>
              <p class="terminal-history-issue"><%= entry.issue_identifier %></p>
              <p class="terminal-history-meta mono"><%= terminal_history_label(entry) %></p>
            </div>
            <button
              type="button"
              class="terminal-popout-button"
              data-popout-target={terminal_popout_id(entry)}
              data-popout-title={terminal_popout_title(entry)}
              onclick="const template = document.getElementById(this.dataset.popoutTarget); const popup = window.open('', this.dataset.popoutTarget, 'popup=yes,width=980,height=720,resizable=yes,scrollbars=yes'); if (popup && template) { popup.document.open(); popup.document.write(template.innerHTML); popup.document.close(); popup.focus(); }"
            >
              Open live terminal
            </button>
            <.terminal_popout_template entry={entry} id={terminal_popout_id(entry)} />
          </article>
        </div>
      <% end %>
    </section>
    """
  end

  defp terminal_popout_template(assigns) do
    ~H"""
    <template id={@id} data-terminal-template="true">
      <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title><%= terminal_popout_title(@entry) %></title>
          <style>
            :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #020617; color: #e2e8f0; }
            body { margin: 0; min-height: 100vh; background: radial-gradient(circle at top left, rgba(124, 58, 237, 0.24), transparent 34rem), #020617; }
            main { max-width: 1100px; margin: 0 auto; padding: 1.25rem; }
            header { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 1rem; margin-bottom: 1rem; }
            h1 { margin: 0; font-size: clamp(1.35rem, 2.5vw, 2rem); letter-spacing: -0.04em; }
            .muted, .terminal-meta, .terminal-pill { color: #94a3b8; }
            .mono, pre { font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace; }
            .terminal-panel { border: 1px solid rgba(148, 163, 184, 0.24); border-radius: 18px; background: rgba(15, 23, 42, 0.86); box-shadow: 0 20px 70px rgba(0, 0, 0, 0.3); padding: 0.95rem; }
            .live-indicator { display: inline-flex; align-items: center; gap: 0.4rem; padding: 0.28rem 0.58rem; border: 1px solid rgba(34, 197, 94, 0.3); border-radius: 999px; background: rgba(34, 197, 94, 0.1); color: #86efac; font-size: 0.78rem; font-weight: 800; }
            .live-indicator::before { content: ""; width: 0.48rem; height: 0.48rem; border-radius: 999px; background: #22c55e; box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.55); animation: pulse 1.6s infinite; }
            @keyframes pulse { 70% { box-shadow: 0 0 0 0.42rem rgba(34, 197, 94, 0); } 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); } }
            .terminal-meta { display: flex; flex-wrap: wrap; gap: 0.75rem; margin-bottom: 0.8rem; font-size: 0.85rem; font-weight: 700; }
            .terminal-timeline { display: grid; gap: 0.72rem; }
            .terminal-entry { display: grid; grid-template-columns: minmax(7rem, 11rem) minmax(0, 1fr); gap: 0.75rem; padding: 0.78rem; border: 1px solid rgba(148, 163, 184, 0.18); border-left-width: 4px; border-radius: 14px; background: rgba(2, 6, 23, 0.68); }
            .terminal-entry-user { border-left-color: #38bdf8; }
            .terminal-entry-assistant { border-left-color: #22c55e; }
            .terminal-entry-thinking { border-left-color: #a78bfa; }
            .terminal-entry-tool { border-left-color: #f59e0b; }
            .terminal-entry-system { border-left-color: #94a3b8; }
            .terminal-entry-label { display: flex; flex-wrap: wrap; align-content: start; gap: 0.35rem; color: #cbd5e1; font-size: 0.76rem; font-weight: 800; text-transform: uppercase; letter-spacing: 0.04em; }
            .terminal-pill { display: inline-flex; align-items: center; height: 1.3rem; padding: 0 0.45rem; border: 1px solid rgba(148, 163, 184, 0.28); border-radius: 999px; text-transform: none; letter-spacing: 0; }
            .terminal-entry-text { margin: 0; color: #e2e8f0; font-size: 0.86rem; line-height: 1.55; white-space: pre-wrap; word-break: break-word; }
            .terminal-empty { margin: 0; color: #cbd5e1; }
            @media (max-width: 720px) { main { padding: 0.8rem; } .terminal-entry { grid-template-columns: 1fr; } }
          </style>
        </head>
        <body data-terminal-template-id={@id}>
          <div data-terminal-popout-body data-live-refresh-ms="1000">
            <main>
              <header>
                <div>
                  <p class="muted mono">Running session</p>
                  <h1>Terminal transcript for <%= @entry.issue_identifier %></h1>
                </div>
                <div class="muted mono"><%= terminal_popout_summary(@entry) %></div>
                <span class="live-indicator">Live</span>
              </header>

              <section class="terminal-panel" role="region" aria-label={"Terminal transcript for #{@entry.issue_identifier}"}>
              <%= if terminal_available?(@entry) do %>
                <div class="terminal-meta">
                  <span><%= terminal_source_label(@entry) %></span>
                  <%= if terminal_truncated?(@entry) do %>
                    <span>Showing most recent <%= length(terminal_entries(@entry)) %> entries</span>
                  <% end %>
                </div>

                <%= if terminal_entries(@entry) == [] do %>
                  <p class="terminal-empty">Transcript is available but no displayable chat, thinking, or tool events have been recorded yet.</p>
                <% else %>
                  <div class="terminal-timeline">
                    <article :for={item <- terminal_entries(@entry)} class={terminal_entry_class(item)}>
                      <div class="terminal-entry-label mono">
                        <span><%= terminal_entry_label(item) %></span>
                        <%= if terminal_entry_compact?(item) do %>
                          <span class="terminal-pill">compact</span>
                        <% end %>
                      </div>
                      <pre class="terminal-entry-text"><%= terminal_entry_text(item) %></pre>
                    </article>
                  </div>
                <% end %>
              <% else %>
                <p class="terminal-empty"><%= terminal_unavailable_message(@entry) %></p>
              <% end %>
              </section>
            </main>
          </div>
          <script>
            (() => {
              const refreshMs = 1000;
              const templateId = document.body.dataset.terminalTemplateId;

              const nearBottom = () => Math.abs(window.innerHeight + window.scrollY - document.body.scrollHeight) < 96;

              const syncFromOpener = () => {
                if (!window.opener || window.opener.closed || !templateId) return;

                const template = window.opener.document.getElementById(templateId);
                const source = template && template.content && template.content.querySelector('[data-terminal-popout-body]');
                const target = document.querySelector('[data-terminal-popout-body]');

                if (!source || !target || source.innerHTML === target.innerHTML) return;

                const shouldPinBottom = nearBottom();
                target.innerHTML = source.innerHTML;

                if (shouldPinBottom) {
                  window.scrollTo(0, document.body.scrollHeight);
                }
              };

              window.setInterval(syncFromOpener, refreshMs);
              window.addEventListener('focus', syncFromOpener);
              syncFromOpener();
            })();
          </script>
        </body>
      </html>
    </template>
    """
  end

  defp terminal_popout_title(entry), do: "Symphony terminal · #{terminal_item_value(entry, :issue_identifier) || "session"}"

  defp terminal_popout_summary(entry) do
    cond do
      terminal_available?(entry) -> "#{length(terminal_entries(entry))} entries"
      terminal_source(entry) -> "Transcript not available yet"
      true -> "Waiting for Pi RPC session"
    end
  end

  defp terminal_history(payload) do
    case Map.get(payload, :terminal_history) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  defp terminal_history_label(entry) do
    [terminal_session_file(entry) |> terminal_basename(), terminal_item_value(entry, :updated_at)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp terminal_basename(path) when is_binary(path), do: Path.basename(path)
  defp terminal_basename(_path), do: nil

  defp terminal_popout_id(entry) do
    suffix =
      [
        terminal_item_value(entry, :project_id),
        terminal_item_value(entry, :issue_identifier),
        terminal_item_value(entry, :session_id),
        terminal_source_hash(entry)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("-")
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.trim("-")

    "terminal-popout-#{suffix}"
  end

  defp terminal_source_hash(entry) do
    case terminal_session_file(entry) || terminal_source(entry) do
      value when is_binary(value) and value != "" -> Integer.to_string(:erlang.phash2(value), 36)
      _ -> nil
    end
  end

  defp terminal_visible?(entry) do
    has_session_file? = match?(session when is_binary(session) and session != "", terminal_session_file(entry))
    has_source? = match?(source when is_binary(source) and source != "", terminal_source(entry))

    has_session_file? or has_source? or terminal_available?(entry)
  end

  defp terminal_available?(entry) do
    terminal_transcript_value(entry, :available) == true
  end

  defp terminal_entries(entry) do
    case terminal_transcript_value(entry, :entries) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  defp terminal_truncated?(entry) do
    terminal_transcript_value(entry, :truncated) == true
  end

  defp terminal_source_label(entry) do
    case terminal_source(entry) do
      nil -> "Pi RPC transcript"
      source -> "Pi RPC transcript · #{Path.basename(source)}"
    end
  end

  defp terminal_source(entry), do: terminal_transcript_value(entry, :source)

  defp terminal_session_file(entry), do: terminal_item_value(entry, :session_file)

  defp terminal_unavailable_message(entry) do
    case terminal_source(entry) do
      nil -> "Terminal transcript will appear after the Pi RPC session file is available for this running task."
      _source -> "Terminal transcript is unavailable right now. The Pi RPC session file may still be starting, may have moved, or may have been cleaned up."
    end
  end

  defp terminal_entry_class(item) do
    kind = terminal_entry_kind(item)
    "terminal-entry terminal-entry-#{kind}"
  end

  defp terminal_entry_kind(item) do
    item
    |> terminal_item_value(:kind)
    |> to_string()
    |> String.downcase()
    |> case do
      kind when kind in ["user", "assistant", "thinking", "tool", "system"] -> kind
      _ -> "system"
    end
  end

  defp terminal_entry_label(item) do
    item
    |> terminal_item_value(:label)
    |> case do
      value when value in [nil, ""] -> terminal_entry_kind(item)
      value -> value
    end
  end

  defp terminal_entry_text(item) do
    item
    |> terminal_item_value(:text)
    |> case do
      value when is_binary(value) -> value
      value -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp terminal_entry_compact?(item) do
    terminal_item_value(item, :compact) == true
  end

  defp terminal_transcript_value(entry, key) do
    case terminal_item_value(entry, :terminal_transcript) do
      nil -> nil
      transcript -> terminal_item_value(transcript, key)
    end
  end

  defp terminal_item_value(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp terminal_item_value(_map, _key), do: nil

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
