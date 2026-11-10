# Recovery procedure

Read when executing or checking recovery procedure.

Procedure routing: [resume](resume.md).

<a id="section-lookup-1"></a>
Related: [Mid-stage yield](recovery-liveness.md#mid-stage-yield) · [Pending communication](recovery-gates.md#pending-communication)

<!-- canonical-body:start -->
## Resume Procedure

1. Liveness pre-check: `claude agents --json --all | jq '.[] | {agent_id, state, waitingFor}'`, matched against `.context/state.json.facts.dispatched_agents[]`. Branch per § Live-agent rows: parked on us → `SendMessage` the answer (a "Needs input" park: surface the prompt verbatim, never auto-answer); busy → leave it; `blocked` → reattach; `done` or absent → re-delegate from the first incomplete stage.

### Step 0 notes — observed CLI field set

   The field names above are the contract; the shipping CLI exposes fewer. A live-probed
   interactive row carries exactly `cwd`, `kind`, `name`, `pid`, `sessionId`, `startedAt` and
   `status` (e.g. `"busy"`) — no `id`, no `agent_id`, no `waitingFor`, no `parent_agent_id`. The
   background-row variant is unobserved, so `id` and `state` stay in the defensive reads. Read
   identity from `agent_id // id // sessionId` (where `id` appears it is a prefix of `sessionId`, so
   match on prefix too), then from `name` only when one live row carries it and liveness from `waitingFor` when present, else `state`/`status`. Probes:
   `skills/agent-coordination/references/headless-dispatch.md § Schema Versioning Watch`. An
   unrecognised token is unknown, not absent — do not re-delegate off one.
   `skills/worktask/scripts/stale-check.sh` implements exactly this tolerance.

### Step 0 notes — own-name &amp; teammate visibility — agent discovery changes

   `ListAgents`/`claude agents --json` lists live teammates and tells a session its own name; a pre-warmed idle worker is not listed until claimed. So a teammate does not read as gone and no phantom row matches a `subagent_type`. The degrade rules below still apply.

### Step 0 notes — own-name &amp; teammate visibility — name matching

   The own name reuses the `name` key. Do not address your own name in a `peer_session` ask. Names are not unique — match on `sessionId`. Use `name` only as the last fallback, and only when exactly one live row carries it; two or more rows are liveness-unknown, never absent. A teammate row's `kind` is unconfirmed.

### Step 0 notes — reattach vs re-dispatch — cost estimation

   `SessionStart` resume hooks receive staleness and estimated re-cache cost. A long-idle session with an aged prompt cache pays the re-cache on its first turn, which can exceed a fresh dispatch for a short stage. Prefer re-dispatch only when the estimate clearly exceeds the stage cost. Reattach wins at any cache price when the agent holds edited tree state (§ Mid-stage yield).

### Step 0 notes — reattach vs re-dispatch — what reattach preserves

   Resumed subagents keep tool list, system-prompt prefix, `SubagentStart` hook context, preloaded skills (cache prefix survives), and nested background results in parent transcript. A `--bg` session receiving a message before idle timeout is not retired mid-turn.

### Step 0 notes — proactive detection

   To ask "is anything wedged?" without resuming, run `skills/worktask/scripts/stale-check.sh` — it
   reconciles the same inputs and prints the verdict from these tables. Read-only; it recovers
   nothing.

### Step 0 notes — why the pre-check

   One pre-check prevents blind respawn of a working subagent, redundant nudging of a busy one, and blind re-dispatch of an invisible blocked one. When `claude agents` is unavailable, skip the pre-check and re-delegate from the first incomplete stage. See `skills/agent-coordination/references/headless-dispatch.md § Live Session Discovery`.

### Step 0 notes — dispatched_agents matching

   The orchestrator loop writes one `dispatched_agents[]` entry per `task_id` (`{stage, task_id, subagent_type, agent_id?, name?, model_requested?, model_resolved?, status}`). Degrade rules for imperfect rows:

- `agent_id` present → match the `claude agents --json --all` row by id; branch per the table above.
- `agent_id` absent (no launch-ack) → match by `subagent_type` among the non-interactive rows (skip `waitingFor = approval/input` rows). Exactly one candidate ⇒ adopt it; ambiguous or none ⇒ skip the pre-check and re-delegate from the first incomplete stage.
- entry `status: completed|failed` → the stage already resolved; do not reattach, advance to the next incomplete stage. Terminal entries may be evicted after compaction; absence means "no live agent".

#### Worktree re-entry

- `tasks.<ID>.worktree.path` recorded → `EnterWorktree(path)` before resuming that stage, so DR/QA/DV-retry run in the right directory rather than the shared checkout. The recorded `worktree.branch` gives the branch without shelling `git rev-parse`.

### Step 0 notes — state-signal reliability

   Trust the `state` signal. With nested spawning (3 levels by default), match only top-level agents from `facts.dispatched_agents[]`; rows whose `parent_agent_id` points at another live row are the stage agent's own children — never reattach or re-delegate those directly.

   A resumed background agent restores its own prompt and tool restrictions, so a live row matched to a stage is still that stage's agent: prefer reattach.

### Step 0 notes — authority caveat

   A `SendMessage` reattach may nudge a parked agent (supply an awaited answer, re-prompt) but cannot authorize anything: a relayed message carries no operator permission authority (the receiver refuses relayed permission requests; auto mode blocks them). Permission escalations and the PL approval gate stay operator-owned.

### Step 0 notes — trigger delivery &amp; reattach

   Scheduled-task and webhook deliveries are task notifications: in auto mode they cannot approve a pending action or set a session title, so they do not satisfy a `waitingFor = approval` park. Treat one like a relayed message: keep the stage parked and resolve the approval through the operator-owned path.

   Messages sent while a subagent is finishing its turn are not dropped, and `ctrl+b` does not restart the session, so a mid-turn reattach keeps the awaited answer.

### Step 0 notes — scheduled tasks &amp; agents-view replies

   Scheduled tasks and `/loop` wakeups come back after a compaction or resume, and a foreground-set task fires after a `/background` hand-off; a recurring one does not run an extra time on resume, respawn or fork. A background session waiting on a scheduled wakeup is kept through updates and low memory. Saved tasks created after `/resume`, `/branch` or `/clear` fire, and a background session's `/loop` survives a process restart. Plan mode is restored on resume.

   A reply sent from `claude agents` arrives as a queued message and is retried for up to 12 s while a crashed session restarts. A slash command or answer it could not deliver is not saved and replayed on the next restart. A reply to a session parked on a permission prompt never approves the pending command. `/tasks` lists finished subagents under "Earlier in this session", even after a restart, and the operator can reopen one and message it. That is an operator path; the orchestrator still reattaches by the recorded id.

### Step 0 notes — background-agent guarantees

   The resume loop may rely on these at the plugin's min CC:

#### Push &amp; honest completion

- **Push signals**: finish/needs-input fires the `Notification` hook (`agent_completed` / `agent_needs_input`) — prefer it as the wake-up; the `claude agents --json` pre-check stays the authoritative reconciliation.
- **Honest completion**: an errored subagent surfaces as an error with partial work preserved, never an empty success — trust `subagent_stopped` `result: error` rows. This is not a hard invariant, so keep the `references/fn-gate.md` cross-check ("BG notification ≠ approval").

#### Stopped &amp; work preservation

- **Stopped means stopped**: an operator-killed agent never auto-respawns or re-runs a stale prompt; a daemon-restart-killed worker auto-resumes when the agents view next opens. Re-delegate only when the pre-check shows the agent truly absent.
- **Work preservation**: waking a background job never deletes its transcript or re-runs the prompt; returning to `claude agents` carries running work over; long-running commands survive session restarts. A running background session holds its worktree's lock, so cleanup leaves it alone. Stale-worktree cleanup is not a resume chore.

#### Interrupted calls &amp; transcript fidelity

- **Interrupted calls**: a session that ended mid-tool-call resumes with that call marked outcome unknown and no hidden "Continue" message, so check its effect before repeating it. MCP calls in a resumed session wait up to 10s for a reconnecting server. `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` does not re-run a turn that ended at `--max-turns`.
- **Transcript fidelity**: `--resume` keeps the turns after a batch of parallel tool calls, the context a compaction restored, and the last messages before a quit. A session backgrounded while idle resumes its conversation instead of reopening empty. A message typed while Claude works survives `←` backgrounding; if it cannot move, the session stays in the foreground and says so.

#### Reattach, cross-spawn &amp; inspection

- **Reattach fidelity**: `SendMessage` asks the caller to retarget when a re-spawned agent reuses a previous name; a `SendMessage`-resumed agent does not stick as `failed`/`completed`; a per-stage model override survives resume and follow-up messages (`skills/shared/model-selection.md § Per-Invocation Override`); `/rename` persists across restarts.
- **Cross-spawn targeting**: `TaskStop` finds agents spawned by another agent and lists them by id/description on error, so resume can target a cross-spawned stage agent. Read a background task's output from its output file with `Read`.
- **Inspection**: completed agents stay in `/tasks` until cleanup and attaching shows the transcript immediately, so a just-finished stage is still inspectable. Reopening a stopped session resumes it or reports why it cannot — a refusal means re-delegate, not retry blindly.

### Steps 1–7 — replay &amp; audit

1. `tail -n 50 .context/logs/audit.jsonl | jq .` — last 50 audit lines
2. `.context/state.json` `tasks{}` — current ledger state
3. Cross-reference with `skills/worktask/references/stage-contracts.md` — identify first incomplete stage
4. Re-read that stage's `.context/*.md` artifact (if partial)
5. If `metadata.retry_count > 0`, read `.context/errors/<agent>.md` for retry history
6. Continue from the execution loop's `while (tasks.some(...))` — no need to replay completed stages; reconcile the parked tasks against the decision ledger and the mailbox (§ Pending communication) before the resumed loop reaches its first boundary
7. Write a `resume` audit entry: `{actor: "orchestrator", action: "resume", subject: "<worktask_id>", result: "ok"}`

See `skills/context-compression/SKILL.md § PostCompact Recovery` for the compaction-specific flow.

### Resume identity rules

Use the stored agent ID across restart and compaction. Names assigned before the last compaction still require the ID,
so do not dispatch a replacement on a name lookup failure alone. Repeated resumes keep SendMessage reachability.
Completion messages can describe an agent waiting on its own background work, receiving a late message, or stopping
at a usage limit. A waiting notice is not a completed stage. Reconcile by task and agent ID before applying a completion once.
Stopping the agents service can stop live sessions after about one minute. Recheck discovery before redispatching.
Resumed headless dispatches carry the same optional compaction and retry controls; do not substitute an in-process run.
