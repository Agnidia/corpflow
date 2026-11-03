#!/usr/bin/env bash
# @description preflight-issue-scan.sh — ADVISORY scan for open GitHub issues that
#   plausibly already cover the request, run at `/worktask` entry BEFORE `.context/`
#   is created (`skills/worktask/references/workflow.md § Step 2a`).
#
#   `skills/gh-issue-dedup` binds one issue per `.context/` via the anchor or an
#   exact-title search — both only reachable once a `.context/` exists, so they
#   guard re-runs and never the first run of work already filed under different
#   wording. This scan is the layer above: advisory only, human-confirmed, and it
#   NEVER links, comments, or writes. The exact-match-only auto-bind stays as is;
#   widening it would let an unrelated same-worded issue capture a fresh context.
#
#   Scoring is local keyword overlap rather than a server-side query because
#   GitHub's issue search ANDs free-text terms — a query built from a whole request
#   sentence returns nothing for exactly the paraphrase this must catch.
#
#   NON-BLOCKING BY CONTRACT, like every helper the orchestrator invokes with a
#   trailing `|| true`: no network, no `gh`, no auth, no remote, a timeout, a
#   malformed response, or zero hits all exit 0 with a `result=` the caller reads as
#   "proceed". There is no runtime state in which this step stops a worktask.
#
#   It writes NO audit row: the ledger it would append to does not exist yet at
#   Step 2a, and creating `.context/logs/` here would strand scratch state in a
#   worktask the user then abandons in favour of an existing issue.
#
# @arg --goal <text>      The user's request text. Empty => `skipped/no_goal`.
# @arg --context <dir>    .context dir probed for the dedup anchor (default: .context).
# @arg --limit <n>        Max candidates emitted (default: 3).
# @arg --no-gh-issue      Caller passed /worktask --no-gh-issue => `skipped/opted_out`.
# @arg -h | --help        Show this header.
#
# @env PREFLIGHT_ISSUE_SCAN   0 => `skipped/opted_out`.
# @env CORPFLOW_NONINTERACTIVE 1 => `skipped/non_interactive` (nothing can answer the gate).
# @env MILESTONE_MODE         1 => `skipped/milestone_mode` (/megatask owns issue identity).
# @env INCIDENT_MODE          1 => `skipped/incident_mode` (no PL stage, no plan issue).
# @env PREFLIGHT_SCAN_POOL    Issues fetched PER STATE before scoring (default: 100).
# @env PREFLIGHT_SCAN_TIMEOUT Seconds bounding each `gh` call (default: 20).
# @env GH_BIN                 `gh` binary (default: gh).
# @env WORKSPACE_ROOT         Root probed for a megatask `workspace.json`.
#
# @stdout `result=shown|prior-run|none|skipped`, `reason=<closed set>` when not `shown`,
#         `candidates=<n>` (OPEN hits only), and one `candidate=<compact-json>` line per
#         open hit (`{number,url,title,state,score}`). JSON per line because issue titles
#         contain every plausible field separator.
#
#         Every candidate and prior `title`/`url` has passed through
#         skills/shared/scripts/path-scrub.sh. When that scrub is missing or fails, no
#         candidate or prior line is printed and the result is `skipped/scrub_unavailable`.
#
#         CLOSED hits are reported separately as `priors=<n>` plus one `prior=<json>` line
#         each, and never as `candidate=`: a closed issue is a "this task ran before"
#         signal, not something to comment on or bind a fresh context to. `result=prior-run`
#         means closed matches only — callers keying on `result=shown` proceed unprompted,
#         which is the correct disposition.
#
# @exitcode 0   Every runtime outcome, candidates or not.
# @exitcode 2   Usage error or -h.
#
# Minimum shell: bash 3.2+ (macOS default).

set -u

CONTEXT_DIR=".context"
GOAL=""
GOAL_SEEN=0
LIMIT=3
OPT_OUT=0

GH_BIN="${GH_BIN:-gh}"
POOL="${PREFLIGHT_SCAN_POOL:-100}"
SCAN_TIMEOUT="${PREFLIGHT_SCAN_TIMEOUT:-20}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-}"

# A title word must clear this many characters to count as a keyword, and a
# candidate must share this many keywords to be shown. Both are deliberately
# blunt: the output is a human prompt, not an automated decision.
MIN_KEYWORD_LEN=3
MIN_SCORE=2
MAX_KEYWORDS=8

# Request-shaped filler that co-occurs with everything and would otherwise score
# unrelated issues into the list. Words under MIN_KEYWORD_LEN are dropped anyway.
STOPWORDS="the and for with that this from into when then make made use used using
add adds added fix fixes fixed new old all any not but can its our your are was were
has have had does did get got set run via per out off support feature
should would could must need needs also more less than them they there here what
which while into onto upon about after before over under such only just even
worktask task work update updates change changes"

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --goal)
      shift
      [ $# -gt 0 ] || { printf >&2 'preflight-issue-scan: --goal requires a value\n'; exit 2; }
      GOAL="$1"; GOAL_SEEN=1; shift ;;
    --context)
      shift
      [ $# -gt 0 ] || { printf >&2 'preflight-issue-scan: --context requires a value\n'; exit 2; }
      CONTEXT_DIR="$1"; shift ;;
    --limit)
      shift
      [ $# -gt 0 ] || { printf >&2 'preflight-issue-scan: --limit requires a value\n'; exit 2; }
      LIMIT="$1"; shift ;;
    --no-gh-issue) OPT_OUT=1; shift ;;
    -h|--help) usage ;;
    *) printf >&2 'preflight-issue-scan: unknown argument: %s\n' "$1"; exit 2 ;;
  esac
done

[ "$GOAL_SEEN" = "1" ] || { printf >&2 'preflight-issue-scan: --goal is required\n'; exit 2; }
case "$LIMIT" in
  ''|*[!0-9]*) printf >&2 'preflight-issue-scan: --limit must be a non-negative integer\n'; exit 2 ;;
esac

finish_skipped() { # $1=reason
  printf 'result=skipped\n'
  printf 'reason=%s\n' "$1"
  printf 'candidates=0\n'
  exit 0
}

finish_none() { # $1=reason
  printf 'result=none\n'
  printf 'reason=%s\n' "$1"
  printf 'candidates=0\n'
  exit 0
}

# Bounded execution WITHOUT coreutils, mirroring publish-pl-issue.sh: stock macOS
# ships neither `timeout` nor `gtimeout`, so the usual `command -v timeout` idiom
# resolves to empty and leaves the call unbounded on the platform that needs it.
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi
  "$@" &
  local p=$! n=0
  while kill -0 "$p" 2> /dev/null && [ "$n" -lt "$secs" ]; do
    sleep 1; n=$((n + 1))
  done
  if kill -0 "$p" 2> /dev/null; then
    kill -9 "$p" 2> /dev/null || true
    wait "$p" 2> /dev/null || true
    return 124
  fi
  wait "$p" 2> /dev/null
  return $?
}

# ---------- guards ----------------------------------------------------------
[ "$OPT_OUT" = "1" ] && finish_skipped opted_out
[ "${PREFLIGHT_ISSUE_SCAN:-1}" = "0" ] && finish_skipped opted_out
[ "$LIMIT" = "0" ] && finish_skipped opted_out

# An AskUserQuestion gate cannot be answered by a batch, cron or CI invocation, so
# an unattended run must never reach one. Skip-and-proceed is the only safe default:
# the worst case is the duplicate this step exists to prevent, which is strictly
# better than a pipeline blocked on a prompt nobody will see.
[ "${CORPFLOW_NONINTERACTIVE:-0}" = "1" ] && finish_skipped non_interactive
[ "${INCIDENT_MODE:-0}" = "1" ] && finish_skipped incident_mode
[ "${MILESTONE_MODE:-0}" = "1" ] && finish_skipped milestone_mode
if [ -n "$WORKSPACE_ROOT" ] && [ -f "$WORKSPACE_ROOT/workspace.json" ]; then
  finish_skipped milestone_mode
fi
[ -f "$PWD/workspace.json" ] && finish_skipped milestone_mode

# A context already bound to an issue is a RESUME, not a first run — the anchor in
# skills/gh-issue-dedup already answers this question authoritatively.
[ -f "$CONTEXT_DIR/gh-issue.json" ] && finish_skipped already_anchored

command -v jq > /dev/null 2>&1 || finish_skipped jq_unavailable

# Titles are free text from GitHub and reach the audit trail, so a host path in one
# must never survive into a candidate line. Loaded before any network call: without
# the scrub there is nothing this scan may print.
SCAN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2> /dev/null && pwd -P)" || SCAN_DIR=""
PATH_SCRUB="$SCAN_DIR/../../shared/scripts/path-scrub.sh"
[ -n "$SCAN_DIR" ] && [ -r "$PATH_SCRUB" ] || finish_skipped scrub_unavailable
# shellcheck source=skills/shared/scripts/path-scrub.sh
. "$PATH_SCRUB" > /dev/null 2>&1 || finish_skipped scrub_unavailable
command -v corpflow_path_scrub > /dev/null 2>&1 || finish_skipped scrub_unavailable
[ -n "${CORPFLOW_HOST_PATH_ERE:-}" ] || finish_skipped scrub_unavailable

# ---------- keyword extraction ----------------------------------------------
# Stemmed to a bare singular, and matched as a word PREFIX below, so "issues"
# scores against "issue" and "open" against "opened" — morphological drift is the
# commonest way a paraphrase escapes exact matching.
KEYWORDS=$(
  printf '%s' "$GOAL" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9' ' ' \
    | LC_ALL=C tr -s ' ' '\n' \
    | awk -v min="$MIN_KEYWORD_LEN" '
        length($0) >= min {
          if (length($0) >= 4 && substr($0, length($0)) == "s" && substr($0, length($0) - 1) != "ss") {
            $0 = substr($0, 1, length($0) - 1)
          }
          if (length($0) >= min) print
        }' \
    | grep -v -w -F -f <(printf '%s' "$STOPWORDS" | tr -s '[:space:]' '\n') \
    | awk '!seen[$0]++' \
    | head -n "$MAX_KEYWORDS"
)
[ -n "$KEYWORDS" ] || finish_skipped no_keywords

KEYWORDS_JSON=$(printf '%s\n' "$KEYWORDS" | jq -R . | jq -cs .) || finish_skipped no_keywords

# A single surviving keyword cannot clear a 2-keyword bar; requiring it would make
# short requests silently unscannable rather than honestly unmatched.
EFFECTIVE_MIN="$MIN_SCORE"
if [ "$(printf '%s\n' "$KEYWORDS" | wc -l | tr -d ' ')" -lt "$MIN_SCORE" ]; then
  EFFECTIVE_MIN=1
fi

# ---------- fetch ------------------------------------------------------------
command -v "$GH_BIN" > /dev/null 2>&1 || finish_skipped gh_not_installed
run_with_timeout "$SCAN_TIMEOUT" "$GH_BIN" auth status > /dev/null 2>&1 || finish_skipped auth_missing
git remote get-url origin 2> /dev/null | grep -q . || finish_skipped no_remote

# Redirected to a file rather than captured through `$(...)`: a killed `gh` can
# leave a grandchild holding the write end of a command-substitution pipe, and the
# read would then outlive the timeout it exists to enforce.
SCAN_TMP=$(mktemp "${TMPDIR:-/tmp}/preflight-issue-scan.XXXXXX" 2> /dev/null) \
  || finish_skipped search_failed
SCAN_TMP_CLOSED=$(mktemp "${TMPDIR:-/tmp}/preflight-issue-scan.XXXXXX" 2> /dev/null) \
  || finish_skipped search_failed
trap 'rm -f "$SCAN_TMP" "$SCAN_TMP_CLOSED" 2>/dev/null || true' EXIT

# Two calls rather than one `--state all`: `gh` returns the newest $POOL issues of
# whatever it was asked for, so on a repo with an active closed backlog an `all` pool
# fills with closed issues and pushes every open one out — hiding exactly the open
# duplicate this scan exists to find. A per-state pool gives each class its own budget.
# `state` joins the field list because the disposition below treats the two classes
# differently and cannot infer the class from number/title/url.
run_with_timeout "$SCAN_TIMEOUT" "$GH_BIN" issue list --state open \
  --json number,title,url,state --limit "$POOL" > "$SCAN_TMP" 2> /dev/null \
  || finish_skipped search_failed
RAW_OPEN=$(cat "$SCAN_TMP" 2> /dev/null || true)
[ -n "$RAW_OPEN" ] || finish_skipped search_failed
printf '%s' "$RAW_OPEN" | jq -e 'type == "array"' > /dev/null 2>&1 || finish_skipped search_failed

# The closed pool only ever ADDS the "this task already ran" hint, so its failure
# degrades to empty instead of skipping: losing that hint is strictly better than
# also losing the open-duplicate check the open pool already fetched.
RAW_CLOSED='[]'
if run_with_timeout "$SCAN_TIMEOUT" "$GH_BIN" issue list --state closed \
  --json number,title,url,state --limit "$POOL" > "$SCAN_TMP_CLOSED" 2> /dev/null; then
  CLOSED_BODY=$(cat "$SCAN_TMP_CLOSED" 2> /dev/null || true)
  if printf '%s' "$CLOSED_BODY" | jq -e 'type == "array"' > /dev/null 2>&1; then
    RAW_CLOSED="$CLOSED_BODY"
  fi
fi

RAW=$(jq -cn --argjson o "$RAW_OPEN" --argjson c "$RAW_CLOSED" '$o + $c' 2> /dev/null) \
  || finish_skipped search_failed
[ -n "$RAW" ] || finish_skipped search_failed

# Keywords are `[a-z0-9]+` by construction above, so interpolating them into the
# regex below cannot inject alternation or anchors. `$k` is bound before the pipe
# because `$t | test(...)` rebinds `.` to the title.
# `state` is normalised to lowercase here so the two dispositions below split on one
# spelling. `gh` emits "OPEN"/"CLOSED"; the GraphQL surface has used lowercase, and a
# case-sensitive split would silently route every closed hit into the open list.
SCORED=$(printf '%s' "$RAW" | jq -c \
  --argjson kws "$KEYWORDS_JSON" --argjson min "$EFFECTIVE_MIN" '
  [ .[]
    | select((.title // "") != "")
    | . as $i
    | (($i.title | ascii_downcase)) as $t
    | { number: $i.number, url: $i.url, title: $i.title,
        state: ((($i.state // "open") | ascii_downcase)),
        score: ([ $kws[] | . as $k
                  | select($t | test("(^|[^a-z0-9])" + $k)) ] | length) }
  ]
  | map(select(.score >= $min))
  | sort_by(-.score, -.number)' 2> /dev/null) || finish_skipped search_failed
[ -n "$SCORED" ] || finish_skipped search_failed

MATCHED=$(printf '%s' "$SCORED" | jq -c --argjson lim "$LIMIT" \
  '[ .[] | select(.state != "closed") ] | .[0:$lim]' 2> /dev/null || printf '[]')
PRIORS=$(printf '%s' "$SCORED" | jq -c --argjson lim "$LIMIT" \
  '[ .[] | select(.state == "closed") ] | .[0:$lim]' 2> /dev/null || printf '[]')

# $1 = JSON array of hits; prints it with title and url scrubbed, or returns 1. One
# value per line through the scrub, counted back against a trailing marker, so a scrub
# that drops or merges a line can never shift a title onto another issue.
scrub_hits() {
  local arr="$1" n fields out
  n=$(printf '%s' "$arr" | jq 'length' 2> /dev/null) || return 1
  if [ "$n" -eq 0 ]; then
    printf '%s' "$arr"
    return 0
  fi
  fields=$(printf '%s' "$arr" \
    | jq -r '.[] | ((.title // ""), (.url // "")) | tostring | gsub("[\r\n\t]"; " ")') || return 1
  out=$(set -o pipefail; printf '%s\nEND-OF-FIELDS\n' "$fields" | corpflow_path_scrub) || return 1
  printf '%s' "$arr" | jq -c --arg s "$out" '
    ($s | split("\n")) as $l
    | if ($l | length) < (length * 2 + 1) or $l[length * 2] != "END-OF-FIELDS"
      then error("scrub changed the line count")
      else [ range(0; length) as $i | .[$i] + {title: $l[2 * $i], url: $l[2 * $i + 1]} ] end' \
    2> /dev/null
}

MATCHED=$(scrub_hits "$MATCHED") || finish_skipped scrub_unavailable
PRIORS=$(scrub_hits "$PRIORS") || finish_skipped scrub_unavailable

COUNT=$(printf '%s' "$MATCHED" | jq 'length' 2> /dev/null || printf '0')
PRIOR_COUNT=$(printf '%s' "$PRIORS" | jq 'length' 2> /dev/null || printf '0')

emit_priors() {
  printf 'priors=%s\n' "$PRIOR_COUNT"
  [ "$PRIOR_COUNT" = "0" ] && return 0
  # A DIFFERENT key from `candidate=`. A closed issue must never reach the caller's
  # "use one of the existing issues" arm: binding a context to it would write a dedup
  # anchor pointing at an issue nothing can be commented onto or closed by this run.
  printf '%s' "$PRIORS" | jq -c '.[]' | while IFS= read -r line; do
    printf 'prior=%s\n' "$line"
  done
  printf >&2 'preflight-issue-scan: %s closed issue(s) match — this task may have run before\n' \
    "$PRIOR_COUNT"
}

# Disposition ladder. Open matches keep today's `result=shown` contract exactly, so no
# existing caller changes behaviour. Closed-only matches are the new arm: `prior-run` is
# not a "comment on it" candidate but a "here is the previous run" signal, and every
# caller that keys on `result=shown` correctly proceeds unprompted.
if [ "$COUNT" != "0" ]; then
  printf 'result=shown\n'
  printf 'candidates=%s\n' "$COUNT"
  printf '%s' "$MATCHED" | jq -c '.[]' | while IFS= read -r line; do
    printf 'candidate=%s\n' "$line"
  done
  emit_priors
  printf >&2 'preflight-issue-scan: %s open issue(s) may already cover this request\n' "$COUNT"
  exit 0
fi

if [ "$PRIOR_COUNT" != "0" ]; then
  printf 'result=prior-run\n'
  printf 'reason=closed_match\n'
  printf 'candidates=0\n'
  emit_priors
  exit 0
fi

finish_none no_candidates
