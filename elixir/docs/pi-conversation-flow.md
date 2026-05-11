# Pi worker conversation flow

This document explains the sequence of messages Symphony sends to a Pi worker for a Linear ticket.

## 1. The first message Pi receives

A Pi-backed run starts in `SymphonyElixir.AgentRunner.run_worker_turns/5`, which opens one long-lived Pi session for the workspace and then executes turns inside that session.

For turn 1, `SymphonyElixir.AgentRunner.build_turn_prompt/4` calls `SymphonyElixir.PromptBuilder.build_prompt/2`.

That prompt is rendered from the workflow template in [`elixir/WORKFLOW.md`](../WORKFLOW.md):

- the opening line `You are working on a Linear ticket` plus the rendered issue identifier
- the `Issue context` block
- the unattended-session instructions
- the workflow/status/PR handling rules

If the workflow body is blank, Symphony falls back to the default template in `elixir/lib/symphony_elixir/config.ex`.

After the prompt text is built, `SymphonyElixir.Pi.WorkerRunner.run_turn/4` sends it to Pi through `SymphonyElixir.Pi.RpcClient.start_prompt/2`, which emits a Pi RPC payload of the form:

```json
{"type":"prompt","message":"...rendered prompt..."}
```

So the very first "message" to Pi is the fully rendered workflow prompt for the current Linear issue.

## 2. What changes on a retry

If Symphony has to retry a ticket in a later agent attempt, `PromptBuilder.build_prompt/2` receives an `attempt` value.

The checked-in workflow template uses that value to prepend a `Continuation context` section:

- `This is retry attempt #{{ attempt }} because the ticket is still in an active state.`
- `Resume from the current workspace state instead of restarting from scratch.`
- `Do not repeat already-completed investigation or validation unless needed for new code changes.`

This is still part of the first prompt for that new attempt. In other words:

- **new attempt:** build the full workflow prompt again
- **retry attempt:** same full workflow prompt, plus retry-specific context

The regression coverage for this lives in `elixir/test/symphony_elixir/core_test.exs` (`prompt builder renders issue and attempt values from workflow template`).

## 3. How later messages continue in the same run

When turn 1 finishes normally but the Linear issue is still active, `AgentRunner.do_run_worker_turns/9` recursively starts another turn **without creating a new Pi session**.

That matters because Pi already has the earlier conversation context in memory for the same session.

For turn 2 and later, `AgentRunner.build_turn_prompt/4` no longer renders the whole workflow template. Instead, it returns a short continuation-only prompt:

- `Continuation guidance:`
- `The previous worker turn completed normally, but the Linear issue is still in an active state.`
- `This is continuation turn #N of max_turns for the current agent run.`
- `Resume from the current workspace and workpad state instead of restarting from scratch.`
- `The original task instructions and prior turn context are already present in this session, so do not restate them before acting.`

That continuation prompt is again sent via Pi RPC as another `{"type":"prompt","message":"..."}` request, but it is sent into the existing session rather than a fresh one.

So the ongoing conversation model is:

1. open one Pi session for the issue workspace
2. send the full workflow prompt on turn 1
3. if the issue remains active, send compact continuation prompts on turns 2+
4. stop when the issue leaves an active state or `agent.max_turns` is reached

## 4. Quick source map

- Workflow prompt template: [`elixir/WORKFLOW.md`](../WORKFLOW.md)
- Fallback default prompt: `elixir/lib/symphony_elixir/config.ex`
- First-turn vs continuation-turn selection: `elixir/lib/symphony_elixir/agent_runner.ex`
- Pi turn execution and prompt dispatch: `elixir/lib/symphony_elixir/pi/worker_runner.ex`
- Pi RPC `prompt` request: `elixir/lib/symphony_elixir/pi/rpc_client.ex`
- Behavior tests: `elixir/test/symphony_elixir/core_test.exs`

## 5. Short answer

If you want the simplest summary:

- **First message:** the rendered workflow prompt for the Linear ticket
- **Later message in the same run:** a short `Continuation guidance` prompt
- **First message on a retry:** the workflow prompt again, with retry context added when `attempt` is present
