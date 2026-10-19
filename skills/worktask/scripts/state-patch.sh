#!/usr/bin/env bash
# @description state-patch.sh — synchronous Step-6.5 state.json completion patch.
#
#   Resolves the artifact path for a stage, parses its `handoff:` frontmatter,
#   builds the completion patch, and performs an atomic tmp → fsync → rename
#   merge into .context/state.json.  Includes the ENOSPC / DISK_MIN_GB guard
#   (< DISK_MIN_GB halts; < DISK_WARN_GB warns) so callers share one policy.
#
#   This is the SINGLE IMPLEMENTATION of the state-patch logic.  The
#   SubagentStop hook at hooks/state-merge.sh delegates to this script
#   via `bash <path>/state-patch.sh [opts]` — no merge logic lives in the hook
#   itself beyond the delegation call.
#
# @arg --stage <CODE>       Stage code (PL AR TL DV DR SR QA DC RE FN ST IR ET).
#                           Required unless --artifact is given with parseable frontmatter.
# @arg --artifact <path>    Explicit artifact path.  When omitted, resolved from
#                           --stage + run_index from state.json.
# @arg --prev <CODE|ID>     Previous stage code (AR), indexed task id (AR0), or USER for the USER→PL /
#                           USER→IR origin edges.  When present, ALSO writes
#                           handoffs["<PREV>→<TASK_ID>"] = "<summary> ref:<artifact basename>"
#                           from the parsed frontmatter summary — the ledger edge every stage
#                           agent would otherwise hand-roll in inline jq.  ABSENT = ledger
#                           patch only, byte-stable; hook callers
#                           never pass it, so the SubagentStop path is untouched.
#                           USER is predecessor-only: it never resolves an artifact and is
#                           NOT a valid --stage.
# @arg --state <path>       state.json path (default: .context/state.json).
# @arg --log <path>         Append log to this file (default: .context/logs/state-merge.log).
# @arg --disk-check [root]  Run the ENOSPC guard before writing.  Optional filesystem-root
#                           value (defaults to "."); a following token that begins with "-"
#                           is NOT consumed as the root.  When the guard fires (halt), exits 2;
#                           on warn exits 0.
# @arg --via <hook|step6_5> Stamp tasks.<ID>.completed_via with the enforcement
#                           layer that fired.  Omit for agent self-patch (Layer 1);
#                           F3 stamps "f3" via its own patch.  Absence encodes Layer 1.
# @arg --task-id <ID>       Explicit ledger key (e.g. DV1).  When omitted the id is resolved
#                           from the stage code: the instance whose recorded (else planned)
#                           artifact matches --artifact, else the open instance of a split
#                           stage, else the highest existing, else <CODE>0.  Two open
#                           instances of one stage with nothing to disambiguate them exit 4
#                           before any write.
# @arg --allow-missing-artifact
#                           Suppress the exit-3 assertion and restore the exit-0 no-op for a
#                           caller that knows the artifact is absent.  It does NOT patch:
#                           with no artifact there is no frontmatter to build a patch from,
#                           so NEITHER the stage entry NOR the handoff edge is written.
#                           To record a stage whose artifact does not exist, write
#                           state.json directly (handoff-protocol.md#layer-1-fallback).
# @arg --facts <json>       Union-merge compressed facts into facts.*.  Object keyed by any
#                           subset of decisions | open_questions | files_modified |
#                           tests_added | branch | stream_branches.  COMPOSES with --stage: applied after the
#                           artifact/verdict preflight, in its own atomic window, so one call
#                           patches both the ledger row and the facts a stage recorded.  A
#                           refused or skipped stage patch (unresolved artifact, unparsed
#                           stage, missing state.json, or a refused verdict) drops the paired
#                           --facts payload too; standalone it exits 0 after the merge.
#                           Union, never replace — identity rule at § Facts union below.
#                           A DV settle (--stage with a DV task id) also adds the paths of
#                           `git diff --name-only <base>...HEAD` to files_modified; the base
#                           comes from the row's base_ref, then the ledger mirror, and an
#                           unresolvable input adds nothing (§ DV-settle fill below).
#                           decisions items accept objects with string .id or non-empty strings;
#                           strings get a deterministic str-<base64> id and the writer stage.
#                           open_questions items must be FULL sweep stubs (string .id, .class
#                           and .ref, boolean .blocks_next_stage); a partial one exits 2 with
#                           state.json untouched.  branch is a string matching
#                           ^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$, stored at facts.branch
#                           (last writer wins, exempt from the array-shape check); any other
#                           shape is a whole-payload refusal, exit 2. A branch-only payload
#                           counts as non-empty (no facts-empty no-op).
#                           stream_branches is an object <stream> -> <branch>: key matching
#                           ^[a-z0-9]+(-[a-z0-9]+)*$ (<=40 chars), value matching the branch
#                           regex; unioned by key into facts.stream_branches (a later write
#                           replaces only its own streams), facts.branch untouched. Any bad
#                           entry is a whole-payload refusal, exit 2; {} is a no-op.
#
#   Ledger ops — direct tasks{} writes.  Each short-circuits the artifact path and exits.
#   --task-create is the ONLY op that may introduce a key; the rest reject an unknown ID
#   rather than autovivifying a task nobody seeded.
#
# @arg --task-create  <ID> --metadata <json>  Seed tasks.<ID> as pending; no-op if it exists.
#                                             --metadata is optional (defaults to {}).
#                                             Repeatable: N `--task-create <ID> [--metadata
#                                             <json>]` pairs seed N rows in ONE merge under one
#                                             lock; each --metadata binds to the --task-create
#                                             before it (one ahead of the first id is exit 2).
#                                             Every row is gated first (id grammar, effort,
#                                             required keys, JSON), and any bad row refuses the
#                                             whole batch with that row's single-call exit code
#                                             and state.json byte-unchanged. An id that already
#                                             exists is a per-row no-op; a repeated id, or a
#                                             batch mixed with another ledger op, is exit 2.
# @arg --task-status  <ID> <status>           pending|in_progress|completed|blocked|skipped|failed|stale.
#                                             `stale` parks a task whose consumed input was
#                                             corrected: it is neither ready (the loop's filter
#                                             takes `pending` only) nor settled, so tasks blocked
#                                             by it stay unready until something settles it. It
#                                             names a ledger status ONLY — unrelated to the
#                                             liveness sense of "stale" in stale-check.sh and to
#                                             the `stale_dependents` field of the replay survey.
# @arg --task-block   <ID> --on  <ID[,ID...]> Union into blocked_by[].
# @arg --task-unblock <ID> --off <ID[,ID...]> Subtract from blocked_by[].
# @arg --task-meta    <ID> --set <json>       Merge into tasks.<ID>.metadata.
#                                             --unset <key[,key...]>: delete those keys
#                                             after the merge, under the same lock and
#                                             atomic write; alone or beside --set, and it
#                                             wins over a key --set also names. An absent
#                                             key is a no-op (exit 0, bytes unchanged). A
#                                             pipeline key (stage, agent, model, effort,
#                                             plan_gate, decision_gate, fn_gate,
#                                             workspace_path, isolation, base_ref,
#                                             requires_screenshots) exits 2, unchanged.
#                                             On create and meta a description over 240
#                                             chars is cut to 239 + "…", never refused;
#                                             stderr gets description_truncated=<id>:<len>.
#                                             --raise-only: drop `model`/`effort` from the
#                                             merge when it would lower the row's CURRENT
#                                             value (ladder rank; opus>sonnet>haiku) — every
#                                             other key still applies. Opt-in; unset means the
#                                             legacy unconditional merge.
# @arg --ledger-meta  --set <json>            Merge into the ledger's TOP-LEVEL metadata{}.
#                                             The only op that writes outside tasks{} and
#                                             facts{}: base_ref, milestone and the other
#                                             run-wide keys readers resolve from there had
#                                             no scripted writer, so they were hand-edited
#                                             into state.json around this script.
# @arg --resolve-models [--corpflow <path>]   Stamp state.models{<agent>: {model,effort,source}}
#                                             for every agents/*.md row, merging a CORPFLOW.md
#                                             `## Models` override row by row, fail-open, over
#                                             the built-in matrix (skills/shared/stage-codes.md
#                                             § Agent Model Matrix). Default lookup, per
#                                             heading: ${CONTEXT_DIR%/.context}/CORPFLOW.md
#                                             when it has `## Models`, else
#                                             ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md;
#                                             --corpflow beats both. Resolved once;
#                                             --task-create reads the result. Idempotent
#                                             overwrite, not a merge.
# @arg --task-replay  <ID> [--cascade]        Reset one settled/failed task to pending so the
#                                             stage loop dispatches it again.  Clears
#                                             metadata.retry_count, metadata.error_escalated_to
#                                             and completed_via; artifact, verdict, worktree and
#                                             handoffs survive (the completion merge rewrites
#                                             them together).  Every guard runs BEFORE any
#                                             mutation, so a refusal leaves state.json
#                                             byte-identical.  --cascade also resets the
#                                             transitive dependents reachable through
#                                             blocked_by, skipping FN/RE with a warning.
#                                             A reset row holding tests_executed also gets
#                                             rework_pending: true, so its next completion
#                                             merge files the prior list under rework_runs[]
#                                             as a new round instead of overwriting it.
# @arg --agents-json <path>                   Passed through to stale-check.sh for the replay
#                                             liveness guard.  Test/diagnostic seam only.
# @arg --task-reopen <TARGET> --from <SOURCE> [--finding-file <path|->]
#                                             Re-open a task a correction names.  Guards run
#                                             BEFORE any mutation — target exists, target is
#                                             not the source, target status is `completed`,
#                                             source exists — so a refusal (exit 4) leaves
#                                             state.json byte-identical, as --claim and
#                                             --task-replay refuse.  One atomic apply then
#                                             sets the target to `pending`, bumps
#                                             metadata.fix_round ((fix_round // 0) + 1), stamps
#                                             metadata.gate_from_stage with the SOURCE's stage
#                                             code and metadata.gate_blockers to [<finding>],
#                                             and parks every consumer as `stale`.  Consumers
#                                             are transitive (downstream through blocked_by),
#                                             filtered to status == "completed", minus the
#                                             source and minus every REPLAY_SIDE_EFFECT_STAGES
#                                             code — the constant the cascading replay skips
#                                             by.  A consumer is PARKED, not reset: its
#                                             verdict, artifact and handoff survive, as the
#                                             target's own do.  Re-running the op is refused by
#                                             the `completed` guard itself, which is what makes
#                                             a retried route idempotent: no second bump.
# @arg --finding-file <path|->                The correction's finding, read from a file or
#                                             (with `-`) from STDIN — never from argv, so it
#                                             reaches neither the process table nor the audit
#                                             row's command head, and it is kept out of the
#                                             --log line this op writes.  <= 2000 bytes and no
#                                             control byte beyond TAB/LF, else exit 2 with
#                                             state.json untouched; a long finding belongs
#                                             behind the return's evidence_ref, not in a
#                                             durable ledger field that renders into a prompt.
#                                             Omitted ⇒ gate_blockers is set to [], never left
#                                             holding the PREVIOUS round's finding.
# @arg --task-settle-stale <TARGET> [--changed <path[,path...]>]
#                                             Settle every `stale` task at the re-opened
#                                             TARGET's own completion boundary and print one
#                                             JSON line {"settled":[{task,to,reason}]}.  A
#                                             dependent whose cited set intersects the change
#                                             set returns to `pending` (re-verify); one that
#                                             does not returns to `completed` and its earlier
#                                             result stands.  Cited set = facts.files_read[]
#                                             for that task's stage code, unioned with
#                                             tasks[T].metadata.consumes[].paths[]; change set
#                                             = handoff.files_touched[] of TARGET's artifact
#                                             (metadata.artifact) MINUS every .context/ path,
#                                             since the target always rewrites its own artifact
#                                             and counting it would return every dependent.
#                                             Both sides are normalised: a leading ./, a
#                                             trailing #anchor and a trailing :N are stripped.
#                                             A change set that is absent, unreadable or empty
#                                             BEFORE that exclusion fails safe to `pending`.
#                                             With an empty cited set, the dependent's own
#                                             files_touched gives own-file-changed (pending)
#                                             or no-own-file-changed (completed); absent,
#                                             unparsed or empty own files yield cited-set-empty
#                                             (pending). One left empty only BY
#                                             the exclusion is a known change set that touched
#                                             no cited file, so the dependent completes.
#                                             --changed is a TEST SEAM, not an orchestrator
#                                             argument: it substitutes the change set whole.
# @arg --claim <ID>                          pending|blocked -> in_progress + claimed_at
#                                             (date -u +%FT%TZ, top-level tasks.<ID>.claimed_at).
#                                             in_progress with claimed_at is a no-op (timestamp
#                                             kept); without it, stamps one.  completed|skipped|
#                                             failed exits 4 untouched: use --task-replay.
#                                             A `stale` row exits 4 untouched too: it is parked
#                                             behind a correction, and resuming it is a
#                                             settlement decision, not a claim.
# @arg --dispatch <ID> <agent_id> <status>   Exactly 3 args. status is launched|completed|
#                                             failed; agent_id matches
#                                             ^/?[A-Za-z0-9_][A-Za-z0-9._:@/-]{0,199}$; the row
#                                             accepts Claude ids and Codex canonical task names.
#                                             must carry non-empty metadata.agent — else exit 2.
#                                             Upserts facts.dispatched_agents[] by task_id: no
#                                             entry appends {stage, task_id,
#                                             subagent_type: metadata.agent, agent_id, status}
#                                             (+ model_requested when metadata.model is set);
#                                             same agent_id updates status in place; a
#                                             different agent_id replaces the entry at the tail.
#                                             Clamped to the last 6 launched, backfilled with
#                                             the newest non-launched, survivors keep order.
# @arg --files-read <ID> <path>...           Reads args until the next --flag; needs >= 1 path
#                                             (else exit 2). Each path: strip a leading ./;
#                                             non-empty, no TAB/CR/LF, <= 512 chars, or the
#                                             whole call fails exit 2 before writing. In-call
#                                             duplicates: last wins. Drops existing same-path
#                                             entries, appends {path, stage: <code from ID>,
#                                             lines: "all"} in arg order. Clamped to the
#                                             newest 30 (facts.files_read); no spill.
# @arg --ack <ID> <msg_id>                   Exactly 2 args; msg_id matches the --dispatch
#                                             agent_id grammar, else exit 2. Appends one
#                                             message_ack row {subject, task_id: ID,
#                                             metadata.msg_id} to <dir of --state>/logs/
#                                             audit.jsonl through audit-lib.sh. Takes no
#                                             merge lock and never writes state.json: the
#                                             ledger is read only to reject an unknown id.
#
# @arg --digest            Opt-in. After a successful write or idempotent no-op, print to
#                          STDOUT a <= 12-line read-back of the WRITTEN ledger: `state-patch
#                          ok`, then one `<ID> <status> [agent=<a>] [model=<m>]` line per
#                          touched task (a long batch ends `tasks +N more`), `edge <PREV>→<ID>`
#                          when --prev was given, `facts decisions=<n> open_questions=<n>
#                          files_modified=<n>` when --facts was applied and `audit +<n>` when
#                          --audit-row rows were appended. Absent ⇒ stdout byte-identical to
#                          the legacy output. Ignored by the ops that already own stdout
#                          (--resolve-task-id, --read-decisions, --verify-decision,
#                          --task-settle-stale) and by --ack/--ledger-meta/--resolve-models.
#                          Nothing is printed on a refusal, a no-op that wrote nothing, or a
#                          partial --facts (exit 2).
# @arg --audit-row <json>  Repeatable. {"action","result","subject"} required non-empty
#                          strings; optional "actor" (default corpflow:unknown), "metadata"
#                          (object) and "task_id" (<STAGE><N>, overrides the default). Any
#                          other key, a control byte in a scalar, or bad JSON is exit 2
#                          before anything is written. Rows are appended through audit-lib.sh
#                          to <dir of state.json>/logs/audit.jsonl AFTER the main op succeeds
#                          (write or idempotent no-op), with task_id defaulting to the id the
#                          call touched (first id of a batched --task-create); a refused op
#                          appends none. Alone (no other op) it appends rows only, after
#                          checking the ledger exists and every named id (row task_id or
#                          --task-id) is a ledger key — unknown ⇒ exit 1. Does not compose
#                          with the read-only ops, --ack, --ledger-meta or --resolve-models
#                          (exit 2).
#
# @arg --resolve-task-id <CODE>
#                           Print the ledger key a bare stage CODE resolves to and exit.
#                           Read-only: takes no lock and writes nothing.  Sibling scripts
#                           call this instead of re-implementing the preference ladder.
#
# @arg --read-decisions    Print facts.decisions[] unioned with the eviction spill, and exit.
# @arg --verify-decision <ud-id> --task-id <ID> [--expect-answer <text>]
#                           Read-only: verifies one user-decision ledger row (actor, per-row and
#                           chain sha256, worktask id, scope covering <ID>, audit corroboration,
#                           and, with --expect-answer, an exact answer match). Dispatches right
#                           after the root ladder and before pre-flight: no lock, no log write
#                           (LOG_FILE forced to /dev/null), no audit row, no state write. Prints
#                           the verifier JSON on stdout; question/answer/scope are null unless
#                           valid. --task-id is required. Exits 0 valid, 5 refused, 2 usage/IO
#                           (missing --task-id, unresolved ledger, unsupported version, missing
#                           jq or the library), 1 never (internal errors there exit 2).
# @arg --self-test          Run the built-in self-test and exit.
# @arg -h | --help          Show this header.
#
# @exitcode 0   Patch applied (or already idempotent; or artifact absent; or state absent on
#               every path EXCEPT --facts; or a --facts payload that was legitimately empty).
# @exitcode 1   Internal error (jq merge failed; use --log to inspect), unsupported ledger
#               version, a ledger op rejected for an unknown/malformed task id, a frontmatter
#               staging failure (mktemp), no ledger resolved for --facts or a ledger op, an
#               unknown id on --claim/--dispatch/--files-read/--ack, an --ack row that failed
#               to append, or --facts with no ledger at --state (that write landed nothing
#               and says so). Also: an --audit-row row that failed to append (the main op's
#               write stands), a standalone --audit-row with no ledger or naming an unknown
#               id, and a batched --task-create row whose --metadata is not valid JSON.
# @exitcode 2   DISK_MIN_GB hard-halt (caller must remediate before retrying), OR a --facts
#               payload that was refused whole (bad JSON, unknown key, non-array value,
#               invalid branch) with state.json byte-unchanged, OR a --facts payload that
#               PARTIALLY succeeded: the valid items were persisted and the rejected ones are
#               named on stderr. Read stderr to tell them apart — a partial success is the
#               only exit 2 that wrote. Also: malformed --dispatch/--files-read/--ack args,
#               --dispatch without the row's metadata.agent, an unreachable lib or resolver,
#               or (--task-create) a row missing a required metadata key.  Also: a
#               --finding-file that is unreadable, empty, over 2000 bytes or carrying a
#               control byte, and a --task-reopen without --from.  Also: a malformed
#               --audit-row (bad JSON, missing/empty required key, unknown key) or one
#               paired with an op it does not compose with, and a malformed batched
#               --task-create (repeated id, mixed op, --metadata ahead of the first id, or
#               any row's id/effort/required-key defect) — nothing written in every case.
# @exitcode 3   Artifact unresolved on the agent self-patch path (--prev given, --via absent),
#               OR a missing/unknown handoff.verdict on ANY path (--stage/--artifact,
#               plain or paired with --facts), state.json unchanged either way. An agent
#               patching the artifact it just wrote and finding nothing on disk, or finding a
#               verdict this map does not recognize, is a real failure; every other unresolved
#               case keeps the exit-0 no-op contract.
# @exitcode 4   Write refused by a pre-mutation guard, state.json untouched: a replay whose
#               target is live/parked, of indeterminate liveness, whose planning is
#               incomplete or whose cascade includes a blocked member; a stage code that
#               resolves to more than one open instance with nothing to disambiguate it; or
#               --claim on a settled (completed|skipped|failed) row or on a parked `stale` one;
#               or a --task-reopen whose target is the source or is not `completed`.
#               Unknown ids stay 1 and malformed ids stay 2.  Also: the ledger directory
#               was INFERRED from the cwd (no --state, CONTEXT_DIR, WORKSPACE_ROOT or
#               CLAUDE_PROJECT_DIR) and lies inside the plugin root (this script's own tree
#               or the host root corpflow_plugin_root reports) with the cwd not the git
#               toplevel — nothing is read or written.
# @exitcode 5   --verify-decision only: the row (or the chain it sits in) is refused — forged,
#               edited, out of scope, uncorroborated or answer-mismatched.  Every other op in
#               this file never returns 5.
#
# Note: --task-replay's liveness guard shells out to stale-check.sh, which needs python3.
# The dependency is out-of-process and fail-closed — without it the replay refuses (exit 4)
# rather than proceeding.  Every other op still needs only bash 3.2 + jq.
#
# Env vars honoured:
#   DISK_MIN_GB         (default 5)   — hard halt threshold in GiB
#   DISK_WARN_GB        (default 8)   — hygiene warn threshold in GiB
#   RUN_INDEX           — override run_index (for callers that know it without reading state.json)
#   CONTEXT_DIR         rank 2 of the root ladder; the audit log and every derived path
#                       otherwise follow dirname(STATE_PATH).  Without --state the ladder is
#                       CONTEXT_DIR, WORKSPACE_ROOT/.context, CLAUDE_PROJECT_DIR/.context,
#                       <git toplevel of $PWD>/.context, $PWD/.context
#                       (corpflow_context_dir_write in state-read-lib.sh).
#   STATE_LOCK_TIMEOUT_S (default 5)  — max seconds to wait for the merge lock before
#                                       proceeding UNLOCKED + WARN (never a silent no-op)
#   STATE_LOCK_STALE_S  (default 60)  — a lock dir older than this (by mtime) is treated
#                                       as leaked and broken so a crashed writer cannot wedge merges
#
# Single-writer / idempotent-merge invariant: state.json is written only when the
# patch changes its content.  Temp file is PID+RANDOM-namespaced to guard against
# PID reuse in Task subagents (CR-7 from handoff-protocol.md#atomic-write).
#
# Minimum shell: bash 3.2+ (macOS default); relies on no bash 4+ features so the
# SubagentStop hook environment on older macOS is fully supported.

set -Eeuo pipefail
IFS=$'\n\t'
unset ATOMIC_APPLY_PROBE ATOMIC_APPLY_PROBE_OUT _FACTS_SPILL_PATH
trap 'printf >&2 "error: %s:%d: exit %d\n" "${BASH_SOURCE[0]}" "$LINENO" "$?"' ERR

# ---------- Constants ----------
DISK_MIN_GB="${DISK_MIN_GB:-5}"
DISK_WARN_GB="${DISK_WARN_GB:-8}"
STATE_LOCK_TIMEOUT_S="${STATE_LOCK_TIMEOUT_S:-5}"
STATE_LOCK_STALE_S="${STATE_LOCK_STALE_S:-60}"

# Stage codes whose completion acts outside the ledger (FN commits/pushes/opens a PR, RE
# tags a release), so resetting one invites a second commit or tag for one unit of work.
# Canonical list: skills/shared/stage-codes.md § Side-effect-bearing stages — bash cannot
# read that table, so QA asserts the two agree.
REPLAY_SIDE_EFFECT_STAGES="FN,RE"

# Set by _lock_acquire so the EXIT trap and _lock_release know which dir to remove.
_LOCK_DIR=""
_LOCK_HELD=""
# The `<pid>:<nonce>:<epoch>` line written inside the lock dir at claim time. Release
# compares it byte-for-byte, which is what lets a writer tell its own lock from the one a
# stale-break handed to a successor; the nonce is what defeats PID reuse.
_LOCK_TOKEN=""
# Seconds _lock_acquire spent waiting. Read by the unlocked-path audit row, which is
# worthless without it: "proceeded unlocked" and "waited the full budget" are the same
# event only when the budget is known.
_LOCK_WAITED=0

# Set when a --facts payload carried no items at all — the sanctioned empty sweep.
FACTS_EMPTY_NOOP=0

# Set when --facts dropped at least one item. A partially accepted payload persists its valid
# remainder AND exits non-zero: every caller branches on exit status, so a silent 0 would hide
# the rejection from all of them.
FACTS_REJECTED=0

usage() {
  # Stop at the first non-comment line rather than a hardcoded count: the header block ends
  # where the code begins, and a line count silently truncates help text whenever it grows.
  awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 2
}

log_msg() {
  # log_msg <LEVEL> <message>
  local level="${1:-INFO}" msg="${2:-}"
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$level" "$msg" >> "$LOG_FILE" 2> /dev/null || true
}

# Stage code → artifact BASENAME (mirrors state-merge.sh and handoff-protocol.md#stage-artifact-map).
basename_for_stage() {
  case "$1" in
    PL) printf 'planning' ;;
    AR) printf 'architecture' ;;
    TL) printf 'coordination' ;;
    DV) printf 'development' ;;
    DR) printf 'developer-review' ;;
    SR) printf 'security-review' ;;
    QA) printf 'testing' ;;
    DC) printf 'documentation' ;;
    RE) printf 'release' ;;
    FN) printf 'complete-summary' ;;
    ST) printf 'retrospective' ;;
    IR) printf 'incident' ;;
    ET) printf 'ethics-review' ;;
    *) printf '' ;;
  esac
}

# handoff.verdict -> mapped ledger status. The ONLY copy of this map (mirrored in
# SKILL.md's VERDICT_STATUS for the orchestrator's JS side — see the parity bats test).
# Exact lowercase match; missing or unrecognized prints nothing, which callers treat as
# a hard refusal rather than guessing a status.
verdict_status() {
  case "$1" in
    ok | pass | go | approve) printf 'completed' ;;
    blocked | escalate) printf 'blocked' ;;
    fail | reject | no-go) printf 'pending' ;;
    *) printf '' ;;
  esac
}

# Stage code → newline-separated fallback basenames, accepted when resolving and NEVER
# emitted. Deliberately a sibling of basename_for_stage() rather than extra arms inside it:
# the seven-way parity guard slices that function's body and must keep seeing exactly one
# canonical name per stage.
alias_basenames_for_stage() {
  case "$1" in
    DR) printf 'review' ;;
    QA) printf 'qa' ;;
    FN) printf 'finalization' ;;
    *) printf '' ;;
  esac
}

# Every basename a stage's artifact may be found under, primary first.
searched_basenames_for_stage() {
  local primary alias_list
  primary=$(basename_for_stage "$1")
  [[ -n "$primary" ]] && printf '%s\n' "$primary"
  alias_list=$(alias_basenames_for_stage "$1")
  [[ -n "$alias_list" ]] && printf '%s\n' "$alias_list"
  return 0
}

# Resolve on-disk artifact for a stage BASENAME.
# Resolution order (per handoff-protocol.md#stage-artifact-map):
#   1. Exact .context/<base>-<RUN_INDEX>.md when RUN_INDEX is known.
#   2. Highest-N numbered artifact (newest run_index).
#   3. Empty (absent) — never yields a literal '*'.
resolve_artifact() {
  local base="$1" ctx="${2:-}"
  # No caller-supplied search root — never fall back to cwd's own tree; that is exactly
  # the ledger-hygiene hazard the root ladder exists to close off.
  [[ -z "$base" || -z "$ctx" ]] && {
    printf ''
    return 0
  }

  # 1. Exact run_index match.
  if [[ -n "${RUN_INDEX:-}" && -f "${ctx}/${base}-${RUN_INDEX}.md" ]]; then
    printf '%s' "${ctx}/${base}-${RUN_INDEX}.md"
    return 0
  fi

  # 2. Highest-N numbered artifact. A glob walk rather than `ls | sort -n`: it survives a
  #    filename the shell would word-split, and it costs no forks on a path taken once per
  #    stage completion.
  #
  #    The stem must be EXACTLY <base>: the glob alone accepts any trailing -<digits>, so
  #    `qa-notes-3.md` would answer for basename `qa`. Harmless while every basename was a
  #    long canonical word; the short aliases make it reachable.
  local newest="" newest_n=-1 cand cand_base cand_n
  for cand in "${ctx}/${base}-"*.md; do
    [[ -f "$cand" ]] || continue
    cand_base="${cand##*/}"
    [[ "$cand_base" =~ ^${base}-([0-9]+)\.md$ ]] || continue
    # 10# forces base 10: a `-08` suffix is an octal literal to bash arithmetic and aborts.
    cand_n=$((10#${BASH_REMATCH[1]}))
    if [[ "$cand_n" -gt "$newest_n" ]]; then
      newest_n="$cand_n"
      newest="$cand"
    fi
  done
  if [[ -n "$newest" && -f "$newest" ]]; then
    printf '%s' "$newest"
    return 0
  fi

  # 3. No match.
  printf ''
}

# Resolve a stage's artifact across its primary basename and then its aliases, each
# through the full run_index → highest-N ladder. Canonical always wins: an alias is only
# reached once the primary has failed both tiers.
resolve_artifact_for_stage() {
  local stage="$1" ctx="${2:-}" base found
  [[ -z "$ctx" ]] && {
    printf ''
    return 0
  }
  while IFS= read -r base; do
    [[ -z "$base" ]] && continue
    found=$(resolve_artifact "$base" "$ctx")
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
  done <<< "$(searched_basenames_for_stage "$stage")"
  printf ''
}

# Parse frontmatter with yq (preferred) or awk fallback.
# Sets PARSED_STAGE, PARSED_VERDICT, PARSED_SUMMARY and (additive, optional)
# PARSED_WT_PATH / PARSED_WT_BRANCH in the caller's scope.
#
# Also sets PARSED_TE_STATE / PARSED_TE_JSON for the ledger's tests_executed mirror:
#   list      handoff.tests_executed is a sequence; PARSED_TE_JSON is it as compact JSON
#   absent    anything else (no key, a legacy scalar, a map)
#   unparsed  the list could not be read (no yq, a yq/jq error, no frontmatter)
# `unparsed` exists so a host without yq leaves the mirror and any rework marker alone
# rather than reading the list as gone.
parse_frontmatter() {
  local art="$1"
  PARSED_STAGE="" PARSED_VERDICT="" PARSED_SUMMARY=""
  PARSED_WT_PATH="" PARSED_WT_BRANCH=""
  PARSED_TE_STATE="unparsed" PARSED_TE_JSON="null"

  local fmfile
  fmfile=$(mktemp "${TMPDIR:-/tmp}/corpflow-fm-XXXXXX") || {
    # A staging failure here is the tool's own disk/tmp, not the artifact's shape — a
    # different failure class from every other arm below, so it exits directly rather than
    # returning into a caller that would fold it into the shape-defect exit code.
    printf >&2 'ERROR: cannot stage frontmatter for %s (mktemp failed); state.json unchanged\n' "$art"
    log_msg ERROR "cannot stage frontmatter for ${art} (mktemp failed); state.json unchanged"
    exit 1
  }

  if ! corpflow_fm_block "$art" > "$fmfile" 2> /dev/null; then
    rm -f "$fmfile"
    # No block at all — the F3 contract for stage/summary, unchanged. An artifact that
    # never carried frontmatter is a different failure from one that carries the WRONG
    # frontmatter, and only the second is a shape defect. The verdict is NOT defaulted:
    # the artifact-preflight refusal must see it missing and refuse, same as any
    # other missing verdict.
    log_msg WARN "no frontmatter in $art — F3 fallback"
    PARSED_STAGE="${STAGE_ARG:-}"
    PARSED_SUMMARY="auto-generated by state-patch.sh (frontmatter missing)"
    return 0
  fi

  # A block with no `handoff:` key is the FLAT shape neither this reader nor
  # handoff-harness.sh accepts: refusing it here keeps a stage from writing a healthy
  # ledger row while failing its own boundary check, with nothing connecting the two.
  if ! corpflow_fm_has_handoff "$fmfile"; then
    rm -f "$fmfile"
    printf >&2 'ERROR: %s has frontmatter with no `handoff:` block — every stage template nests under it (stage-contracts.md#tpl-<CODE>). Rewrite the block; handoff-harness.sh refuses this shape too.\n' \
      "$art"
    log_msg ERROR "frontmatter in ${art} has no handoff: block — refused"
    return 1
  fi

  PARSED_STAGE=$(corpflow_fm_field "$fmfile" stage "")
  PARSED_VERDICT=$(corpflow_fm_field "$fmfile" verdict "")
  PARSED_SUMMARY=$(corpflow_fm_field "$fmfile" summary "")
  PARSED_WT_PATH=$(corpflow_fm_field "$fmfile" worktree_path "")
  PARSED_WT_BRANCH=$(corpflow_fm_field "$fmfile" worktree_branch "")
  parse_tests_executed "$fmfile"
  rm -f "$fmfile"

  # A missing verdict is left empty, never defaulted — the artifact-preflight refusal
  # is the one place that decides what an absent verdict means.
  [[ -z "$PARSED_SUMMARY" ]] && PARSED_SUMMARY="(auto)"
  return 0
}

# parse_tests_executed <block-file> — sets PARSED_TE_STATE / PARSED_TE_JSON (see above).
parse_tests_executed() {
  local fm="$1" tag json
  command -v yq > /dev/null 2>&1 || return 0
  tag=$(yq eval '.handoff.tests_executed | tag' "$fm" 2> /dev/null) || return 0
  if [[ "$tag" != '!!seq' ]]; then
    PARSED_TE_STATE="absent"
    return 0
  fi
  json=$(yq -o=json -I=0 '.handoff.tests_executed' "$fm" 2> /dev/null | jq -c . 2> /dev/null) \
    || return 0
  [[ -n "$json" ]] || return 0
  PARSED_TE_STATE="list" PARSED_TE_JSON="$json"
}

# Predecessor codes are a SUPERSET of stage codes: USER is the documented origin of the
# USER→PL and USER→IR edges but owns no artifact, so it must never reach basename_for_stage().
is_valid_prev() {
  [[ "$1" == "USER" ]] && return 0
  [[ -n "$(basename_for_stage "$1")" ]]
}

# Bare stage CODE → ledger key. Precedence: explicit --task-id, then the artifact match,
# then the status ladder the jq below spells (lowest N first — a split stage is worked in
# order). `completed` is never reused and `skipped` never resurrected: both were settled
# deliberately. Caller must have already established that $STATE_PATH exists.
#
# The artifact tier reads ARTIFACT_ARG — what the CALLER passed — never the stage-resolved
# $ART, which is a basename guess rather than a caller assertion and is not assigned until
# ~1100 lines below. Within it the RECORDED `.artifact` beats the PLANNED
# `.metadata.artifact`: PL0 seeds the planned name and a split stage routinely writes a
# different file (planned development-0-ledger.md, written development-1.md), so reading
# metadata first slots the patch by a stale guess — the mis-slotting this resolution exists
# to prevent. Metadata stays the fallback: it is the only artifact key a stage that has not
# completed yet carries.
#
# Ambiguity INSIDE the winning tier is fatal rather than arbitrary — two indistinguishable
# `in_progress` instances would land the patch on a coin flip. Ambiguity ACROSS tiers is not:
# the ladder orders those deliberately. Returns 1 before any lock is taken.
resolve_task_id() {
  local code="$1" resolved="" raw base
  if [[ -n "${TASK_ID_ARG:-}" ]]; then
    printf '%s' "$TASK_ID_ARG"
    return 0
  fi
  command -v jq > /dev/null 2>&1 || { printf '%s' "${code}0"; return 0; }

  # Ledger paths are `.context/...`-relative; callers pass absolute or `./`-prefixed ones.
  # Compare normalised full paths OR basenames, and require exactly one hit — a basename
  # collision across two instances is an ambiguity, not a match.
  if [[ -n "${ARTIFACT_ARG:-}" ]]; then
    raw="${ARTIFACT_ARG#./}"
    base="${raw##*/}"
    resolved=$(jq -r --arg c "$code" --arg raw "$raw" --arg base "$base" '
      def norm: (. // "") | tostring | sub("^\\./"; "");
      def hit($p): ($p | norm) as $n
        | $n != "" and ($n == $raw or ($n | split("/") | last) == $base);
      [ (.tasks // {}) | to_entries[]
        | select(.key | test("^" + $c + "[0-9]+$")) ] as $all
      | [ $all[] | select(hit(.value.artifact))          ] as $actual
      | [ $all[] | select(hit(.value.metadata.artifact)) ] as $planned
      | if   ($actual  | length) == 1 then $actual[0].key
        elif ($planned | length) == 1 then $planned[0].key
        else "" end' \
      "$STATE_PATH" 2> /dev/null || printf '')
    if [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi

  # Ladder tier + its size in one read: the size is what makes the abort arm possible.
  local tier
  tier=$(jq -r --arg c "$code" '
    ( [ (.tasks // {}) | to_entries[]
        | select(.key | test("^" + $c + "[0-9]+$")) ]
      | sort_by(.key | ltrimstr($c) | tonumber) ) as $all
    | ( [ $all[] | select(.value.status == "in_progress") ]
        | select(length > 0) )
      // ( [ $all[] | select(.value.status == "pending") ]
           | select(length > 0) )
      // ( [ $all[] | select(.value.status == "blocked") ]
           | select(length > 0) )
      // ( [ $all | last | select(. != null) ] )
    | (length | tostring) + " " + ([ .[].key ] | join(","))' \
    "$STATE_PATH" 2> /dev/null || printf '')

  local n keys
  n="${tier%% *}"
  keys="${tier#* }"
  if [[ "${n:-0}" =~ ^[0-9]+$ ]] && [[ "$n" -gt 1 ]]; then
    printf >&2 'ERROR: stage %s is ambiguous — %s open instances share status: %s\n  Pass --task-id <ID>, or --artifact <path> matching exactly one instance.\n  state.json is unchanged.\n' \
      "$code" "$n" "$keys"
    log_msg ERROR "ambiguous stage ${code}: candidates ${keys} — refusing to guess"
    return 1
  fi
  [[ "${n:-0}" == "1" ]] && resolved="$keys"
  printf '%s' "${resolved:-${code}0}"
}

# require_task_exists <ID> <op> — abort unless tasks.<ID> is already in the ledger.
# --task-create is the ONLY op allowed to introduce a key.  Every other op assigns through
# .tasks[$id], which jq would happily autovivify: a typo'd id would land a status-only or
# blocked_by-only ghost that carries no metadata yet still answers every downstream
# readiness check — and, for the dependency ops, gates a real stage on a task nobody runs.
require_task_exists() {
  local id="$1" op="$2"
  if [[ ! -f "$STATE_PATH" ]] \
    || ! jq -e --arg id "$id" '(.tasks // {}) | has($id)' "$STATE_PATH" > /dev/null 2>&1; then
    printf >&2 'unknown task id: %s (--task-%s needs an existing task; create it first)\n' "$id" "$op"
    log_msg ERROR "${op} op on unknown tasks.${id}; state.json unchanged"
    exit 1
  fi
}

# ---------- Replay guards ----------
# Every exit-4 line starts `replay refused: <class-token> — ` so callers and tests match the
# token rather than the prose.
replay_refuse() {
  local token="$1" detail="$2"
  printf >&2 'replay refused: %s — %s\n' "$token" "$detail"
  log_msg ERROR "replay refused (${token}) on tasks.${TASK_OP_ID}: ${detail}; state.json unchanged"
  exit 4
}

replay_warn() {
  printf >&2 'replay warning: %s — %s\n' "$1" "$2"
  log_msg WARN "replay warning (${1}) on tasks.${TASK_OP_ID}: ${2}"
}

# Read-only survey of the ledger: cascade closure, per-member prior fields, stale dependents.
# Pure function of the file, so it can run before the lock without racing a mutation it owns.
replay_survey() {
  jq -c --arg id "$1" --arg se "$REPLAY_SIDE_EFFECT_STAGES" \
    --argjson cascade "${REPLAY_CASCADE:-false}" '
    def deps_of($st; $tid):
      [ ($st.tasks // {}) | to_entries[]
        | select((.value.blocked_by // []) | index($tid)) | .key ];
    def is_side_effect($tid; $codes):
      any($codes[]; . as $c | $tid | test("^" + $c + "[0-9]+$"));
    def member_row($st; $tid):
      ($st.tasks[$tid]) as $t
      | { id: $tid,
          prior_status: ($t.status // null),
          prior_retry: ($t.metadata.retry_count // null),
          prior_escalated: ($t.metadata.error_escalated_to // null),
          cleared: [ "retry_count", "error_escalated_to", "completed_via"
                     | . as $k
                     | select(if $k == "completed_via"
                              then ($t | has("completed_via"))
                              else (($t.metadata // {}) | has($k)) end) ] };
    . as $st
    | ($se | split(",")) as $codes
    # blocked_by has no acyclicity enforcement anywhere, so the visited set alone is not
    # allowed to be the only termination proof; the task count bounds the frontier walk.
    | (($st.tasks // {}) | length) as $bound
    | ( if $cascade
        then ( { frontier: [$id], visited: [$id], order: [], n: 0 }
               | until((.frontier | length) == 0 or .n >= $bound;
                   . as $s
                   | ( [ $s.frontier[] | deps_of($st; .) ] | add // [] | unique ) as $next
                   | ( [ $next[] | . as $d | select(($s.visited | index($d)) == null) ]
                       | sort ) as $new
                   | { frontier: $new,
                       visited: ($s.visited + $new),
                       order: ($s.order + $new),
                       n: ($s.n + 1) })
               | .order )
        else [] end ) as $downstream
    | ([$id] + [ $downstream[] | select(is_side_effect(.; $codes) | not) ]) as $reset
    | { root: $id,
        cascade: $cascade,
        plan_status: ($st.tasks.PL0.status // null),
        run_index: ($st.run_index // 0),
        worktask_id: ($st.worktask_id // "unknown"),
        target_side_effect: is_side_effect($id; $codes),
        skipped: [ $downstream[] | select(is_side_effect(.; $codes)) ],
        # Only dependents this write is NOT resetting can be stale.  Naming a member would
        # assert the opposite of what the same atomic apply is about to do to it, and that
        # false claim would land in the durable audit row a later diagnosis reads.
        stale_dependents: ( [ deps_of($st; $id)[] | . as $d
                              | select((($st.tasks[$d].status) // "") == "completed")
                              | select(($reset | index($d)) == null) ] | sort ),
        members: [ $reset[] | member_row($st; .) ] }' \
    "$STATE_PATH"
}

# Liveness comes from stale-check.sh's per-task FINDING, never from its exit code: rc 1
# ("attention") can be about an unrelated task, so mapping rc→verdict would both refuse
# legitimate replays and allow rc-0 shapes it never examined.  Prints the payload, or the
# empty string when the payload cannot be trusted at all.
replay_liveness_payload() {
  local sc out="" rc=0
  sc="$(dirname "$0")/stale-check.sh"
  [[ -f "$sc" ]] || return 1
  if [[ -n "${AGENTS_JSON_ARG:-}" ]]; then
    out=$(bash "$sc" --state "$STATE_PATH" --context "${CTX}" --json \
      --agents-json "$AGENTS_JSON_ARG" 2> /dev/null) || rc=$?
  else
    out=$(bash "$sc" --state "$STATE_PATH" --context "${CTX}" --json \
      2> /dev/null) || rc=$?
  fi
  # rc 2 is stale-check's usage/unreadable-input error (and the shape a missing python3
  # produces); only 0/1/3 mean it actually classified the ledger.
  case "$rc" in
    0 | 1 | 3) ;;
    *) return 1 ;;
  esac
  jq -e '(.findings | type) == "array" and .liveness == "ok"' <<< "$out" > /dev/null 2>&1 \
    || return 1
  printf '%s' "$out"
}

# One row per reset member, root first then BFS order — and none at all on a refusal.
# That asymmetry is load-bearing: stale-check.sh's budget-halt classifier reads ANY
# result:"error" row as evidence of a real stage failure, so a refusal row would
# mis-diagnose every later look at this worktask.  Best-effort, mirroring --via hook.
replay_audit() {
  local dir="${CTX}/logs" ts
  ts=$(date -u +%FT%TZ)
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the write that already landed.
  mkdir -p "$dir" 2> /dev/null || return 0
  [[ ! -L "$dir/audit.jsonl" ]] || return 0
  jq -c --arg ts "$ts" --arg root "$TASK_OP_ID" --argjson cascade "$REPLAY_CASCADE" '
    (.worktask_id + ":" + (.run_index | tostring)) as $pfx
    | (if $cascade then $pfx + ":" + $root + ":cascade:" + $ts else null end) as $cid
    | .stale_dependents as $stale
    | .skipped as $skipped
    | [ .members[].id ] as $ids
    | .members[]
    | (.id == $root) as $isroot
    | {ts: $ts, actor: "orchestrator", action: "stage_replay", subject: .id,
       result: "ok", task_id: .id,
       metadata: {
         via: "state-patch --task-replay",
         prior_status: .prior_status,
         cleared: .cleared,
         escalation_cap_override: ((.prior_retry // 0) >= 3 or (.prior_escalated != null)),
         prior_retry_count: .prior_retry,
         prior_escalated_to: .prior_escalated,
         liveness: .liveness,
         stale_dependents: (if $isroot then $stale else [] end),
         cascade: $cascade,
         cascade_root: (if $cascade then $root else null end),
         cascade_id: $cid,
         cascade_members: (if ($isroot and $cascade) then $ids else [] end),
         cascade_skipped: (if ($isroot and $cascade) then $skipped else [] end),
         # A replay is intentionally repeatable, so the key carries $ts: unlike the
         # completion row, two legitimate replays must not collapse into one.
         dedupe_key: ($pfx + ":" + .id + ":replay:" + $ts)}}' \
    <<< "$REPLAY_PLAN" >> "$dir/audit.jsonl" 2> /dev/null \
    || log_msg WARN "audit append failed for replay of tasks.${TASK_OP_ID} (reset already applied)"
}

# ---------- Correction guards (--task-reopen / --task-settle-stale) ----------
# Same shape as replay_refuse, and deliberately the same exit class: every exit-4 line starts
# `reopen refused: <class-token> — ` so a caller matches the token, never the prose.
reopen_refuse() {
  local token="$1" detail="$2"
  printf >&2 'reopen refused: %s — %s\n' "$token" "$detail"
  log_msg ERROR "reopen refused (${token}) on tasks.${TASK_OP_ID}: ${detail}; state.json unchanged"
  exit 4
}

# The finding is stage-written text that lands in a durable ledger field and later renders into
# a prompt, so it never travels on argv: a command line is visible in the process table and is
# what the audit hook captures as a command head. It is staged 0600 and removed on exit.
_FINDING_TMP=""
# shellcheck disable=SC2329  # invoked indirectly, from the EXIT trap below — never inline
_finding_cleanup() {
  [[ -n "$_FINDING_TMP" ]] || return 0
  rm -f "$_FINDING_TMP" 2> /dev/null || true
  _FINDING_TMP=""
}

# reopen_read_finding <path|-> — stage the finding into $_FINDING_TMP, or exit 2 untouched.
#
# Bounded and control-byte-free on the way IN, not on the way out: once written, the field is
# read by the brief builder and by whatever reads the ledger later, and neither of those can
# tell a pasted log from a finding. Refusal beats truncation here because R3 promises the
# finding renders byte-for-byte — a silently clipped one would still read as verbatim.
reopen_read_finding() {
  local src="$1" bytes=0
  _FINDING_TMP=$(umask 077 && mktemp "${TMPDIR:-/tmp}/corpflow-finding-XXXXXX") || {
    printf >&2 'reopen: cannot stage the finding (mktemp failed); state.json unchanged\n'
    log_msg ERROR "cannot stage finding for reopen of tasks.${TASK_OP_ID}; state.json unchanged"
    exit 2
  }
  if [[ "$src" == "-" ]]; then
    cat > "$_FINDING_TMP"
  else
    if [[ ! -r "$src" ]]; then
      printf >&2 'invalid --finding-file: %s is not readable; state.json unchanged\n' "$src"
      log_msg ERROR "unreadable --finding-file for reopen of tasks.${TASK_OP_ID}; state.json unchanged"
      exit 2
    fi
    cat -- "$src" > "$_FINDING_TMP"
  fi
  bytes=$(wc -c < "$_FINDING_TMP" | tr -d '[:space:]')
  if [[ "${bytes:-0}" -eq 0 ]]; then
    printf >&2 'invalid --finding-file: the finding is empty; state.json unchanged\n'
    log_msg ERROR "empty --finding-file for reopen of tasks.${TASK_OP_ID}; state.json unchanged"
    exit 2
  fi
  if [[ "$bytes" -gt 2000 ]]; then
    printf >&2 'invalid --finding-file: %s bytes exceeds the 2000-byte cap; put the detail behind the return evidence_ref and pass a finding; state.json unchanged\n' "$bytes"
    log_msg ERROR "oversized --finding-file (${bytes}B) for reopen of tasks.${TASK_OP_ID}; state.json unchanged"
    exit 2
  fi
  # TAB and LF are the only control bytes a finding legitimately carries. Everything else —
  # NUL, ESC, CR — is either a truncated binary or a terminal-control payload, and this field
  # is rendered into a prompt and copied into briefs. LC_ALL=C keeps [:cntrl:] at 0x00-0x1F/0x7F
  # so a UTF-8 finding is not rejected for its continuation bytes.
  if tr -d '\n\t' < "$_FINDING_TMP" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    printf >&2 'invalid --finding-file: the finding carries a control byte (only TAB and LF are allowed); state.json unchanged\n'
    log_msg ERROR "control byte in --finding-file for reopen of tasks.${TASK_OP_ID}; state.json unchanged"
    exit 2
  fi
}

# parse_files_touched <artifact> — sets PARSED_FT_STATE (list|absent|unparsed) and
# PARSED_FT_JSON (a JSON array of strings; [] unless the state is `list`).
#
# `unparsed` and `absent` are NOT merged: the settle op fails safe on both, but only one of
# them means "this host could not read the list", and a later diagnosis needs to tell a missing
# key from a missing parser. Block extraction and the shape gate come from frontmatter-lib.sh,
# the one reader of a handoff block; only the sequence read is local, because that library
# exposes scalars alone.
parse_files_touched() {
  local art="$1" fmfile tag json
  PARSED_FT_STATE="unparsed"
  PARSED_FT_JSON="[]"
  [ -r "$art" ] || return 0
  command -v corpflow_fm_block > /dev/null 2>&1 || return 0
  fmfile=$(mktemp "${TMPDIR:-/tmp}/corpflow-ft-XXXXXX") || return 0
  if ! corpflow_fm_block "$art" > "$fmfile" 2> /dev/null \
    || ! corpflow_fm_has_handoff "$fmfile"; then
    rm -f "$fmfile"
    return 0
  fi
  if command -v yq > /dev/null 2>&1; then
    tag=$(yq eval '.handoff.files_touched | tag' "$fmfile" 2> /dev/null) || tag=""
    if [[ "$tag" == '!!seq' ]]; then
      json=$(yq -o=json -I=0 '.handoff.files_touched' "$fmfile" 2> /dev/null \
        | jq -c 'map(select(type == "string"))' 2> /dev/null) || json=""
      # A post-filter `[]` — an empty sequence, or one holding no strings — is `absent`, NOT an
      # empty list, and the two readers must agree on that: the awk branch below cannot tell a
      # declared-but-empty list from a missing key, so calling it `list` here would make the
      # settle op's fail-safe invert on a host that happens to have yq. The distinction that
      # matters to D2 is "did this call read a change set", and neither shape did.
      if [[ -n "$json" && "$json" != "[]" ]]; then
        PARSED_FT_STATE="list"
        PARSED_FT_JSON="$json"
      elif [[ "$json" == "[]" ]]; then
        PARSED_FT_STATE="absent"
      fi
    else
      PARSED_FT_STATE="absent"
    fi
    rm -f "$fmfile"
    return 0
  fi
  # No yq: read the sequence with the same nesting-aware awk shape corpflow_fm_field uses for
  # scalars, so a host without yq still settles on evidence instead of failing safe every time.
  # Both YAML sequence forms appear in real artifacts — block (`- path`) and flow (`[a, b]`).
  json=$(awk '
      /^handoff:[[:space:]]*$/ { inblk = 1; next }
      inblk && /^[^[:space:]#]/ { inblk = 0 }
      inblk && match($0, /^[[:space:]]+files_touched:[[:space:]]*/) {
        rest = substr($0, RLENGTH + 1)
        if (rest ~ /^\[/) {
          sub(/^\[/, "", rest); sub(/\][[:space:]]*$/, "", rest)
          n = split(rest, a, ",")
          for (i = 1; i <= n; i++) { v = a[i]; emit(v) }
        } else { inseq = 1 }
        next
      }
      inblk && inseq && /^[[:space:]]*-[[:space:]]*/ {
        v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); emit(v); next
      }
      inblk && inseq && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:/ { inseq = 0 }
      function emit(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        gsub(/^"|"$/, "", s); gsub(/^'"'"'|'"'"'$/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (s != "") print s
      }
    ' "$fmfile" | jq -Rs 'split("\n") | map(select(length > 0))' 2> /dev/null) || json=""
  rm -f "$fmfile"
  [[ -n "$json" ]] || return 0
  # An artifact whose block carries no files_touched yields [] here, which is `absent`, not an
  # empty list: the awk reader cannot distinguish "key present, empty sequence" from "no key",
  # and both fail safe the same way.
  if [[ "$json" == "[]" ]]; then
    PARSED_FT_STATE="absent"
  else
    PARSED_FT_STATE="list"
    PARSED_FT_JSON="$json"
  fi
}

# ENOSPC guard.  Returns 0 (ok/warn), exits 2 (halt).
disk_guard() {
  local root="${1:-.}"
  local avail_gb=""
  # -g is BSD-only; GNU df rejects it and prints nothing, which silently degraded
  # the guard to a no-op on Linux. -Pk is POSIX on both, so convert here instead.
  avail_gb=$(df -Pk "$root" 2> /dev/null | awk 'NR==2 {printf "%d", $4/1048576}') || avail_gb=""

  [[ -z "$avail_gb" ]] && return 0 # df unparseable → degrade silently, never block

  if ((avail_gb < DISK_MIN_GB)); then
    log_msg ERROR "DISK_HALT: only ${avail_gb}GB free (< ${DISK_MIN_GB}GB) on $root"
    # The guard runs on every platform, so the advice names the build-cache class
    # rather than one stack: the reader picks the line that matches their tree.
    printf >&2 'HALT: only %dGB free (< %dGB) on %s.\nReclaim space from this project stack build caches, e.g.\n  node_modules/, .gradle/, target/, build/, __pycache__/, .venv/\n  Apple: swift package clean; rm -rf ~/Library/Developer/Xcode/DerivedData/*\n' \
      "$avail_gb" "$DISK_MIN_GB" "$root"
    exit 2
  elif ((avail_gb < DISK_WARN_GB)); then
    log_msg WARN "DISK_WARN: ${avail_gb}GB free (< ${DISK_WARN_GB}GB) on $root — consider clearing this project stack build caches"
  fi
}

# ---------- Merge lock (mkdir-spinlock) ----------
# Serializes the read → merge → rename window of atomic_apply() so legal sibling
# overlap (parallel DVN tracks, DC+QA — one writer per stage KEY) cannot drop a
# patch to last-rename-wins.  mkdir is atomic on POSIX; no flock(1) needed (macOS
# lacks it).  Timeout ⇒ proceed UNLOCKED + WARN (never worse than the pre-lock
# lockless path; an exit-0 no-op would let a leaked lock silently swallow merges).
# The hook inherits this by delegating to state-patch.sh (zero hook changes).

# _lock_break_if_stale <lockdir> — break a lock older than STATE_LOCK_STALE_S (by
# dir mtime) so a crashed writer cannot wedge every later merge.
_lock_break_if_stale() {
  local lockdir="$1" mtime now age
  [[ -d "$lockdir" ]] || return 0
  # stat -f%m (BSD/macOS) then -c%Y (GNU). The format MUST stay attached to the
  # flag: separated, GNU reads -f as --file-system, which takes no argument, so
  # the path becomes an operand and stat prints a filesystem block to stdout
  # while exiting non-zero — `||` tests only status, so the fallback's value is
  # appended to that block and $mtime becomes junk rather than empty.
  mtime=$(stat -f%m "$lockdir" 2> /dev/null || stat -c%Y "$lockdir" 2> /dev/null || printf '')
  # Non-numeric means neither probe parsed; treat as "cannot age the lock".
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 0
  now=$(date +%s 2> /dev/null || printf '')
  [[ -z "$now" ]] && return 0
  age=$((now - mtime))
  if ((age >= STATE_LOCK_STALE_S)); then
    log_msg WARN "lock stale (${age}s ≥ ${STATE_LOCK_STALE_S}s) — breaking $lockdir"
    rmdir "$lockdir" 2> /dev/null || rm -rf "$lockdir" 2> /dev/null || true
  fi
}

# _audit_task_ref — the ledger key this invocation names, for an audit row's task_id;
# "unknown" when it names none.
_audit_task_ref() {
  local t
  for t in "${TASK_OP_ID:-}" "${TASK_ID_ARG:-}"; do
    [[ "$t" =~ ^[A-Z]{2}[0-9]+$ ]] && { printf '%s' "$t"; return 0; }
  done
  printf 'unknown'
}

# _lock_audit <action> <key=value>... — one audit row about the lock, never a gate.
#
# The audit library is probed HERE rather than reusing the --facts probe near the bottom of
# the script: that one runs during --facts handling, which may be reached only AFTER
# atomic_apply has already written, so a flag hoisted from it is empty on exactly the
# unlocked path this row exists to record. Re-probing per call has no ordering precondition
# at all, and the library's include guard makes a second source a no-op.
#
# Values go through --meta-kv, not --meta: they are flat scalars the appender sanitises,
# so no lock path can break the row's JSON literal.
_lock_audit() {
  local action="$1"
  shift
  local lib sp dir pair
  if ! command -v corpflow_audit_row > /dev/null 2>&1; then
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
    [ -r "$lib" ] || return 0
    # shellcheck source=../../shared/lib/audit-lib.sh
    . "$lib" || return 0
    command -v corpflow_audit_row > /dev/null 2>&1 || return 0
  fi
  sp="$STATE_PATH"
  dir="${sp%/*}"
  [ "$dir" = "$sp" ] && dir="."
  local kv=()
  for pair in "$@"; do kv[${#kv[@]}]="--meta-kv"; kv[${#kv[@]}]="$pair"; done
  corpflow_audit_row --file "${dir}/logs/audit.jsonl" \
    --actor "${VIA_ARG:-agent}:state-patch" --action "$action" --subject "${sp##*/}" \
    --result degraded --task-id "$(_audit_task_ref)" ${kv[@]+"${kv[@]}"} || true
}

# _lock_owner_read <lockdir> — the owner token, bounded, empty when there is none.
#
# The bound is not tidiness: this value reaches an audit row, and one oversized value
# inflates that row past the size below which the unlocked `>>` to audit.jsonl is atomic,
# which is the single condition under which the evidence log can interleave. It also makes
# the claim-side prefix test sound — an owner longer than a token can never look like one.
_lock_owner_read() {
  [[ -f "$1/owner" ]] || return 0
  head -c 256 "$1/owner" 2> /dev/null || printf ''
}

# _lock_claim <lockdir> — mkdir + owner token. 0 only when the lock is held AND verifiable.
#
# The token is written after the mkdir that is the atomic claim, so the directory exists
# ownerless for the width of one small write. That residual TOCTOU is accepted, not closed
# (sw-AR0-3): it is microseconds against a stale threshold of many seconds, and strictly
# smaller than the pre-change exposure, where no token existed at any point.
#
# _LOCK_HELD is set only once the token is durable. A lock nobody can verify is worse than
# no lock — release could not tell it from a successor's — so a failed write hands the
# directory back and the caller falls through to the unlocked path.
_lock_claim() {
  local lockdir="$1"
  mkdir "$lockdir" 2> /dev/null || return 1
  _LOCK_TOKEN="$$:${RANDOM}${RANDOM}:$(date +%s 2> /dev/null || printf '0')"
  if ! printf '%s\n' "$_LOCK_TOKEN" > "${lockdir}/owner" 2> /dev/null; then
    log_msg WARN "lock owner token unwritable in $lockdir — releasing the claim"
    # The handback obeys the same asymmetry as _lock_release: a failed write does not
    # prove the directory is still this process's, because a stale-break and re-claim
    # can have landed inside the window. Anything that is not a prefix of the token just
    # attempted belongs to that successor and is left alone — one STATE_LOCK_STALE_S
    # cycle against unbounded corruption.
    #
    # rmdir rather than rm -rf makes that refusal the kernel's, not this test's. It is not
    # sufficient alone: the failed write can also leave an empty or partial owner, and then
    # rmdir refuses and this process wedges every other writer behind its own dead lock for
    # a full stale cycle — the disk-full case, the likely one. So an owner still recognisable
    # as ours is removed first, and only then is the empty directory handed back.
    local found
    found=$(_lock_owner_read "$lockdir")
    if [[ "$_LOCK_TOKEN" == "$found"* ]]; then
      rm -f "${lockdir}/owner" 2> /dev/null || true
    fi
    _LOCK_TOKEN=""
    rmdir "$lockdir" 2> /dev/null || true
    return 1
  fi
  _LOCK_HELD="1"
  return 0
}

# _lock_acquire <statepath> — returns 0 with the lock held, or 1 (proceed unlocked).
_lock_acquire() {
  local state="$1"
  local lockdir="${state}.lock.d"
  local waited=0
  _LOCK_DIR="$lockdir"
  _LOCK_HELD=""
  _LOCK_TOKEN=""
  _LOCK_WAITED=0
  while :; do
    if _lock_claim "$lockdir"; then
      return 0
    fi
    _lock_break_if_stale "$lockdir"
    # Retry immediately after a stale-break before counting against the budget.
    if _lock_claim "$lockdir"; then
      return 0
    fi
    if ((waited >= STATE_LOCK_TIMEOUT_S)); then
      _LOCK_WAITED="$waited"
      log_msg WARN "lock timeout (${waited}s ≥ ${STATE_LOCK_TIMEOUT_S}s) on $lockdir — proceeding UNLOCKED"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# _lock_release — idempotent; safe to call from the EXIT trap and inline.
#
# Removing a lock this process does not own is the defect verbatim: after a stale-break the
# directory belongs to a successor, and removing it lets a third writer in mid-write, with
# no warning on either side. The asymmetry decides it — leaving a foreign lock costs at
# most one STATE_LOCK_STALE_S cycle and self-heals, removing it costs correctness unbounded.
#
# This runs from the EXIT trap AFTER the patch is written and renamed, so it MUST NOT exit
# non-zero on the mismatch path: doing so would report a successful write as a failure,
# the absence-of-evidence inversion this contract exists to remove.
_lock_release() {
  [[ -n "${_LOCK_HELD:-}" && -n "${_LOCK_DIR:-}" && -d "$_LOCK_DIR" ]] || {
    _LOCK_HELD=""
    return 0
  }
  local found=""
  found=$(_lock_owner_read "$_LOCK_DIR")
  if [[ -z "${_LOCK_TOKEN:-}" || "$found" != "$_LOCK_TOKEN" ]]; then
    log_msg WARN "lock owner mismatch on release — refusing to remove ${_LOCK_DIR} (found: ${found:-<none>})"
    _lock_audit lock_release_foreign "lock=${_LOCK_DIR}" "expected_pid=$$" "found=${found:-none}"
    _LOCK_HELD=""
    return 0
  fi
  rm -f "${_LOCK_DIR}/owner" 2> /dev/null || true
  rmdir "$_LOCK_DIR" 2> /dev/null || rm -rf "$_LOCK_DIR" 2> /dev/null || true
  _LOCK_HELD=""
}

# Release any held lock on process end/failure (added to the existing ERR trap flow), and
# remove the staged finding on EVERY exit path — a refusal leaves the ledger untouched, so the
# one artefact a failed correction could still leave behind is that 0600 scratch file.
trap '_lock_release; _finding_cleanup' EXIT

# B3 state bounds are enforced HERE (the single write chokepoint, AD-7) rather than
# scattered across the 13 stage agents: after every mutation the unbounded arrays are
# clamped so a long run cannot grow state.json past its ~500-token budget.
#   facts.decisions          → newest 8 PER TASK (tail-newest, matching the eviction rule).
#   facts.open_questions     → newest 4 PER TASK, resolved-evicted-first WITHIN each task.
#                              4 is the contract's own per-stage emission ceiling
#                              (stage-contracts.md § Ledger bounds), so the transport bound
#                              and the emission bound are the same number and a conforming
#                              writer never spills.
#   facts.dispatched_agents  → last 6 launched survive, free slots backfilled with the
#                              newest non-launched, survivors keep original relative order.
#                              Not a per-writer field, so it keeps its global bound.
#   facts.files_read         → newest 30 GLOBAL (not per-task), a read hint rather than a
#                              record — no spill.
#
# The partition key is the FULL TASK ID (`DV1`), never the bare stage code: the writer is
# the task, and a four-way DV split is four independent writers who must not be able to
# evict one another. Questions carry that id in their own `sw-<TASK_ID>-<n>` id; decisions
# carry it in the `.stage` _FACTS_UNION_FILTER stamps from the writer's identity. An item
# with neither falls into the reserved "_" bucket, which keeps a pre-partition ledger in one
# shared bucket rather than scattering it across confident mis-attributions.
#
# `.stage` on a QUESTION keeps its bare-code meaning for the FN gate's grouping; that is a
# different job from partitioning, which is why the question's partition key is derived
# from the id (index retained) instead of read from `.stage`.
#
# Resolved-evicted-first is evaluated INSIDE each bucket. A global resolved-first pass with
# a per-bucket tail would let one task's resolved items protect another's — the cross-task
# coupling this partition exists to remove.
#
# Each clamp fires ONLY when some bucket exceeds its bound, and survivors keep their
# original positions, so a state inside the bounds is byte-identical to an unbounded merge
# (idempotency + no-op paths hold).
#
# The global ceiling is retired deliberately: worst-case size now scales with the task
# count. The backstop is validate_state's advisory token-budget warning plus the spill
# files — a loud oversized ledger beats a silently lost decision.
_STATE_BOUNDS_FILTER='
      def _task_of_decision: (.stage // "_");
      def _task_of_question:
        (([ (.id // "") | scan("^sw-([A-Za-z]+[0-9]*)-") ] | first | first)
         // (.stage // "_"));
      def _bucket_overflow(keyf; $n):
        (length > $n) and (((group_by(keyf) | map(length) | max) // 0) > $n);
      def _keep_newest_per(keyf; $n):
        . as $arr
        | [ range(0; ($arr | length)) | {i: ., k: ($arr[.] | keyf)} ]
        | group_by(.k) | map(.[-$n:]) | add | map(.i) | sort
        | [ $arr[.[]] ];
      def _keep_newest_unresolved_first(keyf; $n):
        . as $arr
        | [ range(0; ($arr | length))
            | {i: ., k: ($arr[.] | keyf),
               r: ((($arr[.].status) // "open") == "resolved")} ]
        | group_by(.k)
        | map(([ .[] | select(.r | not) ] | .[-$n:]) as $keep
              | $keep
                + ([ .[] | select(.r) ]
                   | .[ ((length - ($n - ($keep | length))) | if . < 0 then 0 else . end) : ]))
        | add | map(.i) | sort
        | [ $arr[.[]] ];
      (if ((.facts.decisions? // []) | _bucket_overflow(_task_of_decision; 8))
       then .facts.decisions |= _keep_newest_per(_task_of_decision; 8) else . end)
    | (if ((.facts.open_questions? // []) | _bucket_overflow(_task_of_question; 4))
       then .facts.open_questions |= _keep_newest_unresolved_first(_task_of_question; 4)
       else . end)
    | (if ((.facts.dispatched_agents? // []) | length) > 6
       then .facts.dispatched_agents |=
            ( to_entries
              | ([ .[] | select(.value.status == "launched") ] | .[-6:]) as $l
              | (6 - ($l | length)) as $free
              | ([ .[] | select(.value.status != "launched") ]) as $restall
              | (if $free <= 0 then [] else ($restall | .[-$free:]) end) as $r
              | ($l + $r | sort_by(.key) | map(.value)) )
       else . end)
    | (if ((.facts.files_read? // []) | length) > 30
       then .facts.files_read |= .[-30:]
       else . end)'

# `stage` and `status` are defaulted, never left null, on incumbents as well as incoming
# items: the FN gate groups unresolved items by stage and reads a missing status as
# unanswered, so a null in either renders an item nobody can attribute or act on. `stage`
# comes from the item's own id — `sw-<TASK_ID>-<n>` is the mandated shape, so the id IS the
# slot — falling back to the writing stage's code for a legacy id that predates it.
#
# open_questions unions through _union_sweep, not _union_keyed: last-writer-wins would let a
# re-emitted stub carrying `status: open` destroy an answer recorded against that id, and the
# element is the ONLY record of a sweep answer. `open < resolved` joins monotonically — a
# later write may raise, never downgrade — and the fields are guarded INDEPENDENTLY, because
# dropping the answer body is a downgrade too. `blocks_next_stage` is sticky only when the
# stub re-emits WITHOUT the key, so a rework round that drops it cannot demote a
# boundary-blocking item; an explicit `false` is the author speaking and CLEARS it. `has`,
# never truthiness, tells those apart — conflating them made `true` unclearable. Legacy
# payloads only: `--facts` requires the key. facts.decisions keeps _union_keyed.
#
# `class` is raise-only on `decision < escalate`: labellers are indistinguishable here, so
# a re-run lowering another labeller's `escalate` would route it to an unattended answer. An
# absent or null class keeps the incumbent's. A third SWEEP_CLASS_ENUM value means revisiting
# this arm. The spill incumbent is read inside the same lock as the ledger.
#
# Object-merge (`. * $patch`) REPLACES arrays, so without this a downstream patch would drop
# every entry an upstream stage recorded. Identity is `.id`, or the string itself for the
# scalar arrays. Keyed survivors move to the TAIL because _STATE_BOUNDS_FILTER keeps the
# newest 8 of each task's bucket: appending is what makes "newest survives" true, where
# unique_by would hand the clamp an arbitrary 8. Scalars keep first-seen order — no clamp
# reads them.
#
# Decisions carry no id convention, so their partition key is stamped here: `.stage` is
# defaulted from the WRITER's own task id on the INCOMING array only, before concatenation.
# Defaulting the union would re-stamp every incumbent with the current writer and
# re-attribute PL's `pd1` to whoever writes next; incumbents without a stage stay in the
# reserved "_" bucket. An explicit `.stage` from the author always wins.
_FACTS_UNION_FILTER='
      def _union_keyed(k):
        reduce .[] as $e ([]; map(select((. | k) != ($e | k))) + [$e]);
      def _union_scalar:
        reduce .[] as $e ([]; if (index($e) != null) then . else . + [$e] end);
      def _sweep_join($prev; $new):
        $new
        + (if (($prev.status // "open") == "resolved") and (($new.status // "open") != "resolved")
           then { status: "resolved" } else {} end)
        + (if ($new.resolution // null) == null and ($prev.resolution // null) != null
           then { resolution: $prev.resolution } else {} end)
        + (if ($prev.blocks_next_stage // false) == true and (($new | has("blocks_next_stage")) | not)
           then { blocks_next_stage: true } else {} end)
        + (if ($prev.class // null) == "escalate"
           then { class: "escalate" }
           elif ($new.class // null) == null and ($prev.class // null) != null
           then { class: $prev.class }
           else {} end);
      def _sweep_defaults:
        # $ARGS.named, not a bare $sweep_stage: a hard reference makes the whole
        # filter fail to COMPILE for any caller that does not pass --arg, which
        # every test extracting this text is.
        ( ([ (.id // "") | scan("^sw-([A-Za-z]+)[0-9]*-") ] | first | first)
          // (($ARGS.named.sweep_stage // "") | if . == "" then null else . end) ) as $slot
        | . + { status: (.status // "open") }
            + (if (.stage // null) == null and $slot != null
               then { stage: $slot } else {} end);
      def _dec_defaults:
        (($ARGS.named.decision_task // "") | if . == "" then null else . end) as $tid
        | (if type == "string" then {id: ("str-" + @base64), summary: .} else . end)
        | . + (if (.stage // null) == null and $tid != null
               then { stage: $tid } else {} end);
      def _union_sweep:
        reduce (.[] | _sweep_defaults) as $e ([];
          ((map(select(.id == $e.id)) | first) // null) as $ledger
          | (reduce ($ARGS.named.sweep_spill // [])[] as $s (null;
               if $s.id != $e.id then .
               elif . == null then $s
               else _sweep_join(.; $s) end)) as $spilled
          | (if $ledger != null and $spilled != null
             then _sweep_join($spilled; $ledger)
             else ($ledger // $spilled) end) as $prev
          | map(select(.id != $e.id)) + [ _sweep_join($prev; $e) ]);
      .facts = ((.facts // {})
        | (if ($f.decisions // null) != null
           then .decisions =
                (((.decisions // []) + [ $f.decisions[] | _dec_defaults ]) | _union_keyed(.id))
           else . end)
        | (if ($f.open_questions // null) != null
           then .open_questions =
                (((.open_questions // []) + $f.open_questions) | _union_sweep)
           else . end)
        | (if ($f.files_modified // null) != null
           then .files_modified = (((.files_modified // []) + $f.files_modified) | _union_scalar)
           else . end)
        | (if ($f.tests_added // null) != null
           then .tests_added = (((.tests_added // []) + $f.tests_added) | _union_scalar)
           else . end)
        | (if ($f.branch // null) != null
           then .branch = $f.branch
           else . end)
        | (if (($f.stream_branches // {}) | length) > 0
           then .stream_branches = ((.stream_branches // {}) + $f.stream_branches)
           else . end))'

# Run against the post-union state INSIDE the lock (ATOMIC_APPLY_PROBE): post `escalate` under
# a non-escalate last write for that id can only be the class arm refusing a downgrade. Emits
# the _FACTS_PARTITION_FILTER `.rejects[]` shape so one reporter serves both.
_FACTS_CLASS_REFUSAL_PROBE='
      (.facts.open_questions // []) as $post
      | [ ($f.open_questions // []) | reduce .[] as $e ({}; .[$e.id] = $e) | .[]
          | select((.class // null) != null and .class != "escalate")
          | . as $n
          | select(any($post[]; .id == $n.id and .class == "escalate"))
          | { key: "open_questions", label: $n.id,
              reason: ("class downgrade escalate -> " + ($n.class | tostring)
                       + " refused; the ledger keeps escalate — set class: escalate in your artifact stub") } ]'

# Per-item gate for --facts. Returns {fatal, clean, rejects[]}: `fatal` is a whole-payload
# refusal, `clean` carries only the items that passed, `rejects` names each dropped item and
# why. A single bad class value must not discard the entire write — decisions, changed
# files and every valid sweep stub in the same object — costing a stage work it already did.
#
# Structural problems stay whole-payload: a non-object, an empty object, an unknown key, or a
# key whose value is not an array. In those cases the caller is writing to a slot that does
# not exist or in a shape nothing can be salvaged from, so no part of it can be trusted to
# land where it was meant to. Everything item-shaped is per-item.
#
# Predicates arrive as jq arguments (never spliced into the program text) for the same reason
# the shape gate did it: a spliced regex would make the program caller-controlled.
_FACTS_PARTITION_FILTER='
      def _allowed: ["decisions","files_modified","open_questions","tests_added","branch",
                     "stream_branches"];
      def _scalar_key: . == "branch" or . == "stream_branches";
      def _label: if (type == "object") and ((.id | type) == "string")
                  then .id else (tojson[0:40]) end;
      def _oq_bad:
        if type != "object" then "not an object"
        elif (.id | type) != "string" then "missing string .id"
        elif (.class | type) != "string" then "missing string .class"
        elif (.ref | type) != "string" then "missing string .ref"
        elif (.blocks_next_stage | type) != "boolean" then "missing boolean .blocks_next_stage"
        elif ((.id | test($idre)) | not) then "id is not sw-<TASK_ID>-<n>"
        elif ((.class as $c | $classes | index($c)) == null)
          then "class is not " + ($classes | join("|"))
        elif ((.ref | test($refre)) | not)
          then "ref is not an optional <artifact>.md path plus one non-empty #anchor"
        else "" end;
      def _dec_bad:
        if type == "string" and length > 0 then ""
        elif type != "object" then "expected {id, summary, ref} or a non-empty string"
        elif (.id | type) != "string" then "expected {id, summary, ref}: missing string .id"
        else "" end;
      def _fatal($m): {fatal: $m, clean: {}, rejects: []};
      if type != "object" then _fatal("must be a JSON object")
      elif (keys | length) == 0 then _fatal("object has no keys")
      elif ((keys - _allowed) | length) > 0
        then _fatal("unknown key(s): " + ((keys - _allowed) | join(", "))
                    + " (allowed: " + (_allowed | join(", ")) + ")")
      elif ([ to_entries[] | select(.key | _scalar_key | not)
              | select((.value | type) != "array") | .key ]
            | length) > 0
        then _fatal("bad shape for "
                    + ([ to_entries[] | select(.key | _scalar_key | not)
                         | select((.value | type) != "array") | .key ] | join(", "))
                    + " (expected an array)")
      elif (has("branch"))
           and (((.branch | type) != "string") or ((.branch | test($branchre)) | not))
        then _fatal("invalid branch: expected a string matching " + $branchre)
      elif (has("stream_branches"))
           and (((.stream_branches | type) != "object")
                or ([ .stream_branches | to_entries[]
                      | select(((.key | test($streamre)) | not) or ((.key | length) > 40)
                               or ((.value | type) != "string")
                               or ((.value | test($branchre)) | not)) ] | length) > 0)
        then _fatal("invalid stream_branches: expected an object of <stream> -> <branch>, stream matching "
                    + $streamre + " (<=40 chars), branch matching " + $branchre)
      else . as $p
        | { fatal: "",
            clean:
              ( (if $p | has("decisions")
                 then {decisions: [ $p.decisions[] | select(_dec_bad == "") ]} else {} end)
              + (if $p | has("open_questions")
                 then {open_questions: [ $p.open_questions[] | select(_oq_bad == "") ]} else {} end)
              + (if $p | has("files_modified")
                 then {files_modified: [ $p.files_modified[] | select(type == "string") ]} else {} end)
              + (if $p | has("tests_added")
                 then {tests_added: [ $p.tests_added[] | select(type == "string") ]} else {} end)
              + (if $p | has("branch") then {branch: $p.branch} else {} end)
              + (if $p | has("stream_branches")
                 then {stream_branches: $p.stream_branches} else {} end) ),
            rejects:
              ( [ ($p.decisions // [])[] | select(_dec_bad != "")
                  | {key: "decisions", label: _label, reason: _dec_bad} ]
              + [ ($p.open_questions // [])[] | select(_oq_bad != "")
                  | {key: "open_questions", label: _label, reason: _oq_bad} ]
              + [ ($p.files_modified // [])[] | select(type != "string")
                  | {key: "files_modified", label: (tojson[0:40]), reason: "not a string"} ]
              + [ ($p.tests_added // [])[] | select(type != "string")
                  | {key: "tests_added", label: (tojson[0:40]), reason: "not a string"} ] ) }
      end'

# Items a bounds clamp evicted are appended to `.context/<file>-<run_index>.jsonl` before
# the rename, so the eviction leaves a record the ledger no longer has room for.  The
# question spill is read by the FN gate, which can still render a dropped question; the
# decision spill is read by `--read-decisions`, the documented path for anyone asking what
# this run decided. Neither is write-only: a record with no reader is a record that loses
# items in silence, which is what both of these were built after.
#
# ADDITIVE around _STATE_BOUNDS_FILTER, which is deliberately NOT edited: the spill is the
# set difference (pre-clamp − post-clamp) by `.id`, computed by re-evaluating the caller's
# filter without the bounds tail.  The ordering jq is untouched, so it cannot regress, and
# output is byte-identical for any state in which no bucket overflows.
#
# Ordered before the rename on purpose: a crash can then leave a spill line whose eviction
# never committed — a duplicate the union collapses — but never an eviction whose spill line
# is missing, which would be loss.  Append-only, never rewritten, never deduped on write.
# Every failure here is swallowed: a spill that cannot be written must not undo a merge.
#
# _spill_evicted_items <state> <tmp> <merged-json> <field> <file-stem> <annotate-resolved>
_spill_evicted_items() {
  local state="$1" tmp="$2" merged="$3" field="$4" stem="$5" annotate="$6"

  # Trigger on pre > post, never on the clamp's literal bound: hard-coding 12 made the
  # spill die silently the moment the bound moved. An empty post-clamp array cannot have
  # evicted anything, which keeps the common path at one cheap length query.
  local post_len pre_len
  post_len=$(jq -r --arg f "$field" '(.facts[$f]? // []) | length' "$tmp" 2> /dev/null || printf '0')
  [[ "$post_len" -gt 0 ]] || return 0
  pre_len=$(printf '%s' "$merged" | jq -r --arg f "$field" '(.facts[$f]? // []) | length' 2> /dev/null || printf '0')
  [[ "$pre_len" -gt "$post_len" ]] || return 0

  # Attribution, in the order the writer's own identity becomes known: parsed frontmatter,
  # then --stage, then the code behind --task-id (the only identity a standalone --facts call has).
  local from_stage
  from_stage="${PARSED_STAGE:-${STAGE_ARG:-${SWEEP_STAGE_FALLBACK:-}}}"
  [[ -n "$from_stage" ]] || from_stage="unknown"

  local run_idx spill_dir spill_path spilled
  run_idx=$(jq -r '.run_index // 0' "$tmp" 2> /dev/null || printf '0')
  spill_dir="${state%/*}"
  [[ "$spill_dir" == "$state" ]] && spill_dir="."
  spill_path="${spill_dir}/${stem}-${run_idx}.jsonl"

  # EVERY eviction spills, resolved ones included, flagged by `was_resolved`. Filtering
  # answered items out destroyed the one field the sweep exists to produce and inverted the
  # incentive: answering a question was what made it disappear without a trace. The flag is
  # sweep-only — a decision has no resolution status to record.
  spilled=$(printf '%s' "$merged" \
    | jq -c --slurpfile post "$tmp" \
           --arg ts "$(date -u +%FT%TZ)" \
           --arg from "$from_stage" \
           --arg f "$field" \
           --argjson annotate "$annotate" '
        ((($post[0].facts[$f]) // []) | map(.id)) as $keep
        | (.facts[$f] // [])
        | map(select(([.id] - $keep) | length > 0))
        | map(. + {spilled_at: $ts, spilled_from_stage: $from}
                + (if $annotate
                   then {was_resolved: ((.status // "open") == "resolved")} else {} end))
        | .[]' 2> /dev/null) || {
    # A failed spill computation must not `return 0` silently — that reads as "nothing was
    # evicted" when items may in fact be lost, so this warns instead.
    log_msg WARN "${field} spill computation failed; up to $((pre_len - post_len)) evicted item(s) may be unrecorded (merge unaffected)"
    printf >&2 'warn: %s spill computation failed; up to %d evicted item(s) unrecorded\n' \
      "$field" "$((pre_len - post_len))"
    return 0
  }

  [[ -n "$spilled" ]] || return 0
  local spill_n
  spill_n=$(printf '%s' "$spilled" | grep -c '^')
  # The INFO line is CONDITIONAL on the append. Logged unconditionally it contradicted the WARN
  # two lines above and recorded a spill that never reached the file — a write that landed
  # nothing, indistinguishable from one that landed. Stderr as well as the log, matching the
  # computation-failure arm above: log_msg writes only to $LOG_FILE, so a log-only warning is
  # silent at the call site, which is where the loss has to be visible.
  if printf '%s\n' "$spilled" >> "$spill_path" 2> /dev/null; then
    log_msg INFO "spilled ${spill_n} evicted ${field} item(s) to ${spill_path}"
  else
    log_msg WARN "${field} spill append failed for ${spill_path}; ${spill_n} evicted item(s) unrecorded (merge unaffected)"
    printf >&2 'warn: %s spill append to %s failed; %d evicted item(s) unrecorded\n' \
      "$field" "$spill_path" "$spill_n"
  fi
}

# Both rings spill through one seam. The pre-clamp merge is computed ONCE here and handed to
# each ring, so a two-field spill costs one extra jq rather than two.
#
# _spill_evicted <state> <tmp> <filter> [jq-args...]
_spill_evicted() {
  local state="$1" tmp="$2" filter="$3"
  shift 3
  local populated merged
  populated=$(jq -r '((.facts.open_questions? // []) | length) + ((.facts.decisions? // []) | length)' \
    "$tmp" 2> /dev/null || printf '0')
  [[ "$populated" -gt 0 ]] || return 0
  merged=$(jq "$@" "( ${filter} )" "$state" 2> /dev/null) || {
    log_msg WARN "eviction spill: pre-clamp re-evaluation failed; evictions (if any) unrecorded (merge unaffected)"
    return 0
  }
  _spill_evicted_items "$state" "$tmp" "$merged" open_questions open-questions true
  _spill_evicted_items "$state" "$tmp" "$merged" decisions decisions false
}

# Atomic state.json mutation (read → apply → temp → fsync → rename), serialized by the
# mkdir-spinlock so concurrent sibling writers cannot drop a patch.
#
# atomic_apply <state> <jq-filter> [jq-args...]
#
# The filter is evaluated against the file contents INSIDE the lock. Read-modify-write ops
# (blocked_by union/subtraction) MUST come through here rather than precomputing from an
# unlocked read: a pre-lock read races a sibling writer and silently drops its edges.
#
# Opt-in observer: an internal caller that sets ATOMIC_APPLY_PROBE (jq text, same args) gets its
# output over the about-to-commit state in ATOMIC_APPLY_PROBE_OUT. A probe failure only
# loses the report, never the write.
atomic_apply() {
  local state="$1" filter="$2"
  shift 2
  ATOMIC_APPLY_PROBE_OUT=""
  # `${state%/*}` returns $state unchanged when the path has no directory component,
  # so a bare `--state state.json` derived `state.json/.state.json….tmp` — ENOTDIR,
  # and every ledger op failed with the file untouched. Same guard the spill path
  # below already carries; the two derivations must agree.
  local dir="${state%/*}"
  [ "$dir" = "$state" ] && dir="."
  local tmp="${dir}/.state.json.$$.${RANDOM}.tmp"

  # Acquire the lock around the whole read-apply-rename window (timeout ⇒ unlocked+WARN).
  # The result is NOT discarded: afterwards an unserialized write is indistinguishable from
  # a clean one unless it is recorded where an audit sweep can find it, and the WARN goes to
  # a plain log nothing sweeps.
  if ! _lock_acquire "$state"; then
    _lock_audit state_write_unlocked "lock=${state}.lock.d" "waited_s=${_LOCK_WAITED:-0}" "reason=timeout"
  fi

  if [[ -n "${_FACTS_SPILL_PATH:-}" ]]; then
    local sweep_spill='[]'
    if [[ -e "$_FACTS_SPILL_PATH" || -L "$_FACTS_SPILL_PATH" ]]; then
      if [[ ! -f "$_FACTS_SPILL_PATH" || -L "$_FACTS_SPILL_PATH" || ! -r "$_FACTS_SPILL_PATH" ]] \
        || ! sweep_spill=$(jq -sc 'if all(.[]; type == "object" and (.id | type) == "string")
          then . else error("invalid sweep spill") end' "$_FACTS_SPILL_PATH" 2>> "$LOG_FILE"); then
        printf >&2 'invalid --facts: sweep spill unreadable or malformed; state.json unchanged\n'
        log_msg ERROR "sweep spill unreadable or malformed; facts union refused"
        _lock_release
        return 1
      fi
    fi
    set -- "$@" --argjson sweep_spill "$sweep_spill"
  fi

  local rc=0
  if jq "$@" "( ${filter} ) | ${_STATE_BOUNDS_FILTER}" "$state" > "$tmp" 2>> "$LOG_FILE"; then
    _spill_evicted "$state" "$tmp" "$filter" "$@"
    if [[ -n "${ATOMIC_APPLY_PROBE:-}" ]]; then
      ATOMIC_APPLY_PROBE_OUT=$(jq -c "$@" "$ATOMIC_APPLY_PROBE" "$tmp" 2>> "$LOG_FILE") || {
        ATOMIC_APPLY_PROBE_OUT=""
        printf >&2 'warn: atomic apply probe failed; merge unaffected\n'
        log_msg WARN "atomic apply probe failed; merge unaffected"
      }
    fi
    sync "$tmp" 2> /dev/null || sync 2> /dev/null || true
    mv -f "$tmp" "$state"
    rc=0
  else
    rm -f "$tmp" 2> /dev/null || true
    rc=1
  fi

  _lock_release
  return "$rc"
}

# A stage completing with sweep ids in its artifact that the ledger does not hold has lost
# them — to a clamp, to a swallowed rejection, or to a --facts call that was never made.
# Left unchecked, the loss would surface later, at the harness's parity arm, as a whole boundary.
#
# Runs AFTER the merge, against the WRITTEN state. The same invocation routinely carries
# --facts, so a pre-write comparison false-warns on every correct combined call — the exact
# false-positive class this check exists to remove. Warns to the log AND stderr, because
# log_msg writes only to $LOG_FILE and the call site is where the loss has to be visible.
# It NEVER moves the exit code: a warning that did would break every `set -e` caller.
#
# The id shape is schema-pinned, so a grep over the frontmatter slice is enough and this
# script gains no yq dependency.
#
# Compared against ledger ∪ spill, the union check_sweep_ledger and the FN gate read: an id
# the clamp evicted to `open-questions-<run_index>.jsonl` is recorded, not lost. A missing
# or unreadable spill contributes the empty set.
#
# _warn_unledgered_sweep_ids <artifact> <state>
_warn_unledgered_sweep_ids() {
  local artifact="$1" state="$2"
  [[ -f "$artifact" && -f "$state" ]] || return 0
  command -v jq > /dev/null 2>&1 || return 0

  local declared missing spill_dir run_idx spill_path spilled_ids
  declared=$(awk 'NR == 1 && $0 !~ /^---[[:space:]]*$/ { exit }
                  NR > 1 && /^---[[:space:]]*$/ { exit }
                  NR > 1 { print }' "$artifact" 2> /dev/null \
    | grep -oE 'sw-[A-Za-z]+[0-9]*-[0-9]+' | sort -u || true)
  [[ -n "$declared" ]] || return 0

  run_idx=$(jq -r '.run_index // 0' "$state" 2> /dev/null || printf '0')
  spill_dir="${state%/*}"
  [[ "$spill_dir" == "$state" ]] && spill_dir="."
  spill_path="${spill_dir}/open-questions-${run_idx}.jsonl"
  spilled_ids="[]"
  if [[ -f "$spill_path" && ! -L "$spill_path" ]]; then
    spilled_ids=$(jq -c -s 'map(.id? // empty)' "$spill_path" 2> /dev/null || printf '[]')
  fi

  missing=$(printf '%s\n' "$declared" \
    | jq -Rsr --slurpfile st "$state" --argjson spilled "$spilled_ids" '
      (split("\n") | map(select(length > 0))) as $want
      | (((($st[0].facts.open_questions) // []) | map(.id)) + $spilled) as $have
      | ($want - $have) | join(", ")' 2> /dev/null || printf '')
  [[ -n "$missing" ]] || return 0
  log_msg WARN "sweep ids declared by ${artifact} are absent from the ledger: ${missing}"
  printf >&2 'warn: %s declares sweep id(s) the ledger does not hold: %s\n' "$artifact" "$missing"
}

# _post_success <default-task-id> <touched-ids,comma-separated> <edge-key|""> <facts 0|1>
#
# The one tail every successful write (or idempotent no-op) passes through when the caller
# asked for --audit-row or --digest. Rows go in AFTER the main op, never before: a refused
# op must leave no row claiming it happened. A row that fails to append exits 1 — the
# ledger write stands, but a caller that asked for the row must not read success.
#
# The digest is read back from the WRITTEN ledger, not echoed from the arguments, so a
# stage agent can trust it in place of re-reading state.json. Capped at 12 lines; a long
# task list collapses its tail into one `tasks +N more` line.
_post_success() {
  local def_tid="$1" touched="$2" edge="$3" facts="$4"
  local n=0 i=0 failed=0 fields actor action result subject tid meta adir
  if [[ -n "$AUDIT_ROWS_JSON" ]]; then
    n=$(jq -r 'length' <<< "$AUDIT_ROWS_JSON")
    adir="${STATE_PATH%/*}"
    [[ "$adir" == "$STATE_PATH" ]] && adir="."
    while [[ "$i" -lt "$n" ]]; do
      fields=$(jq -r --argjson i "$i" --arg d "${def_tid:-unknown}" \
        '.[$i] | [.actor, .action, .result, .subject, (.task_id // $d), (.metadata | tojson)]
         | join("\u001f")' <<< "$AUDIT_ROWS_JSON")
      IFS=$'\037' read -r actor action result subject tid meta <<< "$fields" || true
      corpflow_audit_row --file "${adir}/logs/audit.jsonl" --actor "$actor" \
        --action "$action" --result "$result" --subject "$subject" --task-id "$tid" --meta "$meta"
      [[ "${CORPFLOW_AUDIT_LAST_RC:-1}" -eq 0 ]] || failed=$((failed + 1))
      i=$((i + 1))
    done
    if [[ "$failed" -gt 0 ]]; then
      printf >&2 '%d of %d --audit-row row(s) not recorded; the ledger write stands\n' "$failed" "$n"
      log_msg ERROR "--audit-row: ${failed} of ${n} row(s) not recorded (ledger write already applied)"
      exit 1
    fi
    log_msg INFO "--audit-row: ${n} row(s) appended"
  fi
  [[ -n "$DIGEST_FLAG" ]] || return 0
  { cat "$STATE_PATH" 2> /dev/null || printf 'null'; } \
    | jq -r --arg ids "$touched" --arg edge "$edge" --arg facts "$facts" --argjson audit "$n" '
      (. // {}) as $st
      | ($ids | split(",") | map(select(length > 0))) as $ids
      | ([$edge != "", $facts == "1", $audit > 0] | map(select(.)) | length) as $extra
      | (11 - $extra) as $budget
      | [ $ids[] as $id | ($st.tasks[$id] // null) as $t
          | ([$id, (if $t == null then "absent" else ($t.status // "unknown") end)]
             + ([["agent", $t.metadata.agent?], ["model", $t.metadata.model?]]
                | map(select(.[1] != null and (.[1] | tostring) != "")
                      | .[0] + "=" + (.[1] | tostring))))
          | join(" ") ] as $rows
      | (if ($rows | length) > $budget
         then $rows[0:($budget - 1)] + ["tasks +\(($rows | length) - $budget + 1) more"]
         else $rows end) as $rows
      | ["state-patch ok"] + $rows
        + (if $edge != "" then ["edge " + $edge] else [] end)
        + (if $facts == "1"
           then ["facts decisions=\(($st.facts.decisions // []) | length) open_questions=\(($st.facts.open_questions // []) | length) files_modified=\(($st.facts.files_modified // []) | length)"]
           else [] end)
        + (if $audit > 0 then ["audit +\($audit)"] else [] end)
      | .[]' 2>> "$LOG_FILE" || log_msg WARN "--digest: ledger read-back failed; write already applied"
}

# ---------- Argument parsing ----------
STAGE_ARG=""
ARTIFACT_ARG=""
PREV_ARG=""
STATE_PATH=""
STATE_ARG_GIVEN=""
LOG_FILE=""
LOG_ARG_GIVEN=""
DISK_CHECK_ROOT=""
VIA_ARG=""
ALLOW_MISSING_ARTIFACT=""
TASK_ID_ARG=""
TASK_OP=""
LEDGER_META_OP=""
RESOLVE_MODELS_OP=""
RESOLVE_MODELS_CORPFLOW_ARG=""
TASK_OP_ID=""
TASK_OP_VALUE=""
RESOLVE_CODE_ARG=""
READ_DECISIONS=""
VERIFY_DECISION_ID=""
VERIFY_EXPECT=""
VERIFY_EXPECT_GIVEN=""
FACTS_ARG=""
REPLAY_CASCADE="false"
RAISE_ONLY_FLAG=""
UNSET_KEYS=""
UNSET_GIVEN=""
DESC_TRUNCATED=""
AGENTS_JSON_ARG=""
DISPATCH_AGENT_ID=""
DISPATCH_STATUS=""
DISPATCH_ARGC=0
FILES_READ_PATHS=()
REOPEN_FROM=""
REOPEN_FROM_GIVEN=""
FINDING_FILE=""
FINDING_FILE_GIVEN=""
SETTLE_CHANGED=""
SETTLE_CHANGED_GIVEN=""
SETTLE_PLAN=""
DIGEST_FLAG=""
# Batched --task-create: parallel arrays, one slot per --task-create, so a --metadata binds to
# the row it follows rather than overwriting the single TASK_OP_VALUE every op shares.
TC_IDS=()
TC_METAS=()
TC_PRE_META=""
OTHER_TASK_OP_SEEN=""
AUDIT_ROWS=()
AUDIT_ROWS_JSON=""
DIGEST_TOUCHED=""

while [[ $# -gt 0 ]]; do
  # One line per flag. Every value-taking arm was the same five lines —
  # `shift`, assign `${1:-}`, `shift` — repeated eleven times, which made the
  # two arms that are NOT that shape (--disk-check's optional value and
  # --self-test's guarded source) invisible in the scroll.
  case "$1" in
    --stage) shift; STAGE_ARG="${1:-}"; shift ;;
    --artifact) shift; ARTIFACT_ARG="${1:-}"; shift ;;
    --prev) shift; PREV_ARG="${1:-}"; shift ;;
    --state) shift; STATE_PATH="${1:-}"; STATE_ARG_GIVEN="1"; shift ;;
    --log) shift; LOG_FILE="${1:-}"; LOG_ARG_GIVEN="1"; shift ;;
    --disk-check)
      shift
      # Optional root value: consume the next token only when it is NOT another flag.
      if [[ $# -gt 0 && "${1:-}" != -* ]]; then
        DISK_CHECK_ROOT="$1"
        shift
      else
        DISK_CHECK_ROOT="."
      fi
      ;;
    --via) shift; VIA_ARG="${1:-}"; shift ;;
    --allow-missing-artifact) ALLOW_MISSING_ARTIFACT="1"; shift ;;
    --facts) shift; FACTS_ARG="${1:-}"; shift ;;
    --task-id) shift; TASK_ID_ARG="${1:-}"; shift ;;
    --verify-decision) shift; VERIFY_DECISION_ID="${1:-}"; shift ;;
    --expect-answer) shift; VERIFY_EXPECT="${1:-}"; VERIFY_EXPECT_GIVEN="1"; shift ;;
    --task-create)
      shift
      # The first id stays TASK_OP_ID so a single --task-create runs exactly the legacy path;
      # every later id only accumulates.
      if [[ "${#TC_IDS[@]}" -eq 0 ]]; then
        TASK_OP_ID="${1:-}"
        if [[ -n "$TASK_OP_VALUE" ]]; then TC_PRE_META="1"; fi
      fi
      TASK_OP="create"
      TC_IDS+=("${1:-}")
      TC_METAS+=("")
      if [[ $# -gt 0 ]]; then shift; fi
      ;;
    --task-status) shift; TASK_OP="status"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift; TASK_OP_VALUE="${1:-}"; shift ;;
    --task-block) shift; TASK_OP="block"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --task-unblock) shift; TASK_OP="unblock"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --task-meta) shift; TASK_OP="meta"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --ledger-meta) shift; LEDGER_META_OP="1" ;;
    --resolve-models) shift; RESOLVE_MODELS_OP="1" ;;
    --raise-only) RAISE_ONLY_FLAG="1"; shift ;;
    --unset) shift; UNSET_KEYS="${1:-}"; UNSET_GIVEN="1"; shift ;;
    --corpflow) shift; RESOLVE_MODELS_CORPFLOW_ARG="${1:-}"; shift ;;
    --task-replay) shift; TASK_OP="replay"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --task-reopen) shift; TASK_OP="reopen"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --task-settle-stale) shift; TASK_OP="settle_stale"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    # --from is the correction's SOURCE task, not a path; --finding-file takes `-` for stdin.
    # Both are tracked as "given" separately from their value so an empty value reaches the
    # op's own refusal rather than reading as absent.
    --from) shift; REOPEN_FROM="${1:-}"; REOPEN_FROM_GIVEN="1"; shift ;;
    --finding-file) shift; FINDING_FILE="${1:-}"; FINDING_FILE_GIVEN="1"; shift ;;
    --changed) shift; SETTLE_CHANGED="${1:-}"; SETTLE_CHANGED_GIVEN="1"; shift ;;
    --claim) shift; TASK_OP="claim"; OTHER_TASK_OP_SEEN="1"; TASK_OP_ID="${1:-}"; shift ;;
    --dispatch)
      shift
      TASK_OP="dispatch"
      OTHER_TASK_OP_SEEN="1"
      # Consume up to the next --flag rather than a fixed shift*3: a short call (missing
      # agent_id or status) must fall through to the argc check below as malformed, not
      # crash on an out-of-range shift.
      _DISPATCH_ARGS=()
      while [[ $# -gt 0 && "$1" != --* ]]; do
        _DISPATCH_ARGS+=("$1")
        shift
      done
      DISPATCH_ARGC="${#_DISPATCH_ARGS[@]}"
      TASK_OP_ID="${_DISPATCH_ARGS[0]:-}"
      DISPATCH_AGENT_ID="${_DISPATCH_ARGS[1]:-}"
      DISPATCH_STATUS="${_DISPATCH_ARGS[2]:-}"
      ;;
    --files-read)
      shift
      TASK_OP="files_read"
      OTHER_TASK_OP_SEEN="1"
      TASK_OP_ID="${1:-}"
      [[ $# -gt 0 ]] && shift
      # Same "consume to the next --flag" shape as --dispatch; unlike --dispatch this list is
      # unbounded, so the count is validated in the op arm rather than here.
      FILES_READ_PATHS=()
      while [[ $# -gt 0 && "$1" != --* ]]; do
        FILES_READ_PATHS+=("$1")
        shift
      done
      ;;
    --ack)
      shift
      TASK_OP="ack"
      OTHER_TASK_OP_SEEN="1"
      # Consumed like --dispatch so a short or long call reaches the argc check as exit 2.
      _ACK_ARGS=()
      while [[ $# -gt 0 && "$1" != --* ]]; do
        _ACK_ARGS+=("$1")
        shift
      done
      ACK_ARGC="${#_ACK_ARGS[@]}"
      TASK_OP_ID="${_ACK_ARGS[0]:-}"
      ACK_MSG_ID="${_ACK_ARGS[1]:-}"
      ;;
    --cascade) REPLAY_CASCADE="true"; shift ;;
    --agents-json) shift; AGENTS_JSON_ARG="${1:-}"; shift ;;
    --metadata)
      shift
      TASK_OP_VALUE="${1:-}"
      if [[ "${#TC_IDS[@]}" -gt 0 ]]; then TC_METAS[${#TC_IDS[@]} - 1]="${1:-}"; fi
      shift
      ;;
    --on | --off | --set) shift; TASK_OP_VALUE="${1:-}"; shift ;;
    --digest) DIGEST_FLAG="1"; shift ;;
    --audit-row) shift; AUDIT_ROWS+=("${1:-}"); shift ;;
    --resolve-task-id) shift; RESOLVE_CODE_ARG="${1:-}"; shift ;;
    --read-decisions) READ_DECISIONS="1"; shift ;;
    --self-test)
      # Sourced HERE, not at the top: the harness is ~1k lines the ledger-write
      # path never runs. `[ -r ]` first, not a bare `.`: sourcing a missing file
      # with the `.` builtin is a special-builtin error that exits the shell
      # immediately, bypassing an `if ! . …` guard entirely.
      SELFTEST_LIB_PATH="$(dirname "$0")/state-patch-selftest.sh"
      if [ -r "$SELFTEST_LIB_PATH" ]; then
        # shellcheck source=state-patch-selftest.sh
        # shellcheck disable=SC1090
        . "$SELFTEST_LIB_PATH"
      else
        printf >&2 'state-patch: self-test harness unreachable at %s — plugin install broken\n' \
          "$SELFTEST_LIB_PATH"
        exit 2
      fi
      run_self_test
      ;;
    -h | --help) usage ;;
    *)
      printf >&2 'unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

# ---------- Batch / audit-row / digest validation ----------
# Runs before the root ladder and every write, so a malformed batch or audit row costs
# nothing but the exit code: state.json and audit.jsonl are never touched.
if [[ "${#TC_IDS[@]}" -gt 1 ]]; then
  if [[ -n "$OTHER_TASK_OP_SEEN" ]]; then
    printf >&2 -- 'batched --task-create cannot be combined with another ledger op; issue them separately\n'
    exit 2
  fi
  # In a batch each --metadata belongs to the --task-create before it; one that precedes
  # every id has no row, and guessing would seed metadata onto the wrong task.
  if [[ -n "$TC_PRE_META" ]]; then
    printf >&2 -- '--metadata before the first --task-create binds to no row in a batch\n'
    exit 2
  fi
fi

# Ops that already own stdout keep it byte-stable: a digest appended to a line the caller
# parses as JSON would break that parse.
if [[ -n "$VERIFY_DECISION_ID" || -n "$RESOLVE_CODE_ARG" || -n "$READ_DECISIONS" \
  || "$TASK_OP" == "settle_stale" ]]; then
  DIGEST_FLAG=""
fi

if [[ "${#AUDIT_ROWS[@]}" -gt 0 ]]; then
  if [[ -n "$VERIFY_DECISION_ID" || -n "$RESOLVE_CODE_ARG" || -n "$READ_DECISIONS" \
    || -n "$LEDGER_META_OP" || -n "$RESOLVE_MODELS_OP" || "$TASK_OP" == "ack" ]]; then
    printf >&2 -- '--audit-row does not compose with this op (read-only, --ack, --ledger-meta or --resolve-models)\n'
    exit 2
  fi
  command -v jq > /dev/null 2>&1 || {
    printf >&2 -- '--audit-row needs jq; nothing written\n'
    exit 2
  }
  # Probed before the main op, not after it: a broken install must refuse the whole call
  # rather than land the ledger write and then lose the rows that were to describe it.
  _AR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
  if ! command -v corpflow_audit_row > /dev/null 2>&1 && [ -r "$_AR_LIB" ]; then
    # shellcheck source=../../shared/lib/audit-lib.sh
    . "$_AR_LIB"
  fi
  if ! command -v corpflow_audit_row > /dev/null 2>&1; then
    printf >&2 -- '--audit-row refused: audit lib unreachable at %s; nothing written\n' "$_AR_LIB"
    exit 2
  fi
  # Control bytes are refused in the scalar fields because _post_success splits each row
  # on US in one jq read; metadata travels as compact JSON, which escapes them.
  _AR_FILTER='
    if length != 1 then error("expected exactly one JSON object") else .[0] end
    | if type != "object" then error("not a JSON object") else . end
    | (keys - ["action","result","subject","actor","metadata","task_id"]) as $extra
    | if ($extra | length) > 0 then error("unknown key(s): " + ($extra | join(","))) else . end
    | reduce ("action","result","subject") as $k (.;
        if (.[$k] | type) != "string" or .[$k] == "" then error($k + " must be a non-empty string")
        else . end)
    | if has("actor") and (((.actor | type) != "string") or .actor == "")
      then error("actor must be a non-empty string") else . end
    | if has("metadata") and ((.metadata | type) != "object")
      then error("metadata must be an object") else . end
    | if has("task_id") and (((.task_id | type) != "string") or ((.task_id | test($idre)) | not))
      then error("task_id must match <STAGE><N>") else . end
    | if [.action, .result, .subject, (.actor // "")] | any(test("[[:cntrl:]]"))
      then error("control character in a scalar field") else . end
    | {action, result, subject, actor: (.actor // "corpflow:unknown"), metadata: (.metadata // {})}
      + (if has("task_id") then {task_id} else {} end)'
  AUDIT_ROWS_JSON="[]"
  for _AR_RAW in "${AUDIT_ROWS[@]}"; do
    # The fallback sits inside the substitution: a parse failure there would otherwise
    # fire the ERR trap from the subshell before the refusal below names the defect.
    _AR_ROW=$(printf '%s' "$_AR_RAW" | jq -cs \
      --arg idre '^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$' \
      "try (${_AR_FILTER}) catch {__err: .}" 2> /dev/null || printf '{"__err":"not valid JSON"}')
    [[ -n "$_AR_ROW" ]] || _AR_ROW='{"__err":"not valid JSON"}'
    _AR_ERR=$(jq -r '.__err // empty' <<< "$_AR_ROW")
    if [[ -n "$_AR_ERR" ]]; then
      printf >&2 'invalid --audit-row: %s; nothing written\n' "$_AR_ERR"
      exit 2
    fi
    AUDIT_ROWS_JSON=$(jq -c --argjson r "$_AR_ROW" '. + [$r]' <<< "$AUDIT_ROWS_JSON")
  done
fi

# ---------- Root ladder ----------
# --state is verbatim and caller-trusted. Without it the writer ladder in state-read-lib.sh
# (CONTEXT_DIR, WORKSPACE_ROOT, CLAUDE_PROJECT_DIR, git toplevel of $PWD, $PWD/.context)
# picks the directory. Nothing derives from this script's own location, and no
# main-worktree recovery is tried: a workdir nested inside another checkout, such as a
# benchmark arm under the plugin's own repo, would otherwise be handed that checkout's live
# ledger.
#
# Only the inferred ranks are policed against the plugin root. --state, CONTEXT_DIR,
# WORKSPACE_ROOT and CLAUDE_PROJECT_DIR are explicit caller signals and are trusted even when
# they point inside it: a plugin developed with itself, run from its own checkout, legitimately
# keeps its ledger there.

# _sp_refuse_plugin_root <ctx-dir> — exit 4 when a ledger dir INFERRED from the cwd lies
# inside the plugin's own install/checkout, unless the caller is standing at the git toplevel
# itself (running the plugin from its own repo root). A nested subdirectory such as a benchmark
# workdir would otherwise be handed the checkout's live ledger, and a non-git cwd under the
# plugin root would write into the plugin tree; failing loudly beats a silent write into the
# wrong project. Both the root this script lives in and the host-reported root count, because a
# dev checkout and an installed copy are different trees.
_sp_refuse_plugin_root() {
  # The rule itself is corpflow_inferred_ctx_ok (state-read-lib.sh), shared with the readers.
  corpflow_inferred_ctx_ok "$1" && return 0
  printf >&2 'state-patch.sh: refusing ledger dir %s — inferred from the cwd, and it lies inside the plugin root\n' "$1"
  printf >&2 'state-patch.sh: run from the project directory, or pass --state / set CONTEXT_DIR to its .context\n'
  exit 4
}

if [[ -z "$STATE_ARG_GIVEN" ]]; then
  _SRL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/state-read-lib.sh"
  if [ ! -r "$_SRL_LIB" ]; then
    printf >&2 'state-patch.sh: plugin install broken — state-read-lib.sh not found at %s\n' "$_SRL_LIB"
    exit 2
  fi
  # shellcheck source=../../shared/lib/state-read-lib.sh
  . "$_SRL_LIB"
  _CTX_DIR="$(corpflow_context_dir_write)"
  if [[ -z "${CONTEXT_DIR:-}" && -z "${WORKSPACE_ROOT:-}" && -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
    _sp_refuse_plugin_root "$_CTX_DIR"
  fi
  STATE_PATH="${_CTX_DIR}/state.json"
fi

if [[ -z "$STATE_PATH" ]]; then
  CTX=""
else
  CTX="${STATE_PATH%/*}"
  [[ "$CTX" == "$STATE_PATH" ]] && CTX="."
fi

# The default log follows the ledger, but only once that directory exists or this call is
# the one that seeds it: the ladder now always resolves, so an unconditional default would
# leave a stray .context/logs behind every no-op call made from an arbitrary cwd.
if [[ -z "$LOG_ARG_GIVEN" ]]; then
  if [[ -d "$CTX" || "$TASK_OP" == "create" ]]; then
    LOG_FILE="${CTX}/logs/state-merge.log"
  else
    LOG_FILE="/dev/null"
  fi
fi

# ---------- --verify-decision (read-only; dispatched before pre-flight so this op takes no
# lock, writes no log and touches no audit row — LOG_FILE is forced to /dev/null even though
# --log may have been given, so a caller cannot accidentally make a read-only op write one) ----
if [[ -n "$VERIFY_DECISION_ID" ]]; then
  LOG_FILE="/dev/null"
  if [[ -z "$TASK_ID_ARG" ]]; then
    printf >&2 'state-patch.sh --verify-decision requires --task-id <ID>\n'
    exit 2
  fi
  if [[ -z "$STATE_PATH" ]]; then
    printf >&2 'state-patch.sh --verify-decision: no ledger resolved\n'
    exit 2
  fi
  if [[ -f "$STATE_PATH" ]] && command -v jq > /dev/null 2>&1; then
    _VD_VER=$(jq -r '.version // empty' "$STATE_PATH" 2> /dev/null) || _VD_VER=""
    if [[ -n "$_VD_VER" && "$_VD_VER" != "2" ]]; then
      printf >&2 'state-patch.sh --verify-decision: ledger version %s unsupported (expected 2)\n' "$_VD_VER"
      exit 2
    fi
  fi
  command -v jq > /dev/null 2>&1 || {
    printf >&2 'state-patch.sh --verify-decision: jq is required\n'
    exit 2
  }
  _VD_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib"
  _VD_LIB="$_VD_LIBDIR/user-decision-lib.sh"
  if [[ ! -r "$_VD_LIB" ]]; then
    printf >&2 'state-patch.sh --verify-decision: plugin install broken — user-decision-lib.sh not found at %s\n' "$_VD_LIB"
    exit 2
  fi
  # shellcheck source=../../../hooks/lib/user-decision-lib.sh
  . "$_VD_LIB"
  command -v ud_verify > /dev/null 2>&1 || {
    printf >&2 'state-patch.sh --verify-decision: user-decision-lib.sh loaded without ud_verify\n'
    exit 2
  }
  _VD_CTX="${STATE_PATH%/*}"
  [[ "$_VD_CTX" == "$STATE_PATH" ]] && _VD_CTX="."
  _VD_LEDGER="$_VD_CTX/decisions.jsonl"
  _VD_AUDIT="$_VD_CTX/logs/audit.jsonl"
  _VD_RC=0
  if [[ -n "$VERIFY_EXPECT_GIVEN" ]]; then
    ud_verify "$STATE_PATH" "$_VD_LEDGER" "$_VD_AUDIT" "$VERIFY_DECISION_ID" "$TASK_ID_ARG" "$VERIFY_EXPECT" || _VD_RC=$?
  else
    ud_verify "$STATE_PATH" "$_VD_LEDGER" "$_VD_AUDIT" "$VERIFY_DECISION_ID" "$TASK_ID_ARG" || _VD_RC=$?
  fi
  if [[ "$_VD_RC" -eq 0 ]]; then
    exit 0
  elif [[ "$_VD_RC" -eq 1 ]]; then
    exit 5
  else
    exit 2
  fi
fi

# ---------- Pre-flight ----------
[[ "$LOG_FILE" == "/dev/null" ]] || mkdir -p "$(dirname "$LOG_FILE")" 2> /dev/null || true

# Validate --via (enum hook|step6_5). An unknown value is a caller bug — surface it.
if [[ -n "$VIA_ARG" && "$VIA_ARG" != "hook" && "$VIA_ARG" != "step6_5" ]]; then
  printf >&2 'invalid --via value: %s (expected hook|step6_5)\n' "$VIA_ARG"
  usage
fi

# Validate --prev after removing an optional task index; USER has no indexed form.
if [[ -n "$PREV_ARG" ]]; then
  if [[ "$PREV_ARG" =~ ^([A-Z]+)[0-9]+$ ]]; then
    PREV_ARG="${BASH_REMATCH[1]}"
    [[ "$PREV_ARG" != "USER" ]] || PREV_ARG="USER0"
  fi
  if ! is_valid_prev "$PREV_ARG"; then
    printf >&2 'invalid --prev value: %s (expected a stage code such as AR or task id such as AR0; USER has no index)\n' "$PREV_ARG"
    usage
  fi
fi

# ENOSPC guard (optional — only when caller requests it).
[[ -n "$DISK_CHECK_ROOT" ]] && disk_guard "$DISK_CHECK_ROOT"

# Ledger schema guard. This script is the single writer, so the version check belongs here
# rather than in each caller. An absent .version is a pre-versioning seed and is tolerated;
# an unreadable file is left to the callers below, which already no-op on it.
if [[ -f "$STATE_PATH" ]] && command -v jq > /dev/null 2>&1; then
  if STATE_VERSION=$(jq -r '.version // empty' "$STATE_PATH" 2> /dev/null); then
    if [[ -n "$STATE_VERSION" && "$STATE_VERSION" != "2" ]]; then
      printf >&2 'ledger version %s unsupported (expected 2)\n' "$STATE_VERSION"
      log_msg ERROR "ledger version ${STATE_VERSION} unsupported (expected 2); state.json unchanged"
      exit 1
    fi
  fi
fi

# ---------- Query mode ----------
# Read-only id resolution for sibling scripts that would otherwise re-implement the
# preference ladder in their own jq. No lock: nothing is written.
# `facts.decisions[]` is clamped to the newest 8 PER TASK and the evicted items are
# appended to `.context/decisions-<run_index>.jsonl`. That spill had no reader, so a run
# whose architecture stage recorded twelve decisions lost four of them the moment the ninth
# landed — and nothing anywhere said so. This is that reader: the union both halves of the
# record, which is what "the decisions this run made" has to mean once a clamp exists.
#
# Ledger wins on conflict, for the same reason the FN gate's question union does: a spill
# line is a snapshot taken at eviction time and is necessarily staler than an entry a later
# write restored.
#
# A spill that cannot be parsed is a FAILURE, never an empty set. Degrading it to "no
# evicted decisions" would go quiet in exactly the case this reader exists for.
if [[ -n "$READ_DECISIONS" ]]; then
  command -v jq > /dev/null 2>&1 || { printf >&2 'jq required for --read-decisions\n'; exit 1; }
  _RD_LEDGER="[]"
  if [[ -f "$STATE_PATH" ]]; then
    if ! _RD_LEDGER=$(jq -c '(.facts.decisions // [])' "$STATE_PATH" 2> /dev/null); then
      printf >&2 'ERROR: %s is not readable as JSON — decisions cannot be resolved\n' "$STATE_PATH"
      exit 2
    fi
  fi

  _RD_RUN_IDX=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
  _RD_DIR="${STATE_PATH%/*}"
  [[ "$_RD_DIR" == "$STATE_PATH" ]] && _RD_DIR="."
  _RD_SPILL="${_RD_DIR}/decisions-${_RD_RUN_IDX}.jsonl"

  _RD_SPILLED="[]"
  # A symlinked spill is refused rather than followed, matching every other reader of a
  # `.context/` side file here — and refused LOUDLY, like the unparseable arm below: a
  # spill this reader will not open is a spill it cannot vouch for, and answering with the
  # ledger half alone is the partial set the contract above rules out.
  if [[ -L "$_RD_SPILL" ]]; then
    printf >&2 'ERROR: %s is a symlink — refusing to follow it or to report a partial decision set\n' \
      "$_RD_SPILL"
    exit 2
  fi
  if [[ -f "$_RD_SPILL" ]]; then
    if ! _RD_SPILLED=$(jq -c -s '.' "$_RD_SPILL" 2> /dev/null); then
      printf >&2 'ERROR: %s exists but is not readable as JSON lines — refusing to report a partial decision set\n' \
        "$_RD_SPILL"
      exit 2
    fi
  fi

  jq -cn --argjson ledger "$_RD_LEDGER" --argjson spilled "$_RD_SPILLED" '
    ($spilled | map(select(.id? != null))) as $sp
    | reduce ($sp[] , $ledger[]) as $e
        ([]; map(select(.id != $e.id)) + [$e])' || exit 2
  exit 0
fi

if [[ -n "$RESOLVE_CODE_ARG" ]]; then
  if [[ -z "$(basename_for_stage "$RESOLVE_CODE_ARG")" ]]; then
    printf >&2 'invalid --resolve-task-id code: %s (expected a stage code: PL AR TL DV DR SR QA DC RE FN ST IR ET)\n' \
      "$RESOLVE_CODE_ARG"
    exit 1
  fi
  if [[ ! -f "$STATE_PATH" ]]; then
    printf >&2 'no state.json at %s — cannot resolve a task id\n' "$STATE_PATH"
    exit 1
  fi
  # Ambiguity is exit 4 here too: --resolve-task-id is what the orchestrator asks before it
  # patches, so answering with a guess would only move the mis-slot one call later.
  if ! _RESOLVED=$(resolve_task_id "$RESOLVE_CODE_ARG"); then
    exit 4
  fi
  printf '%s\n' "$_RESOLVED"
  exit 0
fi

# ---------- Top-level metadata ----------
# The ledger's metadata{} is run-wide, not per-task: base_ref, milestone, the gate flags.
# resolve_base_ref (branch-lib.sh) reads a named task row's base_ref first (rank 2a, ahead of
# the mirror) and .metadata.base_ref otherwise, but until this
# op the writer had only --task-meta, so the key had to be hand-edited into state.json
# beside the single writer that exists to keep hand edits out. An unresolved base_ref falls
# through to origin/HEAD — the repository default branch — which is exactly the wrong-base
# finalization the base-sanity check exists to catch.
#
# Merge, not assign: a partial --set updates the named keys and leaves the rest, matching
# --task-meta. One level deep only (jq `*` is recursive, which is what --task-meta uses and
# what a caller updating one nested flag expects).
if [[ -n "$LEDGER_META_OP" ]]; then
  if [[ -n "$TASK_OP" ]]; then
    printf >&2 -- '--ledger-meta and --task-%s are separate writes; issue them separately\n' "$TASK_OP"
    usage
  fi
  command -v jq > /dev/null 2>&1 || {
    printf >&2 -- '--ledger-meta needs jq; state.json unchanged\n'
    log_msg ERROR "--ledger-meta needs jq; state.json unchanged"
    exit 1
  }
  [[ -n "$TASK_OP_VALUE" ]] || {
    printf >&2 -- 'missing value: --ledger-meta requires --set <json>\n'
    usage
  }
  # An object, not merely valid JSON: `--set '"develop"'` parses, and `. * "develop"` would
  # replace the whole metadata block with a string.
  if ! printf '%s' "$TASK_OP_VALUE" | jq -e 'type == "object"' > /dev/null 2>&1; then
    printf >&2 -- 'invalid --ledger-meta: --set must be a JSON object; state.json unchanged\n'
    log_msg ERROR "invalid --ledger-meta (--set is not a JSON object); state.json unchanged"
    exit 1
  fi
  if [[ ! -f "$STATE_PATH" ]]; then
    printf >&2 -- 'no state.json at %s; --ledger-meta writes into an existing ledger only\n' "$STATE_PATH"
    log_msg ERROR "--ledger-meta: no state.json at ${STATE_PATH}; nothing written"
    exit 1
  fi
  if atomic_apply "$STATE_PATH" '.metadata = ((.metadata // {}) * $meta)' \
    --argjson meta "$TASK_OP_VALUE"; then
    log_msg INFO "ledger meta: metadata merged"
    exit 0
  fi
  printf >&2 -- 'ledger meta failed; state.json unchanged (see %s)\n' "$LOG_FILE"
  log_msg ERROR "jq apply failed for --ledger-meta; state.json unchanged"
  exit 1
fi

# ---------- --resolve-models (Validation check 13, sibling of check 12's routing merge) ----
# Stamps state.models for every agents/*.md row so `model-matrix.sh --resolve` has a fast,
# re-readable rank-1 lookup instead of re-parsing stage-codes.md and CORPFLOW.md on every call
# — PL0 runs that wrapper itself now (sw-AR0-1 reversed --task-create's own auto-fill, which
# used to read this map directly; the map itself is unaffected). Idempotent overwrite (not a
# union): re-running mid-worktask reflects an edited CORPFLOW.md rather than freezing the first
# answer, matching routing's resolved-once-per-run contract at the call-site level (the
# orchestrator calls this once, at init).
if [[ -n "$RESOLVE_MODELS_OP" ]]; then
  # model_resolve/model_override_rows signal "no row" and "section absent" via a plain
  # nonzero `return` — routine fail-open control flow, not an exception. The global
  # ERR trap does not exempt a `return` following `||`/`if` (bash only exempts the TEST,
  # never the consequent), so it fires once per miss across 16 agents without this. The op
  # always exits before falling through, so disabling it for the block's duration is safe.
  trap - ERR
  command -v jq > /dev/null 2>&1 || {
    printf >&2 -- '--resolve-models needs jq; state.json unchanged\n'
    log_msg ERROR "--resolve-models needs jq; state.json unchanged"
    exit 1
  }
  if [[ ! -f "$STATE_PATH" ]]; then
    printf >&2 -- 'no state.json at %s; --resolve-models writes into an existing ledger only\n' "$STATE_PATH"
    log_msg ERROR "--resolve-models: no state.json at ${STATE_PATH}; nothing written"
    exit 1
  fi
  _RM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-matrix-lib.sh"
  if [ ! -r "$_RM_LIB" ]; then
    printf >&2 'state-patch.sh: plugin install broken — model-matrix-lib.sh not found at %s\n' "$_RM_LIB"
    exit 2
  fi
  # shellcheck source=model-matrix-lib.sh
  . "$_RM_LIB"

  # Same per-heading precedence CORPFLOW.md § Routing follows (skills/worktask/SKILL.md
  # § Validation check 12): project root, then the user-scope file. No hit -> matrix only.
  _RM_CORPFLOW="$RESOLVE_MODELS_CORPFLOW_ARG"
  if [[ -z "$_RM_CORPFLOW" ]]; then
    _RM_HIT=""
    _RM_HIT=$(corpflow_md_locate "$CTX" '## Models') || _RM_HIT=""
    _RM_CORPFLOW="${_RM_HIT%%$'\t'*}"
  fi
  _RM_OV_SOURCE=$(corpflow_md_source "$_RM_CORPFLOW")

  _RM_AUDIT_DIR="${CTX}/logs"
  if ! command -v corpflow_audit_row > /dev/null 2>&1; then
    _RM_AUDIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
    [ -r "$_RM_AUDIT_LIB" ] && { . "$_RM_AUDIT_LIB" || true; }
  fi

  # model-matrix-lib.sh hardening rule 4 makes the extractor fail-closed (exit 3 on zero rows or a bad row); a
  # process-substitution `while … done < <(model_matrix_rows)` discards that exit and a
  # partial/empty stream just runs the loop zero times, so this consumer re-opened the
  # closed door. Capture first, check the return, and refuse before atomic_apply rather
  # than silently stamping a truncated (or empty) state.models under a success log line.
  _RM_ROWS=""
  _RM_ROWS_RC=0
  _RM_ROWS=$(model_matrix_rows) || _RM_ROWS_RC=$?
  if [[ "$_RM_ROWS_RC" -ne 0 ]]; then
    printf >&2 -- 'resolve-models: matrix extraction failed (exit %s); state.json unchanged\n' "$_RM_ROWS_RC"
    log_msg ERROR "resolve-models: model_matrix_rows exited ${_RM_ROWS_RC}; refusing partial stamp"
    exit 1
  fi
  if [[ -z "$_RM_ROWS" ]]; then
    printf >&2 -- 'resolve-models: matrix extraction returned zero rows; state.json unchanged\n'
    log_msg ERROR "resolve-models: model_matrix_rows returned zero rows; refusing empty stamp"
    exit 1
  fi
  # Zero-row and non-zero-exit are the two failures model_matrix_rows itself can signal;
  # neither catches a TRUNCATED-but-parseable table (some rows silently deleted, the
  # survivors still well-formed) — a bats bijection test asserts that shape, but nothing
  # runtime-side did. Re-derive the same bijection here as the floor DR asked for: the row
  # count must equal the agents/*.md count, or a partial state.models is refused rather
  # than stamped under a success log line.
  _RM_ROW_COUNT=$(printf '%s\n' "$_RM_ROWS" | wc -l | tr -d '[:space:]')
  _RM_AGENT_COUNT=$(find "${_MML_DEFAULT_AGENTS_DIR}" -maxdepth 1 -name '*.md' -type f 2> /dev/null | wc -l | tr -d '[:space:]')
  if [[ "$_RM_ROW_COUNT" != "$_RM_AGENT_COUNT" ]]; then
    printf >&2 -- 'resolve-models: matrix has %s rows but agents/ has %s files; state.json unchanged\n' \
      "$_RM_ROW_COUNT" "$_RM_AGENT_COUNT"
    log_msg ERROR "resolve-models: row-count floor failed (matrix=${_RM_ROW_COUNT} agents=${_RM_AGENT_COUNT}); refusing truncated stamp"
    exit 1
  fi

  _RM_JSON='{}'
  _RM_SOURCE_OVERALL="matrix"
  while IFS=$'\t' read -r _rm_agent _rm_dmodel _rm_deffort; do
    _rm_pair=""
    _rm_pair=$(model_resolve "$_rm_agent" "" "$_RM_CORPFLOW") || _rm_pair=""
    if [[ -z "$_rm_pair" ]]; then
      # A matrix-listed agent that still fails to resolve should not happen; degrade to its
      # own matrix row rather than dropping it from state.models, and name it in the audit
      # trail — this is the sw-PL0-7 "warn, never block" reading applied at seed time.
      _rm_model="$_rm_dmodel"
      _rm_effort="$_rm_deffort"
      _rm_src="matrix"
      if command -v corpflow_audit_row > /dev/null 2>&1; then
        corpflow_audit_row --file "${_RM_AUDIT_DIR}/audit.jsonl" --actor "${VIA_ARG:-agent}:state-patch" \
          --action model_unresolved --subject "$_rm_agent" --result degraded \
          --task-id "$(_audit_task_ref)" --meta-kv "agent=${_rm_agent}" --meta-kv "fallback=matrix" \
          --meta-kv "rank_reached=matrix"
      fi
    else
      _rm_model="${_rm_pair%%$'\t'*}"
      _rm_rest="${_rm_pair#*$'\t'}"
      _rm_effort="${_rm_rest%%$'\t'*}"
      _rm_src="${_rm_rest##*$'\t'}"
    fi
    if [[ "$_rm_src" == "project-override" || "$_rm_src" == "user-override" ]]; then
      _RM_SOURCE_OVERALL="$_rm_src"
      if command -v corpflow_audit_row > /dev/null 2>&1; then
        corpflow_audit_row --file "${_RM_AUDIT_DIR}/audit.jsonl" --actor "${VIA_ARG:-agent}:state-patch" \
          --action model_override --subject "$_rm_agent" --result ok \
          --task-id "$(_audit_task_ref)" \
          --meta "$(jq -cn --arg a "$_rm_agent" --arg dm "$_rm_dmodel" --arg de "$_rm_deffort" \
            --arg om "$_rm_model" --arg oe "$_rm_effort" --arg s "$_rm_src" --arg p "$_RM_CORPFLOW" \
            '{agent:$a, default_model:$dm, default_effort:$de, override_model:$om, override_effort:$oe, source:$s, path:$p}')"
      fi
    fi
    _RM_JSON=$(printf '%s' "$_RM_JSON" | jq -c --arg a "$_rm_agent" --arg m "$_rm_model" \
      --arg e "$_rm_effort" --arg s "$_rm_src" '. + {($a): {model: $m, effort: $e, source: $s}}')
  done <<< "$_RM_ROWS"

  # CORPFLOW.md rows that never reach model_resolve at all (unknown agent, off-enum cell, or
  # the whole section unparseable) still need their own audit trail — model_override_rows' fail-open statuses.
  if [[ -f "$_RM_CORPFLOW" ]]; then
    _RM_OV_RC=0
    _RM_OV_OUT=$(model_override_rows "$_RM_CORPFLOW") || _RM_OV_RC=$?
    if [[ "$_RM_OV_RC" -eq 3 ]]; then
      if command -v corpflow_audit_row > /dev/null 2>&1; then
        corpflow_audit_row --file "${_RM_AUDIT_DIR}/audit.jsonl" --actor "${VIA_ARG:-agent}:state-patch" \
          --action model_override_unparsed --subject "CORPFLOW.md" --result degraded \
          --task-id "$(_audit_task_ref)" --meta-kv "path=${_RM_CORPFLOW}" \
          --meta-kv "source=${_RM_OV_SOURCE}" --meta-kv "reason=header_or_rows"
      fi
    elif [[ "$_RM_OV_RC" -eq 0 && -n "$_RM_OV_OUT" ]] && command -v corpflow_audit_row > /dev/null 2>&1; then
      while IFS=$'\t' read -r _rov_agent _rov_model _rov_effort _rov_status; do
        case "$_rov_status" in
          unknown)
            corpflow_audit_row --file "${_RM_AUDIT_DIR}/audit.jsonl" --actor "${VIA_ARG:-agent}:state-patch" \
              --action model_override_unknown --subject "$_rov_agent" --result degraded \
              --task-id "$(_audit_task_ref)" --meta-kv "agent=${_rov_agent}" \
              --meta-kv "reason=no-matrix-row" --meta-kv "source=${_RM_OV_SOURCE}" \
              --meta-kv "path=${_RM_CORPFLOW}"
            ;;
          invalid)
            corpflow_audit_row --file "${_RM_AUDIT_DIR}/audit.jsonl" --actor "${VIA_ARG:-agent}:state-patch" \
              --action model_override_unknown --subject "$_rov_agent" --result degraded \
              --task-id "$(_audit_task_ref)" --meta-kv "agent=${_rov_agent}" \
              --meta-kv "reason=invalid-cell" --meta-kv "cell=${_rov_model}/${_rov_effort}" \
              --meta-kv "source=${_RM_OV_SOURCE}" --meta-kv "path=${_RM_CORPFLOW}"
            ;;
        esac
      done <<< "$_RM_OV_OUT"
    fi
  fi

  if atomic_apply "$STATE_PATH" '.models = $models | .models_source = $src' \
    --argjson models "$_RM_JSON" --arg src "$_RM_SOURCE_OVERALL"; then
    log_msg INFO "resolve-models: stamped $(printf '%s' "$_RM_JSON" | jq 'length') rows, source=${_RM_SOURCE_OVERALL}"
    exit 0
  fi
  printf >&2 -- 'resolve-models failed; state.json unchanged (see %s)\n' "$LOG_FILE"
  log_msg ERROR "jq apply failed for --resolve-models; state.json unchanged"
  exit 1
fi

# ---------- Standalone --audit-row ----------
# Rows only, no ledger write. The ledger is still read, as --ack reads it: a row naming a
# task this run never seeded is a record of nothing, so an unknown id refuses before the
# append.
if [[ "${#AUDIT_ROWS[@]}" -gt 0 && -z "$TASK_OP" && -z "$STAGE_ARG" && -z "$ARTIFACT_ARG" \
  && -z "$FACTS_ARG" ]]; then
  if [[ ! -f "$STATE_PATH" ]]; then
    printf >&2 -- 'no state.json at %s; --audit-row appends against an existing ledger only\n' "$STATE_PATH"
    exit 1
  fi
  if [[ -n "$TASK_ID_ARG" ]] && ! [[ "$TASK_ID_ARG" =~ ^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$ ]]; then
    printf >&2 'invalid task id: %s (expected <STAGE><N>, e.g. DV0)\n' "$TASK_ID_ARG"
    exit 2
  fi
  _AR_UNKNOWN=$(jq -r --argjson rows "$AUDIT_ROWS_JSON" --arg d "$TASK_ID_ARG" '
    (.tasks // {}) as $t
    | [ ($rows[] | .task_id // empty), (if $d != "" then $d else empty end) ]
    | unique | map(select(. as $i | $t | has($i) | not)) | join(",")' "$STATE_PATH" 2> /dev/null) \
    || _AR_UNKNOWN="(ledger unreadable)"
  if [[ -n "$_AR_UNKNOWN" ]]; then
    printf >&2 'unknown task id: %s (--audit-row needs an existing task); nothing written\n' "$_AR_UNKNOWN"
    log_msg ERROR "--audit-row on unknown tasks.${_AR_UNKNOWN}; nothing written"
    exit 1
  fi
  _post_success "${TASK_ID_ARG:-unknown}" "$TASK_ID_ARG" "" 0
  exit 0
fi

# ---------- Ledger ops ----------
# Direct tasks{} writes for the orchestrator loop; they short-circuit the
# artifact/frontmatter path entirely.
#
# Each op yields a jq filter rather than a precomputed patch so that atomic_apply evaluates
# it against the file INSIDE the merge lock — mandatory for the read-modify-write ops.
if [[ -n "$TASK_OP" ]]; then
  if ! [[ "$TASK_OP_ID" =~ ^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$ ]]; then
    printf >&2 'invalid task id: %s (expected <STAGE><N>, e.g. DV0)\n' "$TASK_OP_ID"
    usage
  fi
  command -v jq > /dev/null 2>&1 || {
    log_msg ERROR "ledger op needs jq; state.json unchanged"
    exit 1
  }
  # Both modifiers are parsed globally, so silently accepting them on the other five ops
  # would let `--task-status DV0 pending --cascade` read as a cascade that never happened.
  if [[ "$TASK_OP" != "replay" ]] \
    && { [[ "$REPLAY_CASCADE" == "true" ]] || [[ -n "$AGENTS_JSON_ARG" ]]; }; then
    printf >&2 -- '--cascade / --agents-json apply to --task-replay only (got --task-%s)\n' "$TASK_OP"
    usage
  fi
  # Same reason for the correction modifiers: `--task-status DV0 pending --from DC0` must not
  # read as a re-open that stamped a source it never recorded, and a --changed silently
  # ignored on --task-reopen would look like a settle that ran.
  if [[ "$TASK_OP" != "reopen" ]] \
    && { [[ -n "$REOPEN_FROM_GIVEN" ]] || [[ -n "$FINDING_FILE_GIVEN" ]]; }; then
    printf >&2 -- '--from / --finding-file apply to --task-reopen only (got --task-%s)\n' "$TASK_OP"
    usage
  fi
  if [[ "$TASK_OP" != "settle_stale" && -n "$SETTLE_CHANGED_GIVEN" ]]; then
    printf >&2 -- '--changed applies to --task-settle-stale only (got --task-%s)\n' "$TASK_OP"
    usage
  fi
  if [[ "$TASK_OP" != "meta" && -n "$RAISE_ONLY_FLAG" ]]; then
    printf >&2 -- '--raise-only applies to --task-meta only (got --task-%s)\n' "$TASK_OP"
    usage
  fi
  if [[ "$TASK_OP" != "meta" && -n "$UNSET_GIVEN" ]]; then
    printf >&2 -- '--unset applies to --task-meta only (got --task-%s)\n' "$TASK_OP"
    usage
  fi

  # --task-create auto-fill REMOVED (sw-AR0-1, reversed at the FN-gate sweep over the
  # recommended design): resolution now happens at the CALLER —
  # PL0 runs `model-matrix.sh --resolve <agent>` and pastes the pair into its own `--metadata`
  # before calling `--task-create` (agents/product-manager.md's new Bash grant). Retaining this
  # block as a silent fallback would defeat the reversal's own premise: a pasted-wrong or
  # forgotten value must surface as a mistier row, not be quietly repaired here, or the
  # hand-copy risk the user explicitly re-accepted stays invisible. `model_resolve` and
  # `model-matrix-lib.sh` are unchanged and still exist — this stage's `--resolve-models` op
  # (state.models, Validation check 13) is untouched by this reversal.

  # `metadata.effort` is a dispatch parameter the ledger carries, not free text: the Step
  # C.0a resolver bumps it one rung (`skills/shared/stage-contracts.md § Blocking items are
  # resolved, not asked`), and an off-ladder value would surface there as a failed dispatch
  # a stage or more later rather than at the write that introduced it. Checked on the two
  # ops that persist metadata. Absent is fine — the field is optional and older ledgers
  # predate it; present-but-unknown is not.
  # _ledger_effort_gate <metadata-json> — exits on an off-ladder effort; a batched
  # --task-create runs it once per row so one bad row refuses the whole call before any write.
  _ledger_effort_gate() {
    # `has` + `tostring`, not `//`: the alternative operator reads JSON null and false as
    # absent, and a required field must not be erasable through its own gate.
    _TASK_EFFORT=$(printf '%s' "$1" \
      | jq -r 'if type == "object" and has("effort") then (.effort | tostring) else empty end' \
        2> /dev/null) \
      || _TASK_EFFORT=""
    if [[ -n "$_TASK_EFFORT" ]]; then
      _EFFORT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/effort-ladder.sh"
      if [ -r "$_EFFORT_LIB" ]; then
        # shellcheck source=/dev/null
        . "$_EFFORT_LIB"
      fi
      # Only the two metadata ops need the ladder, so its absence fails them alone and
      # leaves --task-status/--task-block/--task-replay untouched.
      if [[ -z "${EFFORT_ENUM:-}" ]]; then
        printf >&2 'invalid --task-%s: effort-ladder.sh unreachable at %s; state.json unchanged\n' \
          "$TASK_OP" "$_EFFORT_LIB"
        log_msg ERROR "effort-ladder.sh unreachable; --task-${TASK_OP} refused, state.json unchanged"
        exit 1
      fi
      if ! effort_rank "$_TASK_EFFORT" > /dev/null; then
        printf >&2 'invalid effort: %s (expected one of: %s); state.json unchanged\n' \
          "$_TASK_EFFORT" "$EFFORT_ENUM"
        log_msg ERROR "invalid metadata.effort (${_TASK_EFFORT}); state.json unchanged"
        exit 2
      fi
    fi
  }
  if [[ "${#TC_IDS[@]}" -gt 1 ]]; then
    for _TC_I in "${!TC_IDS[@]}"; do
      if [[ -n "${TC_METAS[$_TC_I]}" ]]; then _ledger_effort_gate "${TC_METAS[$_TC_I]}"; fi
    done
  elif [[ "$TASK_OP" == "create" || "$TASK_OP" == "meta" ]] && [[ -n "$TASK_OP_VALUE" ]]; then
    _ledger_effort_gate "$TASK_OP_VALUE"
  fi

  # --task-meta --raise-only for model/effort (composition
  # reversed by sw-AR0-2 at the FN-gate sweep — see below): opt-in, not the default for every
  # --task-meta caller — an ordinary reassignment (QA re-pinning a stage, a correction round)
  # must still be free to lower a tier. Scoped to the score>=35 DV/DR complexity bump ONLY,
  # which must never silently lower a pair a project already raised via CORPFLOW.md § Models.
  # The `--secure`/`--full` DC override does NOT use this flag: sw-AR0-2 reversed that
  # composition to win outright, so PL0 writes the DC rows with a plain `--task-meta`, and a
  # project's raised tier CAN be silently lowered by a secure run (pl0-procedure.md § Default
  # writer rules states this as the accepted cost). The comparison, when the flag is given, is
  # always against the row's CURRENT value (PL0's own pasted resolution, or an earlier write),
  # never against the built-in matrix directly. Dropping the losing key from the payload —
  # rather than refusing the call — lets PL0 issue the same unconditional
  # `--task-meta --raise-only` on every DV/DR trigger match without computing the comparison
  # itself.
  if [[ "$TASK_OP" == "meta" ]] && [[ -n "$RAISE_ONLY_FLAG" ]] \
    && [[ -n "$TASK_OP_VALUE" ]] && [[ -f "$STATE_PATH" ]]; then
    _TM_HAS_MODEL=$(printf '%s' "$TASK_OP_VALUE" \
      | jq -r 'if type=="object" and has("model") then "1" else "" end' 2> /dev/null) \
      || _TM_HAS_MODEL=""
    _TM_HAS_EFFORT=$(printf '%s' "$TASK_OP_VALUE" \
      | jq -r 'if type=="object" and has("effort") then "1" else "" end' 2> /dev/null) \
      || _TM_HAS_EFFORT=""
    if [[ -n "$_TM_HAS_MODEL" || -n "$_TM_HAS_EFFORT" ]]; then
      _TM_CUR_MODEL=$(jq -r --arg id "$TASK_OP_ID" '.tasks[$id].metadata.model // ""' \
        "$STATE_PATH" 2> /dev/null) || _TM_CUR_MODEL=""
      _TM_CUR_EFFORT=$(jq -r --arg id "$TASK_OP_ID" '.tasks[$id].metadata.effort // ""' \
        "$STATE_PATH" 2> /dev/null) || _TM_CUR_EFFORT=""
      _TM_MML="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/effort-ladder.sh"
      if [[ -z "${EFFORT_ENUM:-}" ]] && [ -r "$_TM_MML" ]; then
        # shellcheck source=effort-ladder.sh
        . "$_TM_MML"
      fi
      if [[ -n "$_TM_HAS_EFFORT" && -n "$_TM_CUR_EFFORT" && -n "${EFFORT_ENUM:-}" ]]; then
        _TM_NEW_EFFORT=$(printf '%s' "$TASK_OP_VALUE" | jq -r '.effort')
        _TM_NEW_RANK=$(effort_rank "$_TM_NEW_EFFORT" 2> /dev/null) || _TM_NEW_RANK=""
        _TM_CUR_RANK=$(effort_rank "$_TM_CUR_EFFORT" 2> /dev/null) || _TM_CUR_RANK=""
        if [[ -n "$_TM_NEW_RANK" && -n "$_TM_CUR_RANK" && "$_TM_NEW_RANK" -lt "$_TM_CUR_RANK" ]]; then
          TASK_OP_VALUE=$(printf '%s' "$TASK_OP_VALUE" | jq -c 'del(.effort)' 2> /dev/null) \
            || true
        fi
      fi
      if [[ -n "$_TM_HAS_MODEL" && -n "$_TM_CUR_MODEL" ]]; then
        _TM_NEW_MODEL=$(printf '%s' "$TASK_OP_VALUE" | jq -r '.model')
        # opus > sonnet > haiku (model-selection.md § Cost Tiers) — the only three ranked
        # aliases; anything else compares as unranked and is never dropped by this guard.
        case "$_TM_NEW_MODEL" in haiku) _TM_NEW_MR=0 ;; sonnet) _TM_NEW_MR=1 ;; opus) _TM_NEW_MR=2 ;; *) _TM_NEW_MR="" ;; esac
        case "$_TM_CUR_MODEL" in haiku) _TM_CUR_MR=0 ;; sonnet) _TM_CUR_MR=1 ;; opus) _TM_CUR_MR=2 ;; *) _TM_CUR_MR="" ;; esac
        if [[ -n "$_TM_NEW_MR" && -n "$_TM_CUR_MR" && "$_TM_NEW_MR" -lt "$_TM_CUR_MR" ]]; then
          TASK_OP_VALUE=$(printf '%s' "$TASK_OP_VALUE" | jq -c 'del(.model)' 2> /dev/null) \
            || true
        fi
      fi
    fi
  fi

  # R-4.4 — the ONLY two paths that persist a task description. Dispatch-time appends
  # (the orchestrator's test-scope, ban and FN banners) mutate an in-memory copy and are
  # never written back, so capping post-append would strip banners that no ledger holds.
  # Truncate, never reject: a refused --task-create would break PL0 stage creation. The
  # cut is still reported (description_truncated=<id>:<len> on stderr after the write), so a
  # caller can tell its value no longer holds the whole text.
  # 240 chars matches the facts.goal precedent in initialization-patterns.md.
  _DESC_CAP='def _cap_desc:
      if (type == "object") and ((.description? | type) == "string")
         and ((.description | length) > 240)
      then .description = (.description[0:239] + "…") else . end;'

  # Keys a stage dispatch, gate or resume reads. Deleting one leaves a row the loop cannot
  # dispatch or resume, which a --set to the right value repairs and a delete never does.
  _UNSET_PROTECTED="stage agent model effort plan_gate decision_gate fn_gate workspace_path isolation base_ref requires_screenshots"
  # _unset_keys_json <key[,key...]> — the list as a JSON array on stdout; exits 2 on a
  # malformed or pipeline key, before any write.
  _unset_keys_json() {
    local k out='[]'
    local -a _keys
    IFS=',' read -r -a _keys <<< "$1"
    [[ "${#_keys[@]}" -gt 0 ]] || {
      printf >&2 'missing value: --unset requires <key[,key...]>\n'
      exit 2
    }
    for k in "${_keys[@]}"; do
      if [[ ! "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf >&2 'refused --unset: "%s" is not a metadata key name; state.json unchanged\n' "$k"
        exit 2
      fi
      case " $_UNSET_PROTECTED " in
        *" $k "*)
          printf >&2 'refused --unset %s: the pipeline reads tasks.%s.metadata.%s; set it to the right value instead; state.json unchanged\n' \
            "$k" "$TASK_OP_ID" "$k"
          log_msg ERROR "refused --unset ${k} on tasks.${TASK_OP_ID}: pipeline key; state.json unchanged"
          exit 2
          ;;
      esac
      out=$(jq -c --arg k "$k" '. + [$k] | unique' <<< "$out")
    done
    printf '%s' "$out"
  }

  TASK_FILTER=""
  TASK_JQ_ARGS=()
  case "$TASK_OP" in
    create)
      # PL/IR rows are exempt because PL0 is the stage that decides base_ref and
      # requires_screenshots: every other row must already be dispatch-ready
      # (effort/isolation/base_ref/requires_screenshots/workspace_path) before it is
      # seeded, so a downstream stage never discovers the gap mid-run.
      # _tc_required_gate <id> <metadata-json-or-empty>
      _tc_required_gate() {
        _TC_CODE="${1%%[0-9]*}"
        if [[ "$_TC_CODE" != "PL" && "$_TC_CODE" != "IR" ]]; then
          # bash 3.2's "${TASK_OP_VALUE:-{}}" leaks a stray "}" onto a non-empty
          # value (brace-matching quirk in the default-word parse), hence the if/else.
          if [[ -z "$2" ]]; then
            _TC_META='{}'
          else
            _TC_META="$2"
          fi
          _TC_MISSING=$(printf '%s' "$_TC_META" | jq -r '
              . as $m
              | ["effort","isolation","base_ref","requires_screenshots","workspace_path"]
              | map(select(. as $k | ($m | has($k) | not) or ($m[$k] == null) or ($m[$k] == "")))
              | join(",")' 2> /dev/null) || _TC_MISSING="effort,isolation,base_ref,requires_screenshots,workspace_path"
          if [[ -n "$_TC_MISSING" ]]; then
            printf >&2 'invalid --task-create %s: metadata missing required key(s): %s (required on every non-PL/IR row); state.json unchanged\n' \
              "$1" "$_TC_MISSING"
            log_msg ERROR "invalid --task-create ${1}: metadata missing required key(s): ${_TC_MISSING}; state.json unchanged"
            exit 2
          fi
        fi
      }
      if [[ "${#TC_IDS[@]}" -gt 1 ]]; then
        # Every row is gated before the single merge below, so one bad row refuses the batch
        # with state.json byte-unchanged rather than landing the rows that preceded it. A row
        # that already exists is a per-row no-op and skips the gates, exactly as a single
        # --task-create on an existing id exits before them.
        _TC_IDS_JSON="[]"
        _TC_ROWS_JSON="[]"
        for _TC_I in "${!TC_IDS[@]}"; do
          _TC_ID="${TC_IDS[$_TC_I]}"
          if ! [[ "$_TC_ID" =~ ^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$ ]]; then
            printf >&2 'invalid task id: %s (expected <STAGE><N>, e.g. DV0); batch refused, state.json unchanged\n' "$_TC_ID"
            exit 2
          fi
          if jq -e --arg id "$_TC_ID" 'index($id) != null' <<< "$_TC_IDS_JSON" > /dev/null; then
            printf >&2 'invalid --task-create batch: %s named twice; state.json unchanged\n' "$_TC_ID"
            exit 2
          fi
          _TC_IDS_JSON=$(jq -c --arg id "$_TC_ID" '. + [$id]' <<< "$_TC_IDS_JSON")
          if [[ -f "$STATE_PATH" ]] \
            && jq -e --arg id "$_TC_ID" 'has("tasks") and (.tasks | has($id))' \
              "$STATE_PATH" > /dev/null 2>&1; then
            continue
          fi
          _tc_required_gate "$_TC_ID" "${TC_METAS[$_TC_I]}"
          # Same failure class as an unparseable single --metadata, which surfaces as a jq
          # apply failure (exit 1) once the required-key gate has let it through.
          if ! _TC_ROWS_JSON=$(jq -c --arg id "$_TC_ID" --argjson meta "${TC_METAS[$_TC_I]:-null}" \
            '. + [{id: $id, meta: $meta}]' <<< "$_TC_ROWS_JSON" 2> /dev/null); then
            printf >&2 'invalid --task-create %s: --metadata is not valid JSON; batch refused, state.json unchanged\n' "$_TC_ID"
            log_msg ERROR "invalid --task-create ${_TC_ID}: --metadata is not valid JSON; state.json unchanged"
            exit 1
          fi
        done
        DIGEST_TOUCHED="$(jq -r 'join(",")' <<< "$_TC_IDS_JSON")"
        # All-present is the whole-batch no-op: skipping the write keeps state.json
        # byte-identical, as the single-row early exit does.
        if [[ "$(jq -r 'length' <<< "$_TC_ROWS_JSON")" -eq 0 ]]; then
          log_msg INFO "idempotent: tasks.${DIGEST_TOUCHED} already exist"
          _post_success "$TASK_OP_ID" "$DIGEST_TOUCHED" "" 0
          exit 0
        fi
        # Re-checked per row inside the lock, so a row a sibling writer seeded after the
        # pre-lock read above still keeps the metadata it has.
        TASK_FILTER="${_DESC_CAP}"'reduce $rows[] as $r (.;
            if ((.tasks // {}) | has($r.id)) then .
            else .tasks[$r.id] = {status: "pending", metadata: (($r.meta // {}) | _cap_desc)} end)'
        TASK_JQ_ARGS=(--argjson rows "$_TC_ROWS_JSON")
        TASK_OP_VALUE="batch=${DIGEST_TOUCHED}"
        DESC_TRUNCATED=$(jq -r '.[] | (.meta.description? | strings | length) as $n
          | select($n > 240) | "\(.id):\($n)"' <<< "$_TC_ROWS_JSON" 2> /dev/null) || DESC_TRUNCATED=""
      else
        # Seeding is idempotent: an existing task keeps the metadata it has accumulated, so a
        # re-run of a seed script cannot roll it back to the seed's view.
        if [[ -f "$STATE_PATH" ]] \
          && jq -e --arg id "$TASK_OP_ID" 'has("tasks") and (.tasks | has($id))' \
            "$STATE_PATH" > /dev/null 2>&1; then
          log_msg INFO "idempotent: tasks.${TASK_OP_ID} already exists"
          _post_success "$TASK_OP_ID" "$TASK_OP_ID" "" 0
          exit 0
        fi
        _tc_required_gate "$TASK_OP_ID" "$TASK_OP_VALUE"
        # --metadata is optional; absent ⇒ an empty object, never a parse abort.
        DESC_TRUNCATED=$(jq -rn --arg id "$TASK_OP_ID" --argjson meta "${TASK_OP_VALUE:-null}" \
          '$meta.description? | strings | length | select(. > 240) | "\($id):\(.)"' 2> /dev/null) \
          || DESC_TRUNCATED=""
        TASK_FILTER="${_DESC_CAP}"'.tasks[$id] = {status: "pending", metadata: (($meta // {}) | _cap_desc)}'
        TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --argjson meta "${TASK_OP_VALUE:-null}")
      fi
      ;;
    status)
      case "$TASK_OP_VALUE" in
        # Sole decode of the status enum in the tooling. Readers use bare jq field access, so a
        # value an older copy does not model still round-trips through it untouched; keeping the
        # closed set on the write path alone is what makes `failed` additive rather than breaking.
        # `stale` joins on the same terms: non-terminal and non-ready, it parks a task whose
        # consumed input was corrected without discarding its verdict, artifact or handoff.
        # Keep this list on ONE line — the status-parity extractors read it as a single match.
        pending | in_progress | completed | blocked | skipped | failed | stale) ;;
        *)
          printf >&2 'invalid status: %s\n' "$TASK_OP_VALUE"
          usage
          ;;
      esac
      require_task_exists "$TASK_OP_ID" status
      TASK_FILTER='.tasks[$id].status = $st'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg st "$TASK_OP_VALUE")
      ;;
    block)
      [[ -n "$TASK_OP_VALUE" ]] || {
        printf >&2 'missing value: --task-block %s requires --on <ID[,ID...]>\n' "$TASK_OP_ID"
        usage
      }
      require_task_exists "$TASK_OP_ID" block
      # Union, not append: re-running a seed must not duplicate an edge.
      TASK_FILTER='.tasks[$id].blocked_by =
        (((.tasks[$id].blocked_by // []) + ($on | split(","))) | unique)'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg on "$TASK_OP_VALUE")
      ;;
    unblock)
      [[ -n "$TASK_OP_VALUE" ]] || {
        printf >&2 'missing value: --task-unblock %s requires --off <ID[,ID...]>\n' "$TASK_OP_ID"
        usage
      }
      require_task_exists "$TASK_OP_ID" unblock
      # Set subtraction mirroring --task-block: dropping an edge that was never there is a no-op.
      TASK_FILTER='.tasks[$id].blocked_by =
        (((.tasks[$id].blocked_by // []) - ($off | split(","))) | unique)'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg off "$TASK_OP_VALUE")
      ;;
    meta)
      require_task_exists "$TASK_OP_ID" meta
      _UNSET_JSON='[]'
      if [[ -n "$UNSET_GIVEN" ]]; then
        # Runs in a subshell, so its exit 2 only ends the subshell: re-raise it here.
        _UNSET_JSON=$(_unset_keys_json "$UNSET_KEYS") || exit 2
        # Nothing to merge and nothing to delete: skip the write so the bytes stay as they are.
        if [[ -z "$TASK_OP_VALUE" ]] && ! jq -e --arg id "$TASK_OP_ID" --argjson u "$_UNSET_JSON" \
          '(.tasks[$id].metadata // {}) as $m | any($u[]; . as $k | $m | has($k))' \
          "$STATE_PATH" > /dev/null 2>&1; then
          log_msg INFO "idempotent: tasks.${TASK_OP_ID}.metadata has none of ${UNSET_KEYS}"
          _post_success "$TASK_OP_ID" "$TASK_OP_ID" "" 0
          exit 0
        fi
      fi
      # Read before the lock: it only words the notice, the cap itself runs inside the write.
      DESC_TRUNCATED=$(jq -r --arg id "$TASK_OP_ID" --argjson meta "${TASK_OP_VALUE:-null}" \
        --argjson u "$_UNSET_JSON" '((.tasks[$id].metadata // {}) * ($meta // {})) as $m
          | select(($u | index("description")) == null)
          | $m.description? | strings | length | select(. > 240) | "\($id):\(.)"' \
        "$STATE_PATH" 2> /dev/null) || DESC_TRUNCATED=""
      # Recursive merge, so a partial --set updates named keys without dropping the rest;
      # --unset runs after it, so it wins over a key the same --set names.
      TASK_FILTER="${_DESC_CAP}"'.tasks[$id].metadata = ((((.tasks[$id].metadata // {}) * ($meta // {})) | _cap_desc)
        | delpaths($unset | map([.])))'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --argjson meta "${TASK_OP_VALUE:-null}" --argjson unset "$_UNSET_JSON")
      ;;
    replay)
      require_task_exists "$TASK_OP_ID" replay
      REPLAY_SURVEY=$(replay_survey "$TASK_OP_ID") || {
        printf >&2 'replay survey failed on tasks.%s; state.json unchanged\n' "$TASK_OP_ID"
        log_msg ERROR "replay survey failed on tasks.${TASK_OP_ID}; state.json unchanged"
        exit 1
      }

      REPLAY_PLAN_STATUS=$(jq -r '.plan_status // ""' <<< "$REPLAY_SURVEY")
      [[ "$REPLAY_PLAN_STATUS" == "completed" ]] || replay_refuse plan-incomplete \
        "PL0 is ${REPLAY_PLAN_STATUS:-absent}; this is the fresh-run path, use /worktask"

      # One subprocess for the whole cascade: N findings are read from the single payload.
      REPLAY_LIVENESS=$(replay_liveness_payload) || replay_refuse liveness-indeterminate \
        "stale-check.sh returned no usable verdict (absent, failed, or unparseable) — the guard cannot prove the target is not still writing"

      REPLAY_CLASS_MAP=""
      while IFS= read -r _member; do
        [[ -n "$_member" ]] || continue
        _class=$(jq -r --arg id "$_member" \
          '[.findings[]? | select(.task_id == $id)]
           | if length == 0 then "none" else .[0].classification end' <<< "$REPLAY_LIVENESS")
        # Allow-list, not deny-list: a class this script has never heard of — including one
        # resume.md adds later — must refuse rather than fall through as permitted.
        case "$_class" in
          none | gone | budget-halt | dispatch-settled) ;;
          *)
            case "$_class" in
              alive-busy) _token="target-live" _why="${_member} agent is busy" ;;
              alive-parked) _token="target-parked" _why="reattach via SendMessage, see resume.md" ;;
              *) _token="liveness-indeterminate" _why="${_member} classified ${_class}" ;;
            esac
            if [[ "$_member" == "$TASK_OP_ID" ]]; then
              replay_refuse "$_token" "$_why"
            fi
            replay_refuse cascade-member-blocked "${_member}: ${_token}"
            ;;
        esac
        REPLAY_CLASS_MAP="${REPLAY_CLASS_MAP}${_member}=${_class}"$'\n'
      done <<< "$(jq -r '.members[].id' <<< "$REPLAY_SURVEY")"
      # A survey that yielded no ids would run the loop zero times and reach the mutation
      # having checked nothing.  Unreachable while the filter always builds members, which
      # is exactly why it must be asserted rather than assumed.
      [[ -n "$REPLAY_CLASS_MAP" ]] || replay_refuse liveness-indeterminate \
        "the survey produced no member to check"

      REPLAY_PLAN=$(jq -c --arg map "$REPLAY_CLASS_MAP" '
        ($map | split("\n") | map(select(length > 0) | split("=") | {key: .[0], value: .[1]})
         | from_entries) as $cls
        | .members |= map(. + {liveness: ($cls[.id] // "none")})' <<< "$REPLAY_SURVEY")

      if jq -e '(.stale_dependents | length) > 0' <<< "$REPLAY_SURVEY" > /dev/null; then
        replay_warn stale-dependents \
          "already-completed dependents may now be stale (never auto-reset): $(jq -r '.stale_dependents | join(", ")' <<< "$REPLAY_SURVEY")"
      fi
      if jq -e '(.skipped | length) > 0' <<< "$REPLAY_SURVEY" > /dev/null; then
        replay_warn side-effect-skipped \
          "traversed but NOT reset (their completion acted outside the ledger): $(jq -r '.skipped | join(", ")' <<< "$REPLAY_SURVEY")"
      fi
      if jq -e '.target_side_effect' <<< "$REPLAY_SURVEY" > /dev/null; then
        replay_warn side-effect-target \
          "${TASK_OP_ID} commits/tags outside the ledger; re-running it may produce a second commit, PR or tag"
      fi
      REPLAY_RUN_IDX=$(jq -r '.run_index' <<< "$REPLAY_SURVEY")
      if ! jq -e --arg s "PL${REPLAY_RUN_IDX}" \
        'select(.action == "approval_received" and .subject == $s)' \
        "${CTX}/logs/audit.jsonl" > /dev/null 2>&1; then
        replay_warn plan-unapproved \
          "no approval_received row for PL${REPLAY_RUN_IDX} — the plan behind this stage was never approved at the gate"
      fi

      # The existence re-assertion lives INSIDE the filter, so a key that vanished
      # between the survey and the lock makes jq error, atomic_apply drop the tmp, and the
      # rename never happen — the multi-member write stays genuinely all-or-nothing.
      TASK_FILTER='
        def blast:
            .status = "pending"
          | del(.completed_via)
          | (if (.metadata | type) == "object"
             then .metadata |= (del(.retry_count) | del(.error_escalated_to))
             else . end)
          | (if has("tests_executed") then .rework_pending = true else . end);
        . as $st
        | [ $members[] | . as $m | select((($st.tasks // {}) | has($m)) | not) ] as $missing
        | if ($missing | length) > 0
          then error("replay member(s) absent under the lock: " + ($missing | join(",")))
          else reduce ($members[]) as $m (.; .tasks[$m] |= blast) end'
      TASK_JQ_ARGS=(--argjson members "$(jq -c '[.members[].id]' <<< "$REPLAY_PLAN")")
      ;;
    reopen)
      # Guard ORDER is the contract, not an implementation detail: every check reads the file
      # and none writes, so a refusal at any rung leaves state.json byte-identical — the same
      # property --claim and --task-replay promise. Unknown ids stay exit 1 (require_task_exists)
      # and malformed ones exit 2 (usage), so only a well-formed, existing, wrongly-stated
      # target reaches exit 4.
      require_task_exists "$TASK_OP_ID" reopen
      if [[ -z "$REOPEN_FROM_GIVEN" || -z "$REOPEN_FROM" ]]; then
        printf >&2 'missing value: --task-reopen %s requires --from <ID>\n' "$TASK_OP_ID"
        usage
      fi
      if ! [[ "$REOPEN_FROM" =~ ^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$ ]]; then
        printf >&2 'invalid --from id: %s (expected <STAGE><N>, e.g. DC0)\n' "$REOPEN_FROM"
        usage
      fi
      # A task correcting itself is a loop, not a correction: it would bump its own fix_round
      # and park its own consumers on evidence it produced.
      if [[ "$REOPEN_FROM" == "$TASK_OP_ID" ]]; then
        reopen_refuse target-is-source \
          "tasks.${TASK_OP_ID} cannot correct itself; --from names the task that RAISED the finding"
      fi
      _REOPEN_STATUS=$(jq -r --arg id "$TASK_OP_ID" '.tasks[$id].status // ""' "$STATE_PATH")
      # THE idempotence guard. A re-routed correction finds the target already `pending` and is
      # refused here, which is why a retried route cannot bump fix_round twice or re-park a
      # consumer that has since settled. Re-opening a task that never completed is also
      # meaningless: nothing downstream consumed an output it never produced.
      [[ "$_REOPEN_STATUS" == "completed" ]] || reopen_refuse target-not-completed \
        "tasks.${TASK_OP_ID} is ${_REOPEN_STATUS:-absent}; a correction re-opens a completed task only"
      require_task_exists "$REOPEN_FROM" reopen
      _REOPEN_SRC_STAGE="${REOPEN_FROM%%[0-9]*}"
      # Read AFTER the guards: a refused route must not consume the caller's stdin.
      _FINDING_SRC="/dev/null"
      if [[ -n "$FINDING_FILE_GIVEN" ]]; then
        reopen_read_finding "$FINDING_FILE"
        _FINDING_SRC="$_FINDING_TMP"
      fi
      # --rawfile, never --arg: the finding must not appear in this process's or jq's argv.
      #
      # The whole write is ONE filter so the target's re-open and its consumers' parking are
      # one rename: a ledger holding a pending target whose consumers still read `completed`
      # would dispatch them against work that is being corrected. The existence and status
      # re-assertions live INSIDE it for the same reason replay's do — a key that changed
      # between the guards and the lock makes jq error, atomic_apply drop the tmp, and the
      # rename never happen (surfacing as exit 1, the write landed nothing, rather than 4).
      TASK_FILTER='
        def deps_of($st; $tid):
          [ ($st.tasks // {}) | to_entries[]
            | select((.value.blocked_by // []) | index($tid)) | .key ];
        def is_side_effect($tid; $codes):
          any($codes[]; . as $c | $tid | test("^" + $c + "[0-9]+$"));
        . as $st
        | ($se | split(",")) as $codes
        # blocked_by has no acyclicity enforcement anywhere, so the task count bounds the walk.
        | (($st.tasks // {}) | length) as $bound
        | (if ((($st.tasks // {}) | has($target)) | not)
              or ((($st.tasks // {}) | has($source)) | not)
           then error("reopen target or source absent under the lock: " + $target + "/" + $source)
           elif ((($st.tasks[$target].status) // "") != "completed")
           then error("reopen target is no longer completed under the lock: " + $target)
           else . end)
        | ( { frontier: [$target], visited: [$target], order: [], n: 0 }
            | until((.frontier | length) == 0 or .n >= $bound;
                . as $s
                | ( [ $s.frontier[] | deps_of($st; .) ] | add // [] | unique ) as $next
                | ( [ $next[] | . as $d | select(($s.visited | index($d)) == null) ]
                    | sort ) as $new
                | { frontier: $new,
                    visited: ($s.visited + $new),
                    order: ($s.order + $new),
                    n: ($s.n + 1) })
            | .order ) as $downstream
        # D3: transitive consumers, completed only, minus the source (it raised the finding,
        # it did not consume a bad output) and minus the side-effect stages the cascading
        # replay already skips — parking FN or RE would re-open a commit or a tag.
        | [ $downstream[]
            | select(. != $source)
            | select(is_side_effect(.; $codes) | not)
            | select((($st.tasks[.].status) // "") == "completed") ] as $consumers
        | ($finding | sub("\\s+$"; "")) as $f
        | .tasks[$target].status = "pending"
        | .tasks[$target].metadata = ((.tasks[$target].metadata // {})
            + { fix_round: ((($st.tasks[$target].metadata.fix_round) // 0) + 1),
                gate_from_stage: $srcstage,
                gate_blockers: (if $f == "" then [] else [$f] end) })
        # Status only: a parked consumer keeps its verdict, artifact and handoff, which is the
        # whole difference between `stale` and a replay reset.
        | reduce $consumers[] as $c (.; .tasks[$c].status = "stale")'
      TASK_JQ_ARGS=(--arg target "$TASK_OP_ID" --arg source "$REOPEN_FROM" \
        --arg srcstage "$_REOPEN_SRC_STAGE" --arg se "$REPLAY_SIDE_EFFECT_STAGES" \
        --rawfile finding "$_FINDING_SRC")
      # Logged, so it carries ids and a byte count — never the finding itself.
      TASK_OP_VALUE="from=${REOPEN_FROM} finding_bytes=$(wc -c < "$_FINDING_SRC" | tr -d '[:space:]')"
      ;;
    settle_stale)
      require_task_exists "$TASK_OP_ID" settle-stale
      # Two states, not one: `known` means this call read a change set and may conclude that
      # nothing cited changed; `unknown` means it could not, and every stale dependent
      # re-verifies. Collapsing them would turn "no evidence" into "no change" — the one
      # direction R5 must never take.
      _SETTLE_STATE="unknown"
      _SETTLE_CHANGED_JSON='[]'
      if [[ -n "$SETTLE_CHANGED_GIVEN" ]]; then
        # -Rs (slurp), not -R: a zero-byte SETTLE_CHANGED has no line for -R to read at all,
        # so it would emit nothing instead of "[]" and --argjson below would see empty text.
        _SETTLE_CHANGED_JSON=$(printf '%s' "$SETTLE_CHANGED" \
          | jq -Rsc 'split(",") | map(select(length > 0))' 2> /dev/null) || _SETTLE_CHANGED_JSON='[]'
        [[ "$_SETTLE_CHANGED_JSON" == "[]" ]] || _SETTLE_STATE="known"
      else
        # Recorded, else planned — the same precedence the id resolver uses. metadata.artifact
        # is what the plan seeded; .artifact is what the completion merge actually wrote, and
        # when the two differ the change set must come from the file the stage really produced.
        _SETTLE_ART=$(jq -r --arg id "$TASK_OP_ID" \
          '.tasks[$id].artifact // .tasks[$id].metadata.artifact // ""' "$STATE_PATH")
        if [[ -n "$_SETTLE_ART" ]]; then
          # Same resolution the artifact path uses: a relative artifact is caller-relative,
          # i.e. against dirname($CTX), never against cwd.
          case "$_SETTLE_ART" in
            /*) _SETTLE_ART_PATH="$_SETTLE_ART" ;;
            *)
              if [[ -n "$CTX" && "$CTX" != "." ]]; then
                _SETTLE_CTX_PARENT="${CTX%/*}"
                [[ "$_SETTLE_CTX_PARENT" == "$CTX" ]] && _SETTLE_CTX_PARENT="."
                _SETTLE_ART_PATH="${_SETTLE_CTX_PARENT}/${_SETTLE_ART}"
              else
                _SETTLE_ART_PATH="$_SETTLE_ART"
              fi
              ;;
          esac
          _SETTLE_FM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter-lib.sh"
          if ! command -v corpflow_fm_block > /dev/null 2>&1 && [ -r "$_SETTLE_FM_LIB" ]; then
            # shellcheck source=frontmatter-lib.sh
            . "$_SETTLE_FM_LIB"
          fi
          # An unreachable library, an unreadable artifact and a missing list all leave the
          # state `unknown`, and every stale dependent then re-verifies. This op degrades
          # toward work, never toward a standing result nothing checked.
          parse_files_touched "$_SETTLE_ART_PATH"
          if [[ "$PARSED_FT_STATE" == "list" ]]; then
            _SETTLE_CHANGED_JSON="$PARSED_FT_JSON"
            _SETTLE_STATE="known"
          fi
        fi
      fi
      # Planned pre-lock and re-asserted under it, the way replay surveys then applies: the
      # decision needs the cited sets of every stale row, and the printed line must name the
      # same rows the write moved.
      _SETTLE_OWN='{}'
      _SETTLE_FM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter-lib.sh"
      if ! command -v corpflow_fm_block > /dev/null 2>&1 && [ -r "$_SETTLE_FM_LIB" ]; then
        . "$_SETTLE_FM_LIB"
      fi
      while IFS=$'\t' read -r _SETTLE_ID _SETTLE_OWN_ART; do
        [[ -n "$_SETTLE_OWN_ART" ]] || continue
        case "$_SETTLE_OWN_ART" in
          /*) _SETTLE_OWN_PATH="$_SETTLE_OWN_ART" ;;
          *)
            if [[ -n "$CTX" && "$CTX" != "." ]]; then
              _SETTLE_CTX_PARENT="${CTX%/*}"
              [[ "$_SETTLE_CTX_PARENT" == "$CTX" ]] && _SETTLE_CTX_PARENT="."
              _SETTLE_OWN_PATH="${_SETTLE_CTX_PARENT}/$_SETTLE_OWN_ART"
            else
              _SETTLE_OWN_PATH="$_SETTLE_OWN_ART"
            fi ;;
        esac
        parse_files_touched "$_SETTLE_OWN_PATH"
        if [[ "$PARSED_FT_STATE" == "list" ]]; then
          _SETTLE_OWN=$(jq -c --arg id "$_SETTLE_ID" --argjson files "$PARSED_FT_JSON" \
            '. + {($id): $files}' <<< "$_SETTLE_OWN")
        fi
      done < <(jq -r '.tasks | to_entries[] | select(.value.status == "stale")
        | [.key, (.value.artifact // .value.metadata.artifact // "")] | @tsv' "$STATE_PATH")
      SETTLE_PLAN=$(jq -c --arg cstate "$_SETTLE_STATE" --argjson own "$_SETTLE_OWN" \
        --argjson changed "$_SETTLE_CHANGED_JSON" '
        # D2 normalisation, applied to BOTH sides: a citation reads `docs/x.md#anchor` or
        # `src/y.sh:42` where files_touched records the bare path, and an unnormalised
        # comparison would miss every anchored citation — failing toward `completed`.
        def norm: sub("^\\./"; "") | sub("#.*$"; "") | sub(":[0-9]+$"; "");
        . as $st
        | [ $changed[]
            | select(type == "string")
            # The files_touched overflow marker is a count, not a path.
            | select(test("^\\+ [0-9]+ more$") | not)
            | norm
            # The target rewrites its own artifact on every completion, so counting .context/
            # would return every dependent and defeat the intersection test entirely.
            | select(startswith(".context/") | not)
            | select(length > 0) ] as $chg
        | [ ($st.tasks // {}) | to_entries[]
            | select((.value.status // "") == "stale") | .key ] | sort
        | { settled: [ .[] | . as $t
            | ($t | sub("[0-9]+$"; "")) as $code
            | ( [ ($st.facts.files_read // [])[] | select(.stage == $code) | .path // empty ]
                + [ ($st.tasks[$t].metadata.consumes // [])[] | (.paths // [])[] ]
                | map(select(type == "string") | norm) | unique ) as $cited
            | (if $cstate != "known" then ["pending", "change-set-unknown"]
               elif ($cited | length) == 0 then
                 ([ ($own[$t] // [])[] | select(type == "string")
                    | select(test("^\\+ [0-9]+ more$") | not) | norm
                    | select(startswith(".context/") | not) | select(length > 0) ] | unique) as $own_files
                 | if ($own_files | length) == 0 then ["pending", "cited-set-empty"]
                   elif any($chg[]; . as $p | ($own_files | index($p)) != null)
                   then ["pending", "own-file-changed"]
                   else ["completed", "no-own-file-changed"] end
               elif any($chg[]; . as $p | ($cited | index($p)) != null)
               then ["pending", "cited-file-changed"]
               else ["completed", "no-cited-file-changed"] end) as $d
            | { task: $t, to: $d[0], reason: $d[1] } ] }' "$STATE_PATH") || {
        printf >&2 'settle plan failed on tasks.%s; state.json unchanged\n' "$TASK_OP_ID"
        log_msg ERROR "settle plan failed on tasks.${TASK_OP_ID}; state.json unchanged"
        exit 1
      }
      TASK_FILTER='
        . as $st
        | [ $plan[] | select((($st.tasks[.task].status) // "") != "stale") ] as $moved
        | if ($moved | length) > 0
          then error("settle member(s) no longer stale under the lock: "
                     + ([$moved[].task] | join(",")))
          else reduce ($plan[]) as $p (.; .tasks[$p.task].status = $p.to) end'
      TASK_JQ_ARGS=(--argjson plan "$(jq -c '.settled' <<< "$SETTLE_PLAN")")
      TASK_OP_VALUE="settled=$(jq -r '.settled | length' <<< "$SETTLE_PLAN") change_set=${_SETTLE_STATE}"
      ;;
    claim)
      require_task_exists "$TASK_OP_ID" claim
      _CLAIM_STATUS=$(jq -r --arg id "$TASK_OP_ID" '.tasks[$id].status // ""' "$STATE_PATH")
      case "$_CLAIM_STATUS" in
        completed | skipped | failed)
          printf >&2 'claim refused: tasks.%s is %s; use --task-replay\n' "$TASK_OP_ID" "$_CLAIM_STATUS"
          log_msg ERROR "claim refused: tasks.${TASK_OP_ID} is ${_CLAIM_STATUS}; state.json unchanged"
          exit 4
          ;;
        # A parked row is refused in the same class as a settled one (exit 4, file untouched),
        # but for the opposite reason: its result still stands and whether it must run again is
        # decided when the corrected task completes, not by whoever dispatches next. Claiming it
        # would burn the rework round the settlement is there to grant or withhold. The remedy is
        # deliberately not --task-replay, which would clear the verdict this status preserves.
        stale)
          printf >&2 'claim refused: tasks.%s is stale; it settles when the corrected task completes\n' "$TASK_OP_ID"
          log_msg ERROR "claim refused: tasks.${TASK_OP_ID} is stale; state.json unchanged"
          exit 4
          ;;
      esac
      # `//` keeps an existing claimed_at on re-claim (byte-identical) and only stamps one
      # when absent; status re-assignment to its current value is itself a no-op write.
      TASK_OP_VALUE="$(date -u +%FT%TZ)"
      TASK_FILTER='
        .tasks[$id].status = "in_progress"
        | .tasks[$id].claimed_at = ((.tasks[$id].claimed_at) // $ts)'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg ts "$TASK_OP_VALUE")
      ;;
    dispatch)
      if [[ "${DISPATCH_ARGC:-0}" -ne 3 ]]; then
        printf >&2 'invalid --dispatch: expected exactly 3 args <ID> <agent_id> <status>\n'
        usage
      fi
      case "$DISPATCH_STATUS" in
        launched | completed | failed) ;;
        *)
          printf >&2 'invalid --dispatch status: %s (expected launched|completed|failed)\n' "$DISPATCH_STATUS"
          usage
          ;;
      esac
      if ! [[ "$DISPATCH_AGENT_ID" =~ ^/?[A-Za-z0-9_][A-Za-z0-9._:@/-]{0,199}$ ]]; then
        printf >&2 'invalid --dispatch agent_id: %s\n' "$DISPATCH_AGENT_ID"
        usage
      fi
      require_task_exists "$TASK_OP_ID" dispatch
      _DISPATCH_AGENT_META=$(jq -r --arg id "$TASK_OP_ID" '.tasks[$id].metadata.agent // ""' "$STATE_PATH")
      if [[ -z "$_DISPATCH_AGENT_META" ]]; then
        printf >&2 'dispatch refused: tasks.%s has no metadata.agent\n' "$TASK_OP_ID"
        log_msg ERROR "dispatch refused: tasks.${TASK_OP_ID} missing metadata.agent; state.json unchanged"
        exit 2
      fi
      # Id shape is pinned by the regex above the switch, so stripping the trailing digits is
      # a safe glob, not a parse.
      _DISPATCH_STAGE="${TASK_OP_ID%%[0-9]*}"
      TASK_FILTER='
        ((.tasks[$id].metadata.model // "")) as $model
        | (.facts.dispatched_agents // []) as $cur
        | ($cur | map(.task_id) | index($id)) as $idx
        | ( { stage: $stage, task_id: $id, subagent_type: $agent, agent_id: $aid, status: $status }
            + (if $model != "" then { model_requested: $model } else {} end) ) as $entry
        | .facts.dispatched_agents =
            ( if $idx == null then
                $cur + [ $entry ]
              elif ($cur[$idx].agent_id) == $aid then
                $cur | .[$idx].status = $status
              else
                ( [ $cur[] | select(.task_id != $id) ] ) + [ $entry ]
              end )'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg stage "$_DISPATCH_STAGE" \
        --arg agent "$_DISPATCH_AGENT_META" --arg aid "$DISPATCH_AGENT_ID" --arg status "$DISPATCH_STATUS")
      TASK_OP_VALUE="${DISPATCH_AGENT_ID}:${DISPATCH_STATUS}"
      ;;
    files_read)
      if [[ "${#FILES_READ_PATHS[@]}" -eq 0 ]]; then
        printf >&2 'invalid --files-read: at least one path required\n'
        usage
      fi
      require_task_exists "$TASK_OP_ID" files-read
      _FR_STAGE="${TASK_OP_ID%%[0-9]*}"
      # Ordered de-dupe without arrays (bash 3.2's empty-array expansion under `set -u` is
      # unreliable): a growing newline list, each new path evicting its own prior line first
      # so "last wins" also means "moves to the tail".
      _FR_ORDERED=""
      for _FR_P in "${FILES_READ_PATHS[@]}"; do
        case "$_FR_P" in
          ./*) _FR_P="${_FR_P#./}" ;;
        esac
        if [[ -z "$_FR_P" || "${#_FR_P}" -gt 512 ]]; then
          printf >&2 'invalid --files-read path: empty (after stripping ./) or over 512 chars\n'
          usage
        fi
        case "$_FR_P" in
          *$'\t'* | *$'\r'* | *$'\n'*)
            printf >&2 'invalid --files-read path: contains a TAB/CR/LF: %s\n' "$_FR_P"
            usage
            ;;
        esac
        _FR_ORDERED=$(printf '%s\n' "$_FR_ORDERED" | grep -Fxv -- "$_FR_P") || true
        _FR_ORDERED="${_FR_ORDERED}"$'\n'"${_FR_P}"
      done
      _FR_PATHS_JSON=$(printf '%s\n' "$_FR_ORDERED" | jq -Rs 'split("\n") | map(select(length > 0))')
      TASK_FILTER='
        ($paths) as $add
        | .facts.files_read =
            ( ((.facts.files_read // []) | map(select((.path as $p | ($add | index($p))) == null)))
              + [ $add[] | { path: ., stage: $stage, lines: "all" } ] )'
      TASK_JQ_ARGS=(--arg id "$TASK_OP_ID" --arg stage "$_FR_STAGE" --argjson paths "$_FR_PATHS_JSON")
      TASK_OP_VALUE="$(printf '%s' "$_FR_PATHS_JSON" | jq -r 'length') path(s)"
      ;;
    ack)
      # Exits inside the arm: an audit append, not a ledger merge, so atomic_apply must never
      # run with an empty filter. Every refusal precedes the append, so a refusal adds no row.
      if [[ "${ACK_ARGC:-0}" -ne 2 ]]; then
        printf >&2 'invalid --ack: expected exactly 2 args <ID> <msg_id>\n'
        usage
      fi
      if ! [[ "$ACK_MSG_ID" =~ ^/?[A-Za-z0-9_][A-Za-z0-9._:@/-]{0,199}$ ]]; then
        printf >&2 'invalid --ack msg_id: %q\n' "$ACK_MSG_ID"
        usage
      fi
      require_task_exists "$TASK_OP_ID" ack
      _ACK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
      if ! command -v corpflow_audit_row > /dev/null 2>&1 && [ -r "$_ACK_LIB" ]; then
        # shellcheck source=../../shared/lib/audit-lib.sh
        . "$_ACK_LIB"
      fi
      if ! command -v corpflow_audit_row > /dev/null 2>&1; then
        printf >&2 'ack refused: audit lib unreachable at %s\n' "$_ACK_LIB"
        log_msg ERROR "ack refused on tasks.${TASK_OP_ID}: audit lib unreachable; no row written"
        exit 2
      fi
      _ACK_DIR="${STATE_PATH%/*}"
      if [[ "$_ACK_DIR" == "$STATE_PATH" ]]; then _ACK_DIR="."; fi
      # No merge lock: one bounded line appended with O_APPEND is atomic, and state.json is
      # never written, so queueing behind ledger merges buys nothing.
      corpflow_audit_row --file "${_ACK_DIR}/logs/audit.jsonl" \
        --actor "${VIA_ARG:-agent}:state-patch" --action message_ack --result ok \
        --subject "$TASK_OP_ID" --task-id "$TASK_OP_ID" --meta-kv "msg_id=${ACK_MSG_ID}"
      if [[ "${CORPFLOW_AUDIT_LAST_RC:-1}" -ne 0 ]]; then
        printf >&2 'ack not recorded: tasks.%s %s\n' "$TASK_OP_ID" "$ACK_MSG_ID"
        log_msg ERROR "ack not recorded: tasks.${TASK_OP_ID} ${ACK_MSG_ID}"
        exit 1
      fi
      log_msg INFO "ledger ack: tasks.${TASK_OP_ID} ${ACK_MSG_ID}"
      exit 0
      ;;
  esac

  if atomic_apply "$STATE_PATH" "$TASK_FILTER" "${TASK_JQ_ARGS[@]}"; then
    log_msg INFO "ledger ${TASK_OP}: tasks.${TASK_OP_ID} ${TASK_OP_VALUE}"
    # After the rename only: a cut that did not land must not be reported as made.
    if [[ -n "$DESC_TRUNCATED" ]]; then
      while IFS= read -r _dt; do
        [[ -n "$_dt" ]] || continue
        printf >&2 'description_truncated=%s\n' "$_dt"
        log_msg INFO "description_truncated=${_dt} (cap 240)"
      done <<< "$DESC_TRUNCATED"
    fi
    if [[ "$TASK_OP" == "replay" ]]; then
      replay_audit
    fi
    # Printed only after the rename: the caller applies this line without re-deciding
    # anything, so a plan that did not land must never reach it.
    if [[ "$TASK_OP" == "settle_stale" ]]; then
      printf '%s\n' "$SETTLE_PLAN"
    fi
    _post_success "$TASK_OP_ID" "${DIGEST_TOUCHED:-$TASK_OP_ID}" "" 0
    exit 0
  fi
  printf >&2 'ledger %s failed on tasks.%s; state.json unchanged (see %s)\n' \
    "$TASK_OP" "$TASK_OP_ID" "$LOG_FILE"
  log_msg ERROR "jq apply failed for ledger ${TASK_OP} on tasks.${TASK_OP_ID}; state.json unchanged"
  exit 1
fi

# ---------- Artifact preflight (resolve + parse + verdict refusal) ----------
# Placed ABOVE the facts union: a doomed completion merge (unresolved artifact, missing or
# unknown verdict) must refuse before any paired --facts payload lands, so a --stage/--facts
# call never persists facts.* only to fail the ledger row alone.
if [[ -n "$STAGE_ARG" || -n "$ARTIFACT_ARG" ]]; then
  if [[ -n "$ARTIFACT_ARG" ]]; then
    ART_RECORD="$ARTIFACT_ARG"
    case "$ARTIFACT_ARG" in
      /*) ART="$ARTIFACT_ARG" ;;
      *)
        # A relative --artifact is a caller-relative path, not a cwd-relative one: it is
        # resolved against dirname($CTX), i.e. the root the ladder actually found, and
        # recorded VERBATIM regardless — the ledger's artifact field is the caller's own
        # naming, never a rewrite.
        if [[ -n "$CTX" && "$CTX" != "." ]]; then
          _CTX_PARENT="${CTX%/*}"
          [[ "$_CTX_PARENT" == "$CTX" ]] && _CTX_PARENT="."
          ART="${_CTX_PARENT}/${ARTIFACT_ARG}"
        else
          ART="$ARTIFACT_ARG"
        fi
        ;;
    esac
  else
    ART=""
  fi

  # `hooks/anchor-preflight.sh` gates its lint on a canonical artifact name and fails OPEN on
  # anything else — a no-op, not an error. So an artifact one character off canonical is
  # written, ledgered, harness-passed and never anchor-linted; that hid two missing required
  # anchors in one run. Failing open is correct for an advisory lint. Failing open SILENTLY is
  # the defect, and this is the one place that sees the name and the stage together.
  #
  # A warning, never a refusal: the name is the caller's, the stage map is advisory here, and
  # a stage that has already written its artifact must not be blocked from recording it.
  # Reuses basename_for_stage() rather than adding a fourth copy of the stage→basename map —
  # basename_for_stage() itself, hooks/anchor-preflight.sh's ARTIFACT_RE and handoff-protocol.md are
  # already three.
  if [[ -n "$ARTIFACT_ARG" && -n "$STAGE_ARG" ]]; then
    _CANON_BASE="$(basename_for_stage "$STAGE_ARG")"
    if [[ -n "$_CANON_BASE" ]]; then
      _GIVEN_BASE="$(basename -- "$ARTIFACT_ARG")"
      # DV alone may carry the S1 stream suffix (handoff-protocol.md § DV fan-out); the
      # slug grammar and 40-char cap mirror hooks/anchor-preflight.sh, so a name this
      # accepts is one the hook lints.
      _CANON_RE="^${_CANON_BASE}-[0-9]+\.md$"
      [[ "$_CANON_BASE" == "development" ]] && _CANON_RE="^development-[0-9]+(-[a-z0-9]+(-[a-z0-9]+)*)?\.md$"
      if ! printf '%s' "$_GIVEN_BASE" | grep -qE "$_CANON_RE" \
        || printf '%s' "$_GIVEN_BASE" | grep -qE '^development-[0-9]+-[a-z0-9-]{41,}\.md$'; then
        printf >&2 'warn: --artifact %s is not the canonical name for stage %s (expected %s-<N>.md). It will be ledgered, but hooks/anchor-preflight.sh gates on the canonical name and will SKIP its anchor lint for this file.\n' \
          "$_GIVEN_BASE" "$STAGE_ARG" "$_CANON_BASE"
        log_msg WARN "non-canonical --artifact ${_GIVEN_BASE} for stage ${STAGE_ARG} (canonical: ${_CANON_BASE}-<N>.md) — anchor lint will not run"
      fi
    fi
  fi

  if [[ -z "$ART" && -n "$STAGE_ARG" ]]; then
    # Pull run_index from state.json when available.
    if [[ -f "$STATE_PATH" ]] && command -v jq > /dev/null 2>&1; then
      RUN_INDEX=$(jq -r '.run_index // empty' "$STATE_PATH" 2> /dev/null || printf '')
    fi

    # Searched (and found) in $CTX, the real root the ladder resolved; the RECORDED value
    # stays the portable ".context/<file>" convention every other ledger reader expects.
    ART=$(resolve_artifact_for_stage "$STAGE_ARG" "$CTX")
    [[ -n "$ART" ]] && ART_RECORD=".context/$(basename "$ART")"
  fi

  if [[ -z "$ART" || ! -f "$ART" ]]; then
    log_msg WARN "no artifact resolved (stage=${STAGE_ARG:-} artifact=${ARTIFACT_ARG:-}) — no-op"
    # `--prev` present with `--via` absent is the documented signature of a Layer-1 agent
    # self-patch (handoff-protocol.md#layer-1-fallback), i.e. a stage patching the artifact it just
    # wrote. Finding nothing there is a real failure, so it is the one unresolved case that
    # must not exit 0. Hook and Step-6.5 callers pass --via and keep the no-op contract.
    if [[ -n "$PREV_ARG" && -z "$VIA_ARG" && -z "$ALLOW_MISSING_ARTIFACT" ]]; then
      _searched=""
      if [[ -n "$STAGE_ARG" ]]; then
        _searched=$(searched_basenames_for_stage "$STAGE_ARG" | sed 's/$/-N.md/' | tr '\n' ' ')
      fi
      [[ -n "$ARTIFACT_ARG" ]] && _searched="${_searched}${ARTIFACT_ARG} "
      printf >&2 'ERROR: self-patch for stage %s found no artifact.\n  searched (in .context/): %s\n  Write the artifact, then re-run. If you cannot, write state.json directly (handoff-protocol.md#layer-1-fallback);\n  --allow-missing-artifact only silences this error and still patches NOTHING.\n' \
        "${STAGE_ARG:-<unset>}" "${_searched:-<none>}"
      log_msg ERROR "self-patch unresolved (stage=${STAGE_ARG:-} prev=${PREV_ARG}) — exit 3"
      exit 3
    fi
    # Every no-op return on the paired path still carries a --facts rejection out.
    exit $((FACTS_REJECTED == 1 ? 2 : 0))
  fi

  if [[ ! -f "$STATE_PATH" ]]; then
    log_msg INFO "state.json absent — nothing to merge (artifact=$ART)"
    exit $((FACTS_REJECTED == 1 ? 2 : 0))
  fi

  # Fail closed, per skills/shared/lib/README.md: a missing library under skills/ is a broken
  # install, not a runtime condition to degrade around — and degrading here would silently
  # restore the flat-shape acceptance this library exists to remove. Tested before `.`
  # because the `.` builtin exits the shell on a missing file, bypassing any `||` guard.
  _FM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter-lib.sh"
  if [ ! -r "$_FM_LIB" ]; then
    printf >&2 'state-patch.sh: plugin install broken — frontmatter-lib.sh not found at %s\n' "$_FM_LIB"
    exit 2
  fi
  # shellcheck source=frontmatter-lib.sh
  . "$_FM_LIB"

  if ! parse_frontmatter "$ART"; then
    exit 2
  fi

  if [[ -z "$PARSED_STAGE" ]]; then
    log_msg WARN "could not extract stage from $ART; aborting merge silently"
    exit $((FACTS_REJECTED == 1 ? 2 : 0))
  fi

  # A missing or unknown verdict refuses the WHOLE call — the ledger row, any
  # paired --facts payload, the handoff edge — regardless of --via, --prev or
  # --allow-missing-artifact (that flag covers a MISSING artifact only, never a bad one).
  STATUS_MAPPED=$(verdict_status "$PARSED_VERDICT")
  if [[ -z "$STATUS_MAPPED" ]]; then
    if [[ -z "$PARSED_VERDICT" ]]; then
      _vreason="missing"
    else
      _vreason="'${PARSED_VERDICT}' is unknown"
    fi
    printf >&2 'ERROR: verdict refused for %s in %s: handoff.verdict %s (allowed: ok pass go approve blocked escalate fail reject no-go); state.json unchanged\n' \
      "$PARSED_STAGE" "$ART" "$_vreason"
    log_msg ERROR "verdict refused for ${PARSED_STAGE} in ${ART}: handoff.verdict ${_vreason}; state.json unchanged"
    exit 3
  fi

  if ! TASK_ID=$(resolve_task_id "$PARSED_STAGE"); then
    exit 4
  fi
elif [[ -z "$FACTS_ARG" ]]; then
  log_msg WARN "no artifact resolved (stage= artifact=) — no-op"
  exit 0
fi

# ---------- DV-settle fill of facts.files_modified ----------
# A DV row self-reports files_modified, and base-sanity reads that list as its denominator,
# so an incomplete list blocks a correct base. The branch diff is the complete record, so a
# DV settle adds it. Prints a JSON array of repo-relative paths or nothing and
# always returns 0: any input it cannot trust means no fill, never a changed exit status.
# The tree is the row's workspace_path, so a call made from another cwd diffs the right tree;
# a named path that is not a work tree means no fill rather than a diff of the caller's cwd.
_dv_settle_git_paths() {
  local lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-lib.sh"
  (
    trap - ERR EXIT
    set +e
    st="$STATE_PATH"
    case "$st" in /*) ;; *) st="$PWD/$st" ;; esac
    tree=$(jq -r --arg id "$TASK_ID" \
      '(.tasks[$id].metadata.workspace_path // .metadata.workspace_path // empty) | strings' "$st")
    if [ -n "$tree" ]; then cd "$tree" || exit 0; fi
    [ "$(git rev-parse --is-inside-work-tree)" = "true" ] || exit 0
    [ -r "$lib" ] || exit 0
    # shellcheck source=branch-lib.sh
    . "$lib"
    STATE_PATH="$st"
    BASE_REF_TASK_ID="$TASK_ID"
    # origin_head is a default, not a configured base: a fill against it inflates the ledger
    # to the PR count of whatever the default happens to be.
    case "$(base_ref_source)" in env | task | state | workspace) ;; *) exit 0 ;; esac
    base=$(resolve_base_ref)
    [ -n "$base" ] || exit 0
    ref=$(resolve_git_ref "$base") || exit 0
    # Piped, not captured first: bash drops the NUL bytes -z emits from a variable.
    set -o pipefail
    out=$(git diff --name-only -z "${ref}...HEAD" | jq -Rsc 'split("\u0000") | map(select(length > 0))') || exit 0
    printf '%s' "$out"
  ) 2> /dev/null || true
}

_DV_CODE="${TASK_ID:-}"
if [[ -n "$STAGE_ARG" && -n "$FACTS_ARG" && "${_DV_CODE%%[0-9]*}" == "DV" && -f "$STATE_PATH" ]] \
  && command -v jq > /dev/null 2>&1; then
  _DV_GIT_PATHS=$(_dv_settle_git_paths)
  if [[ -n "$_DV_GIT_PATHS" ]]; then
    # Appended, never substituted: the union below dedupes and keeps self-reported order.
    # A payload this cannot merge stays as given, for the partition below to judge.
    _DV_FILLED=$(printf '%s' "$FACTS_ARG" | jq -c --argjson g "$_DV_GIT_PATHS" '
      if type == "object" and ((.files_modified // []) | type) == "array"
      then .files_modified = ((.files_modified // []) + $g) else . end' 2> /dev/null) || _DV_FILLED=""
    if [[ -n "$_DV_FILLED" ]]; then FACTS_ARG="$_DV_FILLED"; fi
  fi
fi

# ---------- Facts union ----------
# The compressed-fact channel's write path: facts.* is what stage-contracts.md tells every
# downstream stage to read first, and until this op it had no scripted writer at all.
# Runs before the ledger patch so a stage's facts land even when the ledger row is already
# current and the completion merge below short-circuits as idempotent.
if [[ -n "$FACTS_ARG" ]]; then
  command -v jq > /dev/null 2>&1 || {
    printf >&2 '--facts needs jq; state.json unchanged\n'
    log_msg ERROR "--facts needs jq; state.json unchanged"
    exit 1
  }

  _SWEEP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep-stub-lib.sh"
  if [ -r "$_SWEEP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$_SWEEP_LIB"
  fi
  # --facts is the only op that needs the predicate, so its absence fails this op alone and
  # leaves --stage/--prev/--task-create untouched.
  if [[ -z "${SWEEP_ID_RE:-}" || -z "${SWEEP_CLASS_ENUM:-}" || -z "${SWEEP_REF_RE:-}" ]]; then
    printf >&2 'invalid --facts: sweep-stub-lib.sh unreachable at %s; state.json unchanged\n' "$_SWEEP_LIB"
    log_msg ERROR "sweep-stub-lib.sh unreachable; --facts refused, state.json unchanged"
    usage
  fi
  SWEEP_CLASS_JSON=$(printf '%s' "$SWEEP_CLASS_ENUM" | tr ' ' '\n' | jq -R . | jq -s .)

  # The shared skills-tree appender, for the rejection row below. Degrades rather than
  # failing closed, unlike the sweep library above: an audit row is evidence, never a gate,
  # and a broken install must not turn a valid --facts payload into a refusal. Probed by
  # symbol so a truncated file is caught too, not just a missing one.
  _AUDIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
  _FACTS_AUDIT_OK=""
  if [ -r "$_AUDIT_LIB" ]; then
    # shellcheck source=../../shared/lib/audit-lib.sh
    . "$_AUDIT_LIB"
    command -v corpflow_audit_row > /dev/null 2>&1 && _FACTS_AUDIT_OK=1
  fi

  FACTS_PART=$(printf '%s' "$FACTS_ARG" \
    | jq -c --arg idre "$SWEEP_ID_RE" --arg refre "$SWEEP_REF_RE" \
            --arg branchre '^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$' \
            --arg streamre '^[a-z0-9]+(-[a-z0-9]+)*$' \
            --argjson classes "$SWEEP_CLASS_JSON" "$_FACTS_PARTITION_FILTER" 2> /dev/null) \
    || FACTS_PART=""
  if [[ -z "$FACTS_PART" ]]; then
    printf >&2 'invalid --facts: not valid JSON; state.json unchanged\n'
    log_msg ERROR "invalid --facts (not valid JSON); state.json unchanged"
    exit 2
  fi

  FACTS_FATAL=$(printf '%s' "$FACTS_PART" | jq -r '.fatal')
  if [[ -n "$FACTS_FATAL" ]]; then
    # Plain exit, never usage(): the help block is ~100 lines and scrolls the one line the
    # caller needs off the top of the transcript.
    printf >&2 'invalid --facts: %s; state.json unchanged\n' "$FACTS_FATAL"
    log_msg ERROR "invalid --facts (${FACTS_FATAL}); state.json unchanged"
    exit 2
  fi

  # _facts_report_rejects <header> <rejects-json-array> <log-line>
  # Sets FACTS_REJECTED=1, so every exit site below turns it into exit 2.
  _facts_report_rejects() {
    local header="$1" rejects="$2" logline="$3" list msg
    FACTS_REJECTED=1
    # Built ONCE, then written to each stream. Two independent emissions read as two
    # separate rejections in any caller that merges the streams. Stdout as well as stderr
    # because a caller whose harness swallows stderr otherwise ships a stage one item short,
    # and the artifact/ledger divergence then surfaces a boundary later than its cause.
    list=$(printf '%s' "$rejects" | jq -r '.[] | "  - " + .key + " " + .label + ": " + .reason')
    msg="${header}
${list}"
    printf '%s\n' "$msg" >&2
    printf '%s\n' "$msg"
    log_msg ERROR "$logline"
    # Neither stream above is durable. stderr inside a subagent turn is read by whatever
    # is reattaching, if anything; stdout is the tool result the model may or may not
    # quote. An audit row is the only channel a later sweep can find, and "which items
    # did this run reject" is exactly the question nobody could answer afterwards.
    if [[ -n "$_FACTS_AUDIT_OK" ]]; then
      corpflow_audit_row --file "${STATE_PATH%/*}/logs/audit.jsonl" \
        --actor "${VIA_ARG:-agent}:state-patch" --action facts_items_rejected --subject facts --result degraded \
        --task-id "$(_audit_task_ref)" \
        --meta "$(printf '%s' "$rejects" | jq -c '{rejected: [.[] | {key, label, reason}]}')"
    fi
  }

  FACTS_REJECT_N=$(printf '%s' "$FACTS_PART" | jq -r '.rejects | length')
  if [[ "$FACTS_REJECT_N" -gt 0 ]]; then
    _facts_report_rejects "invalid --facts: ${FACTS_REJECT_N} item(s) rejected, the rest still persist:" \
      "$(printf '%s' "$FACTS_PART" | jq -c '.rejects')" \
      "--facts: ${FACTS_REJECT_N} item(s) rejected; valid remainder persisted"
  fi

  FACTS_ARG=$(printf '%s' "$FACTS_PART" | jq -c '.clean')
  FACTS_KEPT=$(printf '%s' "$FACTS_ARG" | jq -r '[ .[] | length ] | add // 0')
  if [[ "$FACTS_KEPT" -eq 0 ]] && [[ "$FACTS_REJECT_N" -gt 0 ]]; then
    # Every item was rejected: nothing to persist, and the caller must see the refusal.
    printf >&2 'invalid --facts: no valid items in the payload; state.json unchanged\n'
    log_msg ERROR "--facts: no valid items; state.json unchanged"
    exit 2
  fi
  # Nothing kept AND nothing rejected means the payload was legitimately EMPTY —
  # `{"open_questions":[]}` is what stage-contracts.md § Closing Elicitation Sweep tells a stage
  # with nothing to ask to emit. Refusing it turned a no-op into a hard stop that also aborted the
  # stage-completion merge the same call was paired with. The union is skipped (it would be a
  # no-op anyway) and execution falls through to that merge.
  if [[ "$FACTS_KEPT" -eq 0 ]]; then
    log_msg INFO "--facts: empty payload, nothing to union (no-op)"
    FACTS_EMPTY_NOOP=1
  fi

  # Fallback slot for a stub whose id predates the `sw-<TASK_ID>-<n>` shape: the stage this
  # invocation is patching, by the same explicit-then-inferred order the id resolution uses.
  SWEEP_STAGE_FALLBACK="${STAGE_ARG:-$(printf '%s' "${TASK_ID_ARG:-}" | sed 's/[0-9]*$//')}"

  # The decisions ring partitions by the FULL task id, which the sweep fallback above
  # deliberately strips. Explicit --task-id wins, then the id the ledger resolves for
  # --stage, then the bare code. Empty means no stamp at all: an unattributable decision
  # belongs in the reserved bucket, never under whoever happens to write next.
  DECISION_TASK_ID="${TASK_ID_ARG:-}"
  if [[ -z "$DECISION_TASK_ID" && -n "$STAGE_ARG" ]]; then
    [[ -f "$STATE_PATH" ]] && DECISION_TASK_ID=$(resolve_task_id "$STAGE_ARG" 2> /dev/null || printf '')
    [[ -n "$DECISION_TASK_ID" ]] || DECISION_TASK_ID="$STAGE_ARG"
  fi

  if [[ "$FACTS_EMPTY_NOOP" -eq 1 ]]; then
    : # no-op: nothing to write, and an absent ledger is not an error for an empty payload
  elif [[ ! -f "$STATE_PATH" ]]; then
    # log_msg writes only to $LOG_FILE, so an INFO line with exit 0 here would be a write
    # that landed nothing yet is indistinguishable at the call site from one that landed.
    printf >&2 'no ledger at %s — --facts landed nothing\n' "$STATE_PATH"
    log_msg ERROR "no ledger at ${STATE_PATH}; --facts landed nothing"
    exit 1
  elif {
    # The spill and ledger must be read under one lock to retain a concurrent eviction.
    _FACTS_SPILL_DIR="${STATE_PATH%/*}"
    [[ "$_FACTS_SPILL_DIR" == "$STATE_PATH" ]] && _FACTS_SPILL_DIR="."
    _FACTS_RUN_IDX=$(jq -r '.run_index // 0' "$STATE_PATH")
    _FACTS_SPILL_PATH="$_FACTS_SPILL_DIR/open-questions-${_FACTS_RUN_IDX}.jsonl"
    [[ "$(printf '%s' "$FACTS_ARG" | jq -r '(.open_questions // []) | length')" -gt 0 ]] \
      && ATOMIC_APPLY_PROBE="$_FACTS_CLASS_REFUSAL_PROBE"
    _facts_apply_rc=0
    atomic_apply "$STATE_PATH" "$_FACTS_UNION_FILTER" \
      --argjson f "$FACTS_ARG" --arg sweep_stage "$SWEEP_STAGE_FALLBACK" \
      --arg decision_task "$DECISION_TASK_ID" || _facts_apply_rc=$?
    unset ATOMIC_APPLY_PROBE _FACTS_SPILL_PATH
    [[ "$_facts_apply_rc" -eq 0 ]]
  }; then
    log_msg INFO "facts union: $(printf '%s' "$FACTS_ARG" | jq -r 'keys | join(",")')"
    _FACTS_REFUSED_N=$(printf '%s' "${ATOMIC_APPLY_PROBE_OUT:-[]}" | jq -r 'length' 2> /dev/null || printf '0')
    if [[ "${_FACTS_REFUSED_N:-0}" -gt 0 ]]; then
      _facts_report_rejects "invalid --facts: ${_FACTS_REFUSED_N} class downgrade(s) refused, the rest still persist:" \
        "$ATOMIC_APPLY_PROBE_OUT" \
        "--facts: ${_FACTS_REFUSED_N} class downgrade(s) refused; remainder persisted"
    fi
    # Post-write assertion: keys in the log are not evidence the ids landed. An id that went
    # in and is not there afterwards was evicted by a clamp, which is exactly the silent loss
    # this stage exists to remove. Loud on stderr; the merge itself stands.
    FACTS_LOST=$(jq -r --argjson f "$FACTS_ARG" '
        def dec_id: if type == "string" then "str-" + @base64 else .id end;
        (([ ($f.decisions // [])[] | dec_id ] - [ (.facts.decisions // [])[].id ])
       + ([ ($f.open_questions // [])[].id ] - [ (.facts.open_questions // [])[].id ]))
       | join(", ")' "$STATE_PATH" 2> /dev/null || printf '')
    if [[ -n "$FACTS_LOST" ]]; then
      # Eviction and loss are different events and this message asserted the first one
      # unconditionally. On one run it named four ids a later write restored while four
      # OTHER ids were the ones actually gone, so the only durable clue pointed away from
      # the casualties. Ask the spill: an evicted id is recoverable through it, an id in
      # neither place is loss.
      _FACTS_RUN_IDX=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
      _FACTS_SPILL_DIR="${STATE_PATH%/*}"
      [[ "$_FACTS_SPILL_DIR" == "$STATE_PATH" ]] && _FACTS_SPILL_DIR="."
      # Both spills, because --facts writes both rings and either can be the one that
      # overflowed. A missing file is the empty set; an unparseable one is treated as
      # empty too, which errs toward reporting loss rather than hiding it.
      # Only files that exist: a `cat` over a missing spill exits non-zero, and under
      # `pipefail` that fired the `|| printf '[]'` fallback ON TOP of jq's already-emitted
      # array — two JSON documents in one variable, which --argjson then rejected and every
      # evicted id was reported as lost. Caught by this arm's own test.
      _FACTS_SPILL_FILES=()
      for _f in "$_FACTS_SPILL_DIR/decisions-${_FACTS_RUN_IDX}.jsonl" \
                "$_FACTS_SPILL_DIR/open-questions-${_FACTS_RUN_IDX}.jsonl"; do
        [[ -f "$_f" && ! -L "$_f" ]] && _FACTS_SPILL_FILES+=("$_f")
      done
      _FACTS_SPILL_IDS="[]"
      if [[ "${#_FACTS_SPILL_FILES[@]}" -gt 0 ]]; then
        _FACTS_SPILL_IDS=$(jq -c -s 'map(.id? // empty)' "${_FACTS_SPILL_FILES[@]}" 2> /dev/null) \
          || _FACTS_SPILL_IDS="[]"
      fi
      [[ -n "$_FACTS_SPILL_IDS" ]] || _FACTS_SPILL_IDS="[]"
      # Partitioned in jq rather than with grep -f and a process substitution: the fd form
      # silently yielded nothing here, which reported every evicted id as lost — the exact
      # confusion this split exists to end.
      _FACTS_LOST_SPILLED=$(printf '%s' "$FACTS_LOST" \
        | jq -Rr --argjson sp "$_FACTS_SPILL_IDS" \
            '(split(", ") | map(select(length > 0))) | map(select(. as $i | $sp | index($i))) | join(", ")' \
        2> /dev/null || printf '')
      _FACTS_LOST_GONE=$(printf '%s' "$FACTS_LOST" \
        | jq -Rr --argjson sp "$_FACTS_SPILL_IDS" \
            '(split(", ") | map(select(length > 0))) | map(select(. as $i | $sp | index($i) | not)) | join(", ")' \
        2> /dev/null || printf '')
      if [[ -n "$_FACTS_LOST_SPILLED" ]]; then
        printf >&2 'warn: --facts: clamp evicted these ids from the ledger; they remain readable via --read-decisions / the FN gate union: %s\n' \
          "$_FACTS_LOST_SPILLED"
        log_msg WARN "--facts ids evicted to spill (recoverable): ${_FACTS_LOST_SPILLED}"
      fi
      if [[ -n "$_FACTS_LOST_GONE" ]]; then
        printf >&2 'ERROR: --facts wrote but these ids are in NEITHER the ledger nor the spill — they are lost: %s\n' \
          "$_FACTS_LOST_GONE"
        log_msg ERROR "--facts ids absent after write and not spilled: ${_FACTS_LOST_GONE}"
      fi
    fi
  else
    printf >&2 'facts union failed; state.json unchanged (see %s)\n' "$LOG_FILE"
    log_msg ERROR "jq apply failed for --facts; state.json unchanged"
    exit 1
  fi

  # Standalone --facts is done here; with --stage/--artifact it falls through to the
  # completion merge, which takes its own lock.
  if [[ -z "$STAGE_ARG" && -z "$ARTIFACT_ARG" ]]; then
    if [[ "$FACTS_REJECTED" -eq 0 ]]; then
      _post_success "$(_audit_task_ref)" "$TASK_ID_ARG" "" 1
    fi
    exit $((FACTS_REJECTED == 1 ? 2 : 0))
  fi
fi

# ---------- Idempotency check ----------
# One jq read: this runs on every hook-driven stage completion, so each extra jq spawn is
# paid per stage per run. Fields are joined on US (0x1F), not tab: tab is IFS whitespace, so
# `read` would collapse the run around an empty field (gate_from_stage is empty on every
# completed row) and shift every later field one slot left. Newline and US inside a value
# are blanked so the single-line, six-field shape holds. Widened past status/verdict/
# artifact to the two fields this merge also writes: the mirrored facts.verdicts
# entry and, on a pending row, the gate_from_stage marker — either drifting from what this
# call would write means the merge is not actually a no-op.
#
# The tests_executed mirror is compared with jq equality inside the same read, not as a
# string: key order and spacing are not part of the value. A pending rework marker is never
# a no-op, since consuming it is the write that files the prior round.
CURRENT_STATUS="" CURRENT_VERDICT="" CURRENT_ARTIFACT="" CURRENT_FACT_VERDICT="" CURRENT_GATE_FROM=""
CURRENT_TE_DIRTY=""
if command -v jq > /dev/null 2>&1; then
  IDEM_ROW=$(jq -r --arg s "$TASK_ID" --arg te_state "${PARSED_TE_STATE:-unparsed}" \
    --argjson te "${PARSED_TE_JSON:-null}" \
    '(.tasks[$s] // {}) as $row
     | [.tasks[$s].status // "", .tasks[$s].verdict // "", .tasks[$s].artifact // "",
      .facts.verdicts[$s] // "", .tasks[$s].metadata.gate_from_stage // "",
      (if $te_state == "unparsed" then "0"
       elif $row.rework_pending == true then "1"
       elif $te_state == "list" then (if ($row.tests_executed // null) != $te then "1" else "0" end)
       elif ($row | has("tests_executed")) then "1"
       else "0" end)]
     | ([31] | implode) as $us
     | map(if type == "string" then gsub("[\n" + $us + "]"; " ") else . end) | join($us)' \
    "$STATE_PATH" 2> /dev/null || printf '\037\037\037\037\037')
  IFS=$'\037' read -r CURRENT_STATUS CURRENT_VERDICT CURRENT_ARTIFACT CURRENT_FACT_VERDICT \
    CURRENT_GATE_FROM CURRENT_TE_DIRTY <<< "$IDEM_ROW" || true
fi

# A remediation loop re-completes a stage at the same verdict with a fresh artifact and summary,
# so skip only when the patch would change nothing — status, verdict, artifact, the mirrored
# facts.verdicts entry, the gate marker (when pending) and the handoff edge all current.
if [[ "$CURRENT_STATUS" == "$STATUS_MAPPED" && "$CURRENT_VERDICT" == "$PARSED_VERDICT" ]]; then
  PATCH_IS_NOOP=1
  if [[ "$CURRENT_ARTIFACT" != "$ART_RECORD" ]]; then
    PATCH_IS_NOOP=0
  fi
  if [[ "$CURRENT_FACT_VERDICT" != "$PARSED_VERDICT" ]]; then
    PATCH_IS_NOOP=0
  fi
  if [[ "$STATUS_MAPPED" == "pending" && "$CURRENT_GATE_FROM" != "$PARSED_STAGE" ]]; then
    PATCH_IS_NOOP=0
  fi
  if [[ "$CURRENT_TE_DIRTY" == "1" ]]; then
    PATCH_IS_NOOP=0
  fi
  if [[ -n "$PREV_ARG" ]] && command -v jq > /dev/null 2>&1; then
    # Mirrors the handoff value built below; keep the two in step.
    WOULD_HANDOFF=$(jq -rn --arg summary "$PARSED_SUMMARY" --arg ref "$(basename "$ART")" \
      '(($summary) + " ref:" + $ref) | .[0:300]' 2> /dev/null || printf '')
    CURRENT_HANDOFF=$(jq -r --arg k "${PREV_ARG}→${TASK_ID}" '.handoffs[$k] // ""' \
      "$STATE_PATH" 2> /dev/null || printf '')
    if [[ "$CURRENT_HANDOFF" != "$WOULD_HANDOFF" ]]; then
      PATCH_IS_NOOP=0
    fi
  fi

  if [[ "$PATCH_IS_NOOP" == "1" ]]; then
    log_msg INFO "idempotent: tasks.${TASK_ID} already ${STATUS_MAPPED} verdict=${PARSED_VERDICT}"
    if [[ "$FACTS_REJECTED" -eq 0 ]]; then
      _post_success "$TASK_ID" "$TASK_ID" "${PREV_ARG:+${PREV_ARG}→${TASK_ID}}" "$([[ -n "$FACTS_ARG" ]] && printf 1 || printf 0)"
    fi
    exit $((FACTS_REJECTED == 1 ? 2 : 0))
  fi
  log_msg INFO \
    "re-merge: tasks.${TASK_ID} verdict unchanged (${PARSED_VERDICT}) but status/artifact/facts/gate/handoff differ"
fi

# ---------- Build filter + atomic write ----------
# An atomic_apply filter, not a patch object precomputed outside the lock: the gate_from_stage
# set/delete and the derived worst-verdict key both read tasks.* as it stands INSIDE the
# lock, so they must run in the same critical section as the row write, not against a
# pre-lock snapshot a sibling writer could invalidate.
#
# Additive keys (completed_via, worktree) fold in only when present, so absence stays
# absence.  facts.verdicts[<TASK_ID>] is mirrored here because this is the only writer a
# patched stage passes through: the schema has carried the field since v2 and nothing ever
# filled it, so every consumer reading it saw an empty object.  facts.verdicts[<CODE>] is
# the worst verdict across every "${CODE}<N>" row that has reported, so a split
# stage's readers see the harder state rather than whichever instance completed last.
# --prev additionally emits handoffs["<PREV>→<TASK_ID>"] (maxLength 300, must contain
# "ref:"); absent --prev ⇒ no handoffs key at all.  The destination is the WRITING TASK, so
# an N-way split writes N edges instead of collapsing to one last-writer-wins entry; the
# source stays a bare code because it answers which stage this followed, and only the
# destination ever collided.
#
# tasks.<ID>.tests_executed mirrors the artifact's current list. rework_runs[] is
# append-only: a row carrying rework_pending (set by --task-replay) files its prior list as
# {round: last round + 1, tests_executed} before the mirror is overwritten, and the marker is
# consumed. Without a marker nothing is appended, so re-merging the same artifact never adds
# a round and earlier rounds are re-emitted untouched. An unparsed list skips the whole block
# and keeps the marker for a merge that can read it.
ART_BASE=$(basename "$ART")
COMPLETION_FILTER='
  def vrank($v):
    if $v == "escalate" then 4
    elif $v == "blocked" then 3
    elif ($v == "fail" or $v == "reject" or $v == "no-go") then 2
    elif ($v == "ok" or $v == "pass" or $v == "go" or $v == "approve") then 1
    else 2 end;
  ({status: $status, artifact: $artifact, verdict: $verdict}
    + (if $via != "" then {completed_via: $via} else {} end)
    + (if ($wt_path != "" or $wt_branch != "")
       then {worktree: (
              (if $wt_path   != "" then {path:   $wt_path}   else {} end)
            + (if $wt_branch != "" then {branch: $wt_branch} else {} end))}
       else {} end)
  ) as $stageObj
  | .tasks[$taskid] = ((.tasks[$taskid] // {}) + $stageObj)
  | if $status == "pending" then
      .tasks[$taskid].metadata = ((.tasks[$taskid].metadata // {}) + {gate_from_stage: $code})
    elif ((.tasks[$taskid].metadata? // {}) | has("gate_from_stage")) then
      .tasks[$taskid].metadata |= del(.gate_from_stage)
    else . end
  | (if $prev != ""
     then .handoffs[$prev + "→" + $taskid] = ((($summary) + " ref:" + $ref) | .[0:300])
     else . end)
  | .facts.verdicts[$taskid] = $verdict
  | ([ .tasks | to_entries[] | select(.key | test("^" + $code + "[0-9]+$"))
       | select((.value.verdict // "") != "")
       | {verdict: .value.verdict, n: (.key | ltrimstr($code) | tonumber)} ]) as $rows
  | if ($rows | length) > 0
    then .facts.verdicts[$code] = ($rows | max_by([vrank(.verdict), .n]) | .verdict)
    else . end
  | if $te_state == "unparsed" then .
    else
      (.tasks[$taskid]) as $row
      | (if $row.rework_pending == true and ($row.tests_executed | type) == "array"
         then .tasks[$taskid].rework_runs = (($row.rework_runs // []) + [{
                round: (((($row.rework_runs // []) | last | .round) // 0) + 1),
                tests_executed: $row.tests_executed }])
         else . end)
      | .tasks[$taskid] |= del(.rework_pending)
      | if $te_state == "list" then .tasks[$taskid].tests_executed = $te
        else .tasks[$taskid] |= del(.tests_executed) end
    end
'

if atomic_apply "$STATE_PATH" "$COMPLETION_FILTER" \
  --arg status "$STATUS_MAPPED" \
  --arg code "$PARSED_STAGE" \
  --arg taskid "$TASK_ID" \
  --arg artifact "$ART_RECORD" \
  --arg verdict "$PARSED_VERDICT" \
  --arg via "$VIA_ARG" \
  --arg wt_path "$PARSED_WT_PATH" \
  --arg wt_branch "$PARSED_WT_BRANCH" \
  --arg prev "$PREV_ARG" \
  --arg summary "$PARSED_SUMMARY" \
  --arg ref "$ART_BASE" \
  --arg te_state "${PARSED_TE_STATE:-unparsed}" \
  --argjson te "${PARSED_TE_JSON:-null}"; then
  log_msg INFO "merged tasks.${TASK_ID} artifact=${ART} verdict=${PARSED_VERDICT} (summary: ${PARSED_SUMMARY:0:80})"
  _warn_unledgered_sweep_ids "$ART" "$STATE_PATH"
else
  log_msg ERROR "jq apply failed for task=${TASK_ID} artifact=${ART}; state.json unchanged"
  exit 1
fi

# ---------- Audit (hook path only) ----------
# The SubagentStop hook completes a stage without any Bash tool call, so the tool-use
# scraper that produces every other stage_transition row never sees it — this is the only
# place that transition can be recorded. Restricted to --via hook precisely so the scraped
# paths are not double-counted; dedupe_key lets a reader collapse a replayed hook.
# Best-effort: an unwritable log must never undo a merge that already landed.
if [[ "$VIA_ARG" == "hook" ]]; then
  AUDIT_DIR="${CTX}/logs"
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the write that already landed.
  if mkdir -p "$AUDIT_DIR" 2> /dev/null && [[ ! -L "${AUDIT_DIR}/audit.jsonl" ]]; then
    AUDIT_WT_ID=$(jq -r '.worktask_id // "unknown"' "$STATE_PATH" 2> /dev/null || printf 'unknown')
    AUDIT_RUN_IDX=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
    jq -cn \
      --arg ts "$(date -u +%FT%TZ)" \
      --arg subject "$TASK_ID" \
      --arg verdict "$PARSED_VERDICT" \
      --arg status "$STATUS_MAPPED" \
      --arg dedupe "${AUDIT_WT_ID}:${AUDIT_RUN_IDX}:${TASK_ID}:${STATUS_MAPPED}" \
      '{ts: $ts, actor: "hook:state-merge", action: "stage_transition", subject: $subject,
         result: "ok", task_id: $subject,
         metadata: {verdict: $verdict, status: $status, via: "hook", dedupe_key: $dedupe}}' \
      >> "${AUDIT_DIR}/audit.jsonl" 2> /dev/null \
      || log_msg WARN "audit append failed for tasks.${TASK_ID} (merge already applied)"
  fi
fi

if [[ "$FACTS_REJECTED" -eq 0 ]]; then
  _post_success "$TASK_ID" "$TASK_ID" "${PREV_ARG:+${PREV_ARG}→${TASK_ID}}" "$([[ -n "$FACTS_ARG" ]] && printf 1 || printf 0)"
fi
exit $((FACTS_REJECTED == 1 ? 2 : 0))
