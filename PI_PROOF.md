# Pi agent proof points

This repository already contains the pieces Pi needs to run Symphony's Linear-first workflow, and this TAM-5 change was completed from a live Pi session.

## Concrete proof in this repo

1. **Linear GraphQL tool contract**  
   [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex`](elixir/lib/symphony_elixir/codex/dynamic_tool.ex) exposes a `linear_graphql` dynamic tool with a strict `{query, variables}` input contract and explicit auth, transport, and GraphQL error handling.
2. **Regression tests for that contract**  
   [`elixir/test/symphony_elixir/dynamic_tool_test.exs`](elixir/test/symphony_elixir/dynamic_tool_test.exs) verifies that the tool is advertised, accepts raw GraphQL documents, preserves GraphQL error bodies, and reports missing auth or request failures clearly.
3. **Repo-local Linear workflow instructions**  
   [`.codex/skills/linear/SKILL.md`](.codex/skills/linear/SKILL.md) documents the exact issue lookup, comment update, state transition, attachment, and upload flows an unattended Pi session uses to keep a single workpad comment current.
4. **Operator/runtime documentation**  
   [`elixir/README.md`](elixir/README.md) explains how Symphony exposes `linear_graphql` to repo skills during app-server runs so the agent can keep Linear state and workpad comments in sync.
5. **The workflow contract itself**  
   [`elixir/WORKFLOW.md`](elixir/WORKFLOW.md) requires the same unattended behavior this Pi run exercised: one persistent workpad comment, explicit validation, and Linear state management.

## Focused validation

```bash
cd elixir
mix test test/symphony_elixir/dynamic_tool_test.exs
```

## Why this is a good Pi proof

- It points to code, tests, and repo instructions that can be inspected directly.
- It avoids hand-wavy compatibility claims.
- It is backed by the same Linear/tooling path exercised during this TAM-5 Pi run.
