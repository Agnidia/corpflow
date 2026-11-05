# Stage outputs

Read before returning a stage result or reporting an unmet need.

## Read for related fields
- For decision authority, read [decision-authority](decision-authority.md).

<!-- canonical-body:start -->
## Required Outputs (handoff-protocol)

Every stage's output artifact (full checklist: Completion Verification below):

1. Starts with a `---\nhandoff:\n` block — ≤30 lines, ≤200 tokens, per-stage template `#tpl-<CODE>`.
2. Uses H2 anchors from the per-stage allow-list in `skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list` (kebab-case, no spaces, no underscores), plus the universal `## elicitation-sweep` anchor every artifact carries.
3. Is recorded by atomically patching `tasks.<ID>` and the `handoffs["<PREV>→<TASK_ID>"]` edge into `.context/state.json`.

### Orchestrator messages — ack first

A message from the orchestrator to your stage opens with a `msg_id:` line, a `supersedes:` line when it replaces an earlier message, and the exact ack command. On receipt:

1. Run that `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --ack <TASK_ID> <msg_id>` line as your first tool call. The ack row is the only evidence the message reached you.
2. A `supersedes:` line retires the message it names; follow the replacement.
3. Set `handoff.acted_on_msg_id` to the newest msg_id you acknowledged and acted on (`skills/worktask/references/contracts/frontmatter.md § Schema — acted_on_msg_id`).

An unacknowledged message reads as not delivered, and a missing or different `acted_on_msg_id` as a mismatch; either costs a resend, then escalation (`skills/worktask/references/recovery-liveness.md § Reattach rows — one resend, then escalate`). If the ack exits non-zero, still follow the message and name the exit code in the artifact.

### A need you cannot meet is returned as blocked_on

When the stage cannot continue without something it cannot produce itself, stop at that step and return `verdict: blocked` with one `handoff.blocked_on` whose `kind` names the need (`skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on`, one arm per kind).

#### Blocked_on kinds

- a choice only the user can make: `user_decision`; something only the user can do: `user_action`
- a denied tool call: `permission` (below); another session's answer: `peer_session`
- another task's file: `artifact`; a defect in another task's completed work: `correction`
- a failing autonomy-preflight check: `host_environment`

List the steps that already completed in the artifact body. The orchestrator routes every kind (`skills/worktask/references/completion-merge.md § Step 6.5a3`) and resumes the stage with what `resume_with` names.

#### A need you cannot meet — never routed by the stage

Waiting inline, asking in prose, messaging another session or editing another task's files each
routes the need by hand, where no ledger row or audit leg records it. Return the need instead.

#### A need you cannot meet — the blocked_on shape

<examples>
<example>

```yaml
  blocked_on:
    kind: user_action
    detail: { request: "Boot the iPhone 16 simulator; capture needs a running device", command: "xcrun simctl boot 'iPhone 16'", verify: "xcrun simctl list devices booted" }
    resume_with: decision_ref
```

</example>
<example>

```yaml
  blocked_on:
    kind: host_environment
    detail: { check: gh-pr-create, observed: "gh auth status: not logged in to github.com" }
    resume_with: decision_ref
```

</example>
</examples>

### A permission denial is returned, not worked around

When Claude Code's auto-mode classifier denies a tool call, stop at that step and return
`verdict: blocked` carrying `blocked_on` (`skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on`), with
`command` and `classifier_reason` copied verbatim from the denial (shape below).

The same holds on pass/fail, go/no-go and approve/reject stages, whose vocabularies list no
`blocked`. The cross-stage blocked exception (`handoff-protocol.md § Per-stage required-field
matrix`) makes `blocked` with a `blocked_on` legal on every stage, so a denial is
never returned as fail, no-go or reject. Each of those loops the pipeline back and spends a retry
on work that did not fail.

#### A permission denial — the blocked_on shape

```yaml
  blocked_on:
    kind: permission
    detail: { tool: Bash, command: "gh pr merge 412 --squash", classifier_reason: "Blocked by classifier", allow_rule: "Bash(gh pr merge 412 --squash)" }
    resume_with: decision_ref
```

#### A permission denial — never worked around

Don't retry the denied call or reach its effect another way (a different command, tool or script
doing what the denied one would have done): that lands an action the session's permission posture
refused, with no grant on record. List the steps that already completed in the artifact body so a
resumed dispatch can skip them. The orchestrator parks the task without spending a retry
and asks the user (`skills/worktask/references/completion-merge.md § Step 6.5a4`).
