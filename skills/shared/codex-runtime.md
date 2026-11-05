---
name: codex-runtime
---

# Codex Runtime Adapter

This reference translates canonical Corpflow commands and agents to Codex. It is shared support
material, not a user-invocable skill.

## Paths

Treat `BASE_PLUGIN_ROOT` as the canonical plugin root. Hook entrypoints initialize it through
`corpflow_init_base_paths`; an interactive skill resolves it as two directories above its own
`SKILL.md`. Use `corpflow_plugin_path` for executable paths. Codex provides `PLUGIN_ROOT` and
`PLUGIN_DATA` to plugin hooks; Claude Code provides `CLAUDE_PLUGIN_ROOT` and
`CLAUDE_PLUGIN_DATA`. Shared logic consumes only the normalized `BASE_*` values.

## Command execution

Start from `skills/<name>/SKILL.md` and follow its linked procedures, argument grammar, write
boundaries, and output contract. For command-backed skills, read `commands/<name>.md` as directed.
The worktask workflow lives entirely under `skills/worktask/`. Translate only the host operations:

### Host operations

| Canonical Claude operation | Codex operation |
|---|---|
| `Agent(...)` | `spawn_agent` with `fork_turns: "none"` |
| `TaskStop(id)` | `interrupt_agent` |
| `ListAgents()` | `list_agents` |
| `SendMessage(id, text)` | `send_message`; use `followup_task` when an idle agent must run again |
| `TaskOutput` / `Monitor` | `wait_agent`, or wait on the active command session |
| `AskUserQuestion` | `request_user_input` |
| `Skill(name)` | Invoke the installed `$name` skill or read its `SKILL.md` when it is support-only |
| `EnterWorktree(path)` / worktree shell | Run with `workdir` set to the absolute worktree and pass it to children as `WORKSPACE_ROOT` |
| `/name` handoff | `$name` in Codex-facing output |

### Translation boundaries

Do not translate prose examples, persisted agent aliases, or ledger schemas. `cc-update` remains a
Claude Code maintenance workflow even when `$cc-update` launches it from Codex.

## Agent dispatch

1. Read the canonical `agents/<agent>.md` role file and the composed stage brief.
2. Resolve the dispatch fields with `corpflow_codex_dispatch_json`: `haiku` → `gpt-6-luna`,
   `sonnet` → `gpt-6.1-terra`, `opus` → `gpt-6.1-sol`, and `fable` → `gpt-6-astra`. It copies the requested
   reasoning effort unchanged and emits the concrete model as `model_resolved`.
3. Call `spawn_agent` before writing a dispatch row. Spawn with a stable
   `cf_<stage>_<attempt>` task name, fresh context, the workspace path, role instructions, context
   references, and completion contract in the message. The task name is not an agent id.

### Record and coordinate a launched agent

4. Only after `spawn_agent` succeeds, record its returned identifier with
   `state-patch.sh --dispatch`; keep the alias in
   `model_requested` and store the concrete GPT model as `model_resolved` when completing the row.
5. Coordinate through Codex agent controls while respecting the current concurrency limit and the
   ledger DAG. Never invent an external plugin agent: invoke its installed skill or take the
   canonical project-tool fallback.

Never synthesize an agent id or mark a dispatch `launched` before the tool returns one. Only call
`wait_agent` when at least one real spawned agent is still live; an empty agent list is a dispatch
failure, not a reason to wait.

### Persist runtime identifiers

Codex versions may return an `agent_id` plus a canonical `task_name`, or only the canonical name.
Persist `agent_id` when present; otherwise persist the exact `task_name` (such as
`/root/cf_pl0_1`) in the existing ledger `agent_id` field. `state-patch.sh` accepts both forms. Use
the canonical name as the collaboration-tool target. Never derive one identifier from the other.

## Stage catalogue support

The production brief composer selects stage and task skill descriptions from canonical sources.
The controlled Codex benchmark dispatcher installs each stage's catalogue and verifies its effective configuration before every dispatch and retry.

This host's `spawn_agent` API cannot configure the child environment or skill discovery.
A composed brief selects reading references; it cannot replace the system-supplied catalogue.
Do not report native catalogue reduction without effective-configuration evidence.
Keep native catalogue replacement pending until a production host adapter can configure and verify it.

## Questions and failures

Use `request_user_input` for material choices, with the recommended option first. Treat missing
plugins, unavailable models, permission failures, and dispatch failures as the corresponding
existing Corpflow blocked/error class. Codex has no Claude model-switch or PermissionDenied hook;
the orchestrator records those failures directly.

## Runtime capability contract

Before dispatch, declare supported operations and their execution owner in the stage instructions.
The restricted headless benchmark uses the canonical block below. Other hosts declare their verified capabilities in the same location.
A declaration cannot grant permission or override the host sandbox.

### Restricted headless operations

```text runtime-capabilities
This coding stage runs in a restricted headless workspace.
Supported here: source edits, SwiftPM builds, and unit/CLI tests within the granted workspace.
Trusted host only: native GUI capture, CoreSimulator, and all Xcode commands after dispatch.
Do not attempt those operations or weaken the sandbox. Keep their acceptance checks pending host validation.
After a confirmed permission denial or unavailable service, record the operation, evidence, and required recovery condition in blocked_on.
Do not retry until the required condition changes. Resume only the blocked step and retain completed evidence.
Handle transient failures, provider limits, and implementation errors through their existing separate retry paths.
Never claim an unperformed check passed.
```

### Capability-aware recovery

Use the existing `permission` arm for denials and `host_environment` for a named preflight check.
Use `user_action` for capabilities without a preflight probe, including trusted-host native acceptance.
Keep the operation, evidence reference, and recovery condition in the existing detail strings and stage artifact.
For `host_environment`, `detail.observed` records the confirmed failure; repeating that return cannot trigger another probe.
Resume after an explicit recovery signal, then verify the named check before continuing.
Permission recovery still requires its existing user grant; a changed observation is never a grant.
A partial persistence failure remains blocked until the existing blocked_on record is repaired.
Never replace a restricted operation with an unsandboxed command, different tool, or weaker acceptance criterion.
