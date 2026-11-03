#!/usr/bin/env bash
# @description stale-check.sh — read-only staleness detector for a worktask ledger.
#
#   Scans `tasks.*` for `status: "in_progress"`, reconciles each against
#   `facts.dispatched_agents[]` and the live-session list, and prints the verdict
#   `skills/worktask/references/resume.md` already assigns to that shape. It answers
#   one question the resume runbook cannot: *is anything wedged right now* — without
#   an operator first remembering to resume the session.
#
#   The classification taxonomy is NOT defined here. `resume.md § Live-agent rows`
#   is the single source of truth; every finding cites the row it came from so the
#   two cannot drift into disagreeing verdicts. Adding a class means editing
#   resume.md first, this script second.
#
#   STRICTLY READ-ONLY. It writes nothing — not state.json, not an audit row, not a
#   log. It never re-delegates, never patches a task, never nudges an agent.
#   Recovery stays a human decision (`agents/workflow-engineer.md` DO-NOT list:
#   "DO NOT proceed past stuck states without documenting resolution").
#
#   A false "stale" is worse than a missed one: a spurious verdict on a healthy
#   long-running stage invites someone to kill live work. So every ambiguity —
#   command missing, non-zero exit, unparseable or unrecognised output, an
#   unfamiliar liveness token — resolves to `liveness-unknown`, never to `gone`.
#   Detection keys on agent liveness, never on elapsed time, so a legitimately slow
#   stage is never reported stale while its agent is alive.
#
# @arg --state <path>        state.json path (default: <context>/state.json).
# @arg --context <dir>       .context dir (default: .context).
# @arg --agents-json <path>  Read the live-session array from a file instead of
#                            shelling the CLI. For tests, and for diagnosing a
#                            ledger from a host where the sessions do not live.
#                            `-` reads stdin.
# @arg --json                Emit the findings as one JSON object instead of text.
# @arg -h | --help           Show this header.
#
# Exit codes:
#   0  nothing needs attention (no in_progress stages, or every one has a live,
#      busy agent — or no ledger exists at all)
#   1  at least one in_progress stage needs a human decision
#   2  usage / unreadable-input error
#   3  liveness could not be determined for at least one stage, and nothing else
#      needed attention (never reported as stale)

set -euo pipefail

CONTEXT_DIR=".context"
STATE_PATH=""
AGENTS_JSON=""
OUT_FORMAT="text"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

# A value-taking option with nothing after it is a usage error, not a finding: exit 1 is
# reserved for "a stage needs a human decision", and `shift 2` on a one-element "$@" aborts
# under `set -u` with that very code.
# A bare `-` stays legal: --agents-json reads stdin under it. Only a `--flag` in the value
# position is refused, which is the shape a truncated command line actually takes.
need_value() {  # <flag> [candidate]
  case "${2:-}" in
    '' | --*) ;;
    *) return 0 ;;
  esac
  printf 'stale-check: %s needs a value\n' "$1" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)       need_value "$@"; STATE_PATH="$2"; shift 2 ;;
    --context)     need_value "$@"; CONTEXT_DIR="$2"; shift 2 ;;
    --agents-json) need_value "$@"; AGENTS_JSON="$2"; shift 2 ;;
    --json)        OUT_FORMAT="json"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'stale-check: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$STATE_PATH" ] || STATE_PATH="$CONTEXT_DIR/state.json"

# Liveness is gathered in bash so the CLI stays swappable on $PATH, and so a
# missing binary, a crash and empty output stay three distinguishable outcomes
# rather than collapsing into one empty string.
AGENTS_STATUS="ok"
AGENTS_RAW=""
AGENTS_SOURCE="cli"
if [ -n "$AGENTS_JSON" ]; then
  AGENTS_SOURCE="file"
  if [ "$AGENTS_JSON" = "-" ]; then
    AGENTS_RAW="$(cat)"
  elif [ -r "$AGENTS_JSON" ]; then
    AGENTS_RAW="$(cat "$AGENTS_JSON")"
  else
    printf 'stale-check: --agents-json not readable: %s\n' "$AGENTS_JSON" >&2
    exit 2
  fi
elif ! command -v claude >/dev/null 2>&1; then
  AGENTS_STATUS="unavailable"
else
  # `--all` also lists completed background sessions, so a genuinely absent row
  # means gone rather than merely finished (skills/worktask/references/recovery-procedure.md § Resume Procedure step 0).
  if ! AGENTS_RAW="$(claude agents --json --all 2>/dev/null)"; then
    AGENTS_STATUS="error"
  fi
fi

STALE_CHECK_AGENTS_RAW="$AGENTS_RAW" \
python3 - "$STATE_PATH" "$CONTEXT_DIR" "$AGENTS_STATUS" "$OUT_FORMAT" "$AGENTS_SOURCE" <<'PYEOF'
import json, os, sys

state_path, context_dir, agents_status, out_format, agents_source = sys.argv[1:6]
agents_raw = os.environ.get("STALE_CHECK_AGENTS_RAW", "")

RESUME = "skills/worktask/references/resume.md"

# Verdicts are quoted from resume.md so a reader can diff the two; the `source`
# field names the row each one belongs to.
CLASSES = {
    "alive-busy": (
        False,
        "Agent busy. Leave it; poll/await. Do not double-dispatch or nudge",
        f"{RESUME} § Live-agent rows — liveness branch — parked, awaiting input",
    ),
    # The class is the union of two rows: the responsive park keyed on `waitingFor`, cited
    # here, and the operator-owned "Needs input" park under the sibling heading. Both remedies
    # ship, because the CLI field that separates them is not always present.
    "alive-parked": (
        True,
        "Parked on us. SendMessage reattach with awaited answer — do not re-delegate. "
        "Operator-owned (\"Needs input\"): SendMessage only to surface prompt — "
        "never auto-answer or re-dispatch",
        f"{RESUME} § Live-agent rows — liveness branch — alive and responsive",
    ),
    "gone": (
        True,
        "Agent gone. Re-delegate from the first incomplete stage",
        f"{RESUME} § Live-agent rows — parked or gone",
    ),
    "budget-halt": (
        True,
        "Budget halt, not stage failure. Raise the budget, then re-dispatch — and do NOT "
        "increment metadata.retry_count",
        f"{RESUME} § Live-agent rows — parked or gone",
    ),
    "no-dispatch-record": (
        True,
        "Stale task state. Re-derive from the most recent .context/logs/ capture",
        f"{RESUME} § Near-done & stale rows",
    ),
    "dispatch-settled": (
        True,
        "Dispatch record is terminal while the ledger still reads in_progress. Do not reattach — "
        "reconcile the ledger against the on-disk artifact, then advance",
        f"{RESUME} § Step 0 notes — dispatched_agents matching",
    ),
    "liveness-unknown": (
        False,
        "Liveness could not be determined — NOT a staleness verdict. Diagnose by hand via "
        f"{RESUME} § Resume Procedure step 0 before touching the stage",
        f"{RESUME} § Step 0 notes — why the pre-check",
    ),
    "reattach-undeliverable": (
        True,
        "A reattach SendMessage did not deliver (refused / dropped / oversized / burst_limited / "
        "queued / held / session_list_truncated). The stage is still parked, not nudged. "
        "Do NOT re-delegate and do NOT increment metadata.retry_count — resolve the delivery "
        "failure first",
        f"{RESUME} § Reattach rows — the SendMessage has a result too",
    ),
    "hook-config-broken": (
        True,
        "Operator-owned park: a PermissionRequest/PreToolUse hook printed an invalid answer, so the "
        "session is waiting on broken configuration. SendMessage cannot clear it — fix the hook, "
        "then resume. Not a stage to re-dispatch",
        f"{RESUME} § Live-agent rows — broken hook configuration",
    ),
}

TERMINAL = {"done", "completed", "failed", "error", "stopped", "killed", "cancelled", "canceled"}
PARKED = {"blocked", "waiting", "needs input", "needs_input", "needs-input", "paused"}
BUSY = {"active", "busy", "running", "working", "in_progress"}


def die(msg, code=2):
    print(f"stale-check: {msg}", file=sys.stderr)
    sys.exit(code)


def parse_rows(raw, status):
    """Return (rows, status). Any doubt about the shape downgrades to unknown."""
    if status != "ok":
        return [], status
    text = raw.strip()
    if not text:
        return [], "unparseable"
    try:
        rows = json.loads(text)
    except ValueError:
        return [], "unparseable"
    if not isinstance(rows, list):
        return [], "unrecognized-shape"
    rows = [r for r in rows if isinstance(r, dict)]
    # An empty list from a successful `--all` is real data (no sessions at all).
    # A non-empty list where nothing exposes a liveness field is a format we do
    # not understand — reading absence from it would manufacture false verdicts.
    if rows and not any(
        k in r for r in rows for k in ("state", "status", "waitingFor")
    ):
        return [], "unrecognized-shape"
    return rows, "ok"


def row_ids(row):
    return {row.get(k) for k in ("agent_id", "id", "sessionId") if row.get(k)}


def match_row(entry, rows):
    """Find the live row for a dispatch entry, tolerating id/sessionId truncation.

    The CLI abbreviates `id` to a prefix of `sessionId`, so an exact-equality-only
    match silently reports a live agent as gone."""
    aid = entry.get("agent_id")
    if aid:
        for row in rows:
            if aid in row_ids(row):
                return row
        if len(aid) >= 6:
            for row in rows:
                sid, rid = row.get("sessionId") or "", row.get("id") or ""
                if sid.startswith(aid) or (len(rid) >= 6 and aid.startswith(rid)):
                    return row
    # Names are not unique, so a name decides only when exactly one row carries it. Two or
    # more are an ambiguous match: an empty row classifies as liveness-unknown, never as gone,
    # because re-delegating beside a live twin doubles the stage's work. The name itself is
    # stable for peers across a reload or --resume since Claude Code 2.1.309.
    name = entry.get("name")
    if name:
        named = [row for row in rows if row.get("name") == name]
        if len(named) == 1:
            return named[0]
        if named:
            return {}
    return None


def classify_row(row):
    # A hook-config park is checked first: it presents as an ordinary park but
    # SendMessage cannot clear it, so reading it as `alive-parked` sends a nudge
    # the session will reject again. Field name is UNCONFIRMED — coalesce several
    # spellings, exactly as the "Needs input" axis is handled.
    for key in ("hookError", "hook_error", "brokenHook", "broken_hook"):
        if str(row.get(key) or "").strip():
            return "hook-config-broken"
    # `waitingFor` is the documented park signal but is absent from the shipping
    # CLI output; state/status carry it there, so both are consulted.
    if str(row.get("waitingFor") or "").strip().lower() in ("approval", "input"):
        return "alive-parked"
    token = str(row.get("state") or row.get("status") or "").strip().lower()
    if token in TERMINAL:
        return "gone"
    if token in PARKED:
        return "alive-parked"
    if token in BUSY:
        return "alive-busy"
    return "liveness-unknown"


_AUDIT_CACHE = {}


def audit_rows(context_dir):
    """Parsed audit rows, with the count of unparseable lines named on stderr.

    Skipping malformed lines silently makes a corrupt log read exactly like a log
    with no matching rows — the same silent-failure shape this checker reports on.
    Warned once per path; the parsed rows are still returned."""
    path = os.path.join(context_dir, "logs", "audit.jsonl")
    if path in _AUDIT_CACHE:
        return _AUDIT_CACHE[path]
    rows, bad = [], 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if isinstance(row, dict):
                    rows.append(row)
                else:
                    bad += 1
    except OSError:
        _AUDIT_CACHE[path] = []
        return []
    if bad:
        print(
            f"stale-check: {path}: {bad} unparseable audit row(s) skipped",
            file=sys.stderr,
        )
    _AUDIT_CACHE[path] = rows
    return rows


def had_stage_failure(context_dir):
    """True when the audit log records a real per-stage failure.

    Its ABSENCE is what separates a simultaneous multi-agent disappearance
    (external budget halt) from independent stage crashes."""
    for row in audit_rows(context_dir):
        if row.get("result") == "error":
            return True
    return False


def undelivered_reattach(context_dir):
    """Task ids whose most recent reattach_send_result did not deliver.

    A parked stage whose nudge never landed looks identical to one that was
    nudged and is still working; only the audit trail separates them."""
    latest = {}
    for row in audit_rows(context_dir):
        if row.get("action") != "reattach_send_result":
            continue
        tid = row.get("task_id") or row.get("subject")
        if tid:
            latest[tid] = row.get("result")
    return {tid for tid, result in latest.items() if result not in ("ok", None)}


if not os.path.exists(state_path):
    payload = {
        "state_path": state_path,
        "liveness": agents_status,
        "in_progress": 0,
        "verdict": "clear",
        "note": "no ledger at this path — no worktask is in flight here",
        "findings": [],
    }
    if out_format == "json":
        print(json.dumps(payload, indent=2))
    else:
        print(f"stale-check: no ledger at {state_path} — no worktask in flight. Nothing to check.")
    sys.exit(0)

try:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError) as exc:
    die(f"cannot read ledger {state_path}: {exc}")
if not isinstance(state, dict):
    die(f"ledger {state_path} is not a JSON object")

tasks = state.get("tasks") or {}
if not isinstance(tasks, dict):
    die(f"ledger {state_path} has no usable tasks{{}} map")

in_progress = [
    (tid, t)
    for tid, t in tasks.items()
    if isinstance(t, dict) and t.get("status") == "in_progress"
]

facts = state.get("facts") if isinstance(state.get("facts"), dict) else {}
dispatched = facts.get("dispatched_agents")
by_task = {}
if isinstance(dispatched, list):
    for entry in dispatched:
        if isinstance(entry, dict) and entry.get("task_id"):
            by_task[entry["task_id"]] = entry

rows, liveness = parse_rows(agents_raw, agents_status)

findings = []
for task_id, task in sorted(in_progress):
    meta = task.get("metadata") if isinstance(task.get("metadata"), dict) else {}
    entry = by_task.get(task_id)
    matched = None
    if entry is None:
        cls = "no-dispatch-record"
    elif entry.get("status") in ("completed", "failed"):
        cls = "dispatch-settled"
    elif liveness != "ok":
        cls = "liveness-unknown"
    else:
        matched = match_row(entry, rows)
        cls = "gone" if matched is None else classify_row(matched)
    findings.append(
        {
            "task_id": task_id,
            "stage": meta.get("stage") or task_id[:2],
            "agent": meta.get("agent") or (entry or {}).get("subagent_type"),
            "agent_id": (entry or {}).get("agent_id"),
            "retry_count": meta.get("retry_count"),
            "classification": cls,
            "live_row": matched,
        }
    )

# Several agents vanishing at once with no failure row in the audit log is the
# budget-halt shape, not N independent stage failures — and the two get opposite
# retry_count handling, so the promotion has to happen before the verdict.
gone = [f for f in findings if f["classification"] == "gone"]
if len(gone) >= 2 and not had_stage_failure(context_dir):
    for f in gone:
        f["classification"] = "budget-halt"

# An undelivered reattach outranks what liveness said, but only where a nudge is
# the remedy: the stage reads parked (or gone, when discovery itself was
# truncated) yet the fix is the delivery failure, and re-delegating off it spends
# a retry the stage never earned. A settled or unrecorded dispatch never sends
# again, so a stale failed row must not hide its reconcile/re-derive remedy.
NUDGE_REMEDY = {"alive-parked", "gone", "budget-halt", "liveness-unknown"}
undelivered = undelivered_reattach(context_dir)
if undelivered:
    for f in findings:
        if f["task_id"] in undelivered and f["classification"] in NUDGE_REMEDY:
            f["classification"] = "reattach-undeliverable"

for f in findings:
    needs, action, source = CLASSES[f["classification"]]
    f["needs_attention"] = needs
    f["action"] = action
    f["source"] = source

attention = [f for f in findings if f["needs_attention"]]
unknown = [f for f in findings if f["classification"] == "liveness-unknown"]

if attention:
    verdict, code = "attention", 1
elif unknown:
    verdict, code = "unknown", 3
else:
    verdict, code = "clear", 0

payload = {
    "state_path": state_path,
    "worktask_id": state.get("worktask_id"),
    "liveness": liveness,
    "agents_source": agents_source,
    "in_progress": len(in_progress),
    "verdict": verdict,
    "findings": [{k: v for k, v in f.items() if k != "live_row"} for f in findings],
}

if out_format == "json":
    print(json.dumps(payload, indent=2))
    sys.exit(code)

wt = state.get("worktask_id") or "(unnamed)"
print(f"stale-check: {state_path} — worktask {wt}")
print(f"  liveness source: {liveness}   in_progress stages: {len(in_progress)}")
if liveness != "ok":
    print("  live-session list unusable — every stage below reads liveness-unknown, NOT stale.")
if not findings:
    print("  no stage is in_progress. Nothing to check.")
for f in findings:
    mark = "!" if f["needs_attention"] else "-"
    print()
    print(f"  {mark} {f['task_id']}  [{f['classification']}]")
    print(f"      agent:  {f['agent'] or '(none recorded)'}  id={f['agent_id'] or '(none)'}")
    print(f"      action: {f['action']}")
    print(f"      source: {f['source']}")
print()
print(f"  verdict: {verdict}")
sys.exit(code)
PYEOF
