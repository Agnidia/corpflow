#!/usr/bin/env bash
# cache-lint.sh — preamble byte-stability lint for the handoff-protocol cache prefix.
#
# Modes:
#
#   1. Prefix lint (default):
#        cache-lint.sh <prompt-log.jsonl>
#      Reads a prompt-log.jsonl (one prompt per line, schema:
#        {"worktask_id": "...", "stage": "...", "prompt": "..."}
#      where `prompt` contains the marker tags named in
#      skills/worktask/references/contracts/prompt-layout.md#cache-prefix as section delimiters:
#      <<<contract-reminder>>>, <<<worktask-header>>>, <<<state-json>>>,
#      <<<stage-contract>>>, <<<model-discipline>>>, <<<task-description>>>,
#      <<<retry-hints>>>, <<<stage-banners>>>.
#      Asserts byte-identity of sections [1] contract-reminder + [2]
#      worktask-header across ALL stages of the same worktask_id, and
#      byte-identity of sections [4] stage-contract + [4b] model-discipline
#      across all calls of the same (worktask_id, stage) pair. Exits 1 on drift.
#
#      An optional `model` field on a log line turns on the canon check:
#      section [4b] must equal, byte for byte, the block
#      skills/shared/model-prompting.md carries for that alias. Byte-identity
#      alone cannot see a stage that consistently carries the WRONG model's
#      block, which is the routing miss this check exists for.
#
#      An optional `contract_canon: true` field turns on the same kind of
#      check for section [1]: it must equal, byte for byte, the fenced block
#      skills/worktask/references/contract-reminder.md ships.
#
#      Every log line whose prompt carries the <<<state-json>>> marker gets
#      section [3] checked unconditionally (no opt-in field): the first
#      non-empty line must be `ledger: .context/state.json`, all six digest
#      keys must appear in skills/worktask/references/contracts/prompt-layout.md#cache-prefix order, and an
#      embedded ledger (a line opening with `{`, or a `"tasks"`/`"facts"`
#      token) is rejected. A line with no [3] section at all is skipped.
#
#      N (number of lines compared) is computed from the FIRST stage's
#      sections [1]+[2]+[4] line count — derived dynamically, NOT a magic
#      number. Robust to spec changes.
#
#   2. Anchor lint:
#        cache-lint.sh --anchor-lint <artifact.md>
#      Verifies the artifact's H2 headings match the per-stage allow-list
#      from skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list.
#      Stage is read from the artifact's `handoff:` frontmatter block (yq when
#      it parses it; awk subset fallback when yq is absent OR errors).
#      Exits 1 on missing/extra anchors.
#
#   3. Frontmatter template lint:
#        cache-lint.sh --frontmatter-template-lint <agent.md> [<agent.md> ...]
#      For each stage agent, asserts:
#        - The `## Handoff Protocol` section exists.
#        - Inside it, there is exactly one fenced ```yaml block.
#        - That block contains a `handoff:` mapping with a `stage:` value.
#        - The `stage:` value matches the canonical agent→stage mapping.
#        - The block is ≤30 lines (per skills/worktask/references/contracts/frontmatter.md#frontmatter-schema).
#      Drift-detection guard: catches "someone re-inlined boilerplate" or
#      changed the per-stage frontmatter template inconsistently between
#      agents and `skills/worktask/references/stage-contracts.md § Per-Stage Frontmatter
#      Templates`. Exits 1 on any failure; lists every offending agent.
#
#   4. Filename lint:
#        cache-lint.sh --filename-lint <context-dir>
#      Scans all stage artifacts in the given .context/ directory and asserts
#      each filename matches the canonical #stage-artifact-map from
#      handoff-protocol.md. Stage is inferred from handoff: frontmatter.
#      Flags non-canonical names (e.g. arch-0.md instead of
#      architecture-0.md). Exits 1 on any violation.
#
#   5. Agent-section cross-check:
#        cache-lint.sh --agent-section-lint [<repo-root>]
#      For every stage, resolves that stage's agent file and asserts each `## X`
#      section its prose instructs it to write into the stage artifact is already
#      accepted by this lint (stage allow-list row, UNIVERSAL_ANCHORS, or
#      _STAGE_OPTIONAL for that stage or `*`). Catches contradiction shape (iv): an agent mandating a
#      heading anchor_lint rejects, which no artifact can satisfy. Names both files.
#      Extraction under-matches by design — see agent_mandated_sections.
#      Exits 1 on any unaccepted mandate.
#
#   6. Allow-list print (read-only; the generator and the preflight hook read the
#      allow-list only through this mode):
#        cache-lint.sh --allow-list [--stage <CODE>]
#      TSV <stage> <agent> <basename> <kind> <heading>, kind one of required|universal|
#      optional|any-optional; any-optional rows carry stage `*` and empty agent/basename
#      and close every listing. Placeholders stay literal. Exit 2 on an unknown stage.
#
#   7. Anchor diff (the one H2 comparison behind --anchor-lint, the hook and the harness):
#        cache-lint.sh --anchor-diff (--stage <CODE> | --for-path <path>) [--baseline <file>] <file|->
#      TSV `missing\t<h>` rows (allow-list order), then `unexpected\t<h>` rows (document
#      order). --for-path resolves an exact <canonical>-<N>.md basename, plus DV's
#      development-<N>-<stream>.md (S1 slug, <= 40 chars); nothing else. A heading
#      present in --baseline is never unexpected. Exit 0 clean, 1 diff, 2 usage, unknown
#      stage or unreadable input.
#
#   8. Self-test:
#        cache-lint.sh --self-test   (alias: --selftest)
#      Runs all modes against built-in fixtures (tempdir). Exits 0 on pass.
#
# Reference: skills/worktask/references/contracts/prompt-layout.md#cache-prefix
#            skills/worktask/references/contracts/template-rules.md#per-stage-frontmatter-templates

set -euo pipefail

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
  exit 2
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; }

# ---------- Anchor allow-list (mirrors skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list) ----------
# POSIX-compatible lookup (bash 3.2 has no associative arrays).
# One row per stage: <code> <agent-basename> <canonical-artifact-basename> <anchors…>.
#
# One row, not four parallel case tables: a new stage otherwise stayed half-added and nothing
# could report which table was missed. Anchors mirror skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list,
# basenames its #stage-artifact-map, agents stage-contracts.md § Per-Stage Frontmatter
# Templates; UNIVERSAL_ANCHORS and OPTIONAL_ANCHOR_RE add the stage-independent obligations.
_STAGE_TABLE='PL product-manager planning requirements acceptance-criteria scope out-of-scope risks complexity stages summary
AR software-architector architecture decisions trade-offs patterns integration-points schemas open-questions risks
TL team-lead coordination fan-out shared-snippets sequence risks
DV developer development files-changed tests-added deviations follow-ups
DR technical-lead developer-review findings verdict blockers follow-ups
SR security-reviewer security-review findings verdict blockers threat-model
QA qa-engineer testing results coverage regressions verdict
DC technical-writer documentation files-changed cross-references follow-ups
RE release-engineer release artifacts version rollback-plan
FN project-manager complete-summary summary artifacts followups metrics
ST stakeholder retrospective decision learnings followups
IR incident-responder incident root-cause fix-plan blast-radius
ET ethics-reviewer ethics-review findings verdict mitigations'

# Out-parameter of _stage_row, holding the matched row minus its stage code. Not a return
# value: a command substitution would fork once per lookup per artifact.
_STAGE_ROW=""

# _stage_row <stage> — rc 1 with _STAGE_ROW empty when the stage is unknown.
_stage_row() {
  local row
  _STAGE_ROW=""
  [ -n "${1:-}" ] || return 1
  while IFS= read -r row; do
    case "$row" in
      "$1 "*) _STAGE_ROW="${row#* }"; return 0 ;;
    esac
  done <<< "$_STAGE_TABLE"
  return 1
}

# The anchors an artifact of <stage> must carry, space-separated. Empty for an unknown
# stage, which every caller reads as "not a stage artifact".
anchors_for_stage() {
  _stage_row "$1" || { echo ""; return 0; }
  # shellcheck disable=SC2086  # deliberate word split: the row is space-separated
  set -- $_STAGE_ROW
  shift 2
  echo "$*"
}

# The agent basename that owns <stage> — DV -> developer.
stage_to_agent_basename() {
  _stage_row "$1" || { echo ""; return 0; }
  # shellcheck disable=SC2086  # deliberate word split
  set -- $_STAGE_ROW
  echo "$1"
}

# The canonical artifact basename for <stage> — DV -> development. Pinned against six other
# spellings of the same map by artifact-map-parity.bats.
canonical_basename_for_stage() {
  _stage_row "$1" || { echo ""; return 0; }
  # shellcheck disable=SC2086  # deliberate word split
  set -- $_STAGE_ROW
  echo "$2"
}

# The inverse of stage_to_agent_basename, read off the same rows rather than out of a
# second table that could disagree with it.
agent_basename_to_stage() {
  local row key="${1:-}"
  [ -n "$key" ] || { echo ""; return 0; }
  while IFS= read -r row; do
    # shellcheck disable=SC2086  # deliberate word split
    set -- $row
    if [ "$2" = "$key" ]; then echo "$1"; return 0; fi
  done <<< "$_STAGE_TABLE"
  echo ""
}

# Anchors REQUIRED in every stage artifact, on top of that stage's own row. Stage-independent
# obligations live here rather than in thirteen copies of anchors_for_stage:
#   elicitation-sweep  the closing sweep's artifact-body transport — the full items or the
#                      explicit empty statement. Mandatory for all 13 stages, no grace.
UNIVERSAL_ANCHORS='elicitation-sweep'

# Anchors ALLOWED but required in none, so neither retroactively fails an older artifact nor
# is reported as unexpected in a newer one. One `|`-delimited row per stage (title-case
# headings carry spaces); the `*` row applies to every stage. Placeholders: `<N>` is a run
# number, `<Platform>` a platform name; every other character is literal.
#   *   rework-<N>, re-review   rework and second-pass review sections the DR gate reads.
#       design-preview, test-strategy   PL-written, but any stage may carry them.
#   AR  the two H2s agents/software-architector.md mandates.
#   TL  agents/team-lead.md logs a rejected TC under coordination-N.md § Blockers.
#   DV  verification-command and decisions are contract-mandated; the title-case two are
#       agent-mandated. acceptance-commands lists exact-output checks for QA to replay.
#   QA  acceptance-commands records each replayed check (acceptance-check.sh reads it);
#       the title-case form is what cross-skill readers cite as `§ Visual Evidence`.
#   RE, IR, ST   legacy wrappers and the retrospective's self-improvement note.
# Title-case entries sit on their owning stage's row, so another stage writing one is
# unexpected there.
_STAGE_OPTIONAL='*|rework-<N>|re-review|design-preview|test-strategy
AR|<Platform> App Architecture|Test Architecture
TL|Blockers
DV|verification-command|acceptance-commands|decisions|Blockers|DV Completion Checklist
QA|acceptance-commands|Visual Evidence|Design Comparison
RE|Release Preparation Summary
IR|Incident Report
ST|Self-Improvement'

# _optional_headings <stage|*> — the row's headings, one per line; empty for no row.
_optional_headings() {
  local row
  while IFS= read -r row; do
    case "$row" in
      "$1|"*) printf '%s\n' "${row#*|}" | tr '|' '\n'; return 0 ;;
    esac
  done <<< "$_STAGE_OPTIONAL"
}

# _heading_ere <heading> — sets _ERE to the heading as an unanchored ERE. Pure bash: it
# runs at load time on every invocation, including every hooked artifact write.
_heading_ere() {
  local s="$1" c
  _ERE=""
  while [ -n "$s" ]; do
    case "$s" in
      '<N>'*) _ERE="${_ERE}[0-9]+"; s="${s#<N>}"; continue ;;
      '<Platform>'*) _ERE="${_ERE}[A-Za-z][A-Za-z0-9+ -]*"; s="${s#<Platform>}"; continue ;;
    esac
    c="${s:0:1}"
    s="${s:1}"
    case "$c" in
      '.' | '*' | '+' | '?' | '(' | ')' | '{' | '|' | '$' | '[') _ERE="${_ERE}[$c]" ;;
      "\\" | '^') _ERE="${_ERE}\\$c" ;;
      *) _ERE="$_ERE$c" ;;
    esac
  done
}

# _optional_alt <stage|*> — sets _ALT to the row's headings as one ERE alternation.
_optional_alt() {
  local h
  _ALT=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    _heading_ere "$h"
    _ALT="${_ALT:+$_ALT|}$_ERE"
  done <<< "$(_optional_headings "$1")"
}

_optional_alt '*'
# The `^(` prefix of this line is a contract: elicitation-sweep-contracts.bats plants into it.
OPTIONAL_ANCHOR_RE='^('"$_ALT"')$'

# optional_re_for_stage <stage> — sets _OPT_RE to OPTIONAL_ANCHOR_RE widened by the stage's
# own row. Built from OPTIONAL_ANCHOR_RE rather than the `*` row so a planted edit to that
# variable reaches every caller.
optional_re_for_stage() {
  _optional_alt "$1"
  _OPT_RE="$OPTIONAL_ANCHOR_RE"
  [ -n "$_ALT" ] && _OPT_RE="${OPTIONAL_ANCHOR_RE%)\$}|$_ALT)\$"
  return 0
}

# ---------- Frontmatter stage extractor ----------
# The frontmatter block alone (between the first two `---` lines), empty if absent.
# Everything downstream parses THIS, never the whole file: an artifact body is markdown,
# and a table cell or a `**Bold**:` line makes a whole-file YAML parse abort on a document
# whose frontmatter is perfectly well-formed.
frontmatter_block() {
  awk '/^---$/{c++; if (c==1) next; if (c==2) exit} c==1' "$1"
}

# The awk subset parser — the fallback whenever yq cannot answer. Reads a `stage:` line
# out of an already-isolated frontmatter block.
_stage_via_awk() {
  awk '
    /^[[:space:]]*stage:[[:space:]]*/ {
      sub(/^[[:space:]]*stage:[[:space:]]*/, "")
      gsub(/[[:space:]"]+/, "")
      print
      exit
    }'
}

# Prints stage code on stdout; empty if genuinely absent.
#
# Two failure modes that look identical from the outside must NOT be conflated:
#   - yq ran and reported no stage  -> a REAL absence; report it, do not paper over it
#     with a second parser that might disagree.
#   - yq errored (or is missing)    -> NO answer; fall back to awk.
# Treating the second as the first is how this lint failed OPEN: --anchor-lint reported
# "no stage in handoff frontmatter" for artifacts that carry one, and every anchor of
# every such artifact went unchecked on any host where yq is installed.
extract_stage() {
  local fm out
  fm=$(frontmatter_block "$1")
  [ -n "$fm" ] || return 0
  if command -v yq >/dev/null 2>&1; then
    if out=$(printf '%s\n' "$fm" | yq eval '.handoff.stage // ""' - 2>/dev/null); then
      [ "$out" = "null" ] && out=""
      printf '%s\n' "$out"
      return 0
    fi
  fi
  printf '%s\n' "$fm" | _stage_via_awk
}

# ---------- Anchor diff core ----------
# H2 headings of <file|-> in document order, fenced blocks skipped.
h2_headings() {
  awk '
    BEGIN { in_fence = 0 }
    /^```/ { in_fence = !in_fence; next }
    !in_fence && /^## / {
      sub(/^## +/, "")
      sub(/[[:space:]]+$/, "")
      print
    }
  ' "$1"
}

# The stage whose canonical artifact is exactly <basename>-<N>.md; empty otherwise, so an
# aliased name never resolves. The one suffixed form is DV's development-<N>-<stream>.md:
# each DV ledger task's stream file IS that row's handoff (handoff-protocol.md § DV fan-out —
# ledger tasks), so it carries the DV set exactly as the harness and the Post lint apply it.
stage_for_path() {
  local base row code
  base="${1##*/}"
  if [[ "$base" =~ ^development-[0-9]+-([a-z0-9]+(-[a-z0-9]+)*)\.md$ ]]; then
    [[ "${#BASH_REMATCH[1]}" -le 40 ]] && printf 'DV\n'
    return 0
  fi
  case "$base" in *-[0-9]*.md) ;; *) return 0 ;; esac
  local stem="${base%.md}"
  local num="${stem##*-}"
  case "$num" in '' | *[!0-9]*) return 0 ;; esac
  stem="${stem%-*}"
  while IFS= read -r row; do
    # shellcheck disable=SC2086  # deliberate word split: the row is space-separated
    set -- $row
    code="$1"
    if [ "$3" = "$stem" ]; then printf '%s\n' "$code"; return 0; fi
  done <<< "$_STAGE_TABLE"
}

# anchor_diff <stage> <file|-> [baseline-file] — TSV `missing\t<h>` rows in allow-list order,
# then `unexpected\t<h>` rows in document order, deduplicated. A heading also present in the
# baseline is never unexpected. rc 0 clean, 1 on any row, 2 unknown stage or unreadable input.
anchor_diff() {
  local stage="$1" src="$2" baseline="${3:-}"
  local expected
  expected=$(anchors_for_stage "$stage")
  [[ -n "$expected" ]] || return 2
  # Appended AFTER the unknown-stage check so an unrecognised stage still reports as such
  # rather than as a missing sweep heading. Both the missing loop and the unexpected loop read
  # $expected, so one append makes the anchor required and accepted in a single stroke.
  expected="$expected $UNIVERSAL_ANCHORS"

  local found base_found=""
  if [[ "$src" == "-" ]]; then
    found=$(h2_headings -) || return 2
  else
    [[ -r "$src" ]] || return 2
    found=$(h2_headings "$src") || return 2
  fi
  if [[ -n "$baseline" ]]; then
    [[ -r "$baseline" ]] || return 2
    base_found=$(h2_headings "$baseline") || return 2
  fi

  optional_re_for_stage "$stage"
  local rc=0 exp h seen=$'\n'
  local nl=$'\n'
  for exp in $expected; do
    case "$nl$found$nl" in
      *"$nl$exp$nl"*) ;;
      *) printf 'missing\t%s\n' "$exp"; rc=1 ;;
    esac
  done
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    case "$seen" in *"$nl$h$nl"*) continue ;; esac
    seen="$seen$h$nl"
    case "$nl${expected// /$nl}$nl" in *"$nl$h$nl"*) continue ;; esac
    [[ "$h" =~ $_OPT_RE ]] && continue
    case "$nl$base_found$nl" in *"$nl$h$nl"*) continue ;; esac
    printf 'unexpected\t%s\n' "$h"
    rc=1
  done <<< "$found"
  return $rc
}

# ---------- Allow-list print ----------
# allow_list [stage] — TSV `<stage>\t<agent>\t<basename>\t<kind>\t<heading>`, stages in
# _STAGE_TABLE order, then the `*` rows with empty agent and basename. rc 2 unknown stage.
allow_list() {
  local want="${1:-}" row code agent base h
  if [[ -n "$want" ]]; then
    _stage_row "$want" || return 2
  fi
  while IFS= read -r row; do
    # shellcheck disable=SC2086  # deliberate word split: the row is space-separated
    set -- $row
    code="$1" agent="$2" base="$3"
    shift 3
    [[ -z "$want" || "$want" == "$code" ]] || continue
    for h in "$@"; do printf '%s\t%s\t%s\trequired\t%s\n' "$code" "$agent" "$base" "$h"; done
    for h in $UNIVERSAL_ANCHORS; do printf '%s\t%s\t%s\tuniversal\t%s\n' "$code" "$agent" "$base" "$h"; done
    while IFS= read -r h; do
      [[ -n "$h" ]] && printf '%s\t%s\t%s\toptional\t%s\n' "$code" "$agent" "$base" "$h"
    done <<< "$(_optional_headings "$code")"
  done <<< "$_STAGE_TABLE"
  while IFS= read -r h; do
    [[ -n "$h" ]] && printf '*\t\t\tany-optional\t%s\n' "$h"
  done <<< "$(_optional_headings '*')"
  return 0
}

# ---------- Anchor lint ----------
anchor_lint() {
  local artifact="$1"
  [[ -f "$artifact" ]] || { echo "anchor-lint: file not found: $artifact" >&2; exit 2; }

  local stage
  stage=$(extract_stage "$artifact")
  if [[ -z "$stage" ]]; then
    echo "anchor-lint: $artifact: no stage in handoff frontmatter (possibly path F3 — frontmatter missing)" >&2
    exit 1
  fi
  if [[ -z "$(anchors_for_stage "$stage")" ]]; then
    echo "anchor-lint: $artifact: unknown stage '$stage' (no anchor allow-list)" >&2
    exit 1
  fi

  local rows drc=0
  rows=$(anchor_diff "$stage" "$artifact") || drc=$?
  [[ "$drc" -le 1 ]] || { echo "anchor-lint: $artifact: unreadable" >&2; exit 2; }

  if [[ "$drc" -eq 1 ]]; then
    local missing extras
    missing=$(awk -F'\t' '$1 == "missing" { printf "%s%s", (n++ ? " " : ""), $2 }' <<< "$rows")
    # Sorted, space-terminated: the report shape predates the diff core and callers grep it.
    extras=$(awk -F'\t' '$1 == "unexpected" { print $2 }' <<< "$rows" | sort -u | tr '\n' ' ')
    echo "anchor-lint: $artifact (stage=$stage) FAIL" >&2
    [[ -n "$missing" ]] && echo "  missing: $missing" >&2
    [[ -n "$extras" ]] && echo "  unexpected: $extras" >&2
    exit 1
  fi

  echo "anchor-lint: $artifact (stage=$stage) ok"
}

# --anchor-diff CLI: argument parsing and exit mapping around anchor_diff.
anchor_diff_cli() {
  local stage="" for_path="" baseline="" src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage) stage="${2:-}"; shift 2 || return 2 ;;
      --for-path) for_path="${2:-}"; shift 2 || return 2 ;;
      --baseline) baseline="${2:-}"; shift 2 || return 2 ;;
      --) shift; src="${1:-}"; break ;;
      -) src="-"; shift ;;
      -*) echo "anchor-diff: unknown flag: $1" >&2; return 2 ;;
      *) src="$1"; shift ;;
    esac
  done
  if [[ -n "$stage" && -n "$for_path" ]] || [[ -z "$stage" && -z "$for_path" ]] || [[ -z "$src" ]]; then
    echo "anchor-diff: usage: --anchor-diff (--stage <CODE> | --for-path <path>) [--baseline <file>] <file|->" >&2
    return 2
  fi
  if [[ -n "$for_path" ]]; then
    stage=$(stage_for_path "$for_path")
    [[ -n "$stage" ]] || { echo "anchor-diff: not a canonical stage artifact path: $for_path" >&2; return 2; }
  fi
  local rc=0
  anchor_diff "$stage" "$src" "$baseline" || rc=$?
  [[ "$rc" -ne 2 ]] || echo "anchor-diff: unknown stage '$stage' or unreadable input" >&2
  return $rc
}

# ---------- Agent-section cross-check (#16 letter b) ----------
# The H2 names an agent's prose INSTRUCTS it to write into its own stage artifact.
#
# Deliberately under-matching: a false negative leaves today's behaviour, while a
# false positive would block correct work by rejecting a section no agent ever mandated.
# Three filters, all conservative:
#   1. The name must sit in its own code span opening with `## ` — `development-N.md ## decisions`
#      is one span starting with a filename and is not a mandate this check can read.
#   2. The SAME line must name a stage-artifact file (`<name>-N.md`, `-0.md`, `release-*.md`).
#      That is what separates "write this into your artifact" from a cross-reference to another
#      document's heading, and it is why `.context/errors/developer.md` — no run-index segment —
#      never reaches the check.
#   3. A placement word must be ADJACENT to the span — introducing it (`under \x60## X\x60`) or
#      following it (`\x60## X\x60 section`). Same-line proximity is not enough: developer.md
#      L475 cites `## decisions` in prose on a line that separately names `development-N.md`,
#      and security-reviewer.md L65 reaches "read as \x60git diff\x60" and "\x60## anchor\x60" on
#      one line ending in `security-review-N.md`. Adjacency rejects both; a loose same-line
#      word test accepted both.
#   4. Placeholder names are dropped: anything holding `<`, `[`, or a bare trailing ` N`/`-N`
#      segment cannot be compared literally against an allow-list entry.
agent_mandated_sections() {
  local agent="$1"
  grep -E '`## ' "$agent" 2>/dev/null \
    | grep -E '[a-z][a-z-]*-(N|\*|[0-9]+)\.md' \
    | grep -E '(under|over|as|into|H2)[[:space:]]+`##[[:space:]]|`##[[:space:]][^`]+`[[:space:]]+(sections?|H2|headings?)' \
    | grep -oE '`## [^`]+`' \
    | sed -e 's/^`## //' -e 's/`$//' -e 's/[[:space:]]*$//' \
    | grep -vE '[<>[]' \
    | grep -vE '(^|[ -])N$' \
    | sort -u
}

# For each stage: every section its agent mandates must already be accepted by the lint
# (stage row ∪ UNIVERSAL_ANCHORS ∪ OPTIONAL_ANCHOR_RE). The failure this catches is
# contradiction shape (iv) — an agent told to write an H2 that anchor_lint then rejects,
# which no artifact author can satisfy. Both files are named because the fix is a choice
# between them, not a mechanical edit to one.
agent_section_lint() {
  local root="${1:-.}" rc=0 checked=0
  local stage agent_base agent expected sect
  for stage in PL AR TL DV DR SR QA DC RE FN ST IR ET; do
    agent_base=$(stage_to_agent_basename "$stage")
    agent="$root/agents/$agent_base.md"
    [[ -f "$agent" ]] || continue
    checked=$((checked + 1))
    expected="$(anchors_for_stage "$stage") $UNIVERSAL_ANCHORS"
    optional_re_for_stage "$stage"
    while IFS= read -r sect; do
      [[ -n "$sect" ]] || continue
      if [[ "$sect" =~ $_OPT_RE ]]; then continue; fi
      if grep -qx -- "$sect" <<< "$(printf '%s\n' $expected)"; then continue; fi
      echo "agent-section-lint: FAIL stage=$stage" >&2
      echo "  agents/$agent_base.md mandates '## $sect' into its artifact" >&2
      echo "  skills/worktask/scripts/cache-lint.sh accepts neither anchors_for_stage $stage" \
        "nor UNIVERSAL_ANCHORS nor _STAGE_OPTIONAL ($stage or *)" >&2
      rc=1
    done <<< "$(agent_mandated_sections "$agent")"
  done

  if [[ $checked -eq 0 ]]; then
    echo "agent-section-lint: no stage agents found under $root/agents/" >&2
    return 1
  fi
  [[ $rc -eq 0 ]] && echo "agent-section-lint: $checked stage agents checked, all mandated sections accepted"
  return $rc
}

# ---------- Prefix lint ----------
extract_section() {
  # extract_section <prompt-text> <marker> → section body between
  # <<<marker>>> and the next <<<...>>> tag (or EOF).
  local body="$1" marker="$2"
  awk -v m="$marker" '
    $0 == "<<<" m ">>>" { capture = 1; next }
    /^<<<.*>>>$/ && capture { exit }
    capture { print }
  ' <<< "$body"
}

# Resolves the plugin root through the shared host-neutral ladder, then falls back to the
# script's fixed location (skills/worktask/scripts/ -> root).
plugin_root() {
  local d lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared/lib" && pwd)/corpflow-base.sh"
  if [[ -r "$lib" ]]; then
    # shellcheck source=skills/shared/lib/corpflow-base.sh
    . "$lib"
    if d=$(corpflow_plugin_root); then
      printf '%s' "$d"
      return 0
    fi
  fi
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
  printf '%s' "$d"
}

# canonical_model_block <alias> <root> -> the fenced `text` block under that
# alias's H2 in model-prompting.md, or empty when the alias has none (haiku).
# The heading match tolerates both `## haiku` and `## opus — Claude Opus 5.5`,
# because the em-dash suffix is prose and is not part of the key.
canonical_model_block() {
  local alias="$1" root="$2" canon="$2/skills/shared/model-prompting.md"
  [[ -f "$canon" ]] || { echo "prefix-lint: canon not found: $canon" >&2; return 2; }
  awk -v a="$alias" '
    $0 ~ "^## " a "($| )" { inalias = 1; next }
    /^## / { inalias = 0 }
    inalias && $0 == "```text" { infence = 1; next }
    infence && $0 == "```" { exit }
    infence { print }
  ' "$canon"
}

# canonical_contract_block <root> -> the fenced `text` block in
# contract-reminder.md — section [1], copied verbatim into every stage prompt.
# The file holds exactly one fenced block, so this walks the first fence
# with no per-alias heading gate, unlike canonical_model_block above.
canonical_contract_block() {
  local root="$1" canon="$1/skills/worktask/references/contract-reminder.md"
  [[ -f "$canon" ]] || { echo "prefix-lint: contract canon not found: $canon" >&2; return 2; }
  awk '
    $0 == "```text" { infence = 1; next }
    infence && $0 == "```" { exit }
    infence { print }
  ' "$canon"
}

# ---------- Section [3] ledger-digest grammar ----------
# ledger_digest_lint <section-text> <label> -> 0 pass / 1 fail, diagnostics on stderr.
# Not opt-in like `model`/`contract_canon`: a malformed digest is wrong whatever the log sets.
ledger_digest_lint() {
  local section="$1" label="$2" rc=0
  # Short-circuit: an inlined ledger would otherwise also report every key as missing.
  if [[ "$section" =~ (^|$'\n')[[:space:]]*\{ ]] \
    || [[ "$section" == *'"tasks"'* ]] || [[ "$section" == *'"facts"'* ]]; then
    echo "prefix-lint: $label: section [3] embeds the ledger (inlined JSON) instead of the ledger-digest.sh pointer" >&2
    return 1
  fi
  local first_line=""
  while IFS= read -r _ldl_line; do
    [[ -n "$_ldl_line" ]] || continue
    first_line="$_ldl_line"
    break
  done <<< "$section"
  if [[ "$first_line" != "ledger: .context/state.json" ]]; then
    echo "prefix-lint: $label: section [3] first line must be 'ledger: .context/state.json' (got: ${first_line:-<empty>})" >&2
    rc=1
  fi
  # Key order, not just presence: a digest with the right six keys shuffled is
  # still not the grammar this check enforces.
  local keys_found expected_keys
  keys_found=$(printf '%s\n' "$section" | grep -oE '^[a-z_]+:' | sed 's/:$//')
  expected_keys=$'ledger\nrun_index\nready\nin_progress\nblocked\nopen_blocking_questions'
  if [[ "$keys_found" != "$expected_keys" ]]; then
    echo "prefix-lint: $label: section [3] keys must be ledger, run_index, ready, in_progress, blocked, open_blocking_questions in that order (got: $(tr '\n' ',' <<< "$keys_found"))" >&2
    rc=1
  fi
  return $rc
}

# ---------- Forbidden-token scanner ----------
# Scans ONE section's text for the seven forbidden-token classes named in
# skills/worktask/references/contracts/prompt-layout.md#cache-prefix (mirrored verbatim in
# coordination-0.md#shared-snippets so no second taxonomy is ever invented):
#   timestamp / ENV expansion / UUID / $RANDOM / retry-counter / mtime /
#   agent-specific-name-beyond-worktask_id.
# These are INTRINSIC per-section checks (unlike the byte-identity check
# above, which only catches drift ACROSS lines) — a token that is identical
# on every line (e.g. the same ISO timestamp baked in at generation time)
# would pass byte-identity yet still be a latent miss on the NEXT worktask,
# because a fresh worktask_id at a fresh instant produces a NEW timestamp,
# breaking the cross-worktask cache-prefix reuse this scanner exists to
# protect. Prints one line per hit to stderr; returns non-zero on any hit.
forbidden_token_scan() {
  local section_text="$1" label="$2"
  local rc=0

  # Six `grep` forks per section used to run here, three sections per log line —
  # eighteen of the ~29 forks this lint spent on every line. The shell's own
  # regex engine answers the same questions with none. The three classes that
  # were `grep -i` (3, 5, 6) spell their case-folding inline rather than via
  # `nocasematch`: that shopt is function-wide, and it silently turned the
  # case-SENSITIVE classes 2 and 4 into matches on `$user` / `$random`.

  # 1. ISO-8601 timestamp (date/now render), e.g. 2026-07-05T15:15:39Z
  if [[ "$section_text" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    echo "forbidden-token-lint: $label: ISO-8601 timestamp found" >&2
    rc=1
  fi

  # 2. ENV expansions that vary per call (unresolved $VAR / ${VAR} literals,
  #    or a shell already substituted a per-user path under one of these).
  if [[ "$section_text" =~ \$(HOSTNAME|USER|PWD|RANDOM)([^A-Za-z0-9_]|$) \
     || "$section_text" =~ \$\{(HOSTNAME|USER|PWD|RANDOM)\} ]]; then
    # Single-quoted: this message names the four variables, and double quotes
    # made it print the running shell's own $USER and $PWD into a lint report
    # about leaked per-call values.
    echo "forbidden-token-lint: $label:"' ENV expansion ($HOSTNAME/$USER/$PWD/$RANDOM) found' >&2
    rc=1
  fi

  # 3. Random / request IDs — UUID v4 shape.
  if [[ "$section_text" =~ [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12} ]]; then
    echo "forbidden-token-lint: $label: UUID found" >&2
    rc=1
  fi

  # 4. $RANDOM literal (bash builtin) appearing unresolved in the text.
  if [[ "$section_text" =~ \$RANDOM([^A-Za-z0-9_]|$) ]]; then
    echo "forbidden-token-lint: $label: literal \$RANDOM found" >&2
    rc=1
  fi

  # 5. Retry counters (belong in section [6], never [1]/[2]/[4]).
  if [[ "$section_text" =~ [Rr][Ee][Tt][Rr][Yy][_-]?[Cc][Oo][Uu][Nn][Tt][[:space:]]*[:=][[:space:]]*[0-9]+ \
     || "$section_text" =~ [Aa][Tt][Tt][Ee][Mm][Pp][Tt][[:space:]]*#?[0-9]+ ]]; then
    echo "forbidden-token-lint: $label: retry/attempt counter found (belongs in section [6])" >&2
    rc=1
  fi

  # 6. File mtime-shaped values (epoch seconds/millis label or "mtime:").
  if [[ "$section_text" =~ [Mm][Tt][Ii][Mm][Ee][[:space:]]*[:=][[:space:]]*[0-9]{9,13}([^0-9]|$) ]]; then
    echo "forbidden-token-lint: $label: file mtime found" >&2
    rc=1
  fi

  # 7. Agent-specific names beyond worktask_id (the per-stage agent identity
  #    belongs in section [4] ONLY, never baked into [1]/[2]). Checked by the
  #    caller passing the stage's OWN agent name as a second forbidden literal
  #    when scanning [1]/[2] (see prefix_lint call site) — a name appearing in
  #    its OWN [4] is expected and not scanned here.

  return $rc
}

prefix_lint() {
  local log="$1"
  [[ -f "$log" ]] || { echo "prefix-lint: log not found: $log" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "prefix-lint: jq required" >&2; exit 2; }

  # POSIX-compatible state: store per-key sections as files in a tempdir.
  # bash 3.2 has no associative arrays, so we use the filesystem.
  local td
  td=$(mktemp -d "${TMPDIR:-/tmp}/cache-lint-prefix-XXXXXX")
  trap "rm -rf '$td'" RETURN

  local rc=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # One jq per line, not three: the fields come out in a fixed order, and the
    # prompt — the only multi-line one — is whatever follows the first two lines.
    # The `X` sentinel keeps command substitution from eating the separator that
    # an EMPTY prompt is reduced to, which would shift `stage` into `prompt`.
    local fields wid stage model ccanon prompt
    fields=$(jq -r '.worktask_id, .stage, (.model // ""), (.contract_canon // false), .prompt' <<< "$line"; printf 'X')
    fields="${fields%X}"
    wid="${fields%%$'\n'*}"; fields="${fields#*$'\n'}"
    stage="${fields%%$'\n'*}"; fields="${fields#*$'\n'}"
    model="${fields%%$'\n'*}"; fields="${fields#*$'\n'}"
    ccanon="${fields%%$'\n'*}"; prompt="${fields#*$'\n'}"
    # Three separate substitutions stripped every trailing newline from each
    # field; keep that, so a prompt is compared the same way it always was.
    while [ "${prompt%$'\n'}" != "$prompt" ]; do prompt="${prompt%$'\n'}"; done

    local s1 s2 s3 s4 s4b
    s1=$(extract_section "$prompt" "contract-reminder")
    s2=$(extract_section "$prompt" "worktask-header")
    s3=$(extract_section "$prompt" "state-json")
    s4=$(extract_section "$prompt" "stage-contract")
    s4b=$(extract_section "$prompt" "model-discipline")

    # extract_section yields "" for an absent marker and for an empty body; only an
    # absent [3] may skip, since an empty body is itself a missing pointer.
    if grep -qx '<<<state-json>>>' <<< "$prompt"; then
      if ! ledger_digest_lint "$s3" "worktask_id=$wid stage=$stage"; then
        rc=1
      fi
    fi

    # L1 forbidden-token scan — runs on EVERY line (intrinsic per-section
    # check, independent of the cross-line byte-identity comparison below).
    if ! forbidden_token_scan "$s1" "worktask_id=$wid stage=$stage section[1]"; then
      rc=1
    fi
    if ! forbidden_token_scan "$s2" "worktask_id=$wid stage=$stage section[2]"; then
      rc=1
    fi
    if ! forbidden_token_scan "$s4" "worktask_id=$wid stage=$stage section[4]"; then
      rc=1
    fi
    if ! forbidden_token_scan "$s4b" "worktask_id=$wid stage=$stage section[4b]"; then
      rc=1
    fi

    # Canon check. Opt-in on the log line carrying `model`, because the field is
    # new and a log written before it existed must stay lintable rather than
    # fail as if the block were wrong.
    if [[ -n "$model" ]]; then
      local canon
      if canon=$(canonical_model_block "$model" "$(plugin_root)"); then
        while [ "${canon%$'\n'}" != "$canon" ]; do canon="${canon%$'\n'}"; done
        if [[ "$s4b" != "$canon" ]]; then
          echo "prefix-lint: worktask_id=$wid stage=$stage: section [4b] does not match model-prompting.md block for model=$model" >&2
          rc=1
        fi
      else
        rc=1
      fi
    fi

    # Opt-in like `model` above: [1] must equal contract-reminder.md's block byte for byte.
    if [[ "$ccanon" == "true" ]]; then
      local ccanon_block
      if ccanon_block=$(canonical_contract_block "$(plugin_root)"); then
        while [ "${ccanon_block%$'\n'}" != "$ccanon_block" ]; do ccanon_block="${ccanon_block%$'\n'}"; done
        if [[ "$s1" != "$ccanon_block" ]]; then
          echo "prefix-lint: worktask_id=$wid stage=$stage: section [1] does not match contract-reminder.md" >&2
          rc=1
        fi
      else
        rc=1
      fi
    fi

    # Sanitize wid/stage for use in filenames (allow [a-zA-Z0-9._-]). Pattern
    # substitution rather than `tr`, which cost two forks on every line.
    local widsafe="${wid//[!a-zA-Z0-9._-]/_}" stagesafe="${stage//[!a-zA-Z0-9._-]/_}"

    local f1="$td/wf-${widsafe}-s1"
    local f2="$td/wf-${widsafe}-s2"
    local f4="$td/wf-${widsafe}-stage-${stagesafe}-s4"
    local f4b="$td/wf-${widsafe}-stage-${stagesafe}-s4b"

    if [[ ! -f "$f1" ]]; then
      printf '%s' "$s1" > "$f1"
      printf '%s' "$s2" > "$f2"
    else
      if [[ "$s1" != "$(<"$f1")" ]]; then
        echo "prefix-lint: worktask_id=$wid stage=$stage: section [1] contract-reminder DRIFT" >&2
        rc=1
      fi
      if [[ "$s2" != "$(<"$f2")" ]]; then
        echo "prefix-lint: worktask_id=$wid stage=$stage: section [2] worktask-header DRIFT" >&2
        rc=1
      fi
    fi

    if [[ ! -f "$f4" ]]; then
      printf '%s' "$s4" > "$f4"
    elif [[ "$s4" != "$(<"$f4")" ]]; then
      echo "prefix-lint: worktask_id=$wid stage=$stage: section [4] stage-contract DRIFT" >&2
      rc=1
    fi

    if [[ ! -f "$f4b" ]]; then
      printf '%s' "$s4b" > "$f4b"
    elif [[ "$s4b" != "$(<"$f4b")" ]]; then
      echo "prefix-lint: worktask_id=$wid stage=$stage: section [4b] model-discipline DRIFT" >&2
      rc=1
    fi
  done < "$log"

  if [[ $rc -eq 0 ]]; then
    local nlines
    nlines=$(wc -l < "$log" | tr -d ' ')
    echo "prefix-lint: $nlines prompts checked, no drift; forbidden-token scan clean"
  fi
  return $rc
}

# ---------- Frontmatter template lint ----------
# Extract the contents of the first ```yaml fenced block that appears
# AFTER the `## Handoff Protocol` H2 and BEFORE the next H2 heading.
# Returns the YAML body (without the fence markers). Empty if not found.
# A block opening with a `# …continued:` marker is the tail of the one above it, split only
# so the prose stays under the section-length cap; it rejoins here and is not counted twice.
CONTINUATION_RE='^#[[:space:]]*(…|\.\.\.)continued[:[:space:]]'

extract_handoff_yaml_block() {
  local f="$1"
  awk -v cont_re="$CONTINUATION_RE" '
    BEGIN { in_section = 0; in_fence = 0; emit = 0; seen = 0 }
    /^## Handoff Protocol[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^```yaml[[:space:]]*$/ && !in_fence {
      in_fence = 1; first = 1; next
    }
    in_section && /^```[[:space:]]*$/ && in_fence {
      in_fence = 0; emit = 0; next
    }
    in_fence && first {
      first = 0
      if ($0 ~ cont_re) { emit = seen; next }   # tail of the block already emitted
      if (seen) { exit }                        # a second independent block ends the read
      seen = 1; emit = 1
    }
    in_fence && emit { print }
  ' "$f"
}

# Count the number of ```yaml ... ``` fenced blocks inside Handoff Protocol.
count_handoff_yaml_blocks() {
  local f="$1"
  awk -v cont_re="$CONTINUATION_RE" '
    BEGIN { in_section = 0; in_fence = 0; n = 0 }
    /^## Handoff Protocol[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { print n; exit_done = 1; exit }
    in_section && /^```yaml[[:space:]]*$/ && !in_fence {
      in_fence = 1; first = 1; n++; next
    }
    in_section && /^```[[:space:]]*$/ && in_fence { in_fence = 0; next }
    in_fence && first { first = 0; if ($0 ~ cont_re) n-- }
    END { if (!exit_done) print n }
  ' "$f"
}

# Extract the Handoff Protocol section body (between the H2 and the next H2 /
# EOF) — used by the pointer-only acceptance path (P1 dedup, Batch 5) to check
# for a `stage-contracts.md#tpl-<CODE>` reference when no inline yaml block
# remains.
extract_handoff_section_body() {
  local f="$1"
  awk '
    /^## Handoff Protocol[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$f"
}

frontmatter_template_lint() {
  local rc=0 agent base stage_expected nblocks body stage_actual nlines section_body
  for agent in "$@"; do
    [[ -f "$agent" ]] || { echo "frontmatter-template-lint: file not found: $agent" >&2; rc=1; continue; }

    base=$(basename "$agent" .md)
    stage_expected=$(agent_basename_to_stage "$base")
    if [[ -z "$stage_expected" ]]; then
      echo "frontmatter-template-lint: $agent: not a stage agent (no canonical mapping) — skipping" >&2
      continue
    fi

    if ! grep -q '^## Handoff Protocol[[:space:]]*$' "$agent"; then
      echo "frontmatter-template-lint: $agent FAIL: missing '## Handoff Protocol' section" >&2
      rc=1; continue
    fi

    nblocks=$(count_handoff_yaml_blocks "$agent")

    # Pointer-only acceptance path (P1 dedup, Batch 5/ad4): an agent MAY carry
    # ZERO inline yaml blocks if its Handoff Protocol section instead cites the
    # canonical SSOT template `stage-contracts.md#tpl-<stage_expected>`
    # verbatim — this is the collapsed form the boilerplate-dedup pass
    # produces (deletes the byte-duplicated YAML, keeps a one-line pointer).
    # `developer.md` deliberately keeps its INLINE block (carries a load-
    # bearing `worktree:` field beyond the SSOT template) — nblocks==1 there
    # still takes the classic path below, unaffected by this branch.
    if [[ "$nblocks" == "0" ]]; then
      section_body=$(extract_handoff_section_body "$agent")
      # bash 3.2 has no ${var,,} — lowercase via tr for the anchor slug.
      local stage_lc
      stage_lc=$(printf '%s' "$stage_expected" | tr '[:upper:]' '[:lower:]')
      if grep -qE "(stage-contracts\.md|assets/templates/template-${stage_lc}\.md)#tpl-${stage_lc}\b" <<< "$section_body"; then
        echo "frontmatter-template-lint: $agent (stage=$stage_expected, pointer-only) ok"
        continue
      fi
      echo "frontmatter-template-lint: $agent FAIL: no inline yaml block AND no skills/worktask/assets/templates/template-${stage_lc}.md#tpl-${stage_lc} pointer found in Handoff Protocol" >&2
      rc=1; continue
    fi

    if [[ "$nblocks" != "1" ]]; then
      echo "frontmatter-template-lint: $agent FAIL: expected exactly 1 fenced yaml block inside Handoff Protocol, found $nblocks" >&2
      rc=1; continue
    fi

    body=$(extract_handoff_yaml_block "$agent")
    if ! grep -q '^handoff:' <<< "$body"; then
      echo "frontmatter-template-lint: $agent FAIL: yaml block has no top-level 'handoff:' key" >&2
      rc=1; continue
    fi

    # Extract stage value (allow optional quotes / trailing comment).
    stage_actual=$(awk '
      /^[[:space:]]*stage:[[:space:]]*/ {
        sub(/^[[:space:]]*stage:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        gsub(/[[:space:]"]+/, "")
        print; exit
      }
    ' <<< "$body")
    if [[ -z "$stage_actual" ]]; then
      echo "frontmatter-template-lint: $agent FAIL: yaml block has no 'stage:' value" >&2
      rc=1; continue
    fi
    if [[ "$stage_actual" != "$stage_expected" ]]; then
      echo "frontmatter-template-lint: $agent FAIL: stage='$stage_actual' but agent maps to '$stage_expected'" >&2
      rc=1; continue
    fi

    nlines=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
    if (( nlines > 30 )); then
      echo "frontmatter-template-lint: $agent FAIL: yaml block has $nlines lines (limit 30 per skills/worktask/references/contracts/frontmatter.md#frontmatter-schema)" >&2
      rc=1; continue
    fi

    echo "frontmatter-template-lint: $agent (stage=$stage_actual, $nlines lines) ok"
  done
  return $rc
}

# ---------- Filename lint ----------
filename_lint() {
  local ctx_dir="$1"
  [[ -d "$ctx_dir" ]] || { echo "filename-lint: directory not found: $ctx_dir" >&2; exit 2; }

  local rc=0 count=0
  for artifact in "$ctx_dir"/*.md; do
    [[ -f "$artifact" ]] || continue

    local stage
    stage=$(extract_stage "$artifact")
    [[ -z "$stage" || "$stage" == "null" ]] && continue

    count=$((count + 1))
    local expected_base
    expected_base=$(canonical_basename_for_stage "$stage")
    [[ -z "$expected_base" ]] && continue

    local actual_name name_re expected_desc
    actual_name=$(basename "$artifact")
    name_re="^${expected_base}-[0-9]+\\.md\$"
    expected_desc="${expected_base}-N.md"
    # DV fans out onto ledger tasks, one per stream, each writing its own
    # development-N-<stream>.md handoff; a run with a single DV row may omit the
    # stream and write development-N.md (handoff-protocol.md § DV fan-out).
    if [[ "$expected_base" == "development" ]]; then
      name_re="^development-[0-9]+(-[a-z0-9]+(-[a-z0-9]+)*)?\\.md\$"
      expected_desc="development-N.md or development-N-<stream>.md"
    fi
    if ! printf '%s' "$actual_name" | grep -qE "$name_re"; then
      echo "filename-lint: $artifact (stage=$stage) FAIL: expected '${expected_desc}', got '$actual_name'" >&2
      rc=1
    fi
  done

  if [[ $count -eq 0 ]]; then
    echo "filename-lint: no artifacts with handoff frontmatter found in $ctx_dir" >&2
    return 1
  fi

  [[ $rc -eq 0 ]] && echo "filename-lint: $count artifacts checked, all canonical"
  return $rc
}

# ---------- main ----------
case "${1:-}" in
  --anchor-lint) shift; [[ $# -ge 1 ]] || usage; anchor_lint "$1" ;;
  --anchor-diff) shift; anchor_diff_cli "$@"; exit $? ;;
  --allow-list)
    shift
    if [[ "${1:-}" == "--stage" ]]; then
      [[ -n "${2:-}" ]] || usage
      allow_list "$2" || { echo "allow-list: unknown stage '$2'" >&2; exit 2; }
    else
      [[ $# -eq 0 ]] || usage
      allow_list
    fi
    exit 0
    ;;
  --frontmatter-template-lint)
    shift; [[ $# -ge 1 ]] || usage
    frontmatter_template_lint "$@"; exit $?
    ;;
  --filename-lint)
    shift; [[ $# -ge 1 ]] || usage
    filename_lint "$1"; exit $?
    ;;
  --agent-section-lint)
    shift
    agent_section_lint "${1:-.}"; exit $?
    ;;
  # `--selftest` is accepted alongside `--self-test`: the unhyphenated spelling is what
  # coordination-0.md and the DV2->DV3 #16 contract name, and without the alias it falls
  # through to the prefix-lint arm and reports "log not found" — a green contract command
  # that ran no test at all.
  --self-test | --selftest)
    # Sourced HERE, not at the top: the harness is test code the lint path never
    # runs. `[ -r ]` first, not a bare `.`: sourcing a missing file with the `.`
    # builtin is a special-builtin error that exits the shell immediately,
    # bypassing an `if ! . …` guard entirely.
    SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/cache-lint-selftest.sh"
    if [ -r "$SELFTEST_LIB_PATH" ]; then
      # shellcheck source=cache-lint-selftest.sh
      # shellcheck disable=SC1090
      . "$SELFTEST_LIB_PATH"
    else
      printf >&2 'cache-lint: self-test harness unreachable at %s — plugin install broken\n' \
        "$SELFTEST_LIB_PATH"
      exit 2
    fi
    self_test
    ;;
  "") usage ;;
  *) prefix_lint "$1"; exit $? ;;
esac
