# Ledger status

Read when executing or checking ledger status. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[PL0 option fields](ledger-operations.md#pl0-option-fields)

<!-- canonical-body:start -->
## state.json Top-Level `metadata` Fields

Worktask-scoped fields at `state.json:$.metadata`, distinct from the `task.metadata` above. Canonical schema: `skills/worktask/references/handoff-protocol.md#state-json-schema`; the tables below index fields documented elsewhere in this plugin. All optional.

### Orchestrator-stamped fields

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `preexisting_plan` | orchestrator → PL agent | Absolute path to a user-approved plan supplied at init; PL0 adopts it verbatim and reuses its anchors |

The `/worktask` option flags are not here: they land on PL0's task metadata (§ PL0 option fields).

### Release fields

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `release_tag` | `state-patch.sh --ledger-meta --set '{"release_tag":"<tag>"}'` → release engineer (`changelog-from-git.sh --tag`) | The tag this release is cut under. Absent or empty ⇒ no changelog, PR or summary text names a tag |

### CI field

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `ci` | orchestrator, only on an explicit operator or megatask-brief instruction: `state-patch.sh --ledger-meta --set '{"ci":"disabled"}'` → FN, ST | `enabled` or `disabled`. Only the literal `"disabled"` turns CI off; absent or any other value means on, so a typo keeps CI on. Under `disabled`, FN skips `gh run watch` and writes "CI wait skipped: metadata.ci disabled" in `complete-summary-N.md`; ST marks no criterion PARTIAL for a missing CI run alone and records the flag instead. Revert with `{"ci":"enabled"}`: the merge cannot delete a key. The seed does not carry it, so a re-seeded run (new `run_index`) writes it again |

### Issue publishing field

`metadata.github_issue_url` — issue URL written by `publish-pl-issue.sh` on the run that creates the issue; it short-circuits (`already_published`) on a resume of that same run. Readers: `publish-pl-issue.sh` (idempotency), FN PR-issue-link validator (rank-1). Pattern: `^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+(#issuecomment-[0-9]+)?$`.

`state.json` is re-seeded on every fresh `/worktask`, so this field does not survive a `run_index` increment; the run-independent anchor below carries the binding across runs, so a later run comments on the existing issue instead of duplicating it (`skills/gh-issue-dedup`).

### Run-independent issue anchor

`.context/gh-issue.json` (a sibling file, not a `state.json` field) binds one `.context/` to one GitHub issue and survives `run_index` increments. Schema and protocol: `skills/gh-issue-dedup`; folder placement: `skills/task-folder-organization/SKILL.md`. Written/read by `publish-pl-issue.sh`; read by the FN PR-issue-link validator (rank-2).

## Status Values

| Status | Meaning |
|--------|---------|
| `pending` | Not started, may be blocked |
| `in_progress` | Active work |
| `completed` | Done |
| `blocked` | Waiting on an unsatisfied `blocked_by` entry, or held by a refused landing (`metadata.landing_error`); released by clearing that field, then `--task-status <ID> pending` |
| `skipped` | Dropped by dynamic sizing during PL/AR (`state-patch.sh --task-status QA0 skipped`). The entry stays as an audit record of what was sized out; terminal, and never blocks a dependent |
| `failed` | Terminally failed: retries and per-edge escalations are both exhausted, `last_error.class` is `exhausted`, and no further dispatch will be attempted. Terminal, and settles the completion loop (`skills/worktask/references/orchestration.md` `SETTLED`) |
| `stale` | A `completed` task parked because the work it consumed was re-opened by a correction. Written only by `state-patch.sh --task-reopen`, left only by `--task-settle-stale` |

### Status lifecycle — stale and correction semantics

`stale` holds a `completed` task while the work it consumed is redone. Its verdict, artifact and handoff stay untouched — parked, never reset — until `--task-settle-stale` moves it to `pending` or `completed`. It is neither ready (the loop filter takes `pending`) nor settled, so tasks blocked by it stay unready and the loop stays open.

### `stale` names one thing only

A row reads `stale` only because a correction re-opened its input. Two other uses of the word are
unrelated: the liveness check in `skills/worktask/scripts/stale-check.sh`, which never writes a task
status, and `--task-replay`'s `stale_dependents` field, which only reports dependents a replay may
have invalidated.

## Hook Events for Stage Monitoring

Stage-monitoring hooks are configured in the plugin's `.claude-plugin/plugin.json` or project
`settings.json`; plugin agents ignore a frontmatter `hooks` field. Canonical event catalog (subagent lifecycle, agent-teams, elicitation, matchers, payloads,
the conditional `if` field) and configuration examples:
`skills/agent-coordination/references/hook-monitoring.md § Project-Level Configuration`.

The plugin's `SessionEnd` hook, `hooks/session-end-finalize.sh`, appends one `session_end_finalize`
audit row naming every task still `in_progress` at teardown; it never mutates task status
(`skills/agent-coordination/references/hook-monitoring.md § SessionEnd finalization`).

## Agent Teams Integration

With `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` every session has one implicit team: spawn teammates
with the Agent tool's `name` parameter (`team_name` is ignored) and message them with `SendMessage`.
A plugin-defined agent spawned by name runs with its own prompt, tools, `disallowedTools` and
effort. The Agent result's `agent_id` is the teammate's agent ID; its `name@team` address is in
`teammate_id`.
Teammates coordinate through the same `.context/state.json` ledger as every other stage and can
self-claim available work. Live teammates are visible to `ListAgents`/`claude agents --json`, so a
lead resuming mid-batch uses the stage loop's pre-check
(`skills/worktask/references/recovery-procedure.md#step-0-notes--own-name--teammate-visibility--agent-discovery-changes`). Megatask does not use teams. Set
`"autoMemoryDirectory": ".worktask-memory/"` in settings for worktask-specific auto-memory.
