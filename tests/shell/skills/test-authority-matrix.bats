#!/usr/bin/env bats
# Single-sourcing contract for the Test-Execution Authority policy
# (skills/worktask/references/testing-strategy.md § Test-Execution Authority):
#   - the canonical runner enumeration and hooks/test-execution-gate.sh's
#     RUNNERS list agree (parity, not literal-text identity)
#   - every non-DV/QA stage agent carries the pointer exactly once, never a
#     restated runner list
#   - no file outside a documented allow-list restates >=3 runner names on
#     one line
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

TESTING_STRATEGY="$PLUGIN_ROOT/skills/worktask/references/testing-strategy.md"
GATE_HOOK="$PLUGIN_ROOT/hooks/test-execution-gate.sh"

# Canonical runner tokens as spelled in the hook's RUNNERS variable — each
# MUST also be discoverable (as itself, or as the named runner it aliases)
# in testing-strategy.md's § Test-Execution Authority section.
CANONICAL_TOKENS=(bats swift pytest ctest cargo jest vitest playwright rspec gradle python python3 go make xcodebuild dotnet npm pnpm yarn node)
# npx/uvx/bunx are launcher-wrapper tokens the hook strips before matching,
# not runners named in the canonical prose enumeration — excluded here.

# Non-DV/QA stage agents that MUST carry the pointer exactly once.
POINTER_AGENTS=(
  security-reviewer release-engineer incident-responder software-architector
  team-lead technical-writer project-manager stakeholder product-manager
  technical-lead
)

# Allow-list: files legitimately naming >=3 runners on one line for reasons
# unrelated to restating the forbidden-runner policy (tool grants, log-name
# examples, the selection-syntax grammar reference, the hook's own parity
# counterpart, and the canonical section itself).
ALLOWLIST_PATTERNS=(
  "commands/test-coverage.md"
  "commands/"                       # allowed-tools frontmatter on any command
  "skills/logging-conventions/SKILL.md"
  "skills/shared/test-selection-syntax.md"
  "skills/shared/testing-strategy.md"  # general framework and strict-runner reference
  "skills/cross-plugin-handoff/templates/CORPFLOW.md"  # handoff test-evidence vocabulary
  "skills/worktask/references/testing-strategy.md"   # the canonical section itself
  "hooks/test-execution-gate.sh"        # the RUNNERS parity counterpart
  "tests/"
)

@test "parity: every canonical runner token in hooks/test-execution-gate.sh RUNNERS is discoverable in testing-strategy.md's canonical section" {
  local runners_line
  runners_line="$(grep -m1 '^RUNNERS=' "$GATE_HOOK")"
  local section
  section="$(awk '/^## Test-Execution Authority$/,/^## Test Selection Gate$/' "$TESTING_STRATEGY")"

  # -w, not a bare substring: the section's only occurrence of "node" was inside
  # "a pytest nodeid", so an unbounded match would have accepted prose about a
  # different runner as proof this one is documented.
  for tok in "${CANONICAL_TOKENS[@]}"; do
    echo "$runners_line" | grep -qw -- "$tok" || fail "RUNNERS is missing token: $tok"
    printf '%s' "$section" | grep -qiw -- "$tok" || fail "canonical section does not mention: $tok"
  done
}

@test "N3: every MULTI_PURPOSE_RUNNERS token is also a member of RUNNERS (no silently-dead config)" {
  local multi_line runners_line tok
  multi_line="$(grep -m1 '^MULTI_PURPOSE_RUNNERS=' "$GATE_HOOK")"
  multi_line="${multi_line#*=}"
  multi_line="${multi_line%\"}"
  multi_line="${multi_line#\"}"
  runners_line="$(grep -m1 '^RUNNERS=' "$GATE_HOOK")"
  for tok in $multi_line; do
    echo "$runners_line" | grep -q -- "\"$tok " || echo "$runners_line" | grep -q -- " $tok " \
      || echo "$runners_line" | grep -qE "(^|[^A-Za-z0-9_])${tok}([^A-Za-z0-9_]|\$)" \
      || fail "MULTI_PURPOSE_RUNNERS token '$tok' is not present in RUNNERS — dead config, gated too early to ever classify"
  done
}

@test "parity: hook self-test exercises the same RUNNERS enumeration (no drift between doc and code)" {
  run bash "$GATE_HOOK" --self-test
  assert_success
}

@test "single-sourcing: every non-DV/QA stage agent contains the pointer phrase exactly once" {
  for agent in "${POINTER_AGENTS[@]}"; do
    local f="$PLUGIN_ROOT/agents/${agent}.md"
    [ -f "$f" ] || fail "missing agent file: $f"
    local count
    count="$(grep -c 'Test-Execution Authority' "$f")"
    [ "$count" -eq 1 ] || fail "$agent.md: expected exactly 1 occurrence, got $count"
  done
}

@test "single-sourcing: canonical section exists exactly once in testing-strategy.md" {
  local count
  count="$(grep -c '^## Test-Execution Authority$' "$TESTING_STRATEGY")"
  [ "$count" -eq 1 ]
}

@test "single-sourcing: no non-DV/QA agent restates the forbidden-runner list (>=3 runner names on one line)" {
  local runner_regex
  runner_regex="bats|swift test|pytest|ctest|cargo test|go test|jest|vitest|playwright|rspec|dotnet test|gradle|xcodebuild"
  for agent in "${POINTER_AGENTS[@]}"; do
    local f="$PLUGIN_ROOT/agents/${agent}.md"
    while IFS= read -r line; do
      local hits
      hits="$(printf '%s\n' "$line" | grep -oE "$runner_regex" | sort -u | wc -l | tr -d ' ')"
      [ "$hits" -lt 3 ] || fail "$agent.md restates $hits runner names on one line: $line"
    done < "$f"
  done
}

@test "no file outside the documented allow-list contains >=3 distinct runner names on one line" {
  local runner_regex
  runner_regex="bats|swift test|pytest|ctest|cargo test|go test|jest|vitest|playwright|rspec|dotnet test|gradle|xcodebuild|make test"
  local offenders=""
  while IFS= read -r match; do
    local file="${match%%:*}"
    local allowed=0
    for pat in "${ALLOWLIST_PATTERNS[@]}"; do
      case "$file" in
        *"$pat"*) allowed=1; break ;;
      esac
    done
    [ "$allowed" -eq 1 ] && continue
    local line="${match#*:}"
    local hits
    hits="$(printf '%s\n' "$line" | grep -oE "$runner_regex" | sort -u | wc -l | tr -d ' ')"
    [ "$hits" -ge 3 ] && offenders="${offenders}${match}"$'\n'
  done < <(cd "$PLUGIN_ROOT" && grep -rnE "$runner_regex" --include='*.md' --include='*.sh' agents/ skills/ commands/ 2>/dev/null)

  [ -z "$offenders" ] || fail "restated runner lists found outside the allow-list:
$offenders"
}
