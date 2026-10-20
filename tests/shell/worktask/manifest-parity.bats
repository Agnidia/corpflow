#!/usr/bin/env bats
# Guard for the v3.28.1 failure class: manifest/filesystem drift that silently
# breaks command/skill registration (AC-3), and version-triple drift across
# plugin.json / marketplace.json / README.md (AC-4).
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

_claude_skill_dirs() {
  cd "$PLUGIN_ROOT" || return 1
  find skills -name SKILL.md | sed 's#/SKILL\.md$##' | while IFS= read -r skill; do
    name="${skill#skills/}"
    if [ -f "commands/$name.md" ]; then
      case "$name" in megatask|request-plan|worktask) ;; *) continue ;; esac
    fi
    printf '%s\n' "$skill"
  done | sort
}

@test "AC-3: marketplace.json commands[] matches commands/*.md filesystem set exactly" {
  local manifest_list fs_list
  manifest_list="$(jq -r '.plugins[0].commands[]' "$PLUGIN_ROOT/.claude-plugin/marketplace.json" \
    | sed 's#^\./##' | sort)"
  fs_list="$(cd "$PLUGIN_ROOT" && ls commands/*.md | sort)"
  diff <(printf '%s\n' "$manifest_list") <(printf '%s\n' "$fs_list")
}

# agents[] and skills[] were unguarded while commands[] was pinned, so a new agent
# or skill registered correctly on disk and silently missing from the listing broke
# nothing until a user installed from the marketplace.
@test "AC-3: marketplace.json agents[] matches agents/*.md filesystem set exactly" {
  local manifest_list fs_list
  manifest_list="$(jq -r '.plugins[0].agents[]' "$PLUGIN_ROOT/.claude-plugin/marketplace.json" \
    | sed 's#^\./##' | sort)"
  fs_list="$(cd "$PLUGIN_ROOT" && ls agents/*.md | sort)"
  diff <(printf '%s\n' "$manifest_list") <(printf '%s\n' "$fs_list")
}

@test "AC-3: marketplace.json skills[] matches the SKILL.md-bearing directory set exactly" {
  local manifest_list fs_list
  manifest_list="$(jq -r '.plugins[0].skills[]' "$PLUGIN_ROOT/.claude-plugin/marketplace.json" \
    | sed 's#^\./##' | sort)"
  # Carrying a SKILL.md is what makes a directory a skill, so discovery is by that
  # file rather than by depth: it admits skills/shared/milestone-helpers and excludes
  # skills/shared and skills/shared/lib, which are reference material and libraries.
  fs_list="$(_claude_skill_dirs)"
  diff <(printf '%s\n' "$manifest_list") <(printf '%s\n' "$fs_list")
}

@test "AC-4: plugin.json / marketplace.json / README.md agree on version" {
  local plugin_ver market_meta_ver market_plugin_ver
  plugin_ver="$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  market_meta_ver="$(jq -r '.metadata.version' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")"
  market_plugin_ver="$(jq -r '.plugins[0].version' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")"

  [ -n "$plugin_ver" ]
  [ "$plugin_ver" = "$market_meta_ver" ]
  [ "$plugin_ver" = "$market_plugin_ver" ]

  run grep -F -- "$plugin_ver" "$PLUGIN_ROOT/README.md"
  assert_success
}

# The two manifests are read by different consumers — plugin.json by the runtime,
# marketplace.json by the marketplace listing — so a description or keyword edit
# applied to one drifts silently from the other. Nothing else compares them.
@test "AC-13: plugin.json and marketplace.json agree on description" {
  local plugin_desc market_desc market_meta_desc
  plugin_desc="$(jq -r '.description' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  market_desc="$(jq -r '.plugins[0].description' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")"
  market_meta_desc="$(jq -r '.metadata.description' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")"

  [ -n "$plugin_desc" ]
  [ "$plugin_desc" = "$market_desc" ]
  [ "$plugin_desc" = "$market_meta_desc" ]
}

@test "AC-13: plugin.json and marketplace.json agree on keywords, capped at 15" {
  local plugin_kw market_kw count
  plugin_kw="$(jq -c '.keywords' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  market_kw="$(jq -c '.plugins[0].keywords' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")"
  [ "$plugin_kw" = "$market_kw" ] || fail "keyword drift: plugin=$plugin_kw marketplace=$market_kw"

  # The cap is what keeps the list a description of the plugin rather than a
  # changelog: the array reached 120 entries, most of them release-note tokens.
  count="$(jq -r '.keywords | length' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  [ "$count" -ge 1 ]
  [ "$count" -le 15 ] || fail "keywords: $count entries, cap is 15"
}

@test "AC-13: no keyword is version- or release-note-shaped" {
  # CHANGELOG.md already carries per-release detail; a keyword naming a model
  # generation or a removed feature is stale the day the next version ships.
  run bash -c "jq -r '.keywords[]' '$PLUGIN_ROOT/.claude-plugin/plugin.json' \
    | grep -nE 'opus|sonnet|haiku|fable|[0-9]+\\.[0-9]+|removed|cleanup|default\$|deprecat'"
  assert_failure
}

@test "AC-9: test-execution-gate.sh is registered under PreToolUse and is executable on disk" {
  [ -x "$PLUGIN_ROOT/hooks/test-execution-gate.sh" ]
  run jq -r '.hooks.PreToolUse[].hooks[].command' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output --partial 'hooks/test-execution-gate.sh'
}

@test "AC-14: model-switch-gate.sh is registered under PreModelSwitch and is executable on disk" {
  [ -x "$PLUGIN_ROOT/hooks/model-switch-gate.sh" ]
  run jq -r '.hooks.PreModelSwitch[].hooks[].command' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output --partial 'hooks/model-switch-gate.sh'
}

@test "AC-14: model-switch-audit.sh is registered under PostModelSwitch and is executable on disk" {
  [ -x "$PLUGIN_ROOT/hooks/model-switch-audit.sh" ]
  run jq -r '.hooks.PostModelSwitch[].hooks[].command' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output --partial 'hooks/model-switch-audit.sh'
}

@test "AC-14: the shared model-switch library is sourced-only, never registered as a hook" {
  # A library wired as a hook command would be exec'd, hit its anti-execution
  # guard and exit 2 on every model switch.
  [ ! -x "$PLUGIN_ROOT/hooks/model-switch-lib.sh" ]
  run jq -r '[.. | .command? // empty] | .[]' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  refute_output --partial 'model-switch-lib.sh'
}

# Claude Code ignores `hooks`, `mcpServers` and `permissionMode` in the frontmatter of an
# agent loaded from a plugin, which every agents/*.md here is. A declaration there parses,
# loads and never runs, so nothing downstream notices. Agent-scoped hooks belong in
# plugin.json under SubagentStart/SubagentStop with an anchored `^corpflow:<name>$` matcher.
@test "plugin agents: no agent declares hooks, mcpServers or permissionMode frontmatter" {
  local f hits="" count=0
  for f in "$PLUGIN_ROOT"/agents/*.md; do
    count=$((count + 1))
    hits="$hits$(awk -v name="${f##*/}" '
      /^---[[:space:]]*$/ { fences++; if (fences >= 2) exit; next }
      fences == 1 && /^(hooks|mcpServers|permissionMode):/ { print name ": " $0 }
    ' "$f")"
  done
  # Non-vacuity: an empty glob would pass by inspecting nothing.
  [ "$count" -ge 10 ] || fail "non-vacuity: only $count agent files scanned"
  [ -z "$hits" ] || fail "plugin agents ignore these fields; move the hook to plugin.json: $hits"
}

@test "plugin.json hooks: every registered command resolves to an executable script" {
  local cmd script count=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    script="${cmd#\$\{CLAUDE_PLUGIN_ROOT\}/}"
    [ -f "$PLUGIN_ROOT/$script" ] || fail "plugin.json hook missing on disk: $script"
    # `hooks/*` are exec'd directly and are +x (see AC-9).
    case "$script" in
      hooks/*) [ -x "$PLUGIN_ROOT/$script" ] || fail "plugin.json hook not executable: $script" ;;
    esac
    count=$((count + 1))
  done < <(jq -r '[.. | .command? // empty] | .[]' "$PLUGIN_ROOT/.claude-plugin/plugin.json")

  [ "$count" -ge 8 ]
}

# The test above proves registered→exists. Nothing proved the inverse, so a handler
# that was written, documented and never registered passed the suite for as long as
# it existed — the class that left PostCompact unwired while four documents assumed
# it fired. The `-ge 8` floor cannot catch it: an unregistered handler lowers no count.

# Prints every hook handler script that MUST appear in plugin.json, one relpath per
# line. Executable-only: a non-executable hooks/*.sh is a sourced library, and wiring
# one as a command is separately refused (AC-14).
_expected_registered_handlers() {
  local f
  for f in "$PLUGIN_ROOT"/hooks/*.sh; do
    [ -x "$f" ] || continue
    printf 'hooks/%s\n' "${f##*/}"
  done
  # Handlers that live outside hooks/ are invisible to the sweep above and are the
  # reason this test exists; each new one is listed here or it is not guarded.
  printf 'skills/context-compression/scripts/post-compact-recovery.sh\n'
}

@test "plugin.json hooks: every hook handler on disk is registered (inverse parity)" {
  local registered handler marker count=0
  registered="$({
    jq -r '[.. | .command? // empty] | .[]' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
    jq -r '[.. | .command? // empty] | .[]' "$PLUGIN_ROOT/hooks/codex-hooks.json"
  })"

  while IFS= read -r handler; do
    [ -n "$handler" ] || continue
    [ -f "$PLUGIN_ROOT/$handler" ] || fail "expected handler missing on disk: $handler"
    case "$handler" in
      hooks/codex-*.sh) marker="\${PLUGIN_ROOT}/$handler" ;;
      *) marker="\${CLAUDE_PLUGIN_ROOT}/$handler" ;;
    esac
    printf '%s\n' "$registered" | grep -Fq -- "$marker" \
      || fail "handler exists on disk but is registered in no plugin.json hook event: $handler"
    count=$((count + 1))
  done < <(_expected_registered_handlers)

  # Non-vacuity: an empty or broken discovery would otherwise pass silently.
  [ "$count" -ge 14 ] || fail "non-vacuity: only $count handlers checked, expected at least 14"
}

@test "plugin.json hooks: the continuity events PostCompact and SessionEnd are registered" {
  # Named rather than swept: four documents and a six-edge state model assume
  # PostCompact fires, and the SessionEnd row is the only completion record
  # background work gets when a session tears down. Both were absent for releases.
  local events
  events="$(jq -r '.hooks | keys[]' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  printf '%s\n' "$events" | grep -qx 'PostCompact' || fail "PostCompact is not a registered hook event"
  printf '%s\n' "$events" | grep -qx 'SessionEnd' || fail "SessionEnd is not a registered hook event"
}

@test "policy hooks block infrastructure failures while advisory and completion hooks retain their behavior" {
  run jq -e '.hooks.PreToolUse | all(.[]; all(.hooks[];
    if (.command | test("(test-execution-gate|user-decision-record)\\.sh$"))
    then .onFailure == "block" else (has("onFailure") | not) end))' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  run jq -e '.hooks.PreModelSwitch[0].hooks[0].onFailure == "block" and
    (all(.hooks.SubagentStop[].hooks[]; has("onFailure") | not))' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
}
