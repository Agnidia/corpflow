#!/usr/bin/env bats
# Contract test for QA's native UI legs: the `### Native UI Legs` record in
# testing-N.md, the tool-call budget line, and the completion-checklist item in
# agents/qa-engineer.md.
#
# The record is prose an agent writes, so nothing else checks it. The row rules
# are the point: a `not_delegated` leg with no reason reads as silently skipped,
# and a `delegated` leg with a reason reads as both. Enum values are EXTRACTED
# from the agent's record template and alias targets from the routing matrix,
# never restated here; a copy in the test is the drift the test exists to catch.
#
# Bash 3.2 portable: no associative arrays, no mapfile.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

QA_AGENT="agents/qa-engineer.md"
MATRIX="skills/shared/routing-matrix.md"
CACHE_LINT="skills/worktask/scripts/cache-lint.sh"
POSITIVE="tests/fixtures/skills/qa-native-ui-legs/testing-0.md"
NEGATIVE="tests/fixtures/skills/qa-native-ui-legs/testing-bad-reason.md"

RECORD_HEADER="| Leg | Platform | Kind | Alias | Routed to | Status | Reason | Evidence | Verdict |"
NONE_MARK="—"

# Unit separator, not tab: a tab IFS collapses empty cells, which would shift
# every later column and hide exactly the empty `Routed to` this suite rejects.
SEP=$'\037'

# "alias target" pairs from every matrix table row; same parse as routing-matrix.bats.
matrix_target() {
  # Backticks are literal markdown code spans, not command substitution.
  # shellcheck disable=SC2016
  grep -E '^\| `corpflow:' "$PLUGIN_ROOT/$MATRIX" \
    | sed -E 's/^\| `(corpflow:[a-z0-9-]+)` \| `([a-z0-9-]+:[a-z0-9-]+)`.*/\1 \2/' \
    | awk -v a="corpflow:$1" '$1 == a {print $2}'
}

# Allowed values of one record column (1-based), one per line, read from the
# `| UI-<n> | …` template row. Inside that row `\|` separates alternatives.
template_enum() {
  grep -E '^\| UI-<n> \|' "$PLUGIN_ROOT/$QA_AGENT" | head -1 \
    | sed 's/\\|/@@/g' \
    | awk -F'|' -v c="$(($1 + 1))" '{
        n = split($c, v, "@@")
        for (i = 1; i <= n; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v[i]); gsub(/`/, "", v[i]); print v[i]
        }
      }'
}

# Data rows of the `### Native UI Legs` table, cells trimmed and backticks
# stripped, joined by $SEP. The section ends at the next heading of any level.
leg_rows() {
  awk -v sep="$SEP" '
    /^### Native UI Legs[[:space:]]*$/ { on = 1; next }
    on && /^#/ { exit }
    on && /^\|/ {
      if ($0 ~ /^\| *Leg *\|/ || $0 ~ /^\|[-| ]+\|$/) next
      line = $0; sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n = split(line, c, "|"); out = ""
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", c[i]); gsub(/`/, "", c[i])
        out = out (i > 1 ? sep : "") c[i]
      }
      print n sep out
    }' "$1"
}

# 0 when $1 is one of the newline-separated values in $2.
in_set() {
  printf '%s\n' "$2" | grep -qxF -- "$1"
}

# Validate every native UI leg row of one testing artifact against the record
# rules in agents/qa-engineer.md § Record. Prints one line per violation, each
# naming its row, and fails if any row is bad or the table has no rows.
validate_leg_rows() {
  local file="$1" rows platforms kinds aliases statuses reasons verdicts
  local n leg platform kind alias routed status reason evidence verdict family enum bad=0
  rows="$(leg_rows "$file")"
  [ -n "$rows" ] || { echo "$file: no ### Native UI Legs rows"; return 1; }
  platforms="$(template_enum 2)"
  kinds="$(template_enum 3)"
  aliases="$(template_enum 4)"
  statuses="$(template_enum 6)"
  reasons="$(template_enum 7 | grep -vxF -- "$NONE_MARK")"
  verdicts="$(template_enum 9 | grep -vxF -- "$NONE_MARK")"
  # An empty enum means the template parse regressed, which would pass every row.
  for enum in "$platforms" "$kinds" "$aliases" "$statuses" "$reasons" "$verdicts"; do
    [ -n "$enum" ] || { echo "record template enum parse returned nothing"; return 1; }
  done

  while IFS="$SEP" read -r n leg platform kind alias routed status reason evidence verdict; do
    [ "$n" = 9 ] || { echo "row ${leg:-?}: expected 9 cells, found $n"; bad=1; continue; }
    [[ "$leg" =~ ^UI-[0-9]+$ ]] || { echo "row $leg: leg id is not UI-<n>"; bad=1; }
    in_set "$platform" "$platforms" || { echo "row $leg: unknown Platform '$platform'"; bad=1; }
    in_set "$kind" "$kinds" || { echo "row $leg: unknown Kind '$kind'"; bad=1; }
    in_set "$alias" "$aliases" || { echo "row $leg: unknown Alias '$alias'"; bad=1; }
    family=apple
    [ "$platform" = android ] && family=android
    [ "$alias" = "corpflow:${family}-ui-verifier" ] \
      || { echo "row $leg: Alias '$alias' is not the $family family for Platform '$platform'"; bad=1; }
    [[ "$routed" =~ ^[a-z0-9-]+:[a-z0-9-]+$ ]] \
      || { echo "row $leg: Routed to must name plugin:agent on every row, got '$routed'"; bad=1; }
    in_set "$status" "$statuses" || { echo "row $leg: unknown Status '$status'"; bad=1; }
    case "$status" in
      delegated)
        [ "$reason" = "$NONE_MARK" ] \
          || { echo "row $leg: delegated must have Reason '$NONE_MARK', got '$reason'"; bad=1; }
        in_set "$verdict" "$verdicts" \
          || { echo "row $leg: delegated needs a Verdict from the template, got '$verdict'"; bad=1; }
        # A pass or fail is read from evidence; with none returned only no_evidence is honest.
        if [ "$evidence" = "$NONE_MARK" ] && [ "$verdict" != no_evidence ]; then
          echo "row $leg: delegated with no Evidence must have Verdict no_evidence, got '$verdict'"
          bad=1
        fi
        ;;
      not_delegated)
        in_set "$reason" "$reasons" \
          || { echo "row $leg: not_delegated needs a Reason enum value, got '$reason'"; bad=1; }
        [ "$evidence" = "$NONE_MARK" ] \
          || { echo "row $leg: not_delegated must have Evidence '$NONE_MARK', got '$evidence'"; bad=1; }
        [ "$verdict" = "$NONE_MARK" ] \
          || { echo "row $leg: not_delegated must have Verdict '$NONE_MARK', got '$verdict'"; bad=1; }
        ;;
    esac
  done <<< "$rows"
  return "$bad"
}

# Row of the fixture whose Platform cell equals $1; fails on zero or several.
row_for_platform() {
  local rows
  rows="$(leg_rows "$PLUGIN_ROOT/$POSITIVE" | awk -F"$SEP" -v p="$1" '$3 == p')"
  [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 1 ] \
    || { echo "expected exactly one $1 row in $POSITIVE" >&2; return 1; }
  printf '%s\n' "$rows"
}

@test "template: fixture header equals the agent's record template header" {
  grep -qxF -- "$RECORD_HEADER" "$PLUGIN_ROOT/$QA_AGENT" \
    || fail "$QA_AGENT record template header drifted from: $RECORD_HEADER"
  local f
  for f in "$POSITIVE" "$NEGATIVE"; do
    grep -qxF -- "$RECORD_HEADER" "$PLUGIN_ROOT/$f" || fail "$f header differs from the template"
  done
}

@test "template: the Reason enum equals the reasons § Leg not delegated maps to" {
  local mapped template
  # Backticks are literal markdown code spans, not command substitution.
  # shellcheck disable=SC2016
  mapped="$(awk '/^#### Leg not delegated/ {on = 1; next} on && /^#/ {exit} on {print}' \
    "$PLUGIN_ROOT/$QA_AGENT" \
    | sed -nE 's/^\|.*\| `([a-z_]+)` \|[[:space:]]*$/\1/p' | LC_ALL=C sort)"
  template="$(template_enum 7 | grep -vxF -- "$NONE_MARK" | LC_ALL=C sort)"
  [ -n "$mapped" ] || fail "no Reason values parsed from § Leg not delegated"
  [ "$mapped" = "$template" ] \
    || fail "$(printf 'reason map:\n%s\nrecord template:\n%s' "$mapped" "$template")"
}

@test "record: the table is an H3 under ## results, never an H2" {
  local f parent
  for f in "$POSITIVE" "$NEGATIVE"; do
    parent="$(awk '/^## / {h2 = $0} /^### Native UI Legs[[:space:]]*$/ {print h2; exit}' "$PLUGIN_ROOT/$f")"
    [ "$parent" = "## results" ] || fail "$f: ### Native UI Legs sits under '$parent', not ## results"
    if grep -qE '^## Native UI Legs' "$PLUGIN_ROOT/$f"; then
      fail "$f: Native UI Legs is an H2; the testing anchor lint rejects unlisted H2s"
    fi
  done
}

@test "routing: the ios leg is routed to the apple-ui-verifier matrix target" {
  local row target
  row="$(row_for_platform ios)"
  target="$(matrix_target apple-ui-verifier)"
  [ -n "$target" ] || fail "corpflow:apple-ui-verifier missing from $MATRIX"
  [ "$(printf '%s' "$row" | cut -d"$SEP" -f5)" = "corpflow:apple-ui-verifier" ] || fail "ios row alias: $row"
  [ "$(printf '%s' "$row" | cut -d"$SEP" -f6)" = "$target" ] || fail "ios row not routed to $target: $row"
}

@test "routing: the android leg is routed to the android-ui-verifier matrix target" {
  local row target
  row="$(row_for_platform android)"
  target="$(matrix_target android-ui-verifier)"
  [ -n "$target" ] || fail "corpflow:android-ui-verifier missing from $MATRIX"
  [ "$(printf '%s' "$row" | cut -d"$SEP" -f5)" = "corpflow:android-ui-verifier" ] || fail "android row alias: $row"
  [ "$(printf '%s' "$row" | cut -d"$SEP" -f6)" = "$target" ] || fail "android row not routed to $target: $row"
}

@test "routing: a non-iOS apple leg routes to the matching <os>-developer; iOS and iPadOS keep the default" {
  # The apple default names the iOS agent; § Dispatching a leg swaps in the
  # OS-specific agent of the same plugin only for macOS, tvOS, watchOS and
  # visionOS. The apple plugin has no ipados-developer, so iPadOS stays on the
  # default, and a pick arm that listed it would route to a nonexistent agent.
  local default plugin leg platform routed picked=0 kept=0
  default="$(matrix_target apple-ui-verifier)"
  [ -n "$default" ] || fail "corpflow:apple-ui-verifier missing from $MATRIX"
  plugin="${default%%:*}"
  while IFS="$SEP" read -r _ leg platform _ _ routed _; do
    case "$platform" in
      ios | ipados)
        kept=1
        [ "$routed" = "$default" ] \
          || fail "row $leg ($platform) routed to '$routed', expected the default $default"
        ;;
      macos | tvos | watchos | visionos)
        picked=1
        [ "$routed" = "${plugin}:${platform}-developer" ] \
          || fail "row $leg ($platform) routed to '$routed', expected ${plugin}:${platform}-developer"
        ;;
    esac
  done <<< "$(leg_rows "$PLUGIN_ROOT/$POSITIVE")"
  [ "$picked" -eq 1 ] || fail "$POSITIVE has no non-iOS apple row to exercise the pick"
  [ "$kept" -eq 1 ] || fail "$POSITIVE has no ios or ipados row to exercise the default"
}

@test "precedence: § Native UI legs says the Bash fallback never runs a UI test target" {
  # Without this sentence the plugin-unavailable fallback in § Test Execution
  # reads as a second way to run the UI target, bypassing the not_delegated record.
  local section
  section="$(awk '/^### Native UI legs[[:space:]]*$/ {on = 1; next} on && /^### / {exit} on {print}' \
    "$PLUGIN_ROOT/$QA_AGENT")"
  [ -n "$section" ] || fail "no ### Native UI legs section in $QA_AGENT"
  case "$section" in
    *"outranks § Test Execution's plugin-unavailable fallback"*"never includes a UI test target"*) ;;
    *) fail "§ Native UI legs lacks the precedence over the Bash fallback" ;;
  esac
}

@test "validator: the positive fixture passes, with a not_delegated row carrying a reason enum" {
  run validate_leg_rows "$PLUGIN_ROOT/$POSITIVE"
  assert_success
  assert_output ""
  local reasons
  reasons="$(leg_rows "$PLUGIN_ROOT/$POSITIVE" | awk -F"$SEP" '$7 == "not_delegated" {print $8}')"
  [ -n "$reasons" ] || fail "$POSITIVE has no not_delegated row"
  run bash -c "printf '%s\n' \"\$1\" | grep -vxF -- \"\$2\"" _ "$reasons" "$NONE_MARK"
  assert_success
}

@test "validator: every not_delegated row has its AC note in ### Notes" {
  local leg reason
  while IFS="$SEP" read -r _ leg _ _ _ _ _ reason _; do
    grep -qE "^- AC-[0-9]+: native UI leg ${leg} not delegated \(${reason}\)$" "$PLUGIN_ROOT/$POSITIVE" \
      || fail "no '§ Notes' line for not_delegated leg $leg ($reason)"
  done <<< "$(leg_rows "$PLUGIN_ROOT/$POSITIVE" | awk -F"$SEP" '$7 == "not_delegated"')"
}

@test "validator: a not_delegated row with Reason — fails and names that row only" {
  run validate_leg_rows "$PLUGIN_ROOT/$NEGATIVE"
  assert_failure
  assert_output --partial "row UI-3: not_delegated needs a Reason enum value"
  refute_output --partial "row UI-1"
  refute_output --partial "row UI-2"
}

@test "budget: the one tool-call budget line exempts delegated legs and never waives them" {
  local line count
  line="$(grep -E '^\*\*Tool-call budget\*\*:' "$PLUGIN_ROOT/$QA_AGENT")"
  [ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ] || fail "expected one Tool-call budget line in $QA_AGENT"
  case "$line" in
    *"A delegated native UI leg costs one call"*"the delegate's calls are exempt"*) ;;
    *) fail "budget line lacks the one-call cost and delegate exemption: $line" ;;
  esac
  case "$line" in
    *"Native UI legs are never waived for budget"*) ;;
    *) fail "budget line lacks the never-waived rule: $line" ;;
  esac
  # A second statement of the cap could disagree about the exemption.
  count="$(cd "$PLUGIN_ROOT" && grep -rF '≤64 tool calls' agents skills commands | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || fail "expected exactly one '≤64 tool calls' statement, found $count"
}

@test "checklist: Completion Verification requires a row for every native UI leg" {
  local section
  section="$(awk '/^## Completion Verification/ {on = 1; next} on && /^## / {exit} on {print}' \
    "$PLUGIN_ROOT/$QA_AGENT")"
  [ -n "$section" ] || fail "no ## Completion Verification section in $QA_AGENT"
  run bash -c "printf '%s\n' \"\$1\" | grep -F -- \"\$2\"" _ "$section" \
    '- [ ] Every native UI leg has one `### Native UI Legs` row in `testing-N.md`'
  assert_success
  assert_output --partial "not_delegated"
  # Evidence and verdict together: "or" would admit a delegated row with no
  # evidence and a pass, which the validator above rejects.
  # Backticks are literal markdown code spans, not command substitution.
  # shellcheck disable=SC2016
  assert_output --partial '`delegated` with evidence and a verdict'
  assert_output --partial "none waived for call budget"
}

@test "lint: the positive fixture passes the cache-lint anchor lint" {
  run_script "$CACHE_LINT" --anchor-lint "$PLUGIN_ROOT/$POSITIVE"
  assert_success
  assert_output --partial "ok"
}
