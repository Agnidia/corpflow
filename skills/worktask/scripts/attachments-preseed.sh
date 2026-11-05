#!/usr/bin/env bash
# attachments-preseed.sh — renders the two Conductor-convention attachments
# (`.context/attachments/PR instructions.md` and `Review request.md`).
#
# Both writers read attachments-pr-template.md and attachments-review-template.md
# from skills/worktask/assets/templates/. Placeholder sources: attachments-sources.md.
#
# Usage:
#   attachments-preseed.sh [--workdir DIR] [--worktask-id ID] [--branch NAME]
#                          [--base-branch NAME] [--run-index N]
#                          [--commit-type TYPE] [--issue-ref N]
#                          [--uncommitted N] [--upstream NAME|--no-upstream]
#                          [--ts ISO8601]
#   attachments-preseed.sh --self-test
#
# Exit codes: 0 written, 2 usage or broken install (template document missing,
# unreadable or empty), 3 base branch unresolved.
#
# Every input is auto-resolved from git / .context/state.json when the flag is
# omitted, so the orchestrator can invoke it with no arguments from the
# worktask root.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="."
WORKTASK_ID=""
BRANCH=""
BASE_BRANCH=""
RUN_INDEX=""
COMMIT_TYPE=""
ISSUE_REF=""
UNCOMMITTED=""
UPSTREAM=""
UPSTREAM_SET=0
ISO_TS=""
MODE="write"

usage() {
  cat >&2 <<'USAGE'
usage: attachments-preseed.sh [--workdir DIR] [--worktask-id ID] [--branch NAME]
                              [--base-branch NAME] [--run-index N]
                              [--commit-type TYPE] [--issue-ref N]
                              [--uncommitted N] [--upstream NAME|--no-upstream]
                              [--ts ISO8601]
       attachments-preseed.sh --self-test
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)      WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --worktask-id)  WORKTASK_ID="${2:?--worktask-id needs a value}"; shift 2 ;;
    --branch)       BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --base-branch)  BASE_BRANCH="${2:?--base-branch needs a value}"; shift 2 ;;
    --run-index)    RUN_INDEX="${2:?--run-index needs a value}"; shift 2 ;;
    --commit-type)  COMMIT_TYPE="${2:?--commit-type needs a value}"; shift 2 ;;
    --issue-ref)    ISSUE_REF="${2:?--issue-ref needs a value}"; shift 2 ;;
    --uncommitted)  UNCOMMITTED="${2:?--uncommitted needs a value}"; shift 2 ;;
    --upstream)     UPSTREAM="${2:?--upstream needs a value}"; UPSTREAM_SET=1; shift 2 ;;
    --no-upstream)  UPSTREAM=""; UPSTREAM_SET=1; shift ;;
    --ts)           ISO_TS="${2:?--ts needs a value}"; shift 2 ;;
    --self-test)    MODE="self-test"; shift ;;
    -h|--help)      usage; exit 2 ;;
    *) printf >&2 'attachments-preseed.sh: unknown arg: %s\n' "$1"; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- audit ----

# Shared audit-row appender. `[ -r ]` before the `.`: a bare `.` on a missing file is a
# special-builtin error that exits the shell, bypassing an `if !` guard.
_AUDIT_LIB="$SELF_DIR/../../shared/lib/audit-lib.sh"
if [ ! -r "$_AUDIT_LIB" ]; then
  printf >&2 'attachments-preseed: plugin install broken — audit-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/audit-lib.sh
. "$_AUDIT_LIB"

# The row gains a `ts` and carries `reason` under `metadata`, which is where every other
# emitter in the plugin puts it. This was the one row in the plugin with no timestamp —
# an audit row with no time is evidence that cannot be ordered against any other.
#
# `--meta-kv`, not `--meta`: the library drops an arbitrary JSON literal on a jq-less host
# (it cannot be made injection-safe without a parser) but renders a flat pair under the
# same sanitiser, so the reason survives the degradation that the FN refusal path needs.
audit_failed() {
  corpflow_audit_row --file "$WORKDIR/.context/logs/audit.jsonl" --actor orchestrator \
    --action fn_attachments_preseed_failed --subject "FN${RUN_INDEX:-0}" \
    --result error --task-id unknown --meta-kv "reason=$1"
}

# ------------------------------------------------------------ resolvers ----

json_str() {
  # $1 = file, $2..= jq path segments. Prints the value or nothing. jq is a
  # hard prerequisite of the suite, but the writer must still degrade to its
  # documented defaults on a host without it rather than abort the FN gate.
  [[ -f "$1" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$2 // empty" "$1" 2>/dev/null || return 0
}

first_match() {
  # $1 = file, $2 = grep -E pattern. Prints the first matching whole line.
  [[ -f "$1" ]] || return 0
  grep -m1 -E "$2" "$1" 2>/dev/null || return 0
}

section_bullets() {
  # $1 = file, $2 = heading text. Emits the section's non-blank lines as `- `
  # bullets, or nothing when the file or section is absent/empty.
  [[ -f "$1" ]] || return 0
  awk -v h="$2" '
    $0 ~ "^## " h {found=1; next}
    found && /^## / {found=0}
    found && NF {print "- " $0}
  ' "$1"
}

STATE="$WORKDIR/.context/state.json"

if [[ -z "$RUN_INDEX" ]]; then
  RUN_INDEX="$(json_str "$STATE" '.run_index')"
  RUN_INDEX="${RUN_INDEX:-0}"
fi

if [[ -z "$WORKTASK_ID" ]]; then
  WORKTASK_ID="$(json_str "$STATE" '.worktask_id')"
  WORKTASK_ID="${WORKTASK_ID:-unknown}"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$BRANCH" ]] || BRANCH="$(json_str "$STATE" '.facts.branch')"
  BRANCH="${BRANCH:-HEAD}"
fi

# Base-branch resolution order is skills/worktask/references/attachments-sources.md § Git & branch state,
# highest first. There is deliberately NO literal fallback: an unresolved base
# would silently target the wrong branch in the rendered `gh pr create` command.
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="${FN_BASE_REF:-}"
  [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(json_str "$STATE" '.metadata.base_ref')"
  [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(json_str "$STATE" '.git.base_branch')"
  [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(json_str "$WORKDIR/workspace.json" '.git.base_branch')"
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="$(git -C "$WORKDIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
    BASE_BRANCH="${BASE_BRANCH#refs/remotes/origin/}"
  fi
fi
if [[ -z "$BASE_BRANCH" ]] && [[ "$MODE" != "self-test" ]]; then
  printf >&2 'attachments-preseed.sh: base branch unresolved — pass --base-branch\n'
  audit_failed "base_branch_unresolved"
  exit 3
fi

if [[ -z "$COMMIT_TYPE" ]]; then
  # skills/worktask/references/attachments-sources.md § Plan, issue & verdict fields: the type comes from
  # facts.goal via branch-lib's derive_type, NOT from the plan file.
  GOAL="$(json_str "$STATE" '.facts.goal')"
  if [[ -n "$GOAL" && -r "$SELF_DIR/branch-lib.sh" ]]; then
    # shellcheck source=/dev/null
    . "$SELF_DIR/branch-lib.sh"
    COMMIT_TYPE="$(derive_type "$GOAL")"
  fi
  COMMIT_TYPE="${COMMIT_TYPE:-feature}"
fi

if [[ -z "$ISSUE_REF" ]]; then
  ISSUE_REF="$(json_str "$WORKDIR/workspace.json" '.issue_number')"
  [[ -n "$ISSUE_REF" ]] || ISSUE_REF="$(json_str "$STATE" '.metadata.issue_ref')"
fi
ISSUE_REF="${ISSUE_REF#\#}"

if [[ -z "$UNCOMMITTED" ]]; then
  UNCOMMITTED="$(git -C "$WORKDIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  UNCOMMITTED="${UNCOMMITTED:-0}"
fi

if [[ "$UPSTREAM_SET" -eq 0 ]]; then
  UPSTREAM="$(git -C "$WORKDIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
fi
if [[ -n "$UPSTREAM" ]]; then
  UPSTREAM_LINE="Upstream tracking: origin/${BRANCH}."
else
  UPSTREAM_LINE="No upstream branch yet — use \`git push -u origin ${BRANCH}\`."
fi

ISO_TS="${ISO_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

CTX="$WORKDIR/.context"
DR_FILE="$CTX/developer-review-${RUN_INDEX}.md"
QA_FILE="$CTX/testing-${RUN_INDEX}.md"

DR_VERDICT="$(first_match "$DR_FILE" 'Approval Status')"
DR_VERDICT="${DR_VERDICT:-unknown}"
QA_VERDICT="$(first_match "$QA_FILE" 'GO/NO-GO')"
QA_VERDICT="${QA_VERDICT:-unknown}"

DR_CONCERNS="$(section_bullets "$DR_FILE" 'Issues Found')"
DR_CONCERNS="${DR_CONCERNS:-(none flagged)}"
QA_NOTES="$(section_bullets "$QA_FILE" 'Results')"
QA_NOTES="${QA_NOTES:-(none)}"

if [[ -n "$ISSUE_REF" ]]; then
  ISSUE_LINE="- Issue: #${ISSUE_REF} — include \`Closes #${ISSUE_REF}\` in the PR body to auto-close on merge."
else
  ISSUE_LINE=""
fi

# ----------------------------------------------------------- rendering ----

substitute() {
  # Reads $1, resolves every placeholder, writes back. The `X` sentinel keeps
  # command substitution from eating the template's trailing newlines, which
  # the byte-equivalence contract in conductor-attachments.md depends on.
  local f="$1" c
  c="$(cat "$f"; printf 'X')"
  c="${c%X}"

  # `<N>` is overloaded in the source template — it is the uncommitted count in
  # part 1/part 3 and the ISSUE number in part 7's `Closes #<N>` checklist row.
  # Substituting it globally would rewrite the checklist, so both intended
  # sites are matched with their surrounding text instead.
  c="${c//- Uncommitted changes: <N>/- Uncommitted changes: ${UNCOMMITTED}}"
  c="${c//The worktask reports \`<N>\`/The worktask reports \`${UNCOMMITTED}\`}"

  if [[ -n "$ISSUE_LINE" ]]; then
    c="${c//<ISSUE_LINE>/${ISSUE_LINE}}"
  else
    c="${c//<ISSUE_LINE>$'\n'/}"
  fi
  if [[ -n "$ISSUE_REF" ]]; then
    c="${c//<ISSUE>/${ISSUE_REF}}"
  fi

  c="${c//<WORKTASK_ID>/${WORKTASK_ID}}"
  c="${c//<ISO_TS>/${ISO_TS}}"
  c="${c//<BASE_BRANCH>/${BASE_BRANCH}}"
  c="${c//<BRANCH>/${BRANCH}}"
  c="${c//<UPSTREAM_LINE>/${UPSTREAM_LINE}}"
  c="${c//<TYPE>/${COMMIT_TYPE}}"
  c="${c//<DR_VERDICT>/${DR_VERDICT}}"
  c="${c//<QA_VERDICT>/${QA_VERDICT}}"
  c="${c//<DR_CONCERNS_BULLETS>/${DR_CONCERNS}}"
  c="${c//<QA_NOTES_BULLETS>/${QA_NOTES}}"

  printf '%s' "$c" > "$f"
}


# Out-parameter of load_template. Not a return value: command substitution eats
# trailing newlines, and the byte-equivalence contract depends on them.
TEMPLATE_BODY=""

broken_install() {
  printf >&2 'attachments-preseed.sh: plugin install broken — %s\n' "$1"
  audit_failed "template_unreadable"
  exit 2
}

# Concatenates the fenced bodies of the `Template part N` blocks under the
# `## Template — $1` heading, in document order, adding and dropping nothing —
# the emission rule the document states for itself. A trailing blank line at the
# end of a part is therefore load-bearing.
load_template() {
  local name="$1" template_doc
  case "$name" in
    'PR instructions.md') template_doc="$SELF_DIR/../assets/templates/attachments-pr-template.md" ;;
    'Review request.md') template_doc="$SELF_DIR/../assets/templates/attachments-review-template.md" ;;
    *) broken_install "unknown template: $name" ;;
  esac
  [[ -r "$template_doc" ]] || broken_install "template document not readable: $template_doc"
  TEMPLATE_BODY="$(awk -v want="## Template — \`$name\`" '
    $0 == want { inblk = 1; next }
    # Template bodies carry their own `## ` headings, so the end-of-section
    # test only applies outside a fence.
    inblk && !fence && /^## / { inblk = 0 }
    inblk && /^~~~markdown$/ { fence = 1; next }
    inblk && fence && /^~~~$/ { fence = 0; next }
    inblk && fence { print }
  ' "$template_doc"; printf 'X')"
  TEMPLATE_BODY="${TEMPLATE_BODY%X}"
  [[ -n "${TEMPLATE_BODY//[[:space:]]/}" ]] \
    || broken_install "template section is empty or missing: $name"
}


emit() {
  local dir="$WORKDIR/.context/attachments" pr rv
  # Both templates are loaded before either file is opened, so a broken install
  # leaves no partially written attachment behind.
  load_template 'PR instructions.md'; pr="$TEMPLATE_BODY"
  load_template 'Review request.md'; rv="$TEMPLATE_BODY"
  mkdir -p "$dir"
  printf '%s' "$pr" > "$dir/PR instructions.md"
  printf '%s' "$rv" > "$dir/Review request.md"
  substitute "$dir/PR instructions.md"
  substitute "$dir/Review request.md"
  printf '%s\n' "$dir/PR instructions.md" "$dir/Review request.md"
}

# ----------------------------------------------------------- self-test ----

if [[ "$MODE" == "self-test" ]]; then
  td="$(mktemp -d "${TMPDIR:-/tmp}/preseed-selftest-XXXXXX")"
  trap 'rm -rf "$td"' EXIT
  WORKDIR="$td"; BASE_BRANCH="main"; BRANCH="feature/x"; WORKTASK_ID="self-test"
  UNCOMMITTED=0; UPSTREAM=""; UPSTREAM_LINE="No upstream branch yet — use \`git push -u origin ${BRANCH}\`."
  mkdir -p "$td/.context"
  emit >/dev/null
  rc=0
  for f in "$td/.context/attachments/PR instructions.md" "$td/.context/attachments/Review request.md"; do
    [[ -s "$f" ]] || { printf >&2 'FAIL: %s not written\n' "$f"; rc=1; }
    # Every placeholder the § Data sources table defines must be resolved. The
    # skeleton's own angle-bracket prose (<Change 1>, <severity>, …) is not a
    # placeholder, so the check is on the exact token list, not on `<...>`.
    if grep -qE '<(WORKTASK_ID|ISO_TS|BRANCH|BASE_BRANCH|UPSTREAM_LINE|DR_VERDICT|QA_VERDICT|DR_CONCERNS_BULLETS|QA_NOTES_BULLETS|ISSUE_LINE)>' "$f"; then
      printf >&2 'FAIL: unresolved placeholder in %s\n' "$f"; rc=1
    fi
  done
  if [[ $rc -eq 0 ]]; then
    echo "PASS: attachments-preseed.sh --self-test"
  fi
  exit "$rc"
fi

emit
