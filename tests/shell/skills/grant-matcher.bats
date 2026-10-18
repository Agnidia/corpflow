#!/usr/bin/env bats
# Models the documented Claude Code Bash-tool permission-rule matching described in
# permissions.md and plugins-reference.md (skills/shared/plugin-root-resolution.md
# § Granted-script invocation shape) — this file never runs Claude Code itself. It drives
# skills/shared/scripts/grant-lint.sh's corpflow_grant_matches() (sourced once below, so the
# matcher model is defined exactly once) against two real plugin-root shapes an agent actually
# runs from: a linked `git worktree add` checkout, and an installed Claude Code plugin cache
# directory. Both stub trees carry only a `.claude-plugin/plugin.json` marker and a stub
# `skills/worktask/scripts/state-patch.sh`, mirroring plugin-root-resolution.md's two known
# layouts.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/shared/scripts/grant-lint.sh"
# shellcheck source=skills/shared/scripts/grant-lint.sh
. "$PLUGIN_ROOT/$SCRIPT"

RULE='Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *)'

# mk_stub_plugin_tree <root> — a minimal installed-plugin shape: the plugin.json marker
# plugin-root-resolution.md validates against, plus the one granted script this file exercises.
mk_stub_plugin_tree() {
  local root="$1"
  mkdir -p "$root/.claude-plugin" "$root/skills/worktask/scripts"
  printf '{"name":"corpflow"}\n' > "$root/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\nprintf "stub\\n"\n' > "$root/skills/worktask/scripts/state-patch.sh"
}

# --- case 1: a linked `git worktree add` checkout -----------------------------

@test "worktree cwd: the anchored rule matches the substituted invocation, and its script path resolves" {
  local main wt
  main="$(mk_git_fixture \
    --file '.claude-plugin/plugin.json:{"name":"corpflow"}\n' \
    --file 'skills/worktask/scripts/state-patch.sh:#!/usr/bin/env bash\nprintf "stub\\n"\n' \
    --commit 'seed the plugin tree')"
  wt="$(mk_tmpworkdir)/wt"
  git -C "$main" worktree add -q "$wt" -b wt-branch \
    || fail "git worktree add failed"
  cd "$wt" || fail "cd to worktree failed"
  [ -f skills/worktask/scripts/state-patch.sh ]

  run corpflow_grant_matches "$RULE" \
    "bash $wt/skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$wt"
  assert_success

  # cwd resolves the file on disk, but the matcher never consults cwd: a
  # relative invocation still must not match the anchored rule.
  run corpflow_grant_matches "$RULE" \
    "bash skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$wt"
  assert_failure
}

# --- case 2: an installed Claude Code plugin cache directory -------------------

@test "cache root: the anchored rule matches the substituted invocation, and its script path resolves" {
  local cache="$BATS_TEST_TMPDIR/home/.claude/plugins/cache/agnidia/corpflow/9.9.9"
  mk_stub_plugin_tree "$cache"

  run corpflow_grant_matches "$RULE" \
    "bash $cache/skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$cache"
  assert_success
  [ -f "$cache/skills/worktask/scripts/state-patch.sh" ]
}

# --- case 3: negatives, driven against the cache root fixture ------------------

@test "negative: a relative rule never matches even a well-formed substituted command" {
  local root="$BATS_TEST_TMPDIR/neg-relative-rule"
  mk_stub_plugin_tree "$root"
  run corpflow_grant_matches 'Bash(bash skills/worktask/scripts/state-patch.sh *)' \
    "bash $root/skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$root"
  assert_failure
}

@test "negative: a relative invocation from the worktree never matches the anchored rule" {
  local main wt
  main="$(mk_git_fixture \
    --file '.claude-plugin/plugin.json:{"name":"corpflow"}\n' \
    --file 'skills/worktask/scripts/state-patch.sh:#!/usr/bin/env bash\n' \
    --commit 'seed')"
  wt="$(mk_tmpworkdir)/wt"
  git -C "$main" worktree add -q "$wt" -b wt-branch-relative \
    || fail "git worktree add failed"
  cd "$wt" || fail "cd to worktree failed"
  [ -f skills/worktask/scripts/state-patch.sh ]

  run corpflow_grant_matches "$RULE" \
    "bash skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$wt"
  assert_failure
}

@test "negative: a quoted \$PLUGIN_ROOT invocation never matches the anchored rule" {
  local root="$BATS_TEST_TMPDIR/neg-quoted"
  mk_stub_plugin_tree "$root"
  # shellcheck disable=SC2016
  run corpflow_grant_matches "$RULE" \
    'bash "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh"' "$root"
  assert_failure
}

@test "negative: a leading env assignment never matches" {
  local root="$BATS_TEST_TMPDIR/neg-env-prefix"
  mk_stub_plugin_tree "$root"
  run corpflow_grant_matches "$RULE" \
    "X=1 bash $root/skills/worktask/scripts/state-patch.sh --stage DR --prev DV" "$root"
  assert_failure
}

@test "negative: a compound command with a trailing && fails closed" {
  local root="$BATS_TEST_TMPDIR/neg-compound"
  mk_stub_plugin_tree "$root"
  run corpflow_grant_matches "$RULE" \
    "bash $root/skills/worktask/scripts/state-patch.sh && rm -rf $root" "$root"
  assert_failure
}

# --- case 4: repo contract — every anchored grant has a matching invocation -

# repo_grant_prefix <interp> <path> — the literal anchored prefix an invocation must open
# with, byte-identical to the grant it belongs to (before its trailing arguments/terminator).
repo_grant_prefix() {
  printf '%s %s/%s' "$1" "$CORPFLOW_GRANT_TOKEN" "$2"
}

# repo_body <file> — the file's body without frontmatter, plus the body of every
# skills/*/SKILL.md its `related:` list names: a command that loads its skill runs the
# invocation the skill carries.
repo_body() {
  local file="$1" rel
  awk 'NR==1 && $0=="---"{fm=1;next} fm && /^---[[:space:]]*$/{fm=0;next} !fm' "$PLUGIN_ROOT/$file"
  while IFS= read -r rel; do
    [ -f "$PLUGIN_ROOT/$rel" ] && awk 'NR==1 && $0=="---"{fm=1;next} fm && /^---[[:space:]]*$/{fm=0;next} !fm' "$PLUGIN_ROOT/$rel"
  done < <(awk 'NR==1 && $0!="---"{exit} NR>1 && /^---[[:space:]]*$/{exit} /^related:/{r=1;next} r && /^  - skills\/[^ ]+\/SKILL\.md[[:space:]]*$/{print $2;next} r && !/^  - /{r=0}' "$PLUGIN_ROOT/$file")
}

# Sourced helpers are granted but never executed, so no invocation line can exist.
REPO_SOURCE_ONLY_GRANTS="skills/worktask/scripts/effort-ladder.sh"

# repo_file_grants <file> — this suite's own grant collector, over the seam API only
# (corpflow_grant_rule_ok): reads frontmatter Bash(...) tokens with a local awk pass and
# emits "<interp>\t<path>" per anchored grant, mirroring grant-lint.sh's own scan without
# reaching into its private helpers.
repo_file_grants() {
  local file="$1" tok content interp
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    corpflow_grant_rule_ok "$tok" || continue
    content="${tok#Bash(}"
    content="${content%)}"
    for interp in bash python3; do
      case "$content" in
        "$interp ${CORPFLOW_GRANT_TOKEN}/"*)
          printf '%s\t%s\n' "$interp" "${content#"$interp ${CORPFLOW_GRANT_TOKEN}/"}" \
            | sed -E 's/ \*$//'
          ;;
      esac
    done
  done < <(awk '
    function strip_cr(s) { sub(/\r$/, "", s); return s }
    FNR == 1 { fm = (strip_cr($0) == "---") ? 1 : 0 }
    {
      line = strip_cr($0)
      if (FNR > 1 && fm == 1 && line ~ /^---[[:space:]]*$/) { fm = 0; next }
      if (!fm) next
      if (line !~ /^(tools|allowed-tools):/ && line !~ /^[[:space:]]*-[[:space:]]*Bash\(/) next
      rest = line
      while (match(rest, /Bash\([^)]*\)/)) {
        print substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$file")
}

@test "repo contract: every anchored grant in this repo is matched by an invocation line in its own file" {
  # A fixed, non-existent root: this case checks the TEXT contract (a body line carrying the
  # grant's literal prefix), then re-derives corpflow_grant_matches's own accept decision at
  # this root, never the filesystem — corpflow_grant_matches never touches disk.
  local root="/opt/corpflow-fixed-root" file body checked=0 missing=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    local interp path prefix rule cmd
    while IFS="$(printf '\t')" read -r interp path; do
      [ -n "$path" ] || continue
      case " $REPO_SOURCE_ONLY_GRANTS " in *" $path "*) continue ;; esac
      checked=$((checked + 1))
      prefix="$(repo_grant_prefix "$interp" "$path")"
      # Frontmatter is stripped so a grant cannot pass by matching its own text.
      body="$(repo_body "$file")"
      if ! printf '%s\n' "$body" | grep -qF -- "$prefix"; then
        missing="$missing$file -> $interp $path (no body invocation)
"
        continue
      fi
      rule="Bash($prefix *)"
      cmd="${prefix%%"$CORPFLOW_GRANT_TOKEN"*}$root${prefix#*"$CORPFLOW_GRANT_TOKEN"} --sample-arg"
      corpflow_grant_matches "$rule" "$cmd" "$root" \
        || missing="$missing$file -> $interp $path (matcher rejected substituted form)
"
    done < <(repo_file_grants "$PLUGIN_ROOT/$file")
  done < <(cd "$PLUGIN_ROOT" && git ls-files -- 'agents/*.md' 'commands/*.md' 'skills/*/SKILL.md')
  # Guard the collector before asserting emptiness: this plugin genuinely carries anchored
  # grants, so a zero-sized candidate set means the collector regressed, not a clean repo.
  [ "$checked" -ge 10 ] || fail "grant collector regressed: only $checked anchored grants found"
  [ -z "$missing" ] || fail "$missing"
}
