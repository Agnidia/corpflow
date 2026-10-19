---
name: agent-coordination
description: Use when coordinating agent handoffs, debugging multi-stage execution, writing audit.jsonl rows, or managing parallel agent workflows. Patterns for multi-agent coordination, handoffs, parallel execution, and error escalation.
version: 0.4.0
related:
  - ../worktask/SKILL.md
  - ../claude-constitution/SKILL.md
  - ../security-review-process/SKILL.md
  - ../release-engineering/SKILL.md
  - ../incident-response/SKILL.md
---

# Agent Coordination

Coordinating agents across worktask stages: handoffs, errors, the audit trail, dispatch limits.

- **Stage codes and agents**: `${CLAUDE_SKILL_DIR}/../shared/stage-codes.md`
- **State ledger**: `${CLAUDE_SKILL_DIR}/../shared/state-ledger.md`
- **Per-stage I/O contracts**: `${CLAUDE_SKILL_DIR}/../shared/stage-contracts.md` — each stage's Inputs → Outputs → Validation table.
- `references/hook-monitoring.md` — wiring or debugging hooks: event catalog, matchers, conditional `if`, PreToolUse/PostToolUse decisions, gate-feedback contract, OTEL, agent teams vs subagents.
- `references/headless-dispatch.md` — dispatching from CI/cron/a shell: `task.metadata` → `claude agents` flag bridge, live-session discovery, permission-mode pinning.
- `references/audit-actions.md` — writing or reading an `audit.jsonl` row: every registered `action`, grouped by writer.
- `references/cross-session-messaging.md` — messaging a peer session: reach, authority, delivery results.

## Handoff Protocol

1. Agent completes work matching the stage-contracts Required Outputs.
2. Updates the ledger: `state-patch.sh --task-status <ID> completed`.
3. Creates the stage artifact — `planning-0.md` for the first PL run, `planning-1.md` for the next (`skills/worktask/references/pl0-procedure.md § Plan File & Run Index Naming`) — with its required sections.
4. Writes a compressed handoff (50–100 tokens, § Handoff Message Format), open questions included.
5. Orchestrator validates against stage-contracts before transition.
6. Next agent starts: `state-patch.sh --task-status <ID> in_progress`.

### Orchestrator → PL0 Handoff

Before PL0 the orchestrator writes `.context/exploration.md` with pre-explored codebase facts, so PL0 never re-explores. Its prompt to PL0 includes:

```
Read .context/exploration.md for codebase context.
Do NOT re-read files listed there unless you need additional detail.
```

#### `metadata.skip_exploration` Propagation

Every task PL0 creates downstream (AR0, TL0, DV0, …) carries `skip_exploration: true` (boolean) and `exploration_anchors` (string[] of `<file>#<anchor>` pointers, e.g. `["exploration.md#facts", "planning-0.md#requirements"]`).

AR/TL/DV/DR treat the anchors as the authoritative pre-explored set: no Glob/Grep over files they cover, and read the anchor rather than the whole file, because re-exploration is the largest avoidable AR/TL token cost. An agent that must widen scope (AR finds an undeclared dependency) may explore further, and logs one `audit.jsonl` line `action: "exploration_extended"`, `metadata: {reason: "<why>"}` so reviewers see the broadened scope.

### Stage Agent File Read Rules

Every stage reads `exploration.md`; source-file access differs.

| Stage | Source files | Reason |
|-------|:------------:|--------|
| PL | No | Requirements only, no code changes |
| AR | Selective | Only files needing architectural analysis |
| TL | No | Coordination only |
| DV | Yes (modify targets) | Must read files it will modify |
| DR / QA | Yes (changed files) | Must review actual changes |
| DC | No | Documentation from artifacts |

## Error Handling

### Retry / Escalate Matrix

| Classification | Trigger | Retry | Escalate to |
|---|---|---|---|
| `transient` | 5xx / rate-limit / network | 3, backoff 2^n s | — (same agent) |
| `logic` | bug / wrong approach | 3, corrective context from retry 2 | — (same agent) |
| `missing_input` | required artifact absent | No | previous stage per chain |
| `ambiguous_requirements` | requirements unclear | No | PL |
| `design_flaw` | architecture blocks implementation | No | AR |
| `hard_constraint` | ethics / security / legal block | No | abort + block for human (`"ST"`) |
| `exhausted` | `retry_count == 3` | No | previous stage per chain |
| `permission_denied` | auto-mode classifier denies a tool call | No | — (same agent) |

Metadata: `retry_count++` on each retry; on escalation set `error_escalated_to` to the target and reset **`retry_count` alone** at handoff.

#### Retry / Escalate Matrix — one ceiling, reachable from every retrying class

Every retrying class shares the ceiling of 3, so `exhausted` is reachable from each; the non-retrying classes escalate on their first failure, or — `permission_denied` — park for the user. `skills/worktask/SKILL.md § Retry Logic` and its `retry_count == 3` trigger restate the ceiling; keep them equal to the table.

#### Retry / Escalate Matrix — the per-edge escalation cap

`metadata.escalation_counts` on the escalating task counts escalations per target, keyed by the target's full task id (`{"AR0": 2}`) so a split stage's writers do not share a counter. Increment it on each escalation handoff. Unlike `retry_count` it is not reset by that handoff: it is the only bound on a DV→AR→DV→AR ping-pong.

At cap 2 on an edge the escalating task is written `status: "failed"` with `last_error.class: "exhausted"` instead of escalating again; `failed` is settled, so the completion loop terminates. Schema: `skills/shared/state-ledger.md § Schema — error & retry properties`.

#### Retry / Escalate Matrix — environmental contention

QA only — DV's handful of executed tests cannot establish the trigger. `environmental_contention` never retries and never escalates: re-baseline once on a quiet machine and note the outcome in `testing-N.md § Notes` — no defect, no `error_escalated_to`.

Trigger, all three: failures confined to wall-clock/async-timing suites; failing-set membership differs between two consecutive runs (a member added or dropped — not ordering, not duration); no source change between them. If the re-baseline run fails with the same members as the previous run, the classification is void: reclassify as `logic` and escalate to DV.

#### Retry / Escalate Matrix — permission denials

`permission_denied` never retries and never escalates. The task parks `blocked` with `metadata.blocked_on` until the user answers, then the same stage agent resumes only the denied step — hence `— (same agent)` and no `ESCALATE_TO` entry. Parking touches none of `retry_count`, `escalation_counts` or `last_error`, so a denial never walks a stage toward `exhausted`. Mechanism: `skills/worktask/SKILL.md § Step 6.5a4`.

### Escalation Chains

```
11-stage: ST→FN→RE→DC→QA→SR→DR→DV→TL→AR→PL→USER
9-stage:  ST→FN→DC→QA→DR→DV→TL→AR→PL→USER
Emergency: FN→RE→QA→DR→DV→IR→USER
Ethics: Any→ethics-reviewer→stakeholder→USER
```

### Error Documentation

Append to `.context/errors/<agent>.md` — one file per `metadata.agent` basename, shared across retries and splits (DV0/DV1/DV2 → `developer.md`):

```markdown
## [STAGE][N] Retry [X/max] — [TIMESTAMP]
**Agent**: [agent name]
**Task ID**: [task_id]
**Classification**: [transient | logic | missing_input | ambiguous_requirements | design_flaw | hard_constraint | exhausted | environmental_contention | permission_denied]
### Problem
[Description]
### Resolution Path
- [ ] [Action]
```

Raw captures (build/test/monitor stdout) go to `.context/logs/` per `logging-conventions`.

## Parallel Execution

Every megatask issue and every DV stage runs in its own worktree and branch, so parallel issues, parallel DVN streams, QA ∥ DC, and agent-team members can overlap without source-tree conflicts.

Order still binds: AR waits for PL (needs requirements), DV for TL (needs coordination), QA for DV (nothing to test yet).

## Audit Trail

Every material worktask action writes one JSONL line to `.context/logs/audit.jsonl` (folder per `logging-conventions`). The file is append-only and outlives individual stage artifacts; on resume or incident review its tail is the source of truth for what happened.

### Writers

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator | `worktask_init`, `stage_transition`, `approval_received`, `resume`, `stage_replay`, `permission_mode_pinned`, `github_issue_created`, `dispatch_depth_projected` (Pre-Stage Validation check 11), `stage_returned_incomplete` (Step 6.5a2), `reattach_send_result` (one per reattach attempt — `skills/worktask/references/resume.md § Reattach rows`), `blocked_on` (one row per leg, Steps 6.5a3 and 7a; § Writers — blocked_on rows), `mailbox_ingest` |
| Stage agents | `artifact_created`, `error_recorded`, `retry_attempt`, `escalation`, `full_test_run`, `scoped_test_run`, `message_ack` (`state-patch.sh --ack`) |
| Any agent that flattens a dispatch (depth-cap refusal or choice) | `dispatch_flattened` (§ Depth-refusal self-report) — the writer is the *flattening dispatcher*, which may be a stage agent or a nested platform router, never the orchestrator |

#### Writers — permission denials (two writers, one row)

| Actor | Action Examples |
|-------|-----------------|
| `PermissionDenied` hook (`hook:permission-denied`, plugin) | `permission_denied` (auto-mode classifier blocks a tool) — `result: "block"`, `metadata.{tool, dedupe_key, command_head, truncated}` |
| Orchestrator fallback (`permission-park.sh park`, worktask Step 6.5a4) | `permission_denied`, same redacted shape, actor `orchestrator`, from the stage's returned `blocked_on` or tool result |

The fallback exists because hook firing inside a subagent is unverified. Both writers skip the append when the log already holds the same `dedupe_key` — the first 16 hex of `sha256("task_id:tool:command")` of the command after secret masking, never the unmasked text — or its twin under the other writer's subject (§ Information redaction and deduplication), so each denial yields one row whichever lands first.

#### Writers — permission denials, a repeat after a grant

Known limit: re-denying the same command in the same task after a grant writes no second row (the masked command, and so the key, is unchanged); the task still parks.

#### Writers — permission resumes (the decision_ref row)

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator (`permission-park.sh resume`, worktask Step 7a) | `permission_resumed`: one row per successful resume and none on a refusal. `result: "ok"`, `metadata.{tool, dedupe_key, command_head, truncated, answer: grant\|manual, decision_ref}` |

`metadata.decision_ref` is `permission_resumed:<task_id>:<dedupe_key>:<n>`, where `n` is 1 plus the earlier `permission_resumed` rows with the same subject and key, so a call denied and parked again gets a distinct ref. A permission `blocked_on.resume_with: decision_ref` points at it, `resume` returns it as `resume_block.decision_ref`, and the `dedupe_key` pairs the row with the task's `permission_denied` row. The row records the user's own answer to the boundary prompt: the orchestrator calls `resume` only with that answer, and no delegate or resolver answers for the user.

#### Writers — redacted permission rows

`.context/logs/audit.jsonl` is committed, so `permission_denied`, `permission_resumed` and `escalation_parked` rows hold only redacted heads: `audit_command_head` from `hooks/lib/command-head-lib.sh` over the secret-masked command (at most 4 tokens, path-scrubbed, ≤120 chars). When that library is unavailable, `command_head` is `[redacted]` and `redaction` is `scrub_unavailable`.

##### Information redaction and deduplication

No row carries the full command, `classifier_reason`, `allow_rule` or raw `tool_input` (§ Writers — where the full permission detail lives). Each `escalation_parked.metadata.escalated[]` entry is `{tool, command_head, truncated}`. With no command on the row, a twin is found by key alone: the fallback also re-derives the key for `subject: "unknown"`, and a hook that cannot name the task re-derives it for every ledger task id.

#### Writers — where the full permission detail lives

The full command, `classifier_reason` and `allow_rule` stay out of the audit log, not out of `.context/`: in the stage artifact's `handoff.blocked_on` when the stage wrote one (nothing clears it, so it outlives resume); in the ledger's `tasks.<ID>.metadata.blocked_on` (`resume` sets it to `null`); in the resume message or re-dispatch suffix built from `resume_block.instruction`; and in the `batch` output and boundary prompt shown to the user. A project that commits `.context/` commits the artifact copy, and a ledger copy committed while the task was parked stays in that history.

#### Writers — blocked_on rows

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator (`blocked-on-dispatch.sh route\|resume`, worktask Steps 6.5a3 and 7a) | `blocked_on`: one row per leg of a non-permission arm. `subject` and `task_id` are the task id; `result: "blocked"` on a leg that leaves the task parked, `"ok"` on the closing leg. `metadata.{kind, arm, leg}`, plus `fallback_from` and `owner_issue` on a fallback, `command_head` and `truncated` on a need with a command, and `decision_ref` on the closing leg |

The permission arm writes no `blocked_on` row: its `denied` leg is the `permission_denied` row, its `granted` and `resumed` legs the `permission_resumed` row. A closing row's `decision_ref` is `blocked_on:<task_id>:<kind>:<n>` (`skills/worktask/references/handoff-protocol.md § Schema — blocked_on, decision_ref on the other arms`).

#### Writers — blocked_on rows, the peer_session legs

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator (`mailbox.sh leg\|comment\|scan\|sweep`, `blocked-on-dispatch.sh resume`) | `blocked_on`: one row per leg per ask, deduped on `(subject, metadata.ask_id, metadata.leg)`. `metadata.{kind, arm, leg, ask_id}`, plus `transport` (`message\|comment`) on `sent` and `delivered`, `transport_result` on `delivered`, `answered_by_kind` on `answered` and `relayed`, and `reply_ref` with `decision_ref` on `relayed` |

Only the originating orchestrator writes these: a session answering from another worktree has no ledger task to cite, and `mailbox-reply.sh` writes no audit row. Every key above is a neutral name — the question, its options, the answer and the comment body live only in the mailbox files and `tasks.<ID>.metadata.blocked_on`.

#### Writers — blocked_on rows, the correction legs

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator (`blocked-on-dispatch.sh route\|resume`) | `blocked_on`: `opened` at the route that re-opened the target, `closed` at the resume. Metadata includes `kind`, `arm` (always `correction`), and `leg`; plus `decision_ref` on `closed`. No command head — a correction asks nobody to run a command |

##### Correction routing and detail placement

A re-routed correction writes no second `opened` row: the router reads the still-open need's recorded leg and re-parks without calling the op. The row names only its own task — target id, finding, `evidence_ref` and consumer count stay off it (§ Writers — blocked_on rows, redacted). The detail lives in `tasks.<ID>.metadata.blocked_on` and reaches the re-opened stage through `metadata.gate_blockers` and remediation injection.

#### Writers — mailbox_ingest rows

| Actor | Action Examples |
|-------|-----------------|
| Orchestrator (`mailbox.sh ingest-comments`) | `mailbox_ingest`: `result: "ok"`, written only when a reply comment was ignored (`ignored > 0`). `metadata.{ask_id, ignored, reasons}`, `reasons` drawn from `author`, `bot`, `grammar`, `stale`, `schema`, `late`, `duplicate` |

The row records that input was refused and why — never the sender's login or the comment body. An accepted reply writes no row of its own; it becomes the `answered` leg above.

#### Writers — blocked_on rows, redacted

A `blocked_on` row never carries a full `command`, `request`, `question`, `finding` or `observed` text, nor a user answer; that detail stays in the artifact's `handoff.blocked_on` and the ledger's `tasks.<ID>.metadata.blocked_on`. `command_head` is at most 4 tokens of the secret-masked, path-scrubbed command: from `audit_command_head` (`hooks/lib/command-head-lib.sh`) when that file is readable, else the first 4 tokens of `pd_command_head` (`hooks/lib/permission-denied-lib.sh`), else the literal `"[redacted]"`. `truncated: true` marks a cut head or that placeholder.

#### Test-run counter rows

One row per test invocation, keyed on the invocation's shape rather than the plan's mode: ≥1 test-selection flag (`-only-testing:`, `--tests`, `-k` and the rest of `skills/shared/test-selection-syntax.md § Identifier grammar by platform`) or a trailing positional test target → `scoped_test_run`; neither → `full_test_run`; `build-only` runs emit none. `metadata: {stage, plan_mode, suites_selected, run_index}` — `plan_mode` next to the shape answers "how often did we actually run everything". Audit-only: a missing counter row never blocks a stage and never appears in a completion checklist.

#### Writers — plugin hooks (authoritative)

| Actor | Action Examples |
|-------|-----------------|
| `hook:audit-subagent` (SubagentStop, plugin) | `subagent_stopped` |
| `hook:audit-tooluse` (PostToolUse, plugin) | `tool_invoked` for `Bash\|Write\|Edit` with `duration_ms` + `effort`, a redacted `command_head` on Bash, scrubbed paths — never the command line or file content |
| `hook:state-merge` (SubagentStop, via `state-patch.sh --via hook`) | `stage_transition` or one-shot `state_merge_noop` with metadata per artifact |
| `hook:precompact` (PreCompact, plugin) | `precompact_checkpoint` with state file, run index and artifacts |
| `hook:agent-stop` (SubagentStop, matched to the PL/FN/ST agents) | `stage_completion_hook` with metadata.stage |
| `hook:test-execution-gate` (PreToolUse, plugin) | `test_execution_blocked`, `test_execution_deduped`, `test_dedupe_skipped_zero_prior`, `test_delegation_observed`, plus gate control one-shots |

##### Plugin-hook authoritative rows and fields

Every row above is authoritative. `audit-subagent` and `agent-stop` rows also carry `parent_agent_id`, `background_tasks_count`/`_ids`, `session_crons_count`/`_ids`. `stage_transition` is emitted only on the hook path — a hook completion runs no Bash tool call, so `hook:audit-tooluse` never sees it; other layers stay scraped to avoid double counting.

#### Writers — model-switch hooks (authoritative)

| Actor | Action Examples |
|-------|-----------------|
| `hook:model-switch-gate` (PreModelSwitch, plugin) | `model_switch_blocked`, `model_switch_confirm_requested`, `model_switch_annotated`, and one-shot `model_switch_gate_disabled` hatch note — `metadata.{stage, task_id, pinned, requested, kind}` |
| `hook:model-switch-audit` (PostModelSwitch, plugin) | `model_switched` with `metadata.{pinned, origin, resolved, off_tier, dedupe_key}`, gated on an existing ledger |

#### Writers — external & adapters

| Actor | Action Examples |
|-------|-----------------|
| External dispatcher | `external_dispatch` (CI/cron/user-shell invoked a stage outside `Agent()` — see `references/headless-dispatch.md`) |
| `apple-canvas` adapter (in `dv-screenshot-capture`) | `canvas_render` (one row per phase ∈ scaffold\|complete\|retry — see `skills/dv-screenshot-capture/references/apple-canvas.md § Audit row schema`) |
| `apple-canvas` adapter, from the `preview-ensurer` result | `preview_added` (one row per `#Preview` block written to source — `metadata: {file, view_type, mock_strategy, lines_added}`) |
| QA visual-diff wrapper (`skills/dv-screenshot-capture/scripts/visual-diff.sh`) | `visual_diff_run` (one row per RMSE diff — `metadata: {reference, candidate, metric:"RMSE", value_percent, threshold_percent, verdict}`) |

#### Hook authority + dedupe rule

Hook-emitted rows carry `actor: "hook:<name>"` and `metadata.dedupe_key`. Agent-emitted rows for the same action stay valid for installs where the plugin's hooks do not run, but are advisory: readers (resume protocol, incident-responder) prefer the `hook:*` row when two rows share a `dedupe_key`.

#### Hook authority — canonical vs mirrored writers

A hook row's actor is `hook:<name>` or `<plugin>:hook:<name>` — every installed sibling plugin mirrors these hooks under its own prefix, so one completion yields one canonical row plus one per sibling. Mirrors set `metadata.advisory: true` and carry thinner metadata (an empty `subject` in particular). Authority within a `dedupe_key` group is therefore three-tier: canonical hook row, then any hook row, then first by index. Matching on `startswith("hook:")` alone gets this wrong; route through `scripts/audit-dedup.sh`, which implements the ladder.

#### Dedupe-key shapes — tool & subagent

- `tool_invoked`: `"<session_id>:<tool_use_id>"`
- `subagent_stopped`: `"<session_id>:<agent_id>:stop"`

#### Dedupe-key shapes — stage & issue

- `stage_completion_hook`: `"<session_id>:<agent_id>:stage:<PL|FN|ST>"`
- `stage_replay`: `"<worktask_id>:<run_index>:<task_id>:replay:<ts>"` — the timestamp is deliberate: replay is repeatable, so two legitimate replays of one stage must not collapse. Written by `state-patch.sh --task-replay`, on success only; a refusal changed nothing and records nothing.
- `github_issue_created`: `"<worktask_id>:<run_index>:gh_issue"` — a collision on resume detects already-published; multi-track safety via `run_index` increment. Writer: orchestrator (via `skills/worktask/scripts/publish-pl-issue.sh` between PL approval and stage-loop entry).
- `model_switched`: `"<session_id>:<agent_id>:model-switch:<ts>:<resolved>"` — timestamp and destination are deliberate: a session that switches twice (fallback, then back) keeps both rows. Writer: `hooks/model-switch-audit.sh`.

### Schema

```jsonc
{
  "ts": "ISO-8601 UTC",
  "actor": "orchestrator|<agent-name>|hook:<name>",
  "action": "<one registered action — references/audit-actions.md>",
```

`references/audit-actions.md` lists every action a shipped writer emits, grouped by writer; the § Writers tables above name the main owners, not every writer.

#### Schema — remaining fields

```jsonc
// …continued: the same object
  "subject": "required — task ID or artifact path",
  "result": "ok|error|deferred|blocked|block|skipped",   // block: hook-tree appender rows, e.g. permission_denied
  "task_id": "required — ledger key, e.g. DV0; \"none\" when no stage is active, \"unknown\" when one is but cannot be resolved",
  "artifact": "optional — .context/ path",
  "metadata": { "...": "action-specific extras" }
}
```

Both shared appenders, `corpflow_audit_row` (skills) and `corpflow_hook_audit_row` (hooks), refuse a row without a non-empty `subject` and `task_id`: nothing is written and one stderr line names the missing key.

#### Hook-written metadata fields

Optional `metadata` fields on hook-written `subagent_stopped` / `stage_completion_hook` rows, in addition to action-specific extras:

- `duration_ms` (subagent_stopped only): number
- `effort`: `"low"|"medium"|"high"|"xhigh"|"max"|"unknown"`
- `stage`: `"PL"|"FN"|"ST"` on stage_completion_hook, any stage code on subagent_stopped (from `CLAUDE_TASK_METADATA_STAGE`), `"unknown"` when unstamped
- `agent_id` (subagent_stopped only): string — `"unknown"` when absent
- `parent_agent_id`: string — `"none"` when not in hook stdin
- `background_tasks_count` / `session_crons_count`: integer ≥ 0
- `background_task_ids` / `session_cron_ids`: string[] — a `"unknown"` entry means the ID field name shifted; see `references/hook-monitoring.md § BG-Task ID Schema Watch`
- `dedupe_key`: string (always present)

### Append Pattern (Bash)

```bash
mkdir -p .context/logs
jq -c --arg ts "$(date -u +%FT%TZ)" \
  '. + {ts: $ts}' <<< '{"actor":"orchestrator","action":"stage_transition","subject":"DV0→DR0","result":"ok","task_id":"DV0"}' \
  >> .context/logs/audit.jsonl
```

### Retention

Follows `.context/` hygiene — cleared on task archival (FN stage or `/worktask` completion). Never rotate within a task: PostCompact recovery and incident post-mortems need the full trail.

## Task Decomposition

Whether a stage splits depends on *who* initiates the split and *what* the dependency shape is. Pick one pattern; do not mix them.

### Decision Table

| Condition | Pattern | Effect | Example |
|-----------|---------|--------|---------|
| Independent sub-scopes, different owners | **TL-initiated (parallel)** | DVN blocked by TL0, all concurrent; DR0 blocked by all DVN | `theme colors` + `switcher` + `dark assets` |
| Cross-cutting refactor across many modules | **TL-initiated (parallel)** + `track` metadata | Each stream gets its own worktree | `rename User → Account` |
| Sequential discovery (later work depends on earlier) | **DV-initiated (sequential)** | DVN blocked by DV0, run in order | `implement auth` → `migrate users` |
| Stage failed and the retry needs narrower scope | **DV-initiated (sequential)** | DV1 is the focused retry; `retry_count` resets | DV0 full feature → DV1 auth only |
| Single cohesive scope, <3 files | **No split** | DV0 handles it | `fix null check in login validator` |

Full code patterns: `skills/worktask/references/initialization-patterns.md § Stage Sub-Task Splitting`.

### TL-Initiated DV Splitting

The TL split procedure — per-stream file ownership, interface contracts, DR0 rewired onto every DVN, the `### Parallel Streams` record under `## fan-out` — is `agents/team-lead.md`.

### When NOT to Split

- **PL/FN/ST** — always singletons (PL0, FN0, ST0).
- **Trivial scope** — orchestration cost exceeds the benefit.
- **Shared mutable state** — if two streams edit the same file, serialize; merge conflicts cost more than the latency saved.

### Hypothesis-Driven Debugging

For a bug with multiple candidate causes: generate N hypotheses spanning different failure categories, assign each to an investigator agent, have each gather confirming/falsifying evidence, then arbitrate ranked by confidence and evidence strength.

## Agent Selection

### Sub-Task Delegation

| Sub-Task | Delegate To |
|----------|-------------|
| Status check | Self |
| Code implementation | developer |
| Architecture question | software-architector |
| Platform architecture (apple/systems/android/web/backend/ai) | the platform's architect agent |
| Technical decision | technical-lead |
| Test design | qa-engineer |

Model sizing: a worktask stage dispatch takes model and effort from `skills/shared/stage-codes.md`; other delegations use `skills/shared/model-selection.md § Selection Criteria`. Platform roster: `skills/shared/routing-matrix.md § Functional-role aliases`.

#### Cross-plugin AR collaboration

On platform projects `software-architector` consults that platform's architect during AR for platform-specific architecture (e.g. Apple: pattern selection, DI, navigation, concurrency). Per-platform table: `agents/software-architector.md § Platform Architecture Collaboration`; protocol: `cross-plugin-handoff` skill.

#### When not to delegate

The table says who takes a sub-task, not that every sub-task needs one. There is no per-session total-spawn cap, so nothing stops a stage spending its budget on spawns a direct tool call would have answered.

Delegate work that is genuinely independent and parallelizable, or needs expertise this stage lacks: a wide multi-file investigation, a platform specialist, a per-stream DV split. Do not delegate what a grep and two reads would settle, do not spawn a subagent to double-check your own output, and use one delegate where one suffices. A `sonnet` stage at `xhigh` or `max` can start reviewer subagents on its own; brief section `[4b]` counters that at dispatch (`skills/shared/model-prompting.md § sonnet`).

#### Nested delegation

Subagents spawn their own subagents up to 3 levels deep by default (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`; `=1` disables nesting). Depth counts from the session root: the main session is depth 0 and its directly dispatched stage agent depth 1. The canonical DV chain — session → `developer` (1) → `apple-developer:ios-developer` (2) → `apple-developer:test-generator` (3) — sits exactly on the default ceiling; the orchestrator does not flatten Tier-2 dispatch into its own loop.

##### Depth budget sharing

Foreground and background subagents share one depth budget.

`/megatask` consumes a level: it dispatches each per-issue `/worktask` orchestrator as its own subagent (depth 1), pushing the same DV chain to depth 4 — one past the default. Raise `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` before the batch, or accept a flattened Tier-2 dispatch (`skills/megatask/SKILL.md § Nesting-depth budget`).

#### Pre-launch spawn classification

In auto mode the permission classifier evaluates a subagent spawn before it launches, so a dispatch can be denied up front (`PermissionDenied` fires). Route a refused spawn like a failed stage, per the retry/escalate matrix, rather than assuming every `Agent(...)` starts.

#### Depth-refusal self-report

When the depth cap refuses a nested `Agent()`, or an agent chooses to do a specialist's work inline (skipping the platform router included), that dispatcher appends one `dispatch_flattened` row to `.context/logs/audit.jsonl` before doing that work inline. Written afterwards, the row misses its purpose: an agent that finishes the specialist's job and then forgets leaves an artifact indistinguishable from one the specialist produced.

##### No hook covers this refusal

Unlike a refused tool (`PermissionDenied`), nothing in the plugin hook vocabulary (`references/hook-monitoring.md`) is depth-shaped, so this row is a self-report: it closes the silence but does not guarantee capture.

| Field | Value |
|---|---|
| `actor` | the refused dispatcher (e.g. `apple-developer:apple-developer`), never `orchestrator` |
| `action` | `dispatch_flattened` |
| `subject` | the **specialist that would have been used** (e.g. `apple-developer:test-generator`) |
| `result` | `deferred` — the dispatch did not happen; the work still did |
| `metadata.reason` | `depth_cap` (the cap refused the dispatch) or `chosen` (the agent flattened by choice) |
| `metadata.attempted_depth` | the depth the refused child would have occupied; `null` under `chosen` |
| `metadata.cap` | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` as resolved at refusal time; `null` under `chosen` |

##### Required fields and pairing

`subject`, `reason`, `attempted_depth` and `cap` are required for both reasons, the last two as `null` under `chosen` so readers see stable keys: together they tell an operator whose judgment is missing from the output, which is the only question the row answers.

Pairs with the orchestrator's forward-looking `dispatch_depth_projected` (`skills/worktask/SKILL.md § Validation check 11`): the projection warns before the stage runs; this row records what the projection missed.

#### Background-by-default dispatch

Subagents run in the background by default: the dispatching agent keeps its turn and receives the child's result as a completion notification. So (1) an `Agent()` launch acknowledgement is not stage completion — advance a stage (Step 6.5, the `completed` patch) only on the completion notification or the `subagent_stopped` audit row (`skills/worktask/SKILL.md § Orchestrator Execution Loop`); (2) unblocked sibling stages (parallel DVN tracks, DC+QA) overlap with no extra orchestration.

##### Depth accounting & background permission prompts

Resumed subagents restore their original spawn depth and their own prompt and tool restrictions, and forked ones count toward the cap — so reattach is safe and identity alone never forces a re-dispatch. Permission prompts from background subagents surface in the main session (the dialog names the asking agent; Esc denies just that tool), so an unattended run parks on them — see the resume `waitingFor` branch table.

##### Two independent ceilings

Either of two caps can refuse a dispatch; they are counted and raised separately, so check both before a wide fan-out.

| Ceiling | Default | Env override | Counts |
|---------|---------|--------------|--------|
| Nesting depth | 3 | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | Levels below the session root; `=1` disables nesting |
| Concurrently running | 20 | `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` | Agents alive *right now*, at every depth |

###### No total cap; concurrency is the one that bites

There is no per-session total-spawn cap, so `/megatask` batch size is bounded by concurrency, disk and rate budget alone. Concurrency is the easy ceiling to hit: background dispatch keeps stage agents alive at the same time, each nested Tier-2 specialist counts while it runs, and `/megatask` runs `parallel_tracks` orchestrators each with a live stage agent and its children. Project peak concurrency, not the total, at the R1 gate.

###### Bash memory ceiling (Linux)

`CLAUDE_CODE_TOOL_MEMORY_LIMIT` (opt-in, Linux only) puts Bash tool commands in a memory cgroup so a runaway build cannot stall the session; worth setting on CI runners that execute `/<plugin>:build-test`. On macOS only the build timeout catches a runaway build.

###### Budget halts are not stage failures

When `--max-budget-usd` trips, new spawns are denied and running background subagents are halted. Re-dispatch a stage that disappeared under a budget stop once the budget is raised; it does not consume one of that stage's 3 retries, which are for genuine stage failures (`skills/worktask/references/resume.md`).

### Model Selection

Prefer reading an artifact over invoking an agent. Per-invocation override: `Agent({ subagent_type: "corpflow:developer", model: "opus", effort: "high" })` — `effort` needs 2.1.292. The spawn tool is `Agent`; hooks, matchers and grants name only `Agent`.

Permission rules accept `Tool(param:value)` with `*` wildcards — `Agent(model:opus)` permits only opus-model spawns, `Agent(model:*)` any override — so auto mode's dispatch overrides can be constrained without listing every agent. `Agent(type)` deny rules and `Agent(x,y)` allowed-types restrictions apply to named subagent spawns too.

#### Effort on nested delegation

A nested `Agent` call without `effort` runs at the target's own `effort:` frontmatter tier, never the caller's. Probed at 2.1.292: `team-lead` at `xhigh` spawned `technical-lead`, which ran at `high`. So a stage agent that hands its stage's primary work to another agent passes its own tier, the `effort:` line of its brief:

| Delegation | `effort` |
|---|---|
| DV → platform implementer or specialist | the brief's `effort` |
| QA → test-generator or UI verifier (one leg) | the brief's `effort` |
| SR → security auditor | the brief's `effort` |
| RE → platform release engineer | the brief's `effort` |
| Consults: TL → technical-lead, AR → platform architect, PM → designer or ethics | none: the target's own tier |

Pass no `effort` to a haiku target, or when the brief has no `effort:` line.

#### Model aliases, allowlists & @-mentions

Agent-team teammates use the lead session's model unless overridden. Aliases (`fable`/`opus`/`sonnet`/`haiku`) work across all providers. A managed `availableModels` list also constrains subagent overrides, and `enforceAvailableModels` the Default model, so a valid alias may resolve to a different model (`skills/worktask/SKILL.md § Pre-Stage Validation` step 6). `@` mentions named subagents and other Claude sessions; `SendMessage` delivers to a bare name matching exactly one live session.

#### Cross-session messaging

When a stage messages a peer session, read `skills/agent-coordination/references/cross-session-messaging.md`: `SendMessage` reach and `ListAgents`, inbound policy, restricted sessions, authority that does not relay, delivery results, `notify_when_idle` and preview collapse.

#### Replies from a subagent land in the parent conversation

A `SendMessage` from a subagent to another session delivers the reply into the parent session's conversation, never back to the sending subagent. Only a sibling-or-parent subagent target in the same session round-trips — including resume: a subagent that resumes another agent via `SendMessage` is woken by that agent's completion.

So a stage agent never messages another session and waits inline for the answer; it will not arrive. Return `verdict: "blocked"` with `handoff.blocked_on` of kind `peer_session` naming who to ask and what (`skills/worktask/references/handoff-protocol.md § Schema — blocked_on, the peer_session arm`). The orchestrator routes it (`skills/worktask/SKILL.md § Step 6.5a3`, `skills/worktask/references/resume.md § Reply routing`), and the durable mailbox (`skills/worktask/scripts/mailbox.sh`) carries the ask and relays the verified reply.

#### Skill discovery & subagent_type resolution

Subagents resolve project, user and plugin skills natively at every depth, so never inline-load skill instructions before delegating. `subagent_type` matching is case- and separator-insensitive (`"Corpflow:Developer"` → `corpflow:developer`); a bare name still resolves to `corpflow:` first.

#### Dispatch flags

`claude agents` dispatch flags map to `task.metadata` per `references/headless-dispatch.md § Translation Table`. PL0 populates the optional fields (`skills/worktask/references/pl0-procedure.md § Optional dispatch metadata`); external runners consume them per `commands/worktask.md § Headless Dispatch`.

### Monitor Tool for Background Events

`Monitor` streams stdout from this session's own background scripts (Bash `run_in_background`) — event-driven, no polling loops. Waiting on a peer session to go idle is `notify_when_idle` instead (`references/cross-session-messaging.md § notify_when_idle, availability & preview collapse`); neither substitutes for the other. Launch with `run_in_background: true`, tee into `.context/logs/` so the capture outlives the watch (`logging-conventions`), note the returned shell ID, and attach `Monitor` to it. After Monitor detaches, the `.log` is still readable. In an unattended session (`-p`, SDK, CI, cloud) the background command itself stops at its Bash `timeout` (default 30 min, max 2 h), so a command that can run longer sets `timeout` explicitly (`references/headless-dispatch.md` § Print-mode runners — background time limit).

```bash
<command> 2>&1 | tee .context/logs/<kind>-<slug>-<ts>.log
```

#### Per-Stage Monitor Usage

| Stage | Background command → what Monitor watches |
|-------|-------------------------------------------|
| DV | `xcodebuild …` / `swift build` → compile + dependency-resolution errors; abort on first failure |
| QA | `xcodebuild test …` → pass/fail per test, stop on first red; `xcrun simctl spawn … log stream` → runtime behavior |
| IR | `ssh prod tail -f /var/log/app.log` → recurring error pattern |
| DR/SR | `swiftlint --reporter json` → warnings streamed for severity triage |
| RE | `xcodebuild archive …` → signing / archive steps; abort on signing failure |
| FN | `gh run watch <run-id>` → PR check progress; skipped when `metadata.ci` is `"disabled"` (`state-ledger.md § CI field`) |

#### Stall Timeout

A subagent stalled >10 minutes fails with a clear error rather than hanging, and Monitor watches inherit the guard: no output for >10 min is a failure — escalate per § Retry / Escalate Matrix. Idle background shells may be reaped under memory pressure; set `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` where a long-lived monitor or `tee` pipe must survive. The tee'd `.context/logs/*.log` is the durable record either way.

#### Watch Deadline

Every Monitor watch carries a bounded deadline — at most 30 minutes, 10 inside a single-prompt (`-p`) run. On expiry Claude is notified to re-arm the watch: a step that outlives the deadline (QA `xcodebuild test`, RE `xcodebuild archive`, IR log tail) re-attaches Monitor on that notification instead of assuming one attach spans the whole operation. This adds to the stall-timeout guard above; it does not replace it. A re-armed watch cannot outlive the command: in an unattended session the command's own `timeout` (§ Monitor Tool for Background Events) is the outer bound.

### MCP Auto-Background

An MCP tool call past the auto-background threshold (default 2 minutes, `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`) is backgrounded by Claude Code itself: the caller gets a handle, not the result. Handle it like a backgrounded `Agent()` dispatch (§ Background-by-default dispatch): the handle is not the build/test outcome. A completion gate reading an artifact the call produces (e.g. `developer § D1`'s `build-developer-*.log`) waits for the real completion signal — a log still being written is not done, and file presence proves nothing.

#### MCP auto-background threshold tuning

- XcodeBuildMCP `build_sim` / `build_run_sim` / `test_sim` routinely exceed 2 minutes; flows chaining on them await between steps.
- Raise or disable the threshold only when one turn genuinely needs a synchronous result (diagnosing a full log in one pass), and only on an external headless dispatch with its own environment: in-process `Agent()` children share the session setting, so raising it session-wide costs every other MCP call its safety net.

### MCP Tool Inheritance

Subagents inherit MCP tools from servers already running in the parent at delegation time, so cross-plugin tools (XcodeBuildMCP, Pencil, …) need no per-tool `tools:` entries. A lazy-spawned server (`npx -y …` over stdio) starts only on its first tool call in a session, and inheriting the server reference does not spawn it, so a child can fail its first `mcp__<server>__*` call with "tool not available". The orchestrator does no warm-up: the platform plugin owns cold start and its CLI fallback (`skills/worktask/SKILL.md § Platform tooling ownership`).

### Subagent Worktree Access

Worktree-isolated subagents get Read/Edit access to their own worktree with no explicit grant, and cannot redirect git at the shared checkout: `git -C <shared path>`, `--git-dir`, `GIT_DIR` and `GIT_WORK_TREE` are blocked at runtime, so an escape attempt fails loudly instead of polluting the parent tree. A parent session may still reach in with `git -C .worktrees/…` (`skills/shared/milestone-helpers/SKILL.md § Git Commands Reference`); inside a worktree use plain `git` against the inherited cwd.

### Subagent runtime guarantees

- **Partial progress is trustworthy**: a background subagent cut off by a rate limit or server error returns its partial work; an API error (usage limit) reaches the parent as an error, not a successful-looking result; a cutoff before any text fails cleanly; a teammate dying on an API error reports `failed` to the lead. Classify as `transient` (§ Retry / Escalate Matrix) — an errored return is never stage completion (`skills/worktask/SKILL.md` Step 6.5).
- **Forking**: `subagent_type: "fork"` inherits the parent's conversation and prompt cache — the cheapest handoff, paying cache-read rates instead of a re-sent brief. Fork when a stage keeps asking for upstream detail; dispatch normally when a narrow context is the point (`skills/cost-optimization/`).

#### Isolation, cwd & key order

- **Fresh worktrees**: `isolation: "worktree"` never reuses a stale worktree from a prior session, so old untracked files cannot leak into a new stage.
- **cwd survives resume**: subagents resumed via `SendMessage` restore the explicit `cwd` they were spawned with.
- **Stable key order**: `tasks{}` keys sort lexically by stage id, so handoff math like "the latest DV task is the highest-numbered DVN" holds.

## Coordination Patterns

### Sequential Pipeline (Default)
```
PL→AR→TL→DV→DR→QA→DC→FN→ST
```

The full 9-stage reference (`--secure` adds SR after DR and RE after DC), not the set that runs. PL0 sizes the actual stage set; AR and TL are optional (`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`), so the live chain may be `PL→AR→DV→…` or `PL→DV→…`.

### Parallel Documentation
```
       ┌→ DC ─┐
DR →──┤       ├→ FN
       └→ QA ─┘
```

## Handoff Message Format

Verdict first, on the first line: relayed to a peer session the message collapses to that line (`references/cross-session-messaging.md § notify_when_idle, availability & preview collapse`), so it has to say how the stage ended.

```markdown
## [FROM]→[TO] Handoff — [ok|blocked|escalate]: [one clause]

**Summary**: [One sentence]

**Deliverables**:
- [Artifact]: [purpose]

**Open Items**:
- [Question for next stage]
```

## Escalation Message Format

Severity sits in the heading, so the one-line preview is enough to triage on.

```markdown
## Escalation [FROM]→[TO] — [blocking|degraded]: [the ask, in one clause]

**Type**: [dependency|architecture|requirements]

**Problem**: [Description]
**Attempted**: [What was tried]
**Needed**: [Specific ask]
```

## Stage-Specific Handoffs

Fields each handoff carries in addition to the standard format above:

| Handoff | Required fields |
|---|---|
| DV → SR | **Security-Sensitive Areas** (area: why relevant); **Recommended Focus**: auth, data handling, APIs |
| SR → QA | **Security Status** [Approved\|Blocked\|Conditional]; **Critical/High Findings** count; **Security Tests Recommended** |
| DC → RE | **Commit Summary** (feat/fix list); **Recommended Version Bump** [MAJOR\|MINOR\|PATCH] |
| IR → DV | **Incident ID** INC-[N]; **Severity** P[0-3]; **Required Fix**; **Constraints**: minimal change, no refactoring; **Blast Radius** file allow-list; **Verification Command** (`skills/incident-response/SKILL.md § IR → DV Handoff Contract`) |

## Constitutional Coordination

Ethics-reviewer can be invoked at any stage: optional via `--ethics-review`, mandatory when a high-risk feature is detected, on any agent's flagged concern, and as an immediate stop on a hard constraint.

Handoffs are **truthful** (accurate status claims), **calibrated** (appropriate uncertainty), and **transparent** (no hidden issues).

## Multi-Reviewer Coordination

### Review Dimension Allocation

| Dimension | Focus | Include When |
|-----------|-------|-------------|
| **Security** | Vulnerabilities, auth, input validation | Code handling user input or auth |
| **Performance** | Query efficiency, memory, caching | Data access or hot path changes |
| **Architecture** | SOLID, coupling, patterns | Structural changes or new modules |
| **Testing** | Coverage, quality, edge cases | New functionality added |
| **Accessibility** | WCAG, ARIA, keyboard nav | UI/frontend changes |

Combinations: API endpoint, data model → Security + Performance + Architecture. UI component → Architecture + Testing + Accessibility. New feature (full) → Security + Performance + Architecture + Testing.

### Finding Consolidation

1. **Deduplicate**: merge findings at the same file:line.
2. **Resolve conflicts**: take the higher severity when reviewers disagree.
3. **Organize by severity**: Critical > High > Medium > Low.
4. **Cross-reference**: note findings appearing in multiple dimensions.

### Severity Calibration

| Severity | Criteria | Action |
|----------|----------|--------|
| Critical | Exploitable, high impact, easy to find | Block release |
| High | Exploitable or significant impact | Fix before merge |
| Medium | Potential risk, moderate impact | Track, fix soon |
| Low | Minor risk, defense in depth | Advisory |

## Native Dynamic Workflows vs corpflow Staged Worktask

Claude Code's native `/workflows` command and Workflow tool run **dynamic workflows** — ad-hoc background fan-out to tens or hundreds of concurrent agents with lightweight coordination (`CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`, 1–256, raises the per-run limit). They complement the staged worktask; they do not replace it.

### Comparison

| Dimension | Native dynamic workflows (`/workflows`) | corpflow staged worktask |
|---|---|---|
| **Scale** | Tens–hundreds of parallel agents | 11 governed sequential/parallel stages |
| **Governance** | Ad-hoc, minimal overhead | Stage contracts, artifact audit trail, DR/SR/QA gates |
| **State / resume** | Orchestrator-in-context; manual resume | `.context/state.json` + audit.jsonl; Resume Procedure, checkpoints |
| **Reach for it when** | Quick parallelism without governance (batch linting, parallel research, one-off transforms) | Work needing security review, QA sign-off, docs, or an audited multi-stage handoff |

The worktask's two human checkpoints — the PL plan gate and the FN finalization gate — and their `--auto=[plan|finalization|decision]` / `--emergency` bypasses are specified in `skills/worktask/SKILL.md`; a `/megatask` batch stamps `plan_gate`/`fn_gate: "bypass"` on each per-issue PL0.

### Composition & workflow sizing

A DV agent inside a worktask may spin up a native dynamic workflow to parallelize sub-tasks, then consolidate before its DR handoff. Workflow-spawned agents carry `workflow.run_id`/`workflow.name` OTel attributes, so a composed fan-out can be reconstructed alongside the audit trail.

The `/config` "Dynamic workflow size" setting (`workflowSizeGuideline`; default medium = aim for <10 agents, small on Pro plans) governs native dynamic workflows only — not PL0's complexity-scored stage sizing. An 11-stage worktask is not oversized by it, but a DV fan-out composed on top of one is, and that fan-out spends from the same 20-concurrent budget. A DV agent composing a workflow confirms the active guideline via `/config` rather than assuming medium.

### Gate prompts (AskUserQuestion)

`AskUserQuestion` prompts are reserved for genuine decisions needing user input. Two gates exist and only two — the PL plan-approval gate and the FN finalization gate — and the FN gate also renders the batched closing elicitation sweep (`skills/shared/stage-contracts.md § Closing Elicitation Sweep`) immediately before its approve/reject call. Intra-loop stage transitions proceed without confirmation, with two bounded exceptions: a sweep item marked `blocks_next_stage` is rendered at its own stage boundary, because the next stage would otherwise build on a guess; and every permission-parked task is batched into one boundary prompt (`skills/worktask/SKILL.md § Step 7a`), because only the user can grant. Each is a render, not a gate — it creates no approval carrier and changes no gate's firing condition — and the first is opt-in per item.

#### Gate prompts — idle behaviour

These dialogs do not auto-continue on idle, so a PL/FN gate park holds until the operator answers. Idle-timeout auto-continue is an explicit `/config` opt-in; keep it off on hosts running gated worktasks.
