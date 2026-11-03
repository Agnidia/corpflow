# Artifact landing

Read when executing or checking artifact landing. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Schema — blocked_on](blocked-needs.md#schema--blocked_on) · [Schema — blocked_on, the artifact arm's landed leg](blocked-artifacts.md#schema--blocked_on-the-artifact-arms-landed-leg)

<!-- canonical-body:start -->
#### Landing consumed artifacts

One DV row can consume a file another DV row produces, such as an interface contract, without the
producer committing it. The rows declare the pair with `produces` and `consumes`
(`skills/worktask/references/contracts/ledger-streams.md § Landing fields (DV rows)`):

```text
produces := tasks.<P>.metadata.produces = [path, ...]
consumes := tasks.<C>.metadata.consumes = [{"from": "<P>", "paths": [path, ...]}, ...]
path     := repo-relative, post-merge; alphabet [A-Za-z0-9._@+/-]
rule     := C.blocked_by holds every from, and every path is in that producer's produces
writer   := PL0, or TL when TL runs; never the DV agent
source   := P's index blob: P runs `git add -- <path>` per produced path before its completion patch
```

C treats a landed path as read-only and never edits or stages it, because P's tree ships it.

##### Landing — the two passes

`skills/worktask/scripts/land-artifacts.sh` runs from two points in `skills/worktask/references/orchestration.md`:

| Pass | Where | Call | Effect |
|---|---|---|---|
| Boundary | § Step 6.5d, once P is `completed`, before the next ready-filter pass | `--producer P` | Lands into every `pending` consumer's current tree; skips a `blocked` one, keeping its `landing_error`, and leaves any other status untouched with one `warn` row |
| Gate | § Step 4.8, after any re-pin, before Step 5 stamps `in_progress` | `--consumer C` | Re-lands every pair of C into its final tree; an unchanged tree is a no-op that writes nothing |

When P and C resolve to the same physical tree nothing is copied and no `landed_paths` are
recorded; a boundary pass still writes its `same_tree` ok row.

##### Landing — what one consumer's pass does

1. **Preflight.** Every path of every pair of C is checked before the first write, so C lands all or
   nothing.
2. **Source.** Exactly one stage-0 index entry in P, mode `100644` or `100755`, no filter attribute,
   no symlink on its way, and a worktree file unchanged since `git add`.
3. **Destination.** Under C's physical root, every parent a real directory, the file untracked. A
   tracked file is refused unless byte-identical (`already_present`, not recorded). An untracked one
   with a different sha is refused unless C's `landed_paths` already lists it (a producer re-run).
4. **Write.** The blob goes to a temp file beside the destination, is checked against its git
   object id, then renamed into place and re-verified by sha256.
5. **Record.** `landed_paths` and `landed_roots` (every spelling of C's tree) become sorted unions;
   `landing_error` `null`.

A refusal rolls back only files and directories this pass created.

##### Landing — refusal reasons

Each refusal writes exactly one `reason` into `landing_error` and the fail row:

| Check | Reasons |
|---|---|
| Pair | `consumer_already_dispatched` (gate only), `producer_not_completed`, `not_blocked_on_producer`, `self_consume`, `bad_declaration`, `not_produced` |
| Path shape | `bad_path`, `absolute_path`, `dotdot`, `reserved_segment`, `reserved_destination`, `control_char`, `leading_dash`, `unsafe_char` |
| Source | `symlink_source`, `gitlink`, `not_staged`, `conflicted`, `filtered_path`, `staged_then_modified` |
| Destination | `symlink_segment`, `not_dir`, `dest_escape`, `symlink_dest`, `dest_not_regular`, `dest_tracked`, `dest_exists` |
| Copy | `sha256_mismatch`, `dest_race` |
| Any git read | `git_error`, the read failed |
| Gate, exit neither 0 nor 1 | `tool_error`, written by the orchestrator |

###### Landing — reserved names

`reserved_segment` is a segment equal to `.git` or `.context`; `reserved_destination` is one equal to
`.claude`, `.github`, `.mcp.json`, `.envrc`, `.gitattributes` or `.gitmodules`. Both compare
case-insensitively.

##### Landing — exits and the audit row — exit codes

| Exit | Meaning |
|---|---|
| `0` | Landed, same tree, already present, gate no-op, nothing selected, or a consumer a boundary pass skips: `blocked` silently, any other non-`pending` status with one `warn` row |
| `1` | Consumer failed: rolled back, `landing_error {reason, path, producer}` written, row `blocked`, one fail row |
| `2` | Usage error, malformed id, bad ledger, `tree_invalid`, missing tool, failed ledger write, or signal (INT, TERM, HUP). Rolls back writes; ledger entry for completed C stays: `blocked` row fails closed, `landed_paths` entry re-copied next pass |

##### Landing — exits and the audit row — exit 1 guarantee

No other exits exist: signals/unexpected failures exit `2`, never stray `1`. Exit 1 always means `landing_error` on `blocked` row, or refused `--check-path`/unsafe `--strict` (§ Landing — strict readers).

###### Landing — the audit row

Each row is `corpflow_audit_row` with actor `orchestrator`, action `contract_landed`, subject C:

```text
ok:   {"producer":"DV0","consumer":"DV1","mode":"copied","files":[{"path":"src/api.h","sha256":"<hex>"}]}
warn: {"producer":"DV0","consumer":"DV1","reason":"consumer_not_pending","status":"completed","paths":["src/api.h"]}
fail: {"producer":"DV0","consumer":"DV1","reason":"dest_tracked","path":"src/api.h"}
```

`mode` is `copied`, `same_tree` or `already_present`. A lost audit row warns on stderr and never
changes the exit code.

###### Landing — a consumer that already ran

A producer re-run, such as a DR rework, can reach a consumer that is `in_progress`, `completed`,
`failed` or `skipped`. A boundary pass writes no file and no ledger field for that row, exits 0, and
writes the one `warn` row above, so a rework never flips a dispatched stream to `blocked`. The gate
still refuses such a row with `consumer_already_dispatched` (exit 1). `--dry-run` writes no row.

##### Landing — release and readiness

On a gate exit other than 0 or 1 the orchestrator writes `landing_error {reason: "tool_error"}`,
then `--task-status C blocked`; at the boundary that exit is reported only. Release, once the cause is fixed:

```bash
state-patch.sh --task-meta C --set '{"landing_error":null}'
state-patch.sh --task-status C pending
```

Until then C is not ready: the ready filter (`skills/worktask/references/orchestration.md § Readiness is mechanical`)
selects `pending` rows only, so for a `blocked` C this prints nothing:

```bash
jq -r --arg c DV1 '.tasks as $t | $t | to_entries[]
  | select(.value.status == "pending")
  | select([(.value.blocked_by // [])[] | $t[.].status] | all(. == "completed"))
  | .key | select(. == $c)' .context/state.json
```

##### Landing — strict readers

`land-artifacts.sh --list-landed --tree <tree> --strict` prints the same set as the plain call
(`skills/worktask/references/contracts/ledger-streams.md § The landed set`), but exits 1 with empty stdout when any raw
`landed_paths` entry scoped to that tree fails the path ladder: not a string, a control character,
or a lexical refusal (§ Landing — refusal reasons). The script never writes such an entry; strict readers fail closed on hand-edited unsafe values. Two readers are
strict. `fn-stream-merge.sh` reads each stream's own tree set, never a union: an unsafe entry is
`blocked reason=landed_path_unsafe`, a failed read `landed_set_unreadable`. The `blocked_on`
`artifact` arm reads the parked task's tree (§ Schema — blocked_on, the artifact arm's landed leg).
`--check-path <path>` runs the same ladder with no ledger, silent exit 0 when safe and exit 1 with
`reason=<token>` when refused; the router runs it on `detail.path`.

### Run-index resolution

The same N is shared across all stages within a worktask run. `metadata.plan_file` pins the active plan; `metadata.run_index` (integer ≥ 0) resolves `<basename>-N.md` for every other stage. Full resolver and propagation algorithm: `skills/worktask/references/planning-sizing.md § Plan File & Run Index Naming`.

### Alias basenames (resolution-only)

`state-patch.sh` accepts a second, search-only basename for three stages — DR `review`, QA `qa`,
FN `finalization` — in a sibling function, so `skills/worktask/references/contracts/artifact-map.md#stage-artifact-map` stays the single canonical name
per stage. Aliases are accepted, never written, and a canonical match outranks an alias match at
the same run index. Resolution order: primary@run_index → primary highest-N → alias@run_index →
alias highest-N. `AR` has no alias, so a stale `analyzing` file cannot answer for the current
one. `USER` is a `--prev` value only — no
artifact, never a `--stage` or basename (edge tables: `USER→PL`, `USER→IR`).

---
