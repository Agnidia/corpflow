#!/usr/bin/env bats
# Contract tests for skills/self-improvement/scripts/build-context-set.sh
# Contracts (from source):
#   Reads agent names from (a) LEDGER_JSON, (b) CONTEXT_DIR/*.md `agent:`
#   trailers, (c) `git log $BASELINE_SHA..HEAD` `Agent:` trailers.
#   Normalizes corpflow:<name> to agents/<name>.md (also probing the
#   commands/ and skills/ spellings). CROSS_PLUGIN:* refs are dropped.
#   Only emits paths that EXIST on disk RELATIVE TO THE PLUGIN ROOT; output is
#   sorted and deduplicated. No --self-test flag; the tests drive it via env vars.
#
# Every case runs with --cwd on a scratch tree that owns its own agents/, and
# setup() points CLAUDE_PLUGIN_ROOT at that same tree. Both are needed: since R9
# the existence test resolves against the plugin root, so a scratch cwd alone
# would leave every candidate probed against the REAL repo and make the expected
# output depend on whatever it happens to contain.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/self-improvement/scripts/build-context-set.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/agents" "$WD/.claude-plugin"
  printf '{"name":"corpflow"}\n' > "$WD/.claude-plugin/plugin.json"
  export BASE_PLUGIN_ROOT="$WD"
  export CLAUDE_PLUGIN_ROOT="$WD"
  : > "$WD/agents/developer.md"
  : > "$WD/agents/qa-engineer.md"
  : > "$WD/agents/product-manager.md"
}

# Trailer keys are stripped with POSIX bracket classes, so every source below
# asserts one exact output on every sed/grep dialect. The earlier `\s` spelling
# was GNU-only and silently dropped the spaced form on BSD/macOS; these tests
# are what would go red if it came back.
# --- source 1: LEDGER_JSON ------------------------------------------------

@test "source 1: only completed-task agents are emitted, sorted and deduped" {
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"corpflow:developer"}},
  "QA0":{"status":"in_progress","metadata":{"agent":"corpflow:qa-engineer"}},
  "PL0":{"status":"completed","metadata":{"agent":"corpflow:product-manager"}},
  "DV1":{"status":"completed","metadata":{"agent":"corpflow:developer"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md
agents/product-manager.md"
}

@test "source 1: cross-plugin refs are dropped, local ones kept" {
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"apple-developer:ios-developer"}},
  "DV1":{"status":"completed","metadata":{"agent":"corpflow:developer"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

@test "source 1: names with no file on disk are dropped" {
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"corpflow:nonexistent-ghost-agent"}},
  "DV1":{"status":"completed","metadata":{"agent":"corpflow:developer"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

@test "source 1: embedded_commands entries resolve to a canonical skill entry" {
  mkdir -p "$WD/skills/worktask"
  : > "$WD/skills/worktask/SKILL.md"
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"corpflow:developer","embedded_commands":"corpflow:worktask"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  # Each qualified ref probes agents/, commands/ and skills/; only the
  # spellings that exist on disk survive the filter.
  assert_output "agents/developer.md
skills/worktask/SKILL.md"
}

# --- source 2: CONTEXT_DIR trailers ------------------------------------------

@test "source 2: CONTEXT_DIR 'agent:' trailer resolves on every sed dialect" {
  mkdir -p "$WD/ctx"
  cat > "$WD/ctx/planning-0.md" <<'MD'
---
agent: corpflow:product-manager
---
# Planning
MD
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=" --env "CONTEXT_DIR=$WD/ctx" -- "$SCRIPT"
  assert_success
  assert_output "agents/product-manager.md"
}

@test "source 2: an INDENTED 'agent:' trailer resolves too" {
  mkdir -p "$WD/ctx"
  # The leading-space arm of the same POSIX-class fix: `^[[:space:]]*` has to
  # hold at both ends of the key, not only after the colon.
  : > "$WD/agents/software-architector.md"
  cat > "$WD/ctx/architecture-0.md" <<'MD'
metadata:
    agent: corpflow:software-architector
MD
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=" --env "CONTEXT_DIR=$WD/ctx" -- "$SCRIPT"
  assert_success
  assert_output "agents/software-architector.md"
}

@test "source 2: a trailer value with no leading space resolves on every sed" {
  mkdir -p "$WD/ctx"
  printf 'agent:corpflow:qa-engineer\n' > "$WD/ctx/development-0.md"
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=" --env "CONTEXT_DIR=$WD/ctx" -- "$SCRIPT"
  assert_success
  assert_output "agents/qa-engineer.md"
}

# --- source 3: git log Agent: trailers ---------------------------------------

@test "source 3: BASELINE_SHA..HEAD trailers are read and the range is honoured" {
  local repo base
  repo="$(mk_git_fixture \
    --file 'agents/qa-engineer.md:x\n' \
    --commit "$(printf 'chore: before baseline\n\nAgent:corpflow:qa-engineer')" \
    --file 'agents/developer.md:x\n' \
    --commit "$(printf 'feat: after baseline\n\nAgent:corpflow:developer')")"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  run_script_env --cwd "$repo" \
    --env "LEDGER_JSON=" --env "CONTEXT_DIR=$repo/.ctx_none" \
    --env "BASELINE_SHA=$base" -- "$SCRIPT"
  assert_success
  # qa-engineer's trailer is on the baseline commit itself, outside the range.
  assert_output "agents/developer.md"
}

@test "source 3: conventional 'Agent: <name>' trailer resolves on every sed dialect" {
  local repo base
  repo="$(mk_git_fixture \
    --file 'agents/developer.md:x\n' \
    --commit 'chore: base' \
    --file 'note.txt:x\n' \
    --commit "$(printf 'feat: work\n\nAgent: corpflow:developer')")"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  run_script_env --cwd "$repo" \
    --env "LEDGER_JSON=" --env "CONTEXT_DIR=$repo/.ctx_none" \
    --env "BASELINE_SHA=$base" -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

# --- local plugin naming -----------------------------------------------------

# The whole pipeline is gated on this set being non-empty: a ref classified as
# cross-plugin is dropped, and an empty set makes map-and-filter discard every
# change, so Step 5b never writes a label. These two cases are what would go red
# if the accepted-prefix list narrowed back to a single hard-coded name.
@test "legacy igrsoft: refs resolve to local files" {
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"igrsoft:developer"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

@test "the manifest's own plugin name is accepted as local" {
  mkdir -p "$WD/.claude-plugin"
  printf '{"name":"renamed-plugin","version":"9.0.0"}\n' > "$WD/.claude-plugin/plugin.json"
  cat > "$WD/tasks.json" <<'JSON'
{"version":2,"tasks":{
  "DV0":{"status":"completed","metadata":{"agent":"renamed-plugin:developer"}},
  "QA0":{"status":"completed","metadata":{"agent":"apple-developer:qa-engineer"}}
}}
JSON
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/tasks.json" --env "CONTEXT_DIR=$WD/.ctx_none" \
    -- "$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

# --- empty inputs ------------------------------------------------------------

@test "empty task list and empty context dir produce no output (exit 0)" {
  printf '[]\n' > "$WD/empty.json"
  mkdir -p "$WD/ctx_empty"
  run_script_env --cwd "$WD" \
    --env "LEDGER_JSON=$WD/empty.json" --env "CONTEXT_DIR=$WD/ctx_empty" \
    -- "$SCRIPT"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# R9/#6 — two independent defects.
#   (a) Existence was tested against the process cwd. Every corpflow asset lives
#       under the plugin root while the pipeline runs from the worktask's repo,
#       so the production invocation returned the EMPTY set — which SKILL.md
#       § Step 5b itself calls indistinguishable from "the user made no edits".
#   (b) The set derived from tasks.*.metadata.agent only, so every hook and every
#       bundled script that participated was invisible.
# ---------------------------------------------------------------------------

mk_plugin_root() {   # a scratch plugin root, deliberately NOT the cwd
  ROOT="$WD/root"
  mkdir -p "$ROOT/.claude-plugin" "$ROOT/agents" "$ROOT/hooks" \
           "$ROOT/skills/worktask/scripts" "$WD/elsewhere"
  printf '{"name":"corpflow"}' > "$ROOT/.claude-plugin/plugin.json"
  : > "$ROOT/agents/developer.md"
  : > "$ROOT/hooks/audit-tooluse.sh"
  : > "$ROOT/skills/worktask/scripts/state-patch.sh"
}

@test "R9a: a plugin-root-relative candidate survives an invocation from another cwd" {
  mk_plugin_root
  cat > "$WD/tasks.json" <<'JSON'
{"tasks":{"DV0":{"status":"completed","metadata":{"agent":"corpflow:developer"}}}}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" LEDGER_JSON="$WD/tasks.json" CONTEXT_DIR="$WD/nope" \
    run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "agents/developer.md"
}

@test "R9a: the root is discovered from the script's own location when unset" {
  # Rung 3 of plugin-root-resolution.md, in isolation: CLAUDE_PLUGIN_ROOT is
  # emptied and the cwd is a directory that is NOT a plugin root, so the
  # BASH_SOURCE walk-up is the only rung that can resolve anything — and it
  # resolves to the REAL repo, whose agents/developer.md is what gets asserted.
  mkdir -p "$WD/elsewhere"
  cd "$WD/elsewhere"
  cat > "$WD/tasks.json" <<'JSON'
{"tasks":{"DV0":{"status":"completed","metadata":{"agent":"corpflow:developer"}}}}
JSON
  [ -f "$PLUGIN_ROOT/agents/developer.md" ]
  BASE_PLUGIN_ROOT= PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= LEDGER_JSON="$WD/tasks.json" CONTEXT_DIR="$WD/nope" \
    run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output --partial "agents/developer.md"
}

@test "R9b: a hook actor in the audit log becomes hooks/<n>.sh" {
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
{"actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Edit"}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "hooks/audit-tooluse.sh"
}

@test "R9b: a plugin-qualified hook actor is stripped to the same local path" {
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
{"actor":"android-developer:hook:audit-tooluse","action":"tool_invoked"}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "hooks/audit-tooluse.sh"
}

@test "R9b: a script basename is RESOLVED, not assumed to live in one directory" {
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
{"actor":"orchestrator","action":"github_issue_created","metadata":{"via":"state-patch.sh"}}
{"actor":"hook:audit-tooluse","action":"tool_invoked","subject":"state-patch","metadata":{"kind":"tool"}}
{"actor":"x","action":"y","metadata":{"tool":"state-patch.sh"}}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line "skills/worktask/scripts/state-patch.sh"
}

@test "R9b: an audit path that does not exist under the root is dropped" {
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
{"actor":"hook:not-a-real-hook","action":"tool_invoked"}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output ""
}

@test "R9b: a malformed audit line cannot abort the scan" {
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
not json at all
123
[1,2]
{"actor":"hook:audit-tooluse","action":"tool_invoked"}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # `--partial`, not an exact match: the malformed rows are now also COUNTED on stderr,
  # which bats merges into $output. The next case asserts that count.
  assert_output --partial "hooks/audit-tooluse.sh"
}

@test "R9b: the unparseable rows are COUNTED on stderr, not skipped in silence" {
  # Tolerant `fromjson?` drops malformed rows, so a corrupt log used to read exactly like a
  # clean one with no matching rows. stdout still carries only the path set.
  mk_plugin_root
  mkdir -p "$WD/ctx/logs"
  cat > "$WD/ctx/logs/audit.jsonl" <<'JSON'
not json at all
123
{"actor":"hook:audit-tooluse","action":"tool_invoked"}
JSON
  cd "$WD/elsewhere"
  BASE_PLUGIN_ROOT="$ROOT" CONTEXT_DIR="$WD/ctx" run bash "$PLUGIN_ROOT/$SCRIPT" 2>&1
  assert_success
  assert_output --partial "2 unparseable audit row(s) skipped"
  assert_output --partial "hooks/audit-tooluse.sh"
}
