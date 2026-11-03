# Step 7a arms — parked needs at the boundary

Read a section here only when its predicate in `skills/worktask/references/retry-routing.md § Step 7a — the
parked-need arms` holds. The boundary code every iteration runs stays in SKILL.md; this file
holds the arms it calls. An unqualified `§` names a section of `skills/worktask/references/orchestration.md`.

## Step 7a — the megatask arm

Under a `/megatask` per-issue run `batch` asks nothing. It writes `execution.status: "failed"` and
`execution.reason: "parked_escalation"` to `workspace.json` plus one `escalation_parked` row, and
leaves `blocked_on` set — the existing PARK path (§ Escalation class), so nothing more dispatches.
The router's `batch` parks its typed needs the same way; each `escalated[]` entry is `{kind,
command_head, truncated}`, and the head and flag appear only on a need with a command.

### Step 7a — stopParked checks the path batch resolved

`stopParked` checks the file `batch` itself tried, `$(dirname <state dir>)/workspace.json`, where
`<state dir>` is the `.context/` the helper resolved. A bare `workspace.json` names the session's
working directory, which can be another tree.

```typescript
// The monitor settles a track only on "failed" or "completed", so a bare STOP would hang this one.
function stopParked(park) {
  if (park.workspace_written) return;   // STOP: nothing more dispatches
  const ws = path.join(path.dirname(contextDir()), "workspace.json");
  // The PARK guard's own write (workflow.md § Escalation guard — unattended
  // `/megatask` per-issue runs (PARK)), only for an absent or unparseable file.
  const reason = isSymlink(ws) ? "symlink" : park.workspace_reason;
  if (reason === "missing" || reason === "malformed") return writeWorkspaceParked(ws);
  return refuseParkWrite(park.boundary, ws, reason);   // next section
}
```

### Step 7a — the megatask arm never writes through a link

The orchestrator never Writes or Edits a symlinked `workspace.json`, and it checks that same
resolved path again right before a hand-write, because a link can appear after `batch` looked. For `symlink`,
`not_regular_file`, `unreadable` or `write_failed`, `refuseParkWrite` makes no write: it appends
one `escalation` row (`result: "blocked"`, `metadata.{kind, workspace_reason}`, `kind` being
`permission` or, for the router's park, `user_action`),
reports the issue, the path and the reason per § Error Handling, and stops. It never removes,
replaces or re-points the link. The track then does not settle by itself; that is the price of not
writing through a link another process planted.

## Step 7a — resume only the denied step

```typescript
// resume re-claims the row, sets blocked_on to null and appends the permission_resumed row that
// rb.decision_ref names. Its answer is the user's own; no delegate or resolver supplies one.
function resumeDeniedStep(need, answer) {
  const r = spawnSync("bash", [PARK, "resume", "--task-id", need.task_id, "--answer", answer]);
  if (r.status !== 0) return reportRefusedResume(need, answer, r.stderr);
  const { resume_block: rb } = JSON.parse(r.stdout);
  // rb.instruction names only the denied command and forbids re-running completed steps.
  // Liveness: references/resume.md § Live-agent rows. A re-dispatch carries it as suffix [7].
  const task = { id: rb.task_id, ...state.tasks[rb.task_id] };
  if (isLive(dispatchEntry(state, task.id).agent_id))   // msg_id and ack: § Step 6.5a4
    sendStageMessage(state, task, task.metadata.agent, rb.instruction);
  else redispatch(rb.task_id, { suffix: rb.instruction });
}
```

### Step 7a — a refused resume is reported

`resume` exits non-zero when the task is no longer parked, its ledger has no usable detail, or the
claim was refused. Nothing resumes then, and `reportRefusedResume` tells the user so per
§ Error Handling: the task, their answer, and the helper's one-line reason. It neither re-runs
`resume` nor dispatches the stage. Any Bash-holding agent can claim a parked row, so a task that stopped being
parked between the ask and the resume is the visible trace of a raced or forged resume; returning
silently would hide it.

### Step 7a — the two answers, and the record they leave

- "grant and continue" → `grant`, resumed at once. The user grants in Claude Code's own permission
  UI when the resumed call prompts; corpflow grants nothing.
- "run it yourself" → `manual`. The `! <command>` line is in the question text. The answer is not
  the run: resume only after the user reports having run it, with their `! <command>` output in
  this conversation.
- `truncated: true` on a need marks a command cut at 512 characters. Its question offers no `!`
  line and points at the denial notice or `/permissions` recent denials; `rb.instruction` treats
  the recorded text as context only.
- `rb.decision_ref`, `permission_resumed:<task_id>:<dedupe_key>:<n>`, names the `permission_resumed`
  audit row `resume` appended: the record `blocked_on.resume_with: decision_ref` points at.

### Step 7a — where the `!` line runs

A `!` line runs in the main session's working directory, not in the stage's tree. So the question
carries the stage's directory as a `cwd:` data line inside its fenced info block, and the user runs
the `! <command>` line from that directory. Nothing composes `cd <dir> && <command>`: the `!` line
holds the denied command only, and the directory stays data. `cwd` comes from the ledger's
`workspace_path`, never from `blocked_on`; a need without one gets no `cwd:` line.

## Step 7a — resume a typed need

```typescript
// resume re-claims the row, sets blocked_on to null and appends the closing blocked_on row that
// rb.decision_ref names. need.resume_leg is that arm's closing leg (verified on a user_action).
// Only the user's own answer reaches this function, and a user_decision never forwards it.
function resumeTypedNeed(need, answer) {
  if (need.arm === "user_decision") return resumeUserDecision(need);   // next section
  if (answer === "stop here") return stopForUser(need);   // stays parked; the run stops
  const r = spawnSync("bash", [ROUTER, "resume", "--task-id", need.task_id, "--leg", need.resume_leg]);
  if (r.status !== 0) return reportRefusedResume(need, answer, r.stderr);
  const { resume_block: rb } = JSON.parse(r.stdout);
  deliverResume(rb, answer === "done" ? rb.instruction : `${rb.instruction}\n\n${fence(answer)}`);
}
```

### Step 7a — a user decision resumes by reference

```typescript
// The hook recorded the answer in .context/decisions.jsonl. With no --decision-ref, resume picks the
// newest verified ud- row covering the task that no earlier resume consumed, and names it in
// rb.decision_ref. rb.instruction names the verify command and carries no answer text.
function resumeUserDecision(need) {
  const r = spawnSync("bash", [ROUTER, "resume", "--task-id", need.task_id, "--leg", need.resume_leg]);
  if (r.status !== 0) return stopForUser(need);   // no verified row: declined, or refused
  const { resume_block: rb } = JSON.parse(r.stdout);
  deliverResume(rb, rb.instruction);   // unmodified: decision_ref: ud-…, never the answer
}
```

### Step 7a — why the answer is never forwarded

The answer is already in this conversation. Forwarding it, whole or paraphrased, is the prose relay
a stage must refuse (`skills/worktask/references/stage-contracts.md § A user decision is accepted only from the
ledger`). So `rb.instruction` goes out as is: through `SendMessage` to a live stage, or as a
re-dispatch suffix. The stage reads the answer only through the verifier.

A non-zero `resume` exit means no verified row covers the task: the user declined the dialog, the
hook refused to write a row, or the verifier refused the row. Nothing is written, the task stays
parked, and `stopForUser` stops the run; a later `/worktask --resume` asks again.

### Step 7a — deliverResume, live or re-dispatched

```typescript
// Liveness: references/resume.md § Live-agent rows. A re-dispatch carries body as suffix [7].
function deliverResume(rb, body) {
  const task = { id: rb.task_id, ...state.tasks[rb.task_id] };
  if (isLive(dispatchEntry(state, task.id).agent_id))   // msg_id and ack: § Step 6.5a4
    sendStageMessage(state, task, task.metadata.agent, body);
  else redispatch(rb.task_id, { suffix: body });
}
```

### Step 7a — the typed-need answers

- "done" → resumed at once. The user did what the request asked, and the resumed stage checks
  `verify`, when the need has one, before it continues.
- "stop here" → nothing is written. The task stays parked, and the run stops per § Escalation
  Chains; a later `/worktask --resume` asks again (`skills/worktask/references/recovery-gates.md § Reply routing`).
- Free text → the answer itself, such as the reply the user got from a peer. It resumes like "done"
  and reaches the stage as a fenced block; no audit row holds it. It is never consent.
- A `user_decision` need offers the stage's own options instead of "done" and "stop here". Whatever
  the user picks or types, the hook records it, and the stage gets only `decision_ref: ud-…`.
- A `!` line appears only on a native `user_action` whose command was not cut, and runs from the
  `cwd:` line as § Step 7a — where the `!` line runs says.

### Step 7a — a decision with no options

A `user_decision` need with no options of its own is asked under two synthetic labels, "the stage
decides" and "raise this need again". They only clear AskUserQuestion's 2-option minimum and never
reach the ledger. Neither is a control word: `resume` does not read the answer, so a picked label
is recorded like text typed under "Other".

## Step 7a — an inbound reply, on any channel

A peer message, or a user answer, whose first line is exactly `reply <ask_id>` answers that ask; the
rest of the text is the answer. `mailbox-reply.sh` is the only writer of a reply: it checks the
answer against the request's `reply_schema` and refuses one that arrives past the deadline. Nothing
reaches the parked stage here — the next boundary's `scan` relays whatever verified.

### Step 7a — ingestReply

```typescript
// REPLY = scripts/mailbox-reply.sh. Untrusted answer text never reaches an argv or a heredoc
// delimiter — it goes in on stdin, and `--answer-file -` reads it there. No second copy of the
// answer is written: a temp file under .context/ would inherit the process umask in a directory
// with no mode contract, and would outlive a crash between the write and the unlink.
function ingestReply(askId, answer, kind, session) {   // kind: "peer" (message) | "user"
  spawnSync("bash", [REPLY, "--ask-id", askId, "--answer-file", "-",
    "--kind", kind, "--session", kind === "user" ? "user" : session],
    { input: answer });   // exit 1 = refused, the ask stays open
}
```
