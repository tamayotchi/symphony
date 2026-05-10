# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches the configured worker runtime inside the workspace:
   - Codex in [App Server mode](https://developers.openai.com/codex/app-server/), or
   - Pi in RPC mode
4. Sends a workflow prompt to the worker
5. Keeps the worker working on the issue until the work is done

During Codex app-server sessions, Symphony serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls. During Pi sessions, the equivalent capability is restored
through the repo-level `extensions/linear-graphql` worker extension.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `SYMPHONY.md` and `WORKFLOW.md` templates to your control repo (or create
   your own `SYMPHONY.md` manifest and one `WORKFLOW.md` per project).
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to each repo that will
   be worked on by Symphony.
   - The `linear` skill expects a `linear_graphql` tool for raw Linear GraphQL operations such as
     comment editing or upload flows. Codex gets it from the app-server runtime; Pi gets it from
     the repo-level `extensions/linear-graphql` extension.
   - If you plan to run Pi workers, also copy the repo-level `extensions/` directory (or at least
     the `workspace-guard`, `proof`, `linear-graphql`, and `shared` subdirectories) next to your
     workflow file, or adjust `pi.extension_paths` accordingly.
5. Customize one `WORKFLOW.md` per project.
   - To get a project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Customize `SYMPHONY.md` with the list of projects/workflows you want the single Symphony node to
   manage.
7. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./SYMPHONY.md
```

## Configuration

Pass a custom manifest path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/SYMPHONY.md
```

If no path is passed, Symphony defaults to `./SYMPHONY.md`.

Manifest example:

```md
---
server:
  host: 127.0.0.1
  port: 4040
projects:
  - id: backend
    workflow: /repos/backend/WORKFLOW.md
  - id: frontend
    workflow: /repos/frontend/WORKFLOW.md
  - id: mobile
    workflow: /repos/mobile/WORKFLOW.md
---
One dashboard, many project workflows.
```

Symphony boots one orchestrator per listed workflow inside one BEAM node and exposes a single
aggregated dashboard/API. A one-project deployment is just a manifest with one `projects:` entry.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)

`SYMPHONY.md` is the startup/control-plane manifest. Each project `WORKFLOW.md` uses YAML front
matter for project-specific configuration plus a Markdown body used as that worker's session
prompt.

Minimal Codex example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal Pi example:

> If you use the checked-in `elixir/WORKFLOW.md` from this repo directly, its `pi.extension_paths`
> point to `../extensions/...` because the extensions live at the repository root, outside the
> Elixir app directory. If you copy the workflow to another location, keep in mind that
> `pi.extension_paths` resolve relative to that workflow file.
>
> `pi.append_system_prompt: ""` intentionally passes `--append-system-prompt ""` so Pi does not
> load a discovered `APPEND_SYSTEM.md` prompt into Symphony-managed sessions.

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
worker:
  runtime: pi
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
pi:
  command: pi
  session_dir_name: .pi-rpc-sessions
  append_system_prompt: ""
  extension_paths:
    - ./extensions/workspace-guard/index.ts
    - ./extensions/proof/index.ts
    - ./extensions/linear-graphql/index.ts
  disable_extensions: true
  disable_themes: true
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `worker.runtime` defaults to `codex`. Set it to `pi` to launch `pi --mode rpc` workers.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Pi worker defaults when `worker.runtime: pi`:
  - `pi.command` defaults to `pi`
  - `pi.response_timeout_ms` defaults to `60000`
  - `pi.session_dir_name` defaults to `.pi-rpc-sessions`
  - `pi.disable_extensions` defaults to `true`
  - `pi.disable_themes` defaults to `true`
  - `pi.extension_paths` are resolved relative to the directory containing `WORKFLOW.md`
  - `pi.model.provider`, `pi.model.model_id`, and `pi.thinking_level` are optional startup overrides
- Pi workers currently support local execution only; `worker.ssh_hosts` cannot be combined with
  `worker.runtime: pi`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

```yaml
worker:
  runtime: pi
pi:
  command: "$PI_BIN"
  extension_paths:
    - ./extensions/workspace-guard/index.ts
    - ./extensions/proof/index.ts
    - ./extensions/linear-graphql/index.ts
  model:
    provider: openai-codex
    model_id: gpt-5.5
  thinking_level: high
```

- If `SYMPHONY.md` is missing or has invalid YAML, Symphony does not boot.
- Each project entry in `SYMPHONY.md` must point to a valid `WORKFLOW.md`.
- `server.port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- In multi-project mode, `/api/v1/state` is aggregated across all configured projects and the
  dashboard shows per-project runtime cards plus combined running/retry queues.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `SYMPHONY.md`: startup manifest that lists all managed projects/workflows
- `WORKFLOW.md`: per-project workflow contract used by each orchestrator
- `../extensions/`: repo-level Pi worker extensions for `workspace-guard`, `proof`, and `linear-graphql`
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
