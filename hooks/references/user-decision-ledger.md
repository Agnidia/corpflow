# User-decision ledger

Specification for `.context/decisions.jsonl`, the record of the user's answers to `AskUserQuestion`
inside a worktask. One hook writes it, one read-only op verifies it, and a stage accepts a decision
only through that op (`skills/worktask/references/stage-contracts.md § A user decision is accepted only from the
ledger`). The ledger gives tamper evidence, not tamper proof, and uses no signed token. What it
cannot stop is listed under § Security notes.

| Part | Where |
|---|---|
| Record, and the write guard | `hooks/user-decision-record.sh` |
| Every ledger rule: hash, chain, scope, lock, verify | `hooks/lib/user-decision-lib.sh` |
| The verifier | `skills/worktask/scripts/state-patch.sh --verify-decision` |
| Resume by reference | `skills/worktask/scripts/blocked-on-dispatch.sh resume` |

## Why the ledger exists

In one observed run a stage rightly refused consent that the orchestrator relayed as prose, and the
run stalled: nothing the stage could check stood behind the relay. The ledger is that record. The
orchestrator passes only a row id, and the verifier is the only path by which answer text reaches a
stage.

## Row shape

One row per answered, scoped question, serialised with `jq -c` as one LF-terminated line, with its
keys in exactly this order:

```json
{"id":"ud-20260917T101500Z-3","ts":"<UTC timestamp>","actor":"hook:user-decision","tool_use_id":"<tool_use id>","question":"<verbatim>","answer":"<verbatim>","scope":{"worktask_id":"<worktask id>","task_ids":["DV0"],"item":"sw-DV0-1"},"sha256":"<64 hex>","prev_sha256":"<64 hex, or null on row 1>"}
```

- The file is created with mode 0600 in `.context/`, beside `state.json`.
- The hook refuses to append after a last line with no LF (`ledger_torn`).
- The shape is the `.context/decisions.jsonl user-decision row` seam of the milestone's Shared Seams
  registry; a change to a field, the hash inputs or the chain rule updates that entry too.

## Canonical hash

`sha256` is the lowercase hex SHA-256 of the bytes `jq -jc '[.question,.answer]'` prints for the
row: a JSON array with no trailing LF. The array keeps question and answer apart, which plain
concatenation would not.

### The byte rule

Decoded question or answer text never passes through a shell variable, `$(…)` or `read`. It moves
only as jq reading a file or a pipe, or as the argv of `--expect-answer`. A JSON-encoded line may sit
in a variable. A shell round trip can strip a trailing newline and change the digest.

### Digest tools and jq drift

- The digest tool is `shasum -a 256`, else `sha256sum`, which is also used when `shasum` fails or
  prints nothing. There is no cksum fallback: with neither tool the hook refuses with
  `no_digest_tool` and the verifier exits 2.
- Every digest must match `^[0-9a-f]{64}$`. jq 1.6 or later is required.
- jq 1.6 and 1.7+ escape U+007F differently, so the hook refuses a question or answer holding it
  (`unstable_encoding`).
- The verifier runs a pinned probe (DEL, U+2028, U+FFFD, control characters, a non-BMP character,
  `/`, `\`) in its batched pass. A mismatch exits 2 with `jq_canon_drift`, never 5, so drift is never
  read as forgery.

## Id and chain

- `id` is `ud-<YYYYMMDDTHHMMSSZ>-<n>`, where `n` is the row's 1-based line number (`UD_ID_RE`).
- `prev_sha256` is the SHA-256 of the previous line's bytes without its LF, and `null` on row 1.
- The verifier hashes stored lines and never re-serialises them. An `n` other than the row's line
  number is `chain_broken`, and a key set or key order other than the one above is `malformed_row`.

An edit, insert, reorder or deletion before the last row breaks the chain for every later row. The
last row is covered by its own `sha256` and by its audit row (§ Security notes, S3).

## Scope ladder

The hook reads scope from `state.json` only, never from free text. `worktask_id` is always
`state.json .worktask_id`, and each question takes the first rung it meets.

1. **A parked need.** `header` is a task `H` that is `blocked` on `user_decision`, and its
   `detail.question` is byte-equal to the asked question. `task_ids` is every task blocked on an
   equal `(question, options, item)`, sorted. `item` is `detail.item`, or `null`.
2. **A sweep item.** `header` matches `^sw-[A-Z]{2}[0-9]+-[0-9]+$` and is an id in
   `facts.open_questions[]`. `task_ids` is the one task the id names, and `item` is the id.
   `skills/worktask/references/workflow.md § Step C.4` sets that header.
3. **Anything else** writes no row (`no_scope`). A permission or gate prompt can quote commands and
   secrets, and a row that covers no task could never authorise anything.

### Scope ladder — rung 3 is an open question

Open question sw-AR0-1 asks whether rung 3 should record with empty `task_ids`. It does not block
this design, and until it is answered rung 3 writes nothing. Gate and permission answers keep their
audit rows either way.

## Provenance

The hook runs on PostToolUse for the ask tool: `AskUserQuestion`, or any MCP proxy of it named
`mcp__<server>__AskUserQuestion`. Its checks run in order and the first failure wins.
On a failure it writes no row and one `user_decision_refused` audit row, then exits 0 with no
stdout. A fork subagent's call (`agent_id` present) is accepted: the answer is still the user's.

### Provenance — P1 to P3

- **P1 context.** `corpflow_context_root` finds a `state.json` with a non-empty `.worktask_id`.
  Otherwise the hook exits silently, because there is no context to audit into.
- **P2 event.** `hook_event_name` is `PostToolUse`, `tool_name` matches the lib's
  `UD_ASK_TOOL_RE`, `^(AskUserQuestion|mcp__[A-Za-z0-9_-]+__AskUserQuestion)$` (its only shell copy; the plugin.json matcher mirrors it; a
  missing lib or an empty pattern refuses as `no_digest_tool` before the match), and `tool_use_id` matches `^[A-Za-z0-9_-]{1,128}$` (`bad_event`).
- **P3 the user answered.** `tool_input.answers` alone is no signal, since the permission UI fills it
  for genuine answers. A pre-answer shows as `answers` in the transcript's own `tool_use.input`
  (`pre_answered`). A `tool_response.afkTimeoutMs` is an idle auto-answer (`idle_auto_answer`), and
  a response with no per-question answers is `no_answer`. An MCP proxy answers with a text content
  array (`User responses:`, then a `k. <answer>` block per question); it is normalized to
  `tool_response.answers` before this check. A line matching `^[1-9][0-9]*\. ` whose number is
  1..N (N = question count) starts a block; every other line, including a number above N, text
  that is not numbered and a blank line, continues the block above it, joined with LF and kept
  verbatim. Only trailing newlines at the end of the whole text are dropped. The block starts must
  be exactly 1, 2, …, N in order. A missing header, text before block 1, a repeated, missing or
  out-of-order start, or an answer that is empty or only whitespace synthesizes nothing and stays
  `no_answer`: a guessed split could record one question's answer against another.

### Provenance — P4 to P7

- **P4 transcript.** `transcript_path` is a regular file, not a symlink, named `<session_id>.jsonl`.
  It holds an assistant `tool_use` with this id, the payload's own `tool_name` and the same
  `input.questions[].question` values. It is re-read up to 3 times, 0.2 s apart, for a flush race
  (`transcript_miss`).
- **P5 dedupe.** The `tool_use_id` is not already in the ledger (`replay`).
- **P6 answer.** `tool_response.answers[<question>]`, else `tool_input.answers[<question>]`. A
  string is kept verbatim, an array of strings is joined with `", "`, and anything else is
  `answer_shape`.
- **P7 scope.** § Scope ladder. When no question in the call scopes, the call writes nothing.

The PostToolUse `tool_response` shape for this tool is inferred to match the SDK's
`AskUserQuestionOutput`, and the test fixtures pin the shape used.

### Provenance — the append refusals

After P7 the append itself can refuse: `unstable_encoding`, `ledger_torn`, `lock_timeout`,
`no_digest_tool` or `ledger_symlink`. Each writes no row and one `user_decision_refused` audit row.

## Lock and append

- **Lock.** `mkdir decisions.jsonl.lock`. A symlinked ledger or lock is refused (`ledger_symlink`).
- **Timeout.** Up to 25 tries, 0.2 s apart, then fail closed with `lock_timeout`. An unlocked
  append could fork the chain and poison every later row; a lost row only means the question is
  asked again.
- **Stale lock.** An mtime of 60 s or more, or a dead owner pid on the same host. The owner writes a
  token into the lock dir. A breaker removes `owner` only while it still reads the token it aged,
  then runs a plain `rmdir`, never `rm -rf`, so a successor's lock survives.
- **Hook timeout.** The manifest gives both entries `timeout: 15` s, and the retry budget stays at
  13 s or less.

### Lock and append — what the lock covers

The lock covers the tail check, dedupe, and the id and `prev_sha256` computation. The append copies
the ledger into an `mktemp` file in the same directory under umask 077, appends the rows and renames
with `mv -f`, so the lock-free verifier never reads a half row. The copy's own exit status is
checked, and before the rename the temp file is re-verified against the pre-copy state: its line
count must equal the rows the call expects to leave behind, and the digest of the copied prefix's
last line must equal the digest taken of the ledger's tail under the lock. Either mismatch refuses
as `ledger_torn` with nothing renamed, which is what keeps a copy cut short by ENOSPC from replacing
the chain with a truncation no later row could detect. A symlinked
ledger is refused as `ledger_symlink` before the lock is taken, not replaced, and the rename is
skipped if the ledger has become a symlink by then. Each row's `user_decision_recorded` audit row is written under the same lock, after the
rename, and confirmed with `grep -F`; a miss reports `degraded`.

## Write guard

The same script runs on PreToolUse `Write|Edit|Bash` as a separate manifest entry. It only ever
emits a deny, so it cannot loosen a deny or ask from another hook, and it has no ordering dependency.
Every name test below is case-blind (`nocasematch`). On a case-insensitive volume
`.context/DECISIONS.JSONL` and `hooks/User-Decision-Record.sh` are the real files. On a
case-sensitive one they are other files, and a deny there costs only a false positive.
The name tests also run on text folded by `_ud_fold`, which maps U+017F to `s` and U+212A to `k`,
raw or `\u`-escaped: APFS treats those characters as the same file names.

- **Fast path.** The script reads stdin first, with one `cat`, and a payload naming none of
  `decisions.jsonl`, `user-decision-record.sh` and `AskUserQuestion` exits 0 there: no library is
  sourced and no `jq` runs. A builtin `read` is not used because bash reads a pipe one byte at a
  time, which is slower than the fork on a large Write payload. Past that, a PreToolUse payload
  naming neither of the first two strings exits 0 before any further fork, as does a tree with no
  `state.json` once the context library has loaded.
- **Write or Edit.** Denied when `file_path`, resolved to its physical parent plus basename, names
  the ledger or a path under its lock dir. The name compare is case-blind. When the ledger or lock
  dir exists, it also denies a target that is the same file (`-ef`, which also covers a hard link)
  or whose parent is the lock dir. Editing the hook source stays allowed.
- **Fail closed.** After a fast-path hit, a missing jq or library denies, printing the deny
  document without jq. With no context library there is no root to prove "no worktask here", so
  that denies too. Without jq the event comes from the raw text: only a single, unescaped top-level
  `"hook_event_name"` whose value is `"PostToolUse"` (whitespace allowed around the colon) exits 0.
  Every other shape counts as PreToolUse. A copy of the key inside a Write, Edit or Bash input is a
  JSON string and so always escaped, which means it cannot fake the match. The parse is one linear
  `sed | grep` pass, because bash 3.2's `${x//pat/}` is superlinear and would reach the hook timeout
  (a fail-open) on a payload of tens of KB. There is no environment switch.

### Write guard — Bash

- **Naming the ledger** (in any case). Allowed only when every segment, split on `|`, `;`, `&&`, `||`, `&` and
  newline, holds no command substitution, process substitution, `eval`, `xargs` or `tee`, and no
  redirects other than `2>/dev/null`, `>/dev/null`, `2>&1` or `>&2` (checked on the raw segment).
  The program name is derived from assignments stripped and must be one of `cat head tail wc grep
  jq ls stat file shasum sha256sum`. The program names stay case-sensitive, so `CAT` is denied.
- **Running the hook.** Denied by default when a segment names `user-decision-record.sh`, in any case. Allowed only when the program is one of `cat head tail wc grep jq ls stat file shasum sha256sum shellcheck`, or the segment has the form `[path/]bash -n` or `[path/]sh -n`. `git` is deliberately absent: it is a configurable command executor that cannot be guarded by substring checks on one line.
- **The cost.** False denials, such as `jq '.a > 1'` on the ledger. The deny reason names the read
  path.

## Verifier

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --verify-decision <ud-id> --task-id <ID> [--expect-answer <text>]
```

Read-only: no lock, no log, no audit row, no state write. It runs right after the root ladder,
before pre-flight. It reads the ledger and the audit log beside the resolved `state.json`, as
`.context/decisions.jsonl` and `.context/logs/audit.jsonl`. Every call walks the whole chain over
one snapshot, in about five forks at any size.

| Exit | Meaning |
|---|---|
| 0 | valid |
| 5 | refused |
| 2 | usage or IO: id grammar, missing `--task-id`, unresolved state, unreadable library, no jq or digest tool, `jq_canon_drift` |
| 1 | internal error |

Stdout is one JSON object: `{decision_ref, task_id, valid, reasons[], question, answer, scope,
row_index, chain_rows}`. `question`, `answer` and `scope` are printed only when `valid` is true and
are `null` otherwise, so a forged row's text never reaches an agent.

### Verifier — whole-ledger reasons

A closed set, in check order. These eight judge every row, so an edit anywhere refuses every
decision in the file.

| Reason | Means |
|---|---|
| `not_found` | no row has the id |
| `ledger_symlink` | the ledger is a symlink |
| `malformed_row` | a line is not one row with the keys above in order, holds NUL or CR, or the file lacks its final LF |
| `duplicate_id` | two rows share an id |
| `duplicate_tool_use` | two rows share a `(tool_use_id, canonical [question,answer] digest, scope.item)` triple |
| `actor_mismatch` | a row's `actor` is not `hook:user-decision` |
| `sha256_mismatch` | a row's `sha256` is not its canonical digest |
| `chain_broken` | a `prev_sha256` or an id ordinal does not match |

### Verifier — target-row reasons

These four follow, and judge the row the id names.

| Reason | Means |
|---|---|
| `worktask_mismatch` | `scope.worktask_id` is not this worktask |
| `scope_not_covering` | `scope.task_ids` lacks the `--task-id` value |
| `audit_uncorroborated` | no `user_decision_recorded` row from `hook:user-decision` matches the id, `tool_use_id` and line digest, or one with the same id has a different digest |
| `answer_mismatch` | `--expect-answer` differs from the stored answer |

## Audit rows

Actor `hook:user-decision`, with `task_id` from `corpflow_audit_task_id`. No row carries question or
answer text.

| action | result | subject | metadata |
|---|---|---|---|
| `user_decision_recorded` | ok | the `ud-` id | `{decision_id, tool_use_id, row_sha256, item}` |
| `user_decision_refused` | skipped | `AskUserQuestion` | `{reason}`, plus `tool_use_id` once P2 passed |
| `user_decision_ledger_write_denied` | block | the tool | `{tool, dedupe_key, command_head, truncated}`, head of at most 4 tokens |

`user_decision_recorded` is the `answered` leg of the `user_decision` blocked-on arm.

## Relay by reference

1. `route` parks a stage's `user_decision` need and writes the `asked` leg.
2. `batch` asks the stage's question verbatim, with `header` set to the lowest covered task id.
3. The user answers. The hook writes the row and its `user_decision_recorded` audit row.
4. `blocked-on-dispatch.sh resume --task-id <ID> --leg resumed [--decision-ref <ud-id>]` finds a
   verified row covering the task whose `question` and `scope.item` equal the parked
   `blocked_on.detail`, writes `resumed` with that `decision_ref`, and returns an
   `instruction` that names the verify command and no answer text.
5. The orchestrator delivers that instruction unmodified and never appends the answer it saw
   (`skills/worktask/references/step-7a-arms.md § Step 7a — a user decision resumes by reference`).
6. The stage verifies the ref and cites it in `decisions_applied: [ud-…]`.

Declining the dialog writes no row, so `resume` exits 1, nothing is written, and the run stops with
the task still parked.

## Megatask

A `/megatask` per-issue run has no user, so it parks a `user_decision` need as it always did, and
`escalated[]` gets `{kind: "user_decision"}`. Only an attended `/worktask --resume` in that issue's
worktree resolves it. A prompt answered in the parent session resolves that session's own context
root and covers nothing, so it fails closed.

## Security notes

The ledger is tamper-evident, not tamper-proof. These risks remain, each with what narrows it.

### S1 — a forged tail append

Until upstream U1 lands, a subagent or the orchestrator with Bash could still append a forged row
with a correct `prev_sha256`, plus a matching `user_decision_recorded` audit row. The chain detects a
forged row only when that row breaks the chain, and a well-formed tail append does not. The write
guard is a speed bump that obfuscated shell evades. Audit corroboration, which fails closed, means a
forgery needs both writes to land, and dedupe on the `(tool_use_id, canonical [question,answer]
digest, scope.item)` triple blocks a replay while still admitting the several questions of one batched call.
Re-invoking this hook is not the cheap path to both writes it once was: a segment naming
`user-decision-record.sh` is denied unless it is `bash -n`, shellcheck or a read-only reader, so
feeding the hook a hand-built payload no longer mints the row and its audit row for free. What is
left is a shell that writes both files without naming either — obfuscation the guard cannot see. U1, the
harness forwarding a user's answer into a subagent thread itself, is tracked outside this milestone.

### S2 — a forged transcript

P4 trusts the transcript file, which Bash can also write. Binding its basename to the payload's
`session_id` raises the bar without closing the gap.

### S3 — a last-row edit or truncation

No later row covers the last one. An edit to it is caught by its own `sha256` and by the audit row's
`row_sha256`. Truncation removes decisions, and each removed id fails closed as `not_found`.

### S4 — answers the user did not give

A PreToolUse `updatedInput` from another plugin or a settings hook is indistinguishable from a real
answer, except when the transcript's `tool_use.input` already carries `answers` (P3). Keep Claude
Code's `askUserQuestionTimeout` off; an answer carrying `afkTimeoutMs` is refused as
`idle_auto_answer`.

### S5 — retention

The ledger holds verbatim question and answer text, as the registry seam requires. It is mode 0600,
lives under `.context/`, which the committed `.gitignore` excludes, and receives rung 1 and rung 2
questions only. Audit rows
never hold the text.

### S6 — root divergence

If the hook and the verifier resolve different `.context` roots, the verifier finds no row and
refuses with `not_found`, which fails closed. Both use the shared root ladder.

### S7 — jq drift

A jq upgrade that changes escaping beyond U+007F makes old rows refuse. The probe reports it as
`jq_canon_drift` with exit 2, so it fails closed and is never read as forgery.
