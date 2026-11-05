#!/usr/bin/env bats
# Single-sourcing and completeness contracts for the closing elicitation sweep
# (skills/worktask/references/stage-contracts.md § Closing Elicitation Sweep).
#
# Every parity assertion extracts BOTH sides from their own defining file. A
# hardcoded copy inside the test would be the same drift defect these contracts
# exist to catch, so each helper takes the files it reads as arguments — which is
# also what lets the can-actually-fail twin re-run it against a planted copy.
#
# No JSON-Schema validator is vendored in this suite, so AC-3 asserts the schema
# FACTS (one item shape and no residual disjunction; exactly-one-recommended as
# contains/minContains/maxContains) rather than executing the schema against instances.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

CONTRACTS="skills/worktask/references/stage-contracts.md"
HANDOFF="skills/worktask/references/handoff-protocol.md"
STAGE_CODES="skills/worktask/references/stage-codes.md"
WORKTASK_CMD="skills/worktask/references/workflow.md"
PL0_PROC="skills/worktask/references/pl0-procedure.md"
PREFLIGHT="skills/worktask/scripts/preflight-issue-scan.sh"
WORKTASK_SKILL="skills/worktask/references/orchestration.md"

# Agents that are NOT stage agents and therefore owe no sweep pointer.
NON_STAGE_AGENTS="designer prompt-engineer"

# --- extraction helpers ------------------------------------------------------

# Canonical stage vocabulary: stage-codes.md § Primary Stages UNION the
# handoff-protocol.md § Handoff Schemas titles (ET lives only in the latter).
left_codes() {
  { awk '/^## Primary Stages/,/^### /' "$1" | sed -nE 's/^\| ([A-Z]{2}) \|.*/\1/p'
    sed -nE 's/^ *"title": "([A-Z]{2})Handoff",?$/\1/p' "$2" ; } | sort -u
}

# The obligation section's own body. `####` sub-headings stay inside the range;
# the next `### ` ends it, so the range needs no knowledge of what follows it.
matrix_body() {
  awk '/^### Sweep obligation matrix/{f=1;next} /^### /{f=0} f' "$1"
}

# The stages that DEPART from the universal obligation — the exceptions table's rows.
exception_codes() {
  matrix_body "$1" | sed -nE 's/^\| ([A-Z]{2}) \|.*/\1/p' | sort -u
}

# The stages the default sentence covers, named so a code can never fall between the
# two lists. Together these must reconstitute the canonical vocabulary exactly.
default_codes() {
  matrix_body "$1" | sed -nE 's/^Every other code — (.*) — takes the default.*/\1/p' \
    | tr ',' '\n' | tr -d ' ' | grep -E '^[A-Z]{2}$' | sort -u
}

canonical_phrase() { sed -nE 's/^## (Closing Elicitation Sweep)$/\1/p' "$1"; }

# The open_questions branch list, extracted from the frontmatter schema block.
open_questions_schema() {
  awk '/^      open_questions:$/{f=1} f{print} f&&/^      refs:$/{exit}' "$1"
}

sweep_defs() { awk '/^  SweepItem:$/{f=1} f{print} /^  SweepStub:$/{g=1} g&&/^```$/{exit}' "$1"; }

section_body() {  # section_body <file> <heading-regex>
  awk -v re="$2" '$0 ~ re {f=1;next} f && /^#{2,5} /{f=0} f' "$1"
}

# --- contract helpers (each carries its own non-vacuity guard) ---------------

# Vocabulary parity, over a section that no longer restates the obligation once per
# stage. The obligation is universal, so the completeness question moved: every canonical
# code must be accounted for EXACTLY ONCE, either as a named exception or as a member of
# the default-covered list. A code in neither list, or in both, is the silent gap the
# thirteen-row table used to make impossible.
check_matrix_completeness() {  # <contracts> <stage-codes> <handoff>
  local left exc def union nl ne nd both
  left="$(left_codes "$2" "$3")"
  exc="$(exception_codes "$1")"
  def="$(default_codes "$1")"
  nl=$(printf '%s\n' "$left" | grep -c '[A-Z]' || true)
  ne=$(printf '%s\n' "$exc" | grep -c '[A-Z]' || true)
  nd=$(printf '%s\n' "$def" | grep -c '[A-Z]' || true)
  [ "$nl" -ge 12 ] || { echo "non-vacuity: canonical stage list extracted only $nl codes"; return 1; }
  [ "$ne" -ge 1 ] || { echo "non-vacuity: no exception rows extracted"; return 1; }
  [ "$nd" -ge 1 ] || { echo "non-vacuity: the default-covered list extracted no codes"; return 1; }

  # The exceptions must stay exceptions: a section that listed every code again would
  # satisfy the union check while reintroducing exactly the duplication this removed.
  [ "$ne" -lt "$nl" ] || { echo "the exceptions table names every stage; it is a matrix again"; return 1; }

  both="$(comm -12 <(printf '%s\n' "$exc") <(printf '%s\n' "$def"))"
  [ -z "$both" ] || { echo "code(s) both excepted and defaulted: $both"; return 1; }

  union="$(printf '%s\n%s\n' "$exc" "$def" | grep -E '^[A-Z]{2}$' | sort -u)"
  [ "$left" = "$union" ] || {
    echo "the obligation section and the canonical stage list disagree:"
    diff <(printf '%s\n' "$left") <(printf '%s\n' "$union") || true
    return 1
  }
}

check_pointer_once() {  # <agents-dir> <contracts>
  local phrase f base n checked=0 rc=0
  phrase="$(canonical_phrase "$2")"
  [ -n "$phrase" ] || { echo "non-vacuity: no canonical heading found in $2"; return 1; }
  for f in "$1"/*.md; do
    base="$(basename "$f" .md)"
    case " $NON_STAGE_AGENTS " in *" $base "*) continue ;; esac
    checked=$((checked + 1))
    n="$(grep -c -F "$phrase" "$f" || true)"
    [ "$n" -eq 1 ] || { echo "$base.md: expected exactly 1 pointer, got $n"; rc=1; }
  done
  [ "$checked" -ge 14 ] || { echo "non-vacuity: only $checked stage agents checked"; return 1; }
  return $rc
}

# Every stage agent must show the SECOND transport as a literal command. A stage
# told to emit open_questions[] but never shown `--facts` writes a stub that
# reaches the frontmatter and stops: `handoff-protocol.md` § open_questions is
# agent-written says the two have no derivation between them, so the FN gate
# never renders it. QA shipped exactly that way, and the run's only blocker was
# nearly lost to it.
#
# PL is the one stage whose payload lives in a procedure file rather than the
# agent (pl0-procedure.md § Union this stage's facts), so it points there instead.
FACTS_VIA_PROCEDURE="product-manager"

check_facts_transport() {  # <agents-dir>
  local f base checked=0 rc=0
  for f in "$1"/*.md; do
    base="$(basename "$f" .md)"
    case " $NON_STAGE_AGENTS " in *" $base "*) continue ;; esac
    case " $FACTS_VIA_PROCEDURE " in *" $base "*) continue ;; esac
    checked=$((checked + 1))
    grep -q -- "--facts" "$f" \
      || { echo "$base.md: no --facts invocation — its sweep stub cannot reach the ledger"; rc=1; }
  done
  [ "$checked" -ge 13 ] || { echo "non-vacuity: only $checked stage agents checked"; return 1; }
  return $rc
}

@test "transport: every stage agent shows --facts as a literal command (F-06)" {
  run check_facts_transport "$PLUGIN_ROOT/agents"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "transport: PL's --facts payload is literal in pl0-procedure.md" {
  # The exemption above is only sound while the procedure it defers to carries
  # the command; otherwise PL is a hole this suite declared out of scope.
  grep -q -- "state-patch.sh --stage PL" \
    "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/pl0-procedure.md")" \
    || fail "pl0-procedure.md carries no literal PL --facts invocation"
}

# The stub is the ONLY item shape. Non-vacuity is the presence of exactly one
# `$ref: '#/$defs/SweepStub'` under `items:` — an extraction that silently returned nothing
# would otherwise satisfy every "must not contain" assertion below.
check_schema_shape() {  # <handoff>
  local blk defs n
  blk="$(open_questions_schema "$1")"
  n=$(printf '%s\n' "$blk" | grep -cF "\$ref: '#/\$defs/SweepStub'" || true)
  [ "$n" -eq 1 ] \
    || { echo "non-vacuity: expected exactly 1 \$ref to SweepStub under items:, found $n"; return 1; }
  printf '%s\n' "$blk" | grep -qE '^ *items:' \
    || { echo "non-vacuity: open_questions declares no items: key"; return 1; }
  if printf '%s\n' "$blk" | grep -q 'oneOf'; then
    echo "open_questions is a disjunction again; the stub is the only item shape"; return 1
  fi
  if printf '%s\n' "$blk" | grep -qE '^ *- type: string'; then
    echo "the legacy free-text branch was re-admitted"; return 1
  fi
  if printf '%s\n' "$blk" | grep -qE '^ *required: \[id, summary\]'; then
    echo "the legacy bare-object branch was re-admitted"; return 1
  fi
  if printf '%s\n' "$blk" | grep -q 'not:'; then
    echo "a disjointness guard reappeared; with one shape there is nothing to discriminate"; return 1
  fi

  defs="$(sweep_defs "$1")"
  [ -n "$defs" ] || { echo "non-vacuity: \$defs block not extracted"; return 1; }
  printf '%s\n' "$defs" | grep -q 'minItems: 2' || { echo "options minItems 2 missing"; return 1; }
  printf '%s\n' "$defs" | grep -q 'maxItems: 4' || { echo "options maxItems 4 missing"; return 1; }
  printf '%s\n' "$defs" | grep -qE 'contains:.*recommended.*const: true' \
    || { echo "exactly-one-recommended is not a schema fact"; return 1; }
  printf '%s\n' "$defs" | grep -q 'minContains: 1' || { echo "zero recommended options would pass"; return 1; }
  printf '%s\n' "$defs" | grep -q 'maxContains: 1' || { echo "two recommended options would pass"; return 1; }
}

check_templates_carry_field() {  # <contracts>
  local n_tpl n_field
  n_tpl=$(grep -c '^### #tpl-' "$1" || true)
  [ "$n_tpl" -ge 13 ] || { echo "non-vacuity: only $n_tpl templates found"; return 1; }
  n_field=$(awk '/^### #tpl-/{t=1} t&&/^  open_questions:/{c++} END{print c+0}' "$1")
  [ "$n_field" -eq "$n_tpl" ] \
    || { echo "$n_field of $n_tpl per-stage templates carry open_questions:"; return 1; }
}

check_empty_obligation_once() {  # <contracts>
  local n; n=$(grep -c 'nothing to elicit' "$1" || true)
  [ "$n" -eq 1 ] || { echo "explicit-empty obligation stated $n times, expected exactly 1"; return 1; }
}

# The LATTICE is asserted where it is stated — once, in the contracts file. The command
# file is asserted for the two things only it can carry: that it points at that statement
# instead of copying it, and that classification is ordered before auto-answer.
check_raise_only() {  # <worktask-cmd> <contracts>
  local body cmd c2 c3
  body="$(section_body "$2" '^#{2,5} Self-labels raise, never lower')"
  [ -n "$body" ] || { echo "non-vacuity: raise-only section absent from the contracts file"; return 1; }
  printf '%s\n' "$body" | grep -q 'max(' || { echo "guard is not stated as a monotone join"; return 1; }
  printf '%s\n' "$body" | grep -q 'decision < escalate' || { echo "the class lattice is not ordered"; return 1; }
  # Raising honoured AND lowering refused — both directions must be spelled out.
  printf '%s\n' "$body" | grep -q 'raising is honoured' || { echo "the raise direction is unstated"; return 1; }
  printf '%s\n' "$body" | grep -q 'lowering is refused' || { echo "the lower direction is unstated"; return 1; }

  cmd="$(section_body "$1" '^##### Escalation guard — raise-only self-labels')"
  [ -n "$cmd" ] || { echo "non-vacuity: raise-only guard section absent from the command"; return 1; }
  printf '%s\n' "$cmd" | grep -q 'Self-labels raise, never lower' \
    || { echo "the command neither points at the canonical statement nor is one"; return 1; }
  printf '%s\n' "$cmd" | grep -q 'max(' \
    && { echo "the command restates the join instead of pointing at it"; return 1; }

  c2=$(grep -n '^#### Step C.2 — classify' "$1" | head -1 | cut -d: -f1)
  c3=$(grep -n 'C.3 — Auto-answer' "$1" | head -1 | cut -d: -f1)
  [ -n "$c2" ] && [ -n "$c3" ] || { echo "non-vacuity: Step C.2/C.3 not found"; return 1; }
  [ "$c2" -lt "$c3" ] || { echo "classification does not precede auto-answer"; return 1; }
  return 0
}

# Carriers are extracted from the files that DEFINE them, never listed here.
carrier_tokens() {  # <pl0> <worktask-cmd> <preflight>
  { grep -oE '\b[a-z][a-z_]*_gate\b' "$1"
    grep -oE '\bmegatask_group\b' "$2"
    grep -oE '\bCORPFLOW_NONINTERACTIVE\b' "$3" ; } | sort -u
}

check_carriers() {  # <contracts> <pl0> <worktask-cmd> <preflight>
  local tables tok n hits rc=0
  tables="$(awk '/^### Unattended fallbacks/{f=1;next} /^### /{f=0} f' "$1")"
  [ -n "$tables" ] || { echo "non-vacuity: fallback tables not extracted"; return 1; }
  n=$(carrier_tokens "$2" "$3" "$4" | grep -c . || true)
  [ "$n" -ge 5 ] || { echo "non-vacuity: only $n carriers extracted from their defining files"; return 1; }
  for tok in $(carrier_tokens "$2" "$3" "$4"); do
    hits=$(printf '%s\n' "$tables" | grep -c -F "$tok" || true)
    [ "$hits" -eq 1 ] || { echo "carrier $tok has $hits behaviour rows, expected exactly 1"; rc=1; }
  done
  return $rc
}

check_channels() {  # <contracts> <repo-root>
  local rows n line path token needle rc=0
  rows="$(awk '/^### Not the sweep/{f=1;next} /^### /{f=0} f' "$1" | grep -E '^\| [a-z]' || true)"
  n=$(printf '%s\n' "$rows" | grep -c . || true)
  [ "$n" -eq 4 ] || { echo "expected 4 pre-existing channels, found $n"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    token=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | grep -oE '`[^`]+`' | head -1 | tr -d '`:')
    path=$(printf '%s\n' "$line" | awk -F'|' '{print $4}' | grep -oE '[A-Za-z0-9_./-]+\.md' | head -1)
    if [ -z "$token" ] || [ -z "$path" ]; then
      echo "unparseable channel row: $line"; rc=1; continue
    fi
    case "$path" in */*) ;; *) echo "channel row must cite a repo-relative path: $line"; rc=1; continue ;; esac
    [ -f "$(contract_source "$2/$path")" ] || { echo "channel row cites a missing file: $path"; rc=1; continue; }
    needle=$(printf '%s' "$token" | sed 's/^handoff\.//; s/^facts\.//')
    grep -qF "$needle" "$(contract_source "$2/$path")" \
      || { echo "channel $token is not defined in the file it cites ($path)"; rc=1; }
  done <<EOF
$rows
EOF
  return $rc
}

check_single_heading() {  # <repo-root>
  local n
  n=$(cd "$1" && grep -rl '^## Closing Elicitation Sweep' --include='*.md' agents/ commands/ skills/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq 1 ] || { echo "canonical heading appears in $n files, expected exactly 1"; return 1; }
}

check_no_fourth_escalation_copy() {  # <repo-root>
  local n
  n=$(cd "$1" && grep -rlE 'spend[- ]authoriz' --include='*.md' agents/ commands/ skills/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq 3 ] || { echo "escalation-class enumeration is in $n files, expected 3 (point at the canonical one)"; return 1; }
}

check_no_escape_hatch() {  # <contracts>
  local body
  body="$(awk '/^## Closing Elicitation Sweep/{f=1;next} /^## /{f=0} f' "$1")"
  [ -n "$body" ] || { echo "non-vacuity: canonical section not extracted"; return 1; }
  if printf '%s\n' "$body" | grep -qiE 'warn-only|warn:|advisory|_STRICT|--strict|opt-in'; then
    echo "the sweep surface carries a rollout escape hatch; REQ-10 is strict from day one"
    return 1
  fi
  return 0
}

check_frontmatter_line_budget() {  # <contracts>
  local over
  [ "$(grep -c '^### #tpl-' "$1" || true)" -ge 13 ] || { echo "non-vacuity: templates not found"; return 1; }
  over=$(awk '/^```yaml$/{n=0;f=1;next} f&&/^```$/{if(n>30) print NR":"n; f=0; next} f{n++}' "$1")
  [ -z "$over" ] || { echo "template yaml block over the 30-line budget at line:count $over"; return 1; }
}

# P2-6: check_no_escape_hatch only reaches the canonical section body. The
# sweep obligation is also enforced by three functions in handoff-harness.sh
# (check_sweep_stub_shape, check_sweep_ref_anchor, check_sweep_ledger) and
# their call sites — a warn-only arm could land there without tripping the
# canonical-section grep. This widens the reach without keying on the generic
# "warn:"/"--strict" vocabulary, which the UNRELATED AR-reference rollout
# (§ Step B) legitimately uses in the same file — a naive wide grep would
# false-positive on that rollout's own advisory text.
check_no_sweep_escape_hatch_wide() {  # <harness>
  local fn body hits ln
  for fn in check_sweep_stub_shape check_sweep_ref_anchor check_sweep_ledger; do
    body=$(awk -v f="${fn}() {" 'index($0, f) == 1 {p=1} p{print} p && /^}/{exit}' "$1")
    [ -n "$body" ] || { echo "non-vacuity: $fn not found in $1"; return 1; }
    if printf '%s\n' "$body" | grep -qE 'STRICT|--strict|warn-only|opt-in|echo "warn:'; then
      echo "$fn carries a strict/warn-only escape hatch"
      return 1
    fi
  done
  # Keyed on the CALL (with its real argument list), not on an "if !" prefix:
  # a warn-only wrapper naturally changes the if-condition's shape (e.g. adds
  # a STRICT test ahead of the "!"), which would silently evade a prefix match.
  hits=$(grep -n 'check_sweep_stub_shape "\$fmfile"\|check_sweep_ref_anchor "\$f" "\$fmfile"\|check_sweep_ledger "\$fmfile"' "$1")
  [ -n "$hits" ] || { echo "non-vacuity: no sweep check call sites found in $1"; return 1; }
  while IFS=: read -r ln _; do
    if sed -n "$((ln - 2)),$((ln + 2))p" "$1" | grep -qE 'STRICT|--strict|warn-only|opt-in'; then
      echo "sweep check call at line $ln is gated behind a strict/warn-only conditional"
      return 1
    fi
  done <<< "$hits"
  return 0
}

# --- fixture helper ----------------------------------------------------------

plant() {  # plant <src> <sed-expr> -> prints the mutated copy's path
  local d out
  d="$(mk_tmpworkdir)"
  out="$d/$(basename "$1")"
  sed "$2" "$1" > "$out"
  # A sed that matches nothing yields a byte-identical copy, so the arm below
  # tests an unmutated file and passes forever. Refuse that silently-green shape:
  # every plant must change something.
  if cmp -s "$1" "$out"; then
    printf >&2 'plant: sed matched nothing in %s -- %s\n' "$1" "$2"
    return 1
  fi
  printf '%s' "$out"
}

# --- obligation matrix covers every stage code -------------------------

@test "AC-1: sweep obligation matrix rows equal the canonical stage list (both sides extracted)" {
  run check_matrix_completeness "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" "$PLUGIN_ROOT/$STAGE_CODES" "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
  assert_success
}

@test "AC-1 twin: dropping one matrix row makes the completeness check fail" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" 's/, RE, ET — takes the default/, RE — takes the default/')"
  run check_matrix_completeness "$planted" "$PLUGIN_ROOT/$STAGE_CODES" "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
  assert_failure
}

# --- one pointer per stage agent, never a restatement ------------------

@test "AC-2: every stage agent carries the sweep pointer exactly once" {
  run check_pointer_once "$PLUGIN_ROOT/agents" "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-2 twin: a duplicated pointer in one agent fails the check" {
  local d phrase
  d="$(mk_tmpworkdir)"
  cp "$PLUGIN_ROOT"/agents/*.md "$d/"
  phrase="$(canonical_phrase "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  printf '\nsee %s\n' "$phrase" >> "$d/stakeholder.md"
  run check_pointer_once "$d" "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_failure
}

@test "AC-2 twin: an agent restating the canonical section as its own heading fails AC-8" {
  local d
  d="$(mk_tmpworkdir)"
  mkdir -p "$d/agents" "$d/commands" "$d/skills"
  cp "$PLUGIN_ROOT/agents/stakeholder.md" "$d/agents/"
  cp "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" "$d/skills/"
  printf '\n## Closing Elicitation Sweep\n\nrestated\n' >> "$d/agents/stakeholder.md"
  run check_single_heading "$d"
  assert_failure
}

# --- one item shape, and exactly-one-recommended still pinned ----------

@test "AC-3: open_questions accepts the sweep stub and nothing else, and pins exactly-one-recommended" {
  run check_schema_shape "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
  assert_success
}

@test "AC-3 twin: re-adding the not:{required:[class]} guard fails (nothing left to discriminate)" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    "s|^        items: { \\\$ref: '#/\\\$defs/SweepStub' }.*|        items: { not: { required: [class] }, \\\$ref: '#/\\\$defs/SweepStub' }|")"
  run check_schema_shape "$planted"
  assert_failure
  assert_output --partial "disjointness guard reappeared"
}

@test "AC-3 twin: re-admitting the legacy string form via a oneOf fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    "s|^        items: { \\\$ref: '#/\\\$defs/SweepStub' }.*|        items: { oneOf: [{ type: string }, { \\\$ref: '#/\\\$defs/SweepStub' }] }|")"
  run check_schema_shape "$planted"
  assert_failure
  assert_output --partial "disjunction again"
}

@test "AC-3 twin: dropping the \$ref fails non-vacuity rather than passing silently" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    "s|^        items: { \\\$ref: '#/\\\$defs/SweepStub' }.*|        items: { type: object }|")"
  run check_schema_shape "$planted"
  assert_failure
  assert_output --partial "non-vacuity"
}

@test "AC-3 twin: dropping maxContains would let a two-recommended item pass, and fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" '/maxContains: 1/d')"
  run check_schema_shape "$planted"
  assert_failure
}

@test "AC-3 twin: dropping minContains would let a zero-recommended item pass, and fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" '/minContains: 1/d')"
  run check_schema_shape "$planted"
  assert_failure
}

# --- the other two transports carry the same single shape -------------

# Every typed-return schema must reach SweepItem through a bare `items: { "$ref": ... }`.
# Counted against the number of *Handoff titles so a dropped schema cannot pass by absence.
check_typed_return_shape() {  # <handoff>
  local titles refs oneofs
  titles=$(grep -cE '^  "title": "[A-Z]{2}Handoff",$' "$1" || true)
  [ "$titles" -ge 13 ] || { echo "non-vacuity: only $titles Handoff titles found"; return 1; }
  oneofs=$(grep -cF '"open_questions": { "type": "array", "items": { "oneOf": [{ "type": "string" }' "$1" || true)
  [ "$oneofs" -eq 0 ] || { echo "$oneofs typed-return schemas still admit the legacy string form"; return 1; }
  refs=$(grep -cF '"open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }' "$1" || true)
  [ "$refs" -eq "$titles" ] \
    || { echo "$refs of $titles typed-return schemas use items:{\$ref SweepItem}"; return 1; }
}

@test "AC-3b: all 13 typed-return schemas carry items:{\$ref SweepItem} and no oneOf" {
  run check_typed_return_shape "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
  assert_success
}

@test "AC-3b twin: schemas reverting to the legacy oneOf fail" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    's|"open_questions": { "type": "array", "items": { "\$ref": "#/\$defs/SweepItem" } }|"open_questions": { "type": "array", "items": { "oneOf": [{ "type": "string" }, { "$ref": "#/$defs/SweepItem" }] } }|')"
  run check_typed_return_shape "$planted"
  assert_failure
  assert_output --partial "legacy string form"
}

# The ledger mirrors SweepStub inline (it is a different document), so the two `required:`
# lines are compared rather than assumed equal.
ledger_oq_required() {  # <handoff>
  # Stops at the next H2-H4, not at the next heading of any level: the schema block
  # is split across H5 children, and `required:` lives in the item-shape child.
  awk '/^#### facts — open_questions$/{f=1;next} f && /^#{2,4} /{f=0} f' "$1" \
    | grep -m1 'required:'
}

@test "AC-3b: the ledger open_questions item requires the same set as SweepStub" {
  local ledger stub
  ledger="$(ledger_oq_required "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" | sed 's/^ *//')"
  [ -n "$ledger" ] || fail "non-vacuity: the ledger required: line was not extracted"
  stub="$(sweep_stub_defs "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" | grep -m1 'required:' | sed 's/^ *//')"
  [ -n "$stub" ] || fail "non-vacuity: SweepStub required: line was not extracted"
  [ "$ledger" = "$stub" ] || fail "ledger requires '$ledger'; SweepStub requires '$stub'"
}

@test "AC-3b twin: a ledger that reverts to required: [id] fails the comparison" {
  local planted ledger stub
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    's/^          required: \[id, class, ref, blocks_next_stage\]$/          required: [id]/')"
  ledger="$(ledger_oq_required "$planted" | sed 's/^ *//')"
  stub="$(sweep_stub_defs "$planted" | grep -m1 'required:' | sed 's/^ *//')"
  [ "$ledger" != "$stub" ] || fail "the planted divergence was not observable: '$ledger' vs '$stub'"
}

# --- every template carries the field; empty obligation stated once ----

@test "AC-4: every per-stage frontmatter template carries open_questions" {
  run check_templates_carry_field "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-4 twin: a template missing open_questions fails the enumeration" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/sw-ST0-1/d')"
  # Chained through plant(), not a bare `sed -i`: this second mutation is the one
  # the assertion actually rests on, and an unguarded sed that stops matching
  # leaves a twin that can no longer fail.
  planted="$(plant "$planted" '/^  stage: ST$/,/^  refs:$/ s/^  open_questions:$//')"
  run check_templates_carry_field "$planted"
  assert_failure
}

@test "AC-4: the explicit-empty obligation is stated exactly once" {
  run check_empty_obligation_once "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-4 twin: restating the explicit-empty obligation a second time fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '$a\
A stage with nothing to ask says so: nothing to elicit.')"
  run check_empty_obligation_once "$planted"
  assert_failure
}

# --- raise-only classification -----------------------------------------

@test "AC-5: the class self-label may be raised, never lowered, and is applied before auto-answer" {
  run check_raise_only "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-5 twin: removing the monotone-join statement fails the guard check" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" 's/`max(agent label, orchestrator label)`/a label the orchestrator picks/')"
  run check_raise_only "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" "$planted"
  assert_failure
}

@test "AC-5 twin: the command restating the join, instead of pointing at it, fails" {
  # The failure mode R-24 closes: a second copy that drifts from the first while both
  # read as authoritative.
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" '/^A closing-sweep item arrives/a\
The orchestrator computes `effective = max(agent_label, orchestrator_label)`.')"
  run check_raise_only "$planted" "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_failure
}

# --- one behaviour row per unattended carrier --------------------------

@test "AC-6: every carrier named in its defining file has exactly one fallback row" {
  run check_carriers "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" "$(contract_source "$PLUGIN_ROOT/$PL0_PROC")" "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" "$PLUGIN_ROOT/$PREFLIGHT"
  assert_success
}

@test "AC-6 twin: deleting a carrier's fallback row fails the completeness check" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/CORPFLOW_NONINTERACTIVE=1/d')"
  run check_carriers "$planted" "$(contract_source "$PLUGIN_ROOT/$PL0_PROC")" "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" "$PLUGIN_ROOT/$PREFLIGHT"
  assert_failure
}

# --- no duplication of channels that already exist ---------------------

@test "AC-7: each of the four pre-existing channels is named once and resolves in the file it cites" {
  run check_channels "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" "$PLUGIN_ROOT"
  assert_success
}

@test "AC-7 twin: a fifth channel row fails the count" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/^| an ethics decision |/a\
| a fifth thing | `made_up_field:` | `skills/worktask/references/stage-codes.md` |')"
  run check_channels "$planted" "$PLUGIN_ROOT"
  assert_failure
}

# --- single-sourcing across the whole prompt surface -------------------

@test "AC-8: the canonical section heading exists in exactly one file" {
  run check_single_heading "$PLUGIN_ROOT"
  assert_success
}

@test "AC-8: the sweep added no fourth copy of the escalation-class enumeration" {
  run check_no_fourth_escalation_copy "$PLUGIN_ROOT"
  assert_success
}

@test "AC-8 twin: a fourth escalation-class copy fails the count" {
  local d
  d="$(mk_tmpworkdir)"
  mkdir -p "$d/agents" "$d/commands" "$d/skills"
  cp "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/workflow.md")" "$d/commands/"
  cp "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/orchestration.md")" "$d/skills/"
  cp "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/pl0-procedure.md")" "$d/skills/"
  cp "$PLUGIN_ROOT/agents/stakeholder.md" "$d/agents/"
  printf '\nirreversible, scope-expanding, posture-weakening, or spend-authorizing.\n' >> "$d/agents/stakeholder.md"
  run check_no_fourth_escalation_copy "$d"
  assert_failure
}

# --- the 30-line frontmatter budget survives the wider template -------

@test "AC-13: every per-stage template yaml block stays within the 30-line budget" {
  run check_frontmatter_line_budget "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-13 twin: a template block past 30 lines fails the budget check" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/^  stage: ST$/a\
  filler_01: x\
  filler_02: x\
  filler_03: x\
  filler_04: x\
  filler_05: x\
  filler_06: x\
  filler_07: x\
  filler_08: x\
  filler_09: x\
  filler_10: x\
  filler_11: x\
  filler_12: x\
  filler_13: x\
  filler_14: x\
  filler_15: x\
  filler_16: x\
  filler_17: x\
  filler_18: x\
  filler_19: x\
  filler_20: x\
  filler_21: x\
  filler_22: x\
  filler_23: x\
  filler_24: x\
  filler_25: x')"
  run check_frontmatter_line_budget "$planted"
  assert_failure
}

@test "AC-13: the agent-side frontmatter template lint passes for EVERY stage agent, no carve-outs" {
  local f base rc=0 checked=0
  for f in "$PLUGIN_ROOT"/agents/*.md; do
    base="$(basename "$f" .md)"
    case " $NON_STAGE_AGENTS " in *" $base "*) continue ;; esac
    # No file is skipped: a `## Handoff Protocol` section is itself part of the contract,
    # so an agent lacking one must fail here rather than be stepped over.
    checked=$((checked + 1))
    grep -q '^## Handoff Protocol[[:space:]]*$' "$f" \
      || { echo "$base.md: no '## Handoff Protocol' section"; rc=1; continue; }
    run bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" --frontmatter-template-lint "$f"
    if [ "$status" -ne 0 ]; then echo "$base: $output"; rc=1; fi
  done
  [ "$checked" -ge 14 ] || fail "non-vacuity: only $checked stage agents checked"
  [ "$rc" -eq 0 ]
}

# --- strict from day one, no escape hatch -----------------------------

@test "AC-15: the sweep surface carries no warn-only mode, opt-in variable, or advisory tier" {
  run check_no_escape_hatch "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
}

@test "AC-15 twin: adding a warn-only arm to the canonical section fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '/^### Sweep obligation matrix$/a\
A missing sweep is warn-only until the next minor.')"
  run check_no_escape_hatch "$planted"
  assert_failure
}

@test "AC-15 twin: an advisory column in the matrix fails" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" 's/^| Code | Obligation |/| Code | Advisory |/')"
  run check_no_escape_hatch "$planted"
  assert_failure
}

@test "P2-6: the sweep-specific harness gate (check_sweep_*) carries no strict/warn-only escape hatch" {
  run check_no_sweep_escape_hatch_wide "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh"
  assert_success
}

@test "P2-6 twin: gating a check_sweep_* call site behind STRICT fails the wide check" {
  local planted
  planted="$(plant "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" \
    's/check_sweep_ledger "\$fmfile" "\$f" || rc=1/[[ "\$STRICT" == "1" ]] \&\& { check_sweep_ledger "\$fmfile" "\$f" || rc=1; }/')"
  run check_no_sweep_escape_hatch_wide "$planted"
  assert_failure
}

@test "P2-6 twin: an unrelated warn-only rollout elsewhere in the same file does not false-positive" {
  # The AR-reference check (§ Step B) legitimately says warn-only/--strict in this
  # same file; the widened guard must key on the sweep functions specifically.
  run bash -c "grep -q 'is warn-only by default and blocks only under --strict' '$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh'"
  assert_success
  run check_no_sweep_escape_hatch_wide "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh"
  assert_success
}

# --- orchestrator wiring: the STOP is not moved ------------------------------

@test "the sweep render precedes the FN approve/reject STOP, which stays last and unmodified" {
  local render stop
  render=$(grep -n '(c+) Render the collected sweep' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")" | head -1 | cut -d: -f1)
  stop=$(grep -n '(d) AskUserQuestion: approve' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")" | head -1 | cut -d: -f1)
  [ -n "$render" ] && [ -n "$stop" ] || fail "non-vacuity: step 4.9 sub-steps not found"
  [ "$render" -lt "$stop" ] || fail "the sweep does not precede the approve/reject call"
}

@test "both orchestrator commands declare AskUserQuestion in allowed-tools" {
  local f
  for f in skills/worktask/SKILL.md commands/megatask.md; do
    grep -q 'AskUserQuestion' "$(contract_source "$PLUGIN_ROOT/$f")" || fail "$f never calls AskUserQuestion"
    grep -E '^allowed-tools:' "$(contract_source "$PLUGIN_ROOT/$f")" | grep -q 'AskUserQuestion' \
      || fail "$f calls AskUserQuestion but does not declare it"
  done
}

# --- P1-1 rework: the ledger transport has a writer, and it is checked ------

HARNESS="skills/worktask/scripts/handoff-harness.sh"
STATE_PATCH="skills/worktask/scripts/state-patch.sh"

# Every agent that shows a --facts payload must show open_questions in it: the
# frontmatter stub and facts.open_questions[] are separate transports with separate
# writers, so an example without it teaches the stage to drop its own sweep.
facts_example_agents() {  # <agents-dir> -> agent files carrying a --facts example
  grep -rl -- "state-patch.sh --stage .* --facts" "$1"/*.md 2>/dev/null | sort
}

check_facts_examples() {  # <agents-dir>
  local f n=0 rc=0 block
  for f in $(facts_example_agents "$1"); do
    n=$((n + 1))
    block="$(awk '/state-patch\.sh --stage .* --facts/{f=1} f{print} f&&/\}.$/{exit}' "$f")"
    printf '%s\n' "$block" | grep -q '"open_questions"' \
      || { echo "$(basename "$f"): --facts example omits open_questions"; rc=1; }
  done
  [ "$n" -ge 8 ] || { echo "non-vacuity: only $n --facts examples found"; return 1; }
  return $rc
}

@test "P1-1: every agent --facts example carries open_questions" {
  run check_facts_examples "$PLUGIN_ROOT/agents"
  assert_success
}

@test "P1-1 twin: an agent whose --facts example drops open_questions fails" {
  local d
  d="$(mk_tmpworkdir)"
  cp "$PLUGIN_ROOT"/agents/*.md "$d/"
  sed -i.bak '/"open_questions": \[{"id":"sw-DC0-1"/d' "$d/technical-writer.md"
  sed -i.bak2 's/"decisions": \[{"id":"dv-1","summary":"≤160 chars","ref":"development-0.md#deviations"}\],/"decisions": [{"id":"dv-1","summary":"≤160 chars","ref":"development-0.md#deviations"}]}'"'"'/' "$d/developer.md"
  run check_facts_examples "$d"
  assert_failure
}

# The harness cross-check is what makes the obligation non-memory-dependent.
sweep_fixture() {  # sweep_fixture <dir> <ref-or-empty> [with-anchor|no-anchor]
  local d="$1" ref="$2"
  if [ -n "$ref" ]; then
    sweep_fixture_items "$d" "$(printf '    - { id: sw-DC0-1, summary: "q", class: decision, ref: "%s", blocks_next_stage: false }' "$ref")" "${3:-with-anchor}"
  else
    sweep_fixture_items "$d" '    - { id: sw-DC0-1, summary: "q", class: decision, blocks_next_stage: false }' "${3:-with-anchor}"
  fi
}

# The same fixture with the open_questions[] items supplied verbatim, so a test can plant
# any item shape — including the ones the harness must now reject.
sweep_fixture_items() {  # sweep_fixture_items <dir> <items-yaml> [with-anchor|no-anchor]
  local d="$1" items="$2"
  mkdir -p "$d"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n'
    printf '  summary: "fixture"\n  files_touched: [a.md]\n'
    printf '  open_questions:\n'
    printf '%s\n' "$items"
    printf '  refs: { dev: development-0.md#files-changed }\n'
    printf -- '---\n\n# Documentation\n'
    # The anchor the stub points at: present by default so each test isolates one contract.
    # Each item carries two options, so the harness's item-body check never decides a verdict here.
    if [ "${3:-with-anchor}" = "with-anchor" ]; then
      printf '\n## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\n'
      for id in sw-DC0-1 sw-DC0-2; do
        printf -- '- id: %s\n  summary: "Which way?"\n  options:\n' "$id"
        printf -- '    - { label: "A", detail: "first" }\n    - { label: "B", detail: "second" }\n'
      done
    fi
  } > "$d/documentation-0.md"
}

@test "P1-1: the harness fails a stub that never reached facts.open_questions[]" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep"
  printf '{"facts":{"open_questions":[]}}\n' > "$d/state.json"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md" --state "$d/state.json"
  assert_failure
  assert_output --partial "not in facts.open_questions[]"
}

@test "P1-1 twin: the same stub passes once it is in the ledger (the check is not unconditional)" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep"
  printf '{"facts":{"open_questions":[{"id":"sw-DC0-1","class":"decision","ref":"documentation-0.md#elicitation-sweep","blocks_next_stage":false}]}}\n' > "$d/state.json"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md" --state "$d/state.json"
  assert_success
}

@test "a stub with no ref fails legibly rather than as a bare schema mismatch" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" ""
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "carries no ref"
}

# --- sw-DR0-2: the stage filter reads a field that may be absent -------------

@test "sw-DR0-2: Step C.1 derives the stage from the item id and treats an explicit stage as optional" {
  local body
  body="$(awk '/^### Step C — Closing-sweep collection/{f=1;next} f && /^#{2,3} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: Step C not found"
  printf '%s\n' "$body" | grep -q 'Derive' || fail "C.1 does not derive the stage"
  printf '%s\n' "$body" | grep -q 'sw-<TASK_ID>-<n>' || fail "C.1 does not name the id shape it parses"
  printf '%s\n' "$body" | grep -q 'explicit .*stage.* wins when present' || fail "explicit stage precedence unstated"
  # The schema must keep `stage` optional, or the derivation is pointless.
  local defs
  defs="$(sweep_stub_defs "$(contract_source "$PLUGIN_ROOT/$HANDOFF")")"
  printf '%s\n' "$defs" | grep -q 'required: \[id, class, ref, blocks_next_stage\]' \
    || fail "SweepStub's required set changed; stage may have become mandatory"
}

# --- sw-DR0-3: sweep answers must not evict architectural decisions ----------

@test "sw-DR0-3: Step C.5 records answers in open_questions[].resolution, not facts.decisions[]" {
  local body
  body="$(section_body "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" '^#### Step C.5')"
  [ -n "$body" ] || fail "non-vacuity: Step C.5 not found"
  printf '%s\n' "$body" | grep -q 'resolution' || fail "C.5 does not record into resolution"
  printf '%s\n' "$body" | grep -q 'do not append.*facts.decisions' || fail "C.5 does not exclude facts.decisions[]"
  # The field it writes has to exist in the ledger schema.
  grep -q 'resolution: { type: string, maxLength: 160 }' "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    || fail "facts.open_questions[].resolution is not in the ledger schema"
}

# The clamp is extracted from state-patch.sh and executed, so this asserts behaviour
# rather than the presence of a line.
bounds_filter() { sed -n "/^_STATE_BOUNDS_FILTER='/,/'$/p" "$1" | sed "1s/^_STATE_BOUNDS_FILTER='//" | sed "\$s/'$//"; }

# The bound is READ from the clamp, never restated here. Two cases below hard-coded
# `12` and went stale the moment the bound moved per task — the failure mode is the
# assertion, not the code. Deriving it closes the class: a future rescope moves these
# with it, and a bound that vanishes from the filter fails as non-vacuity.
bounds_value() {  # <state-patch> <decisions|open_questions>
  bounds_filter "$1" \
    | sed -n "s/.*\.facts\.$2 |= _keep_newest[a-z_]*(_task_of_[a-z]*; \([0-9][0-9]*\)).*/\\1/p" \
    | head -1
}

@test "sw-DR0-3: facts.open_questions is clamped PER TASK, unresolved surviving ahead of resolved" {
  local filter bound out
  filter="$(bounds_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  [ -n "$filter" ] || fail "non-vacuity: bounds filter not extracted"
  printf '%s\n' "$filter" | grep -q 'open_questions' || fail "open_questions is not clamped at the chokepoint"
  bound="$(bounds_value "$PLUGIN_ROOT/$STATE_PATCH" open_questions)"
  [ -n "$bound" ] || fail "non-vacuity: the open_questions bound was not derived from the clamp"

  # One task's bucket, over-filled with resolved items first: the bound survives and
  # every survivor is unresolved, because resolved items are eviction bait.
  local input i n=$((bound * 2))
  input='{"facts":{"open_questions":['
  for i in $(seq 0 $((n - 1))); do input="${input}{\"id\":\"sw-DV0-1$i\",\"status\":\"resolved\"},"; done
  for i in $(seq 0 $((n - 1))); do input="${input}{\"id\":\"sw-DV0-2$i\"},"; done
  input="${input%,}]}}"
  out="$(printf '%s' "$input" | jq -c "$filter" | jq -c '[.facts.open_questions[]]')"
  [ "$(printf '%s' "$out" | jq 'length')" -eq "$bound" ] \
    || fail "clamp did not bound the bucket to $bound: $out"
  [ "$(printf '%s' "$out" | jq '[.[] | select((.status // "open") == "resolved")] | length')" -eq 0 ] \
    || fail "a resolved item survived while unresolved ones were evicted: $out"
}

@test "sw-DR0-3: one task's bucket cannot evict another's" {
  local filter bound input i out
  filter="$(bounds_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  bound="$(bounds_value "$PLUGIN_ROOT/$STATE_PATCH" open_questions)"
  [ -n "$bound" ] || fail "non-vacuity: the open_questions bound was not derived from the clamp"

  # DV0 over-fills its bucket; DV1 stays inside its own. A global ring would evict
  # DV1's older items on volume alone — the cross-task coupling being removed.
  input='{"facts":{"open_questions":['
  for i in $(seq 0 $bound); do input="${input}{\"id\":\"sw-DV1-$i\"},"; done
  for i in $(seq 0 $((bound * 3))); do input="${input}{\"id\":\"sw-DV0-$i\"},"; done
  input="${input%,}]}}"
  out="$(printf '%s' "$input" | jq -c "$filter" | jq -c '[.facts.open_questions[].id]')"
  [ "$(printf '%s' "$out" | jq '[.[] | select(startswith("sw-DV1-"))] | length')" -eq "$bound" ] \
    || fail "DV1's bucket was not clamped to its own bound: $out"
  [ "$(printf '%s' "$out" | jq '[.[] | select(startswith("sw-DV0-"))] | length')" -eq "$bound" ] \
    || fail "DV0's bucket was not clamped to its own bound: $out"
}

@test "sw-DR0-3 twin: a below-bound array is left byte-identical (no-op path holds)" {
  local filter out
  filter="$(bounds_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"a"},{"id":"b"}]}}' | jq -c "$filter")"
  [ "$out" = '{"facts":{"open_questions":[{"id":"a"},{"id":"b"}]}}' ] || fail "no-op path mutated state: $out"
}

# --- P2-7: the sweep anchor is required in every artifact ---------------------

@test "P2-7: the elicitation-sweep anchor is required — fails without it, passes with it" {
  local d
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n  summary: "s"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n'
    printf '## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n'
  } > "$d/documentation-0.md"
  # Every DC anchor present, sweep heading absent: the universal anchor is the only defect.
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/documentation-0.md"
  assert_failure
  assert_output --partial "missing: elicitation-sweep"
  # And it is accepted when present, rather than reported as unexpected.
  printf '\n## elicitation-sweep\n\nnothing to elicit\n' >> "$d/documentation-0.md"
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/documentation-0.md"
  assert_success
  # rework-<N> keeps its allowance: agents/technical-lead.md reads it at the DR gate,
  # and anchor-lint used to reject the very section its own contract asks for.
  printf '\n## rework-1\n\nx\n' >> "$d/documentation-0.md"
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/documentation-0.md"
  assert_success
}

@test "P2-7 twin: a genuinely unknown anchor is still rejected (the allowance is scoped)" {
  local d
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n  summary: "s"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n'
    printf '## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n'
    printf '\n## elicitation-sweep\n\nnothing to elicit\n'
    printf '\n## not-an-anchor\n\nx\n'
  } > "$d/documentation-0.md"
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/documentation-0.md"
  assert_failure
  assert_output --partial "unexpected: not-an-anchor"
}

# --- P2-7b: the obligation is ONE constant, not thirteen table rows ----------

CACHE_LINT="skills/worktask/scripts/cache-lint.sh"

@test "P2-7b: elicitation-sweep is a universal anchor and no longer an optional one" {
  grep -q "^UNIVERSAL_ANCHORS='elicitation-sweep'\$" "$PLUGIN_ROOT/$CACHE_LINT" \
    || fail "UNIVERSAL_ANCHORS is not the single source of the obligation"
  if grep -q "^OPTIONAL_ANCHOR_RE=.*elicitation-sweep" "$PLUGIN_ROOT/$CACHE_LINT"; then
    fail "elicitation-sweep is still in OPTIONAL_ANCHOR_RE, which would make it not-required"
  fi
  # The append must reach BOTH the missing loop and the comm, i.e. \$expected itself.
  grep -q 'expected="\$expected \$UNIVERSAL_ANCHORS"' "$PLUGIN_ROOT/$CACHE_LINT" \
    || fail "UNIVERSAL_ANCHORS is declared but never folded into \$expected"
}

@test "P2-7b twin: a copy that moves the anchor back to optional accepts the no-sweep fixture" {
  local planted d
  planted="$(plant "$PLUGIN_ROOT/$CACHE_LINT" \
    "s/^OPTIONAL_ANCHOR_RE='\^(/OPTIONAL_ANCHOR_RE='^(elicitation-sweep|/; /UNIVERSAL_ANCHORS\"/d")"
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n  summary: "s"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n'
    printf '## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n'
  } > "$d/documentation-0.md"
  run env PATH="/usr/bin:/bin" bash "$planted" --anchor-lint "$d/documentation-0.md"
  assert_success   # the planted regression is real: without it the fixture must fail
}

# --- sw-DR0-5 / sw-DV0-5: the ref anchor is the only transport of options[] ---

@test "sw-DV0-5: a stub whose ref anchor does not exist fails, naming the dangling anchor" {
  local d
  d="$(mk_tmpworkdir)"
  # Same stub, same well-formed ref — but no `## elicitation-sweep` heading to resolve to.
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep" no-anchor
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "dangling"
}

@test "sw-DV0-5 twin: the identical stub passes once the anchor exists (the check is not unconditional)" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_success
}

@test "sw-DV0-5: a ref naming a file that does not exist fails" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "no-such-artifact-0.md#elicitation-sweep"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "does not exist"
}

# --- the stub is the ONLY item shape: each pre-sweep form is rejected by name ----

@test "shape gate: the legacy free-text form is rejected, naming the shape it must take" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture_items "$d" '    - "q1: hook lang (AR to decide)"'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "is not a sweep stub"
}

@test "shape gate: the legacy bare object is rejected, naming the id shape" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture_items "$d" '    - { id: q2, summary: "bare object" }'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial 'id "q2" is not sw-'
}

@test "shape gate: a class outside {decision, escalate} is rejected" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture_items "$d" \
    '    - { id: sw-DC0-1, class: advisory, ref: "documentation-0.md#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "class is not decision|escalate"
}

@test "shape gate: a non-string id fails by name instead of passing on a yq error" {
  # yq's test() throws on an int; the gate must report the id, not pass on the read error.
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture_items "$d" \
    '    - { id: 5, class: decision, ref: "documentation-0.md#elicitation-sweep" }'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial 'id "5" is not sw-'
}

@test "shape gate: a scalar open_questions is rejected — [] is the only empty form" {
  local d
  d="$(mk_tmpworkdir)"
  mkdir -p "$d"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n'
    printf '  summary: "fixture"\n  files_touched: [a.md]\n'
    printf '  open_questions: "none"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n'
    printf -- '---\n\n# Documentation\n\n## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\nnothing to elicit\n'
  } > "$d/documentation-0.md"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_failure
  assert_output --partial "open_questions is !!str, not a sequence"
}

@test "sw-DV0-5: a ref that repeats the artifact's own directory resolves to the same file" {
  # The templates' refs: rows use `.context/<artifact>-N.md#…`; a stub copying that
  # convention names the artifact itself, not `.context/.context/…`.
  local d
  d="$(mk_tmpworkdir)/.context"
  sweep_fixture_items "$d" \
    '    - { id: sw-DC0-1, class: decision, ref: ".context/documentation-0.md#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_success
}

@test "shape gate twin: an all-stub artifact with its anchor passes (the gate is not unconditional)" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture_items "$d" \
    '    - { id: sw-DC0-1, class: decision, ref: "documentation-0.md#elicitation-sweep", blocks_next_stage: false }
    - { id: sw-DC0-2, summary: "optional", class: escalate, ref: "documentation-0.md#elicitation-sweep", blocks_next_stage: true }'
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  assert_success
}

@test "sw-DV0-5: no warn arm — the dangling-anchor path fails rather than warning (REQ-10)" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep" no-anchor
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md"
  [ "$status" -ne 0 ] || fail "non-vacuity: the fixture did not exercise the check at all"
  if printf '%s\n' "$output" | grep -q '^warn:'; then
    fail "the sweep surface degraded to a warning"
  fi
  printf '%s\n' "$output" | grep -q '^fail:' || fail "expected a fail: line, got: $output"
}

# --- sw-DV0-4 (USER: resolved-first): pin the ORDERING, not just the count ---
# The bound is derived from the clamp (bounds_value), never restated: this case
# hard-coded the retired global 12 and went stale the moment the bound moved.

@test "sw-DV0-4: eviction prefers resolved items — every unresolved item outlives every resolved one" {
  local filter bound input out i open_n res_n
  filter="$(bounds_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  [ -n "$filter" ] || fail "non-vacuity: bounds filter not extracted"
  bound="$(bounds_value "$PLUGIN_ROOT/$STATE_PATCH" open_questions)"
  [ -n "$bound" ] || fail "non-vacuity: the open_questions bound was not derived from the clamp"

  # One bucket, interleaved so position alone cannot produce the answer. Fewer
  # unresolved items than the bound, so the spare seats are contested: every
  # unresolved item must survive and a resolved one may take only what is left.
  open_n=$((bound - 1))
  res_n=$((bound + 2))
  input='{"facts":{"open_questions":['
  for i in $(seq 0 $((open_n - 1))); do
    input="${input}{\"id\":\"sw-DV0-1$i\",\"status\":\"open\"},{\"id\":\"sw-DV0-2$i\",\"status\":\"resolved\"},"
  done
  for i in $(seq $open_n $((res_n - 1))); do
    input="${input}{\"id\":\"sw-DV0-2$i\",\"status\":\"resolved\"},"
  done
  input="${input%,}]}}"
  out="$(printf '%s' "$input" | jq -c "$filter" | jq -c '[.facts.open_questions[]]')"

  [ "$(printf '%s' "$out" | jq 'length')" -eq "$bound" ] || fail "bound not applied: $out"
  [ "$(printf '%s' "$out" | jq '[.[] | select(.status == "open")] | length')" -eq "$open_n" ] \
    || fail "an unresolved item was evicted while resolved ones survived: $out"
  [ "$(printf '%s' "$out" | jq '[.[] | select(.status == "resolved")] | length')" -eq $((bound - open_n)) ] \
    || fail "resolved items were not evicted first: $out"
}

@test "sw-DV0-4: the bound is documented as a deliberate choice with its eviction preference" {
  local body
  # Read the whole H4 subtree: the rationale lives in its H5 child, and section_body
  # (leaf semantics, matching section-lint) would stop at that child's heading.
  body="$(awk '/^#### Ledger bounds/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: the Ledger bounds section is absent"
  # The LIVE bound, not merely a number: the retired global 12 is still named in this
  # section as history, so grepping a bare digit would pass on the wrong value.
  printf '%s\n' "$body" | grep -q 'per task' || fail "the bound is not stated as per-task"
  printf '%s\n' "$body" | grep -qE 'newest \*\*4 per task\*\*|4 per task' || fail "the bound value is not stated"
  printf '%s\n' "$body" | grep -qi 'resolved' || fail "the eviction preference is not stated"
  printf '%s\n' "$body" | grep -qi 'deliberate' || fail "the bound does not read as a decision anyone made"
}

# --- q10: the stub sheds `summary`, and the disjointness guard must survive it ---

# SweepStub spans two fenced blocks since the routing/answer fields were split out for the
# section cap; read from its definition to the end of that H4 subtree, not to the first fence.
sweep_stub_defs() {
  awk '/^#### \$defs — SweepStub/{f=1;next} f && /^#{2,4} /{f=0} f' "$1"
}

@test "q10: SweepStub requires [id, class, ref, blocks_next_stage] and no more" {
  local defs
  defs="$(sweep_stub_defs "$(contract_source "$PLUGIN_ROOT/$HANDOFF")")"
  [ -n "$defs" ] || fail "non-vacuity: SweepStub not extracted"
  printf '%s\n' "$defs" | grep -q 'required: \[id, class, ref, blocks_next_stage\]' \
    || fail "SweepStub's required set is not [id, class, ref, blocks_next_stage]: $defs"
  printf '%s\n' "$defs" | grep -q 'summary:' \
    || fail "summary was removed entirely; it must stay legal-but-optional"
  ! printf '%s\n' "$defs" | grep -qE '^ *required: \[[^]]*(status|resolution)' \
    || fail "the answer fields leaked into the frontmatter stub's required set"
}

@test "q10 TRAP: no disjointness guard remains, and summary is still legal-optional" {
  # With one item shape there is nothing to discriminate, so the guard must be gone —
  # while `summary` stays a legal optional field, which is the half q10 was about.
  local blk defs
  blk="$(open_questions_schema "$(contract_source "$PLUGIN_ROOT/$HANDOFF")")"
  [ -n "$blk" ] || fail "non-vacuity: the open_questions block was not extracted"
  if printf '%s\n' "$blk" | grep -q 'not:'; then
    fail "a disjointness guard survives; with one item shape it discriminates nothing"
  fi
  defs="$(sweep_stub_defs "$(contract_source "$PLUGIN_ROOT/$HANDOFF")")"
  printf '%s\n' "$defs" | grep -q 'summary:' \
    || fail "summary was removed entirely; it must stay legal-but-optional"
  printf '%s\n' "$defs" | grep -q 'required: \[id, class, ref, blocks_next_stage\]' \
    || fail "summary was made mandatory again"
}

@test "q10 TRAP twin: a planted guard is observable (the check can actually fail)" {
  local planted blk
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    "s|^        items: { \\\$ref: '#/\\\$defs/SweepStub' }.*|        items: { not: { required: [class] }, \\$ref: '#/\\$defs/SweepStub' }|")"
  blk="$(open_questions_schema "$planted")"
  printf '%s\n' "$blk" | grep -q 'not:' \
    || fail "the planted guard was not observable through the extraction helper"
}

@test "q10 twin: a stub schema that keeps summary required fails the check" {
  local planted
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" 's/required: \[id, class, ref, blocks_next_stage\]/required: [id, summary, class, ref, blocks_next_stage]/')"
  run bash -c "awk '/^  SweepStub:\$/{f=1} f{print} f&&/^\`\`\`\$/{exit}' '$planted' | grep -q 'required: \[id, class, ref, blocks_next_stage\]'"
  assert_failure
}

@test "q10: the 200-token budget is stated as a property of the whole handoff block" {
  local body
  body="$(awk '/^#### The stub carries no summary/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: the stub-shortening rationale section is absent"
  printf '%s\n' "$body" | grep -q '200-token' || fail "the driver budget is not named"
  printf '%s\n' "$body" | grep -qi 'whole .handoff:. block\|property of the block' \
    || fail "the budget is described as the sweep's, not the block's"
}

@test "q10: no per-stage template still carries summary in its sweep stub" {
  local hits
  hits="$(grep -c 'id: sw-[A-Z][A-Z]0-1, summary:' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" || true)"
  [ "$hits" -eq 0 ] || fail "$hits templates still put summary in the stub"
  [ "$(grep -c 'id: sw-[A-Z][A-Z]0-1, class: decision, ref:' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")" -ge 13 ] \
    || fail "non-vacuity: shortened stubs not found in the templates"
}

# --- q8 / sw-DR0-4: no downgrade of status or resolution, in BOTH transports ---

union_filter() { sed -n "/^_FACTS_UNION_FILTER='/,/'\$/p" "$1" | sed "1s/^_FACTS_UNION_FILTER='//" | sed "\$s/'\$//"; }

@test "q8 union: a re-emitted open stub cannot downgrade a recorded resolution" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  [ -n "$filter" ] || fail "non-vacuity: union filter not extracted"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","status":"resolved","resolution":"answered"}]}}' \
        | jq -c --argjson f '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":false}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].status == "resolved"' > /dev/null \
    || fail "the downgrade was accepted: $out"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].resolution == "answered"' > /dev/null \
    || fail "the recorded answer was lost: $out"
}

@test "q8 union: raising open to resolved is honoured (the join is monotone, not frozen)" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","status":"open"}]}}' \
        | jq -c --argjson f '{"open_questions":[{"id":"sw-DV0-1","status":"resolved","resolution":"now answered"}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].resolution == "now answered"' > /dev/null \
    || fail "a genuine answer was refused: $out"
}

@test "q8 union: an incoming stub that omits resolution inherits it, even when both say resolved" {
  # Found live: patching a stub with status:resolved but no body wiped three recorded answers.
  # Status and resolution are guarded independently — dropping the body is a downgrade too.
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"x","status":"resolved","resolution":"the answer"}]}}' \
        | jq -c --argjson f '{"open_questions":[{"id":"x","status":"resolved"}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].resolution == "the answer"' > /dev/null \
    || fail "the recorded answer was dropped by a resolution-less re-emit: $out"
}

@test "q8 union: a genuinely new resolution still replaces the old one (guarded, not frozen)" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"x","status":"resolved","resolution":"old"}]}}' \
        | jq -c --argjson f '{"open_questions":[{"id":"x","status":"resolved","resolution":"new"}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].resolution == "new"' > /dev/null \
    || fail "the field was frozen rather than guarded: $out"
}

@test "q8 union: scoped to open_questions — facts.decisions keeps last-writer-wins" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  printf '%s\n' "$filter" | grep -q '_union_keyed(.id)' \
    || fail "the shared keyed union was removed; facts.decisions semantics changed"
  out="$(printf '%s' '{"facts":{"decisions":[{"id":"d1","summary":"old"}]}}' \
        | jq -c --argjson f '{"decisions":[{"id":"d1","summary":"new"}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.decisions[0].summary == "new"' > /dev/null \
    || fail "decisions no longer take the last writer: $out"
}

@test "q8 union: a stub with no status/resolution gains only the two defaults (no null keys added)" {
  # `resolution` absent must stay absent: a null answer body renders as an answered
  # question with nothing in it. `status` and `stage` are the two keys _sweep_defaults
  # is allowed to synthesize, and the slot comes from the id when it carries one.
  local filter out stub
  stub='{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}'
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' "{\"facts\":{\"open_questions\":[$stub]}}" \
        | jq -c --arg sweep_stage "" --argjson f "{\"open_questions\":[$stub]}" "$filter")"
  printf '%s' "$out" | jq -e '
    .facts.open_questions | length == 1
    and (.[0] | has("resolution") | not)
    and (.[0] | [to_entries[] | select(.value == null)] | length == 0)
    and (.[0] | .id == "sw-PL0-1" and .class == "decision"
                and .ref == "planning-0.md#elicitation-sweep"
                and .blocks_next_stage == false
                and .status == "open" and .stage == "PL")
  ' > /dev/null || fail "the union mutated an unanswered stub: $out"
}

@test "q8 union: an EXPLICIT false clears the flag — sticky means absent, never falsy" {
  # The OV-183 defect lived in this one filter: the join ORed the flag, so once `true` reached
  # the ledger nothing could clear it, and an agent whose artifact said `false` was outvoted by
  # its own ledger stub. Absent still sticks (the test below); explicit false does not.
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":true}]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":false}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].blocks_next_stage == false' > /dev/null \
    || fail "an explicit false could not clear an incumbent true: $out"
}

@test "q8 union: blocks_next_stage is raise-only — a bare re-emit keeps the flag, a raise is honoured" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  # A BARE re-emit — the key absent, not false. --facts refuses this shape at the door now,
  # so the arm survives for legacy payloads only and is exercised here against the filter.
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":true}]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x"}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].blocks_next_stage == true' > /dev/null \
    || fail "a bare re-emit cleared blocks_next_stage: $out"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":false}]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":true}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].blocks_next_stage == true' > /dev/null \
    || fail "raising to blocking was refused: $out"
}

@test "q8 union: class is raise-only — escalate survives decision, a raise is honoured" {
  local filter out
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-SR0-1","class":"escalate","ref":"a.md#x","blocks_next_stage":false}]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-SR0-1","class":"decision","ref":"b.md#y","blocks_next_stage":false}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0] | .class == "escalate" and .ref == "b.md#y"' > /dev/null \
    || fail "an incumbent escalate was lowered: $out"
  out="$(printf '%s' '{"facts":{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"a.md#x","blocks_next_stage":false}]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","class":"escalate","ref":"a.md#x","blocks_next_stage":false}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0].class == "escalate"' > /dev/null \
    || fail "a raise to escalate was refused: $out"
}

@test "q8 union: a stub that omits class keeps the incumbent's class, whatever it is" {
  # Unreachable through --facts (the shape gate requires .class), so exercised on the filter.
  local filter out cls
  filter="$(union_filter "$PLUGIN_ROOT/$STATE_PATCH")"
  for cls in escalate decision; do
    out="$(printf '%s' "{\"facts\":{\"open_questions\":[{\"id\":\"sw-DV0-1\",\"class\":\"$cls\",\"ref\":\"a.md#x\",\"blocks_next_stage\":false}]}}" \
          | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","ref":"a.md#x","blocks_next_stage":false}]}' "$filter")"
    printf '%s' "$out" | jq -e --arg c "$cls" '.facts.open_questions[0].class == $c' > /dev/null \
      || fail "an omitted class dropped the incumbent $cls: $out"
  done
  out="$(printf '%s' '{"facts":{"open_questions":[]}}' \
        | jq -c --arg sweep_stage "" --argjson f '{"open_questions":[{"id":"sw-DV0-1","ref":"a.md#x","blocks_next_stage":false}]}' "$filter")"
  printf '%s' "$out" | jq -e '.facts.open_questions[0] | has("class") | not' > /dev/null \
    || fail "a new stub with no class gained a class key: $out"
}

@test "q9: the raise-only lattice is scoped to labellers, and transports are named a defect" {
  # Without this scope the orchestrator reaches for the nearest rule when an agent's artifact
  # and its own ledger stub disagree, ORs them, and manufactures a gate out of a bookkeeping slip.
  local body
  body="$(awk '/^#### Self-labels raise, never lower/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: § Self-labels raise, never lower is absent"
  printf '%s\n' "$body" | grep -qi 'never transports' \
    || fail "the lattice is not scoped away from transports"
  printf '%s\n' "$body" | grep -qi 'defect, not a lattice' \
    || fail "a transport divergence is not named a defect"
  printf '%s\n' "$body" | grep -q 'check_sweep_ledger' \
    || fail "the enforcing check is unnamed, so the rule has no mechanism"
}

@test "q9: the transport rule is mirrored where the orchestrator actually reads the join" {
  # A rule stated only in stage-contracts.md is a rule the orchestrator may never reach.
  local body
  body="$(awk '/^##### Escalation guard — raise-only self-labels/{f=1;next} f && /^#{2,5} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: § Escalation guard — raise-only self-labels is absent"
  printf '%s\n' "$body" | grep -qi 'never transports' \
    || fail "the orchestrator's own copy does not scope the join away from transports"
  printf '%s\n' "$body" | grep -q 'check_sweep_ledger' \
    || fail "the orchestrator's copy names no enforcing check"
}

@test "q9: a raise recorded at C.5 is written to BOTH transports" {
  # The corollary of the harness refusing a divergence: a ledger-only write-back would fail the
  # next --validate-frontmatter on a value this very step created.
  local body
  body="$(awk '/^#### Step C.5 — record, and the unattended lanes/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: § Step C.5 recording is absent"
  printf '%s\n' "$body" | grep -q 'blocks_next_stage' \
    || fail "the complete item does not name blocks_next_stage"
  printf '%s\n' "$body" | grep -qi 'both.*ledger.*artifact' \
    || fail "a raise is not bound to both transports"
}

@test "q8 artifact side: § Item shape requires a re-emitted stub to carry its answer forward" {
  local body
  body="$(awk '/^#### A re-emitted stub carries its answer forward/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: the carry-forward rule is absent from the canonical section"
  printf '%s\n' "$body" | grep -q 'status' || fail "carry-forward does not name status"
  printf '%s\n' "$body" | grep -q 'resolution' || fail "carry-forward does not name resolution"
  # The reason the artifact arm exists at all: it outlives ledger eviction.
  printf '%s\n' "$body" | grep -qi 'eviction' \
    || fail "the artifact arm's rationale (it survives ledger eviction) is unstated"
}

# --- q9 / sw-DR0-5: blocking items surface at their own boundary --------------

@test "q9: blocks_next_stage is a REQUIRED stub field (class stays the discriminator)" {
  # It was additive once. Absent and explicit `false` are different claims, and treating them
  # alike is what let one item's two transports disagree undetected, so the author states it.
  local defs
  defs="$(sweep_stub_defs "$(contract_source "$PLUGIN_ROOT/$HANDOFF")")"
  printf '%s\n' "$defs" | grep -q 'blocks_next_stage' || fail "the q9 carrier is absent from SweepStub"
  printf '%s\n' "$defs" | grep -q 'required: \[id, class, ref, blocks_next_stage\]' \
    || fail "blocks_next_stage is not in required[]: $defs"
  printf '%s\n' "$defs" | grep -q 'class:.*enum: \[decision, escalate\]' \
    || fail "class stopped being the render discriminator"
}

@test "q9: the canonical section no longer claims no stage boundary gains a round-trip" {
  local body
  body="$(awk '/^## Closing Elicitation Sweep/{f=1;next} /^## /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: canonical section not extracted"
  if printf '%s\n' "$body" | grep -q 'no stage boundary gains a round-trip'; then
    fail "the section still asserts a claim q9 made false"
  fi
  printf '%s\n' "$body" | grep -q 'No new gate is created' \
    || fail "the surviving half of the claim (no new gate) was dropped too"
}

@test "q9: both destinations are documented, selected per item rather than per stage" {
  local body
  body="$(awk '/^#### Where an item is answered/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")")"
  [ -n "$body" ] || fail "non-vacuity: § Where an item is answered is absent"
  printf '%s\n' "$body" | grep -q 'blocks_next_stage' || fail "the selector is not named"
  printf '%s\n' "$body" | grep -qi 'never by stage' || fail "per-item selection is not stated"
}

@test "q9: Step C.0 renders blocking items at their own boundary, with a per-boundary subject" {
  grep -q '^#### Step C.0 — blocking items, at their own boundary' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" \
    || fail "Step C.0 is absent"
  local body
  body="$(awk '/^#### Step C.0 — blocking/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  printf '%s\n' "$body" | grep -q 'subject:"<CODE><N>"' || fail "C.0 does not scope its audit subject to the boundary"
  printf '%s\n' "$body" | grep -qi 'no-op' || fail "the common (no blocking items) path is unstated"
  grep -q 'Step 6.6' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")" || fail "the loop has no step for the blocking render"
}

@test "q9: Step C.1's filter is status-based, and explicitly not stage-based" {
  local body
  body="$(awk '/^#### Step C.1 — collect/{f=1;next} f && /^#{2,4} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: Step C.1 not found"
  if printf '%s\n' "$body" | grep -q 'stage != "PL"'; then
    fail "the stage-name exclusion survived q9"
  fi
  printf '%s\n' "$body" | grep -qi 'regardless of originating stage' || fail "C.1 does not forbid a stage filter"
  # sw-DR0-2's id-derivation is retained for grouping rather than deleted silently.
  printf '%s\n' "$body" | grep -qi 'grouping' || fail "id-derivation's surviving purpose is unstated"
}

@test "q9: the obligation matrix Surfaced-by column is conditional, and AC-1 still passes" {
  grep -q 'Surfaced by (non-blocking / blocking)' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" \
    || fail "the Surfaced by column was not made conditional"
  # AC-1 reads the code column only, so it must be unaffected by the column rename.
  run check_matrix_completeness "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" "$PLUGIN_ROOT/$STAGE_CODES" "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
  assert_success
}

@test "q9: the raise-only guard covers the blocking axis by OR, and keeps the axes orthogonal" {
  # Asserted at the ONE surviving statement. The command file used to carry a second
  # copy; it now carries the procedural step and a pointer, so asserting there would
  # pin a restatement back into existence.
  local body
  body="$(section_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" '^#{2,5} Self-labels raise, never lower')"
  [ -n "$body" ] || fail "non-vacuity: the raise-only section is absent"
  printf '%s\n' "$body" | grep -q 'OR' || fail "the join is not stated as OR"
  printf '%s\n' "$body" | grep -qi 'never clear' || fail "raise-only is not stated for the blocking axis"
  printf '%s\n' "$body" | grep -qi 'orthogonal' || fail "orthogonality with class is unstated"

  # And the command file points at it rather than restating it.
  body="$(awk '/^##### Escalation guard — raise-only self-labels/{f=1;next} f && /^#{2,6} /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: the command-side procedural step is absent"
  printf '%s\n' "$body" | grep -q 'Self-labels raise, never lower' \
    || fail "the command file neither states the join nor points at where it is stated"
}

@test "q9: agent-coordination's checkpoint clause survives its third reconciliation" {
  local f body
  f="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
  body="$(awk '/^### Gate prompts \(AskUserQuestion\)/{f=1;next} f && /^#{2,4} /{f=0} f' "$f")"
  [ -n "$body" ] || fail "non-vacuity: the gate-prompts section is absent"
  if printf '%s\n' "$body" | grep -q 'the one such checkpoint'; then
    fail "the original wrong count came back"
  fi
  printf '%s\n' "$body" | grep -q 'blocks_next_stage' \
    || fail "the clause does not account for the boundary render q9 introduced"
  printf '%s\n' "$body" | grep -qi 'not a gate' \
    || fail "the boundary render is not distinguished from a gate"
}

@test "q9: the megatask park subject is per-boundary, not FN-scoped" {
  local f
  f="$PLUGIN_ROOT/skills/megatask/SKILL.md"
  if grep -q 'subject:"FN<N>". instead of' "$f"; then
    fail "the park path is still FN-scoped"
  fi
  grep -q 'CODE><N>' "$f" || fail "the park path names no per-boundary subject"
}

# --- P2-13 / P2-14 -----------------------------------------------------------

@test "P2-13: the \$defs injector is stated as an obligation, not attributed to a section that lacks it" {
  local note
  # Singular or plural: TestRunEntry made it more than one block to inline.
  note="$(grep -nE 'inline th(at|ose) .\$defs. blocks?' "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" || true)"
  [ -n "$note" ] || fail "non-vacuity: the \$defs obligation sentence is absent"
  # The previous text cited SKILL.md Step 6, which carries no such claim. Verify both:
  # the citation is gone, and the file it named still does not carry the claim.
  if grep -q 'Orchestrator Execution Loop. Step 6, so the item shape' "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"; then
    fail "the misattributed citation is still present"
  fi
  if grep -q 'SweepItem' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")"; then
    fail "SKILL.md now mentions SweepItem — re-check whether the citation should be restored"
  fi
  grep -q 'no shipped file implements that step today' "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    || fail "the unimplemented status is not stated"
}

@test "P2-14: a re-review section is an allowed anchor, like rework-<N>" {
  local d
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DR\n  verdict: pass\n  summary: "s"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n'
    printf '## findings\n\nx\n\n## verdict\n\npass\n\n## blockers\n\nnone\n\n## follow-ups\n\nx\n'
    printf '\n## elicitation-sweep\n\nnothing to elicit\n'
    printf '\n## re-review\n\nsecond pass\n'
  } > "$d/developer-review-0.md"
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/developer-review-0.md"
  assert_success
}

@test "P2-14 twin: the allowance is still scoped — an invented anchor is rejected" {
  local d
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DR\n  verdict: pass\n  summary: "s"\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n'
    printf '## findings\n\nx\n\n## verdict\n\npass\n\n## blockers\n\nnone\n\n## follow-ups\n\nx\n'
    printf '\n## elicitation-sweep\n\nnothing to elicit\n'
    printf '\n## re-re-review\n\nnope\n'
  } > "$d/developer-review-0.md"
  run env PATH="/usr/bin:/bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" \
    --anchor-lint "$d/developer-review-0.md"
  assert_failure
}

# --- review: the harness has a per-stage call site, and parity never skips ----

@test "review-1: the orchestrator invokes the harness at every stage completion, not only DV" {
  grep -q '^### Step B.1 — Sweep checks at every stage completion' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" \
    || fail "Step B.1 is absent"
  local body
  body="$(awk '/^### Step B.1 — Sweep/{f=1;next} f && /^### /{f=0} f' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  printf '%s\n' "$body" | grep -q 'handoff-harness.sh --validate-frontmatter' || fail "B.1 does not call the harness"
  printf '%s\n' "$body" | grep -q -- '--state' || fail "B.1 omits --state, so ledger parity never runs"
  printf '%s\n' "$body" | grep -q 'sweep_check' || fail "B.1 records no audit row"
  grep -q 'Step 6.5c' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")" || fail "the loop has no step for the per-stage harness call"
  local b1 c0
  b1=$(grep -n '^### Step B.1' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" | head -1 | cut -d: -f1)
  c0=$(grep -n '^#### Step C.0' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" | head -1 | cut -d: -f1)
  [ "$b1" -lt "$c0" ] || fail "the harness call is documented after the render it guards"
}

@test "review-2: ledger parity fails, not skips, when --state is unreadable and a stub exists" {
  local d
  d="$(mk_tmpworkdir)"
  sweep_fixture "$d" "documentation-0.md#elicitation-sweep"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md" --state "$d/nope.json"
  assert_failure
  assert_output --partial "cannot be verified"
  printf 'not json {{' > "$d/corrupt.json"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md" --state "$d/corrupt.json"
  assert_failure
  assert_output --partial "cannot be verified"
}

@test "review-2 twin: an empty sweep + unreadable --state on a non-DV stage still passes" {
  local d
  d="$(mk_tmpworkdir)"
  {
    printf -- '---\nhandoff:\n  stage: DC\n  verdict: ok\n  summary: "empty sweep"\n'
    printf '  files_touched: [a.md]\n  open_questions: []\n'
    printf '  refs: { dev: development-0.md#files-changed }\n---\n\n# Documentation\n'
    # The prose half of an empty sweep: the array says nothing was asked, the heading says a
    # sweep ran. Both are required — this fixture is exercising the LEDGER-parity arm, which
    # must stay silent when there are no stubs, and it needs a compliant artifact to do so.
    printf '\n## files-changed\n\nx\n\n## cross-references\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\nNothing to elicit.\n'
  } > "$d/documentation-0.md"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$d/documentation-0.md" --state "$d/nope.json"
  assert_success
}

# --- PL speaks the sweep contract ---------------------------------------------

FIGMA="skills/shared/figma-capture.md"
FIGMA_FIXTURE="skills/worktask/references/fixtures/figma-capture/03-auth-failure.md"
RESUME="skills/worktask/references/resume.md"

# The two live PL-side producers plus the PL procedure. A legacy id in any of them
# re-introduces a shape the harness and --facts now reject by name.
PL_PRODUCERS="$FIGMA $FIGMA_FIXTURE $PL0_PROC"

check_no_legacy_pl_ids() {  # <repo-root> <files...>
  local root="$1"; shift
  local f n=0 rc=0
  for f in "$@"; do
    [ -f "$(contract_source "$root/$f")" ] || { echo "non-vacuity: $f is absent"; return 1; }
    n=$((n + 1))
    if grep -qE '(^|[^a-z-])q[0-9]+:|"id" *: *"q[0-9]+"|id: q[0-9]+' "$(contract_source "$root/$f")"; then
      echo "$f still writes a legacy q<N> open-question id"
      rc=1
    fi
    grep -q 'sw-PL' "$(contract_source "$root/$f")" || { echo "$f names no sw-PL<N>-<n> id at all"; rc=1; }
  done
  [ "$n" -ge 3 ] || { echo "non-vacuity: only $n PL producers checked"; return 1; }
  return $rc
}

@test "PL-1: no PL-side producer writes a legacy q<N> open-question id" {
  run check_no_legacy_pl_ids "$PLUGIN_ROOT" $PL_PRODUCERS
  assert_success
}

@test "PL-1 twin: a producer that reverts to q1: fails" {
  local d f
  d="$(mk_tmpworkdir)"
  for f in $PL_PRODUCERS; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$(contract_source "$PLUGIN_ROOT/$f")" "$d/$f"
  done
  printf '\nAppend `q1: Figma MCP auth pending` to `facts.open_questions[]`.\n' >> "$d/$FIGMA"
  run check_no_legacy_pl_ids "$d" $PL_PRODUCERS
  assert_failure
  assert_output --partial "legacy q<N>"
}

# One resolution idiom across all thirteen stages: an answered item is MARKED resolved,
# never deleted. Deleting it takes its ref anchor and its recorded answer with it, so a
# resumed run can neither re-render the question nor show what was decided.
AUTO_DECISION="skills/worktask/references/auto-decision.md"
SWEEP_RECORDING="skills/worktask/references/closing-sweep-step-c3c4--auto-answer-then-render.md"
PL_RESOLVERS="$AUTO_DECISION $SWEEP_RECORDING"

check_resolved_not_dropped() {  # <repo-root> <files...>
  local root="$1"; shift
  local f n=0 rc=0
  for f in "$@"; do
    [ -f "$(contract_source "$root/$f")" ] || { echo "non-vacuity: $f is absent"; return 1; }
    n=$((n + 1))
    if [ "$f" = "$AUTO_DECISION" ]; then
      grep -qF "$(basename "$SWEEP_RECORDING")#step-c5--record-and-the-unattended-lanes" "$(contract_source "$root/$f")" \
        || { echo "$f does not route to the canonical resolution procedure"; rc=1; }
    else
      grep -q 'status: "resolved"' "$(contract_source "$root/$f")" \
        || { echo "$f never states the mark-resolved idiom"; rc=1; }
    fi
    if grep -qE '(remove|removes|removing|drop|drops|dropped|dropping) the resolved|resolved entries (from|dropped)' "$(contract_source "$root/$f")"; then
      echo "$f still describes deleting answered open_questions entries"
      rc=1
    fi
  done
  [ "$n" -ge 1 ] || { echo "non-vacuity: only $n resolver files checked"; return 1; }
  return $rc
}

@test "PL-2: every PL-side resolver marks answered items resolved and none deletes them" {
  run check_resolved_not_dropped "$PLUGIN_ROOT" $PL_RESOLVERS
  assert_success
}

@test "PL-2 twin: a file that reverts to deleting answered entries fails" {
  local d f
  d="$(mk_tmpworkdir)"
  for f in $PL_RESOLVERS; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$(contract_source "$PLUGIN_ROOT/$f")" "$d/$f"
  done
  printf '\nThe orchestrator then drops the resolved entries from `facts.open_questions[]`.\n' \
    >> "$d/$AUTO_DECISION"
  run check_resolved_not_dropped "$d" $PL_RESOLVERS
  assert_failure
  assert_output --partial "deleting answered"
}

step_a4_body() {  # <worktask-cmd>
  awk '/^### Step A.4 — Auto-Decision Pre-Pass/{f=1;next} f && /^### /{f=0} f' "$1"
}

@test "PL-3: Step A.4 reads the sweep anchor the way Step C.4 does" {
  local body
  body="$(step_a4_body "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
  [ -n "$body" ] || fail "non-vacuity: Step A.4 body not extracted"
  printf '%s\n' "$body" | grep -q '#elicitation-sweep' \
    || fail "A.4 does not resolve the question text from the sweep anchor"
  printf '%s\n' "$body" | grep -q 'Step C.4' \
    || fail "A.4 does not reuse the C.4 resolution rule"
  printf '%s\n' "$body" | grep -q 'sw-PL' || fail "A.4 does not key on sw-PL<N>-* ids"
  # `grep && fail` cannot express "must not match": grep's own exit 1 is the last
  # status and fails the arm on a correct document. `if` returns 0 when the
  # condition is false, so the absent-match case passes.
  if printf '%s\n' "$body" | grep -qi 'numbered'; then
    fail "A.4 still describes a numbered elicitation list"
  fi
}

@test "PL-3 twin: restoring the numbered-list wording fails" {
  local planted body
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" \
    's|unresolved `sw-PL<N>-\*` items|unresolved items (the numbered elicitation list)|')"
  body="$(step_a4_body "$planted")"
  printf '%s\n' "$body" | grep -qi 'numbered' \
    || fail "the planted wording was not observable through the extraction helper"
}

@test "PL-4: Signal 2b and the resume row key on status, not on a non-empty array" {
  local body
  body="$(awk '/^##### Signal 2b \(decision gate\)/{f=1;next} f && /^#{2,5} /{f=0} f' \
        "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")")"
  [ -n "$body" ] || fail "non-vacuity: Signal 2b body not extracted"
  printf '%s\n' "$body" | grep -q 'status != "resolved"' \
    || fail "Signal 2b does not key on status != resolved"
  grep -q 'status != "resolved"' "$(contract_source "$PLUGIN_ROOT/$RESUME")" \
    || fail "the resume auto-decision row does not key on status != resolved"
}

@test "PL-4 twin: keying Signal 2b back on a non-empty array is observable" {
  local planted body
  planted="$(plant "$(contract_source "$PLUGIN_ROOT/$WORKTASK_SKILL")" \
    's|`status != "resolved"`|a non-empty `open_questions[]`|')"
  body="$(awk '/^##### Signal 2b \(decision gate\)/{f=1;next} f && /^#{2,5} /{f=0} f' "$planted")"
  if printf '%s\n' "$body" | grep -q 'status != "resolved"'; then
    fail "the planted regression was not observable through the extraction helper"
  fi
  printf '%s\n' "$body" | grep -q 'non-empty' \
    || fail "non-vacuity: the plant did not land in the extracted body"
}

# --- Step C.0a resolver contract ---------------------------------------------
#
# The resolver answers a blocking `decision` item with a sub-agent one effort tier up instead
# of stopping the run. Its three load-bearing properties are all cross-file, so each assertion
# extracts both sides rather than restating either.

HEADLESS="skills/agent-coordination/references/headless-dispatch.md"
LADDER="skills/worktask/scripts/effort-ladder.sh"

# The resolver contract spans two sections, and must: AC-15 forbids advisory vocabulary
# anywhere under § Closing Elicitation Sweep, while the effort caveat below is legitimately
# advisory, so the tier material cannot live nested inside the sweep. Both halves are required
# — a silent half-extraction would let either section be renamed with the assertions still green.
resolver_body() {
  local policy tier
  policy=$(awk '/^#### Blocking items are resolved, not asked/{f=1;next} /^#### /{f=0} f' "$1")
  tier=$(awk '/^## Resolver Effort Tier/{f=1;next} /^## /{f=0} f' "$1")
  [ -n "$policy" ] || { echo "non-vacuity: § Blocking items are resolved, not asked not extracted"; return 1; }
  [ -n "$tier" ] || { echo "non-vacuity: § Resolver Effort Tier not extracted"; return 1; }
  printf '%s\n%s\n' "$policy" "$tier"
}

@test "the resolver contract exists and is canonical in stage-contracts.md" {
  run resolver_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_success
  [ -n "$output" ]
}

@test "the resolver exempts exactly the four stages the obligation matrix exempts" {
  # Derived on both sides: a fifth exception added to one file alone must fail here.
  matrix_exceptions=$(grep -o 'Exceptions — PL, FN, ST, IR' "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")" | head -1)
  [ -n "$matrix_exceptions" ]
  run resolver_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_output --partial "PL, FN, ST or IR"
}

@test "every non-exception stage code is resolver-eligible in the command" {
  # The nine are derived from the canonical vocabulary minus the four exceptions, never listed.
  expected=$(left_codes "$PLUGIN_ROOT/$STAGE_CODES" "$(contract_source "$PLUGIN_ROOT/$HANDOFF")" \
    | grep -vxE 'PL|FN|ST|IR' | tr '\n' ' ')
  [ -n "$expected" ]
  scope=$(grep 'blocking `decision` item from' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")
  [ -n "$scope" ] || fail "the --auto=[decision] resolver scope line is gone"
  for code in $expected; do
    grep -q "\b$code\b" <<< "$scope" \
      || fail "stage $code missing from the --auto=[decision] resolver scope line"
  done
}

@test "Step C.0a is ordered before Step C.0 in the command" {
  # C.0a must have had its pass before C.0 renders, or C.0 asks about items a resolver owns.
  a=$(grep -n '^#### Step C.0a' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" | cut -d: -f1)
  b=$(grep -n '^#### Step C.0 — blocking items' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ]
  [ "$a" -lt "$b" ]
}

@test "the escalate carve-out is stated in both the contract and the command" {
  run resolver_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_output --partial 'effective_class == "decision"'
  grep -q 'must never' <<< "$(sed -n '/^#### Step C.0a/,/^#### Step C.0 —/p' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")"
}

@test "the resolver runs strictly after the C.2 raise-only join" {
  # Ordering is the whole guard: joined before dispatch, an item raised to escalate cannot
  # reach a delegate. Reversed, the raise happens too late to exclude anything.
  run bash -c "sed -n '/^#### Step C.0a/,/^#### Step C.0 —/p' '$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")'"
  assert_success
  assert_output --partial "**after** the § Step C.2"
  assert_output --partial "Run C.2 first"
}

@test "the contract cites the executable ladder rather than restating the rungs" {
  run resolver_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_output --partial "effort-ladder.sh"
  [ -f "$PLUGIN_ROOT/$LADDER" ]
}

@test "the in-process effort claim matches what headless-dispatch.md actually says" {
  # The contract claims the Agent tool carries effort in-process; that claim is only
  # safe while the translation table says so too. If the table falls back to Advisory, this
  # fires and the contract's claim becomes wrong rather than merely stale.
  grep -qE '^\| `effort` \|.*\| \*\*Yes\*\* \(`Agent` `effort`' "$PLUGIN_ROOT/$HEADLESS"
  run resolver_body "$(contract_source "$PLUGIN_ROOT/$CONTRACTS")"
  assert_output --partial "\`effort\` parameter"
  refute_output --partial "takes no effort parameter"
}

@test "the resolver records effort_transport on every path" {
  run bash -c "sed -n '/^#### Step C.0a/,/^#### Step C.0 —/p' '$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")'"
  assert_output --partial "effort_transport"
  assert_output --partial '`agent-param`'
  assert_output --partial "dispatch-flag"
  assert_output --partial '`none`'
}

@test "an unstamped effort skips the resolver instead of defaulting a tier" {
  run bash -c "sed -n '/^#### Step C.0a/,/^#### Step C.0 —/p' '$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")'"
  assert_output --partial "effort_unstamped"
  refute_output --partial "default to"
}

@test "metadata.effort is mandatory in the PL0 stamp table, not optional" {
  grep -q '`metadata.effort`' "$(contract_source "$PLUGIN_ROOT/$PL0_PROC")"
  # The checklist is the half that actually gets read during a run.
  grep -q 'metadata.effort' <<< "$(grep 'Stage tasks created with' "$(contract_source "$PLUGIN_ROOT/$PL0_PROC")")"
}

@test "the deep_reads resolver exemption is stated where deep_reads is defined" {
  grep -q 'deep_reads — the resolver exemption' "$(contract_source "$PLUGIN_ROOT/$HANDOFF")"
}

AUDIT_FIXTURE="tests/fixtures/worktask/audit.resolver-effort.jsonl"

@test "the resolver-effort fixture has one row per transport, pairing with C.0a's prose" {
  local none_resolved dispatch_resolved frontmatter_resolved agent_param_resolved c0a
  none_resolved=$(jq -r 'select(.metadata.effort_transport == "none") | .metadata.effort_resolved' \
    "$PLUGIN_ROOT/$AUDIT_FIXTURE")
  dispatch_resolved=$(jq -r 'select(.metadata.effort_transport == "dispatch-flag") | .metadata.effort_resolved' \
    "$PLUGIN_ROOT/$AUDIT_FIXTURE")
  frontmatter_resolved=$(jq -r 'select(.metadata.effort_transport == "frontmatter") | .metadata.effort_resolved' \
    "$PLUGIN_ROOT/$AUDIT_FIXTURE")
  agent_param_resolved=$(jq -r 'select(.metadata.effort_transport == "agent-param") | .metadata.effort_resolved' \
    "$PLUGIN_ROOT/$AUDIT_FIXTURE")
  [ "$none_resolved" = "requested, not applied" ]
  [[ "$agent_param_resolved" =~ ^(low|medium|high|xhigh|max)$ ]]
  [[ "$dispatch_resolved" =~ ^(low|medium|high|xhigh|max)$ ]]
  [[ "$frontmatter_resolved" =~ ^(low|medium|high|xhigh|max)$ ]]

  # Every literal above must be the one C.0a documents, not a fixture-only string.
  c0a=$(sed -n '/^#### Step C.0a/,/^#### Step C.0 —/p' "$(contract_source "$PLUGIN_ROOT/$WORKTASK_CMD")")
  grep -qF "$none_resolved" <<< "$c0a"
  grep -qF '`dispatch-flag`' <<< "$c0a"
  grep -qF '`agent-param`' <<< "$c0a"
  # A bare `frontmatter` substring passes on almost any prose (it also occurs inside
  # "frontmatter tier", "agent's own frontmatter", etc.) — require the backtick-quoted
  # table-cell form the other two transports are also checked against.
  grep -qF '`frontmatter`' <<< "$c0a"
  grep -qF '`none`' <<< "$c0a"
}
