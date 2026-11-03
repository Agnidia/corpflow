#!/usr/bin/env bats
# Shape and parity contracts for the stage-agent runbooks: the PL0, DR and SR digests that
# replace whole-file reads of their canonical procedure docs.
#
# A runbook is a cost cut only while it stays short and true. Shape: each exists, fits in 60
# lines, and names the canonical file it digests. Parity: the lines a runbook copies verbatim
# (the #tpl-dr / #tpl-sr frontmatter, the estimation stage-set table) hash-equal their
# defining file. Both sides are extracted from their own files — a hardcoded copy here would
# be the drift this suite exists to catch — and each helper takes its files as arguments, so
# the can-actually-fail twins re-run it against a planted copy.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

CONTRACTS="skills/worktask/references/stage-contracts.md"
ESTIMATION="skills/estimation-methodology/SKILL.md"
PL0_PROC="skills/worktask/references/pl0-procedure.md"
PM="agents/product-manager.md"
TL="agents/technical-lead.md"
SR="agents/security-reviewer.md"
RUNBOOK_MAX_LINES=60

# --- extraction helpers ------------------------------------------------------

# runbook_body <file> <exact ### heading> — the heading through the line before the next
# H1–H3, so the runbook's own #### subsections stay inside it.
runbook_body() {
  awk -v h="$2" '$0 == h {f=1; print; next} f && /^#{1,3} / {exit} f' "$1"
}

# first_yaml_after <file> <heading-regex> — the first ```yaml fence after the heading.
first_yaml_after() {
  awk -v re="$2" '$0 ~ re {f=1; next} f && /^```yaml[[:space:]]*$/ {g=1} g {print} g && /^```[[:space:]]*$/ {exit}' "$1"
}

# first_table_after <file> <heading-regex> — the first contiguous run of `|` rows after it.
first_table_after() {
  awk -v re="$2" '$0 ~ re {f=1; next} f && /^\|/ {t=1; print; next} t {exit}' "$1"
}

_hash() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

# --- contract helpers (each carries its own non-vacuity guard) ---------------

check_runbook_shape() {  # <file> <heading> <canonical-path> <plugin-root>
  local body n
  body="$(runbook_body "$1" "$2")"
  [ -n "$body" ] || { echo "$1: no '$2' section"; return 1; }
  n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
  [ "$n" -ge 10 ] || { echo "non-vacuity: '$2' extracted only $n lines"; return 1; }
  [ "$n" -le "$RUNBOOK_MAX_LINES" ] || { echo "$1: '$2' is $n lines (cap $RUNBOOK_MAX_LINES)"; return 1; }
  printf '%s\n' "$body" | grep -qF "$3" || { echo "$1: '$2' never names its canonical source $3"; return 1; }
  [ -f "$4/$3" ] || { echo "canonical source $3 does not exist"; return 1; }
}

check_yaml_parity() {  # <agent> <agent-heading-re> <contracts> <contracts-heading-re>
  local a c
  a="$(first_yaml_after "$1" "$2")"
  c="$(first_yaml_after "$3" "$4")"
  printf '%s\n' "$a" | grep -q '^handoff:$' || { echo "non-vacuity: no handoff yaml under $2 in $1"; return 1; }
  printf '%s\n' "$c" | grep -q '^handoff:$' || { echo "non-vacuity: no handoff yaml under $4 in $3"; return 1; }
  [ "$(printf '%s' "$a" | _hash)" = "$(printf '%s' "$c" | _hash)" ] || {
    echo "$1 copy under $2 drifted from $3 $4:"
    diff <(printf '%s\n' "$c") <(printf '%s\n' "$a") || true
    return 1
  }
}

check_table_parity() {  # <agent> <agent-heading-re> <source> <source-heading-re>
  local a s n
  a="$(first_table_after "$1" "$2")"
  s="$(first_table_after "$3" "$4")"
  n="$(printf '%s\n' "$s" | grep -c '^|' || true)"
  [ "$n" -ge 7 ] || { echo "non-vacuity: $3 table under $4 has only $n rows"; return 1; }
  [ "$(printf '%s' "$a" | _hash)" = "$(printf '%s' "$s" | _hash)" ] || {
    echo "$1 table under $2 drifted from $3 $4:"
    diff <(printf '%s\n' "$s") <(printf '%s\n' "$a") || true
    return 1
  }
}

plant() {  # plant <src> <sed-expr> -> prints the mutated copy's path; refuses a no-op sed
  local d out
  d="$(mk_tmpworkdir)"
  out="$d/$(basename "$1")"
  sed "$2" "$1" > "$out"
  if cmp -s "$1" "$out"; then
    printf >&2 'plant: sed matched nothing in %s -- %s\n' "$1" "$2"
    return 1
  fi
  printf '%s' "$out"
}

# --- shape -------------------------------------------------------------------

@test "shape: the PL0 runbook exists, fits the cap and names pl0-procedure.md" {
  run check_runbook_shape "$PLUGIN_ROOT/$PM" "### PL0 runbook" "$PL0_PROC" "$PLUGIN_ROOT"
  assert_success
}

@test "shape: the DR runbook exists, fits the cap and names commands/tech-code-review.md" {
  run check_runbook_shape "$PLUGIN_ROOT/$TL" "### DR runbook" "commands/tech-code-review.md" "$PLUGIN_ROOT"
  assert_success
}

@test "shape: the SR runbook exists, fits the cap and names the threat-model procedure" {
  run check_runbook_shape "$PLUGIN_ROOT/$SR" "### SR runbook" \
    "skills/security-review-process/references/threat-model.md" "$PLUGIN_ROOT"
  assert_success
}

@test "shape twin: a runbook grown past the cap fails" {
  local planted
  planted="$(mk_tmpworkdir)/technical-lead.md"
  awk '{print} $0 == "### DR runbook" {for (i = 0; i < 61; i++) print "filler"}' \
    "$PLUGIN_ROOT/$TL" > "$planted"
  run check_runbook_shape "$planted" "### DR runbook" "commands/tech-code-review.md" "$PLUGIN_ROOT"
  assert_failure
  assert_output --partial "cap $RUNBOOK_MAX_LINES"
}

@test "shape twin: a runbook that stops naming its canonical source fails" {
  local planted
  planted="$(plant "$PLUGIN_ROOT/$SR" 's#references/threat-model\.md#references/threat-notes.md#g')"
  run check_runbook_shape "$planted" "### SR runbook" \
    "skills/security-review-process/references/threat-model.md" "$PLUGIN_ROOT"
  assert_failure
  assert_output --partial "never names its canonical source"
}

# --- parity: verbatim copies --------------------------------------------------

@test "parity: the DR runbook frontmatter hash-equals stage-contracts.md #tpl-dr" {
  run check_yaml_parity "$PLUGIN_ROOT/$TL" '^#### DR runbook — frontmatter' \
    "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '^### #tpl-dr '
  assert_success
}

@test "parity: the SR runbook frontmatter hash-equals stage-contracts.md #tpl-sr" {
  run check_yaml_parity "$PLUGIN_ROOT/$SR" '^#### SR runbook — frontmatter' \
    "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '^### #tpl-sr '
  assert_success
}

@test "parity twin: a changed #tpl-dr in the canonical file fails the DR copy" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/^  stage: DR$/,/^---$/s/verdict: pass /verdict: ok   /')"
  run check_yaml_parity "$PLUGIN_ROOT/$TL" '^#### DR runbook — frontmatter' "$planted" '^### #tpl-dr '
  assert_failure
  assert_output --partial "drifted"
}

@test "parity: the PL0 runbook stage-set table hash-equals the estimation methodology table" {
  run check_table_parity "$PLUGIN_ROOT/$PM" '^#### PL0 runbook — 3\. Size' \
    "$PLUGIN_ROOT/$ESTIMATION" '^### Stage set table'
  assert_success
}

@test "parity twin: a re-tiered row in the planted runbook copy fails" {
  local planted
  planted="$(plant "$PLUGIN_ROOT/$PM" 's/^| 31–40 | High | AR0\*, DV0, DR0, QA0, DC0, FN0, ST0 |$/| 31–40 | High | AR0*, DV0, DR0, QA0 |/')"
  run check_table_parity "$planted" '^#### PL0 runbook — 3\. Size' \
    "$PLUGIN_ROOT/$ESTIMATION" '^### Stage set table'
  assert_failure
  assert_output --partial "drifted"
}

# --- the exact-output rule lives in both the digest and its source -----------

@test "exact output: the PL0 runbook and pl0-procedure.md both make exact-output rules byte-exact criteria" {
  local f
  for f in "$PM" "$PL0_PROC"; do
    grep -q 'byte-exact' "$(contract_source "$PLUGIN_ROOT/$f")" || fail "$f lost the byte-exact acceptance-criteria rule"
    grep -q 'quoted verbatim in a' "$(contract_source "$PLUGIN_ROOT/$f")" || fail "$f no longer requires the verbatim fenced quote"
  done
}
