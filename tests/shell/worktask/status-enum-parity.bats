#!/usr/bin/env bats
# The task-status enum is written out longhand in four places — prose table, the writer's
# validating `case`, the JSON Schema, and the orchestrator's settled set. Nothing tied them
# together, so `failed` could land in three of the four and the fourth would silently reject
# or spin on it. Every extraction carries a count floor: a parity test that stops matching
# anything passes vacuously, which is the defect it exists to prevent.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LEDGER_DOC="skills/worktask/references/state-ledger.md"
WRITER="skills/worktask/scripts/state-patch.sh"
SCHEMA_DOC="skills/worktask/references/handoff-protocol.md"
LOOP_DOC="skills/worktask/references/orchestration.md"

# --- extractors: one per surface, each returning a sorted newline-separated value list ----

# Rows of the `## Status Values` table, first cell only, backticks stripped.
enum_from_prose() {
  awk '/^## Status Values$/ { inside = 1; next }
       inside && /^## / { exit }
       inside && /^\| `/ { gsub(/^\| `/, ""); sub(/` \|.*$/, ""); print }' \
    "$(contract_source "$PLUGIN_ROOT/$LEDGER_DOC")" | sort
}

# The single `case` arm that closes the set on the write path (the sole decode).
enum_from_writer() {
  grep -E '^[[:space:]]+pending \| in_progress \|.*\) ;;$' "$PLUGIN_ROOT/$WRITER" \
    | tr '|' '\n' | sed 's/[^a-z_]//g' | grep -v '^$' | sort
}

# Three `status:` enums live in this schema; only the task-ledger one starts at `pending`.
enum_from_schema() {
  grep -E 'status: \{ type: string, enum: \[pending' "$(contract_source "$PLUGIN_ROOT/$SCHEMA_DOC")" \
    | sed 's/.*enum: \[//; s/\].*//' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort
}

settled_from_loop() {
  grep -E '^const SETTLED = new Set\(\[' "$(contract_source "$PLUGIN_ROOT/$LOOP_DOC")" \
    | sed 's/.*Set(\[//; s/\]).*//' | tr ',' '\n' | tr -d ' "' | grep -v '^$' | sort
}

# Statuses the prose table calls terminal — the set the loop must settle on.
terminal_from_prose() {
  awk '/^## Status Values$/ { inside = 1; next }
       inside && /^## / { exit }
       inside && /^\| `/ && tolower($0) ~ /terminal/ { gsub(/^\| `/, ""); sub(/` \|.*$/, ""); print }' \
    "$(contract_source "$PLUGIN_ROOT/$LEDGER_DOC")" | sort
}

# The loop's JS mirror of the verdict map, one `verdict:status` line per entry. Quotes are
# stripped so the quoted "no-go" key compares like the bare ones.
verdict_map_from_loop() {
  awk '/^const VERDICT_STATUS = \{/ { inside = 1; next }
       inside && /^\};/ { exit }
       inside { print }' "$(contract_source "$PLUGIN_ROOT/$LOOP_DOC")" \
    | tr ',' '\n' | tr -d ' "' | grep -v '^$' | sort
}

# Runs the writer's own verdict_status over every verdict its case arms name, so the diff
# exercises the function rather than a second hand-copied table.
verdict_map_from_writer() {
  local fn v
  fn="$(awk '/^verdict_status\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' \
    "$PLUGIN_ROOT/$WRITER")"
  for v in $(printf '%s\n' "$fn" | grep -E '^[[:space:]]+[a-z| -]+\) printf' \
    | sed 's/).*//' | tr '|' '\n' | tr -d ' '); do
    printf '%s:%s\n' "$v" "$(bash -c "$fn"$'\n''verdict_status "$1"' _ "$v")"
  done | sort
}

@test "the loop's VERDICT_STATUS mirrors state-patch.sh verdict_status for every verdict" {
  local loop writer n fn
  loop="$(verdict_map_from_loop)"
  writer="$(verdict_map_from_writer)"
  n="$(printf '%s\n' "$loop" | grep -c .)"
  [ "$n" -ge 9 ] || fail "non-vacuity: only $n verdicts extracted from VERDICT_STATUS in $LOOP_DOC"
  n="$(printf '%s\n' "$writer" | grep -c .)"
  [ "$n" -ge 9 ] || fail "non-vacuity: only $n verdicts extracted from verdict_status in $WRITER"
  diff <(printf '%s\n' "$loop") <(printf '%s\n' "$writer")
  # An unmapped verdict must print nothing: the writer refuses it, so the mirror cannot default it.
  fn="$(awk '/^verdict_status\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' \
    "$PLUGIN_ROOT/$WRITER")"
  run bash -c "$fn"$'\n''verdict_status conditional'
  assert_success
  assert_output ""
}

@test "R1c: the prose table and the writer's validating case name the same statuses" {
  local prose writer n
  prose="$(enum_from_prose)"
  writer="$(enum_from_writer)"
  n="$(printf '%s\n' "$prose" | grep -c .)"
  [ "$n" -ge 6 ] || fail "non-vacuity: only $n statuses extracted from $LEDGER_DOC"
  n="$(printf '%s\n' "$writer" | grep -c .)"
  [ "$n" -ge 6 ] || fail "non-vacuity: only $n statuses extracted from $WRITER"
  diff <(printf '%s\n' "$prose") <(printf '%s\n' "$writer")
}

@test "R1c: the JSON Schema enum names the same statuses as the prose table" {
  local prose schema n
  prose="$(enum_from_prose)"
  schema="$(enum_from_schema)"
  n="$(grep -cE 'status: \{ type: string, enum: \[pending' "$(contract_source "$PLUGIN_ROOT/$SCHEMA_DOC")")"
  [ "$n" -eq 1 ] || fail "expected exactly 1 task-status schema enum, found $n"
  n="$(printf '%s\n' "$schema" | grep -c .)"
  [ "$n" -ge 6 ] || fail "non-vacuity: only $n statuses extracted from $SCHEMA_DOC"
  diff <(printf '%s\n' "$prose") <(printf '%s\n' "$schema")
}

@test "R1b: SETTLED is a subset of the enum and covers every terminal status" {
  local settled prose terminal n missing
  settled="$(settled_from_loop)"
  prose="$(enum_from_prose)"
  terminal="$(terminal_from_prose)"
  n="$(printf '%s\n' "$settled" | grep -c .)"
  # Floor 2, not 3: the pre-change set had two members, so a floor of 3 would report a
  # missing terminal status as a vacuous extraction and hide which assertion really broke.
  [ "$n" -ge 2 ] || fail "non-vacuity: only $n values extracted from the SETTLED set"
  n="$(printf '%s\n' "$terminal" | grep -c .)"
  [ "$n" -ge 2 ] || fail "non-vacuity: only $n terminal statuses extracted from $LEDGER_DOC"
  # Subset: a settled value the enum does not model can never be observed.
  missing="$(comm -23 <(printf '%s\n' "$settled") <(printf '%s\n' "$prose"))"
  [ -z "$missing" ] || fail "SETTLED names statuses absent from the enum: $missing"
  # Cover: a terminal status outside SETTLED spins the loop with an empty ready set.
  missing="$(comm -23 <(printf '%s\n' "$terminal") <(printf '%s\n' "$settled"))"
  [ -z "$missing" ] || fail "terminal statuses missing from SETTLED: $missing"
  printf '%s\n' "$settled" | grep -qx completed || fail "SETTLED lost 'completed'"
}

@test "R1a: 'failed' is present in all four copies of the enum" {
  local checked=0 src
  for src in "$(enum_from_prose)" "$(enum_from_writer)" "$(enum_from_schema)" "$(settled_from_loop)"; do
    printf '%s\n' "$src" | grep -qx failed || fail "copy $((checked + 1)) does not name 'failed'"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 4 ] || fail "non-vacuity: only $checked copies checked"
}

@test "exactly one status-validating case exists in the writer" {
  # A second closed set would be a read-side gate, turning the additive change breaking.
  local n
  n="$(grep -cE '^[[:space:]]+pending \| in_progress \|.*\) ;;$' "$PLUGIN_ROOT/$WRITER")"
  [ "$n" -eq 1 ] || fail "expected exactly 1 status-validating case in $WRITER, found $n"
}

@test "back-compat: the new writer loads a real pre-change ledger and loses no field" {
  local wd
  wd="$(mk_tmpworkdir)"
  mkdir -p "$wd/.context"
  cp "$FIXTURES/worktask/state.pre-failed-enum.json" "$wd/.context/state.json"
  cd "$wd"
  export WORKSPACE_ROOT="$wd"
  run bash "$PLUGIN_ROOT/$WRITER" --task-status PL0 completed
  assert_success
  # Field-for-field over every scalar path: nothing the writer does not model may be dropped.
  local lost
  jq -r 'paths(scalars) | map(tostring) | join(".")' \
    "$FIXTURES/worktask/state.pre-failed-enum.json" | sort > "$wd/before.paths"
  jq -r 'paths(scalars) | map(tostring) | join(".")' .context/state.json | sort > "$wd/after.paths"
  [ "$(grep -c . "$wd/before.paths")" -ge 20 ] \
    || fail "non-vacuity: the pre-change fixture yielded too few scalar paths"
  lost="$(comm -23 "$wd/before.paths" "$wd/after.paths")"
  [ -z "$lost" ] || fail "pre-change fields lost by the new writer: $lost"
  run jq -r '.tasks.PL0.status' .context/state.json
  assert_output completed
}

@test "back-compat: the new writer accepts 'failed' and round-trips a pre-change ledger" {
  local wd
  wd="$(mk_tmpworkdir)"
  mkdir -p "$wd/.context"
  cp "$FIXTURES/worktask/state.pre-failed-enum.json" "$wd/.context/state.json"
  cd "$wd"
  export WORKSPACE_ROOT="$wd"
  run bash "$PLUGIN_ROOT/$WRITER" --task-status PL0 failed
  assert_success
  run jq -r '.tasks.PL0.status' .context/state.json
  assert_output failed
  # Still a closed set: an unmodelled value is refused, not written.
  run bash "$PLUGIN_ROOT/$WRITER" --task-status PL0 exploded
  assert_failure
  run jq -r '.tasks.PL0.status' .context/state.json
  assert_output failed
}

@test "R1d: one retry ceiling — the matrix, the prose and the escalation trigger agree on 3" {
  local coord="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
  local loop="$(contract_source "$PLUGIN_ROOT/$LOOP_DOC")" checked=0 row
  # Every retrying class in the matrix; a class capped below the trigger parks unescalated.
  while IFS= read -r row; do
    case "$row" in
      *'| 3'* | *'| No |'*) ;;
      *) fail "retry ceiling diverges from 3 in the matrix row: $row" ;;
    esac
    checked=$((checked + 1))
  done < <(awk '/^### Retry \/ Escalate Matrix$/ { inside = 1; next }
                inside && /^#/ { exit }
                inside && /^\| `/ { print }' "$coord")
  [ "$checked" -ge 7 ] || fail "non-vacuity: only $checked matrix rows read"
  grep -q 'retry_count == 3' "$loop" || fail "escalation trigger is no longer == 3"
  grep -q 'max 3 retries' "$loop" || fail "the orchestration prose ceiling is no longer 3"
  grep -q '`exhausted` | `retry_count == 3`' "$coord" || fail "exhausted trigger is no longer == 3"
}

@test "R1e: the escalation handoff resets retry_count alone and never escalation_counts" {
  local checked=0 f
  for f in skills/agent-coordination/SKILL.md agents/workflow-engineer.md; do
    grep -q 'escalation_counts' "$(contract_source "$PLUGIN_ROOT/$f")" \
      || fail "$f does not mention escalation_counts"
    grep -qi 'retry_count` alone\|retry_count\*\* alone\|`retry_count` alone' "$(contract_source "$PLUGIN_ROOT/$f")" \
      || grep -q 'retry_count\*\* alone' "$(contract_source "$PLUGIN_ROOT/$f")" \
      || fail "$f does not narrow the reset to retry_count alone"
    grep -qi 'NOT reset\|not reset' "$(contract_source "$PLUGIN_ROOT/$f")" \
      || fail "$f does not state that escalation_counts is NOT reset"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 2 ] || fail "non-vacuity: only $checked reset surfaces checked"
  grep -q '"escalation_counts"' "$(contract_source "$PLUGIN_ROOT/$LEDGER_DOC")" \
    || fail "escalation_counts has no schema entry in $LEDGER_DOC"
}

@test "R1f: routeToRetryMatrix is absent from the shipped tree" {
  local hits
  hits="$(grep -rln 'routeToRetryMatrix' "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents" \
    "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/hooks" 2>/dev/null || true)"
  [ -z "$hits" ] || fail "routeToRetryMatrix is still referenced in: $hits"
}

@test "R1e: ESCALATE_TO mirrors the Escalate-to column of the matrix" {
  # The map is data in the orchestration doc; the matrix is the SSOT. Without this diff the
  # two are a second source for the routing decision — the same failure mode, one layer over.
  local coord="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
  local map expected checked=0 cls col
  map="$(awk '/^const ESCALATE_TO = \{/ { inside = 1; next }
              inside && /^\};/ { exit }
              inside { print }' "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/return-arms.md")" \
    | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort)"
  [ "$(printf '%s\n' "$map" | grep -c .)" -ge 4 ] \
    || fail "non-vacuity: ESCALATE_TO extracted fewer than 4 entries"
  while IFS='|' read -r _ cls _ _ col _; do
    cls="$(printf '%s' "$cls" | tr -d ' `')"
    col="$(printf '%s' "$col" | sed 's/^ *//; s/ *$//')"
    checked=$((checked + 1))
    case "$col" in
      '— (same agent)'|*abort*) expected="" ;;
      'previous stage per chain') expected='"PREV"' ;;
      PL) expected='"PL"' ;;
      AR) expected='"AR"' ;;
      *) fail "unrecognised Escalate-to value for $cls: $col" ;;
    esac
    if [ -z "$expected" ]; then
      printf '%s\n' "$map" | grep -q "^${cls}:" \
        && fail "$cls escalates to nothing in the matrix but appears in ESCALATE_TO"
    else
      printf '%s\n' "$map" | grep -qx "${cls}: ${expected}" \
        || fail "ESCALATE_TO disagrees with the matrix for $cls (expected $expected)"
    fi
  done < <(awk '/^### Retry \/ Escalate Matrix$/ { inside = 1; next }
                inside && /^#/ { exit }
                inside && /^\| `/ { print }' "$coord")
  [ "$checked" -ge 7 ] || fail "non-vacuity: only $checked matrix rows compared"
}
