#!/usr/bin/env bats
# Contract test for skills/shared/routing-matrix.md — the single source of truth
# for alias→target routing. The stage agents keep inline copies of the default
# targets (mandated copies), and this file is what keeps every copy in lockstep:
# the pre-matrix layout drifted silently (plugin-protocols.md shipped stale
# android bare names for two releases). Also guards the virtual alias namespace
# and the bare-Agent grant convention that project routing overrides depend on.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

MATRIX="skills/shared/routing-matrix.md"

# Space-separated to stay bash-3.2 portable; must equal SIBLINGS in
# cross-plugin-refs.bats and the publish-pl-issue prefix alternation.
DEV_PLUGINS="apple-developer system-developer android-developer frontend-developer backend-developer ai-engineer"
PLATFORMS="apple systems android web backend ai"

STAGE_AGENTS="agents/developer.md agents/software-architector.md agents/security-reviewer.md agents/qa-engineer.md"

# Emit "alias target" pairs from every matrix table row.
matrix_rows() {
  grep -E '^\| `corpflow:' "$PLUGIN_ROOT/$MATRIX" \
    | sed -E 's/^\| `(corpflow:[a-z0-9-]+)` \| `([a-z0-9-]+:[a-z0-9-]+)`.*/\1 \2/'
}

# Target of one alias.
matrix_target() {
  matrix_rows | awk -v a="corpflow:$1" '$1 == a {print $2}'
}

@test "matrix: aliases are well-shaped and unique" {
  local rows aliases
  rows="$(matrix_rows)"
  [ -n "$rows" ]
  # Every row parsed into exactly "corpflow:<alias> <plugin>:<agent>".
  run bash -c "printf '%s\n' \"\$1\" | grep -vE '^corpflow:[a-z][a-z0-9-]* [a-z][a-z0-9-]*:[a-z][a-z0-9-]*$'" _ "$rows"
  assert_output ""
  aliases="$(printf '%s\n' "$rows" | awk '{print $1}')"
  run bash -c "printf '%s\n' \"\$1\" | sort | uniq -d" _ "$aliases"
  assert_output ""
}

@test "matrix: expected alias set is complete (6 entry + 24 role + 2 release + 2 ui-verifier + 2 support)" {
  local p role count
  for p in $DEV_PLUGINS; do
    [ -n "$(matrix_target "${p}")" ] || { echo "missing entry alias corpflow:$p" >&2; return 1; }
  done
  for p in $PLATFORMS; do
    for role in architect security-auditor test-generator code-fixer; do
      [ -n "$(matrix_target "${p}-${role}")" ] \
        || { echo "missing role alias corpflow:${p}-${role}" >&2; return 1; }
    done
  done
  count="$(matrix_rows | wc -l | tr -d ' ')"
  [ "$count" -eq 36 ] || { echo "expected 36 matrix rows, found $count" >&2; return 1; }
}

@test "matrix: release-engineer aliases exist for the two platforms with a store" {
  # Bumping the row count above without this pair would let ANY two new rows satisfy it.
  local p
  for p in apple android; do
    [ -n "$(matrix_target "${p}-release-engineer")" ] \
      || { echo "missing corpflow:${p}-release-engineer" >&2; return 1; }
  done
}

@test "matrix: no release-engineer alias exists for a platform with no store" {
  # The row is a promise that the target agent exists. system-developer,
  # frontend-developer, backend-developer and ai-engineer ship no release engineer,
  # so an alias here would resolve to nothing at dispatch time.
  local p
  for p in systems web backend ai; do
    [ -z "$(matrix_target "${p}-release-engineer")" ] \
      || { echo "corpflow:${p}-release-engineer must not exist — no such target" >&2; return 1; }
  done
}

@test "matrix: ui-verifier aliases exist for the two native-runtime platforms, on their own plugin" {
  # Same guard as the release-engineer pair: the row count alone would accept any
  # two new rows. The plugin prefix pins each alias to the plugin whose agents
  # hold that platform's simulator or emulator tools.
  local p plugin target
  for p in apple:apple-developer android:android-developer; do
    plugin="${p#*:}"
    target="$(matrix_target "${p%%:*}-ui-verifier")"
    [ -n "$target" ] || { echo "missing corpflow:${p%%:*}-ui-verifier" >&2; return 1; }
    [ "${target%%:*}" = "$plugin" ] \
      || { echo "corpflow:${p%%:*}-ui-verifier targets $target, not a $plugin agent" >&2; return 1; }
  done
}

@test "matrix: no ui-verifier alias exists for a platform with no native runtime" {
  # systems, web, backend and ai have no simulator or emulator to drive, and a
  # browser leg is not a native UI leg; any such row would route QA to an agent
  # that cannot run the leg.
  local p extra
  for p in systems web backend ai; do
    [ -z "$(matrix_target "${p}-ui-verifier")" ] \
      || { echo "corpflow:${p}-ui-verifier must not exist — no native runtime" >&2; return 1; }
  done
  extra="$(matrix_rows | awk '$1 ~ /-ui-verifier$/ && $1 != "corpflow:apple-ui-verifier" && $1 != "corpflow:android-ui-verifier" {print $1}')"
  [ -z "$extra" ] || { echo "unexpected ui-verifier aliases: $extra" >&2; return 1; }
}

@test "matrix: no alias collides with a real corpflow agent name" {
  # Aliases are virtual corpflow:* ids; a collision with agents/*.md frontmatter
  # `name:` would make `corpflow:<name>` ambiguous between alias and agent.
  local names alias base
  names="$(grep -h '^name:' "$PLUGIN_ROOT"/agents/*.md | sed 's/^name:[[:space:]]*//')"
  while IFS= read -r alias; do
    base="${alias#corpflow:}"
    if printf '%s\n' "$names" | grep -qx "$base"; then
      echo "alias $alias collides with agents/$base.md" >&2
      return 1
    fi
  done <<< "$(matrix_rows | awk '{print $1}')"
}

@test "grants: the architect keeps a bare Agent grant, no literal dev-plugin grants" {
  # AR consults rarely (§ Consult Gate) and any plugin's architect may be an override target.
  local tools
  tools="$(grep -E '^tools:' "$PLUGIN_ROOT/agents/software-architector.md")"
  printf '%s\n' "$tools" | grep -qE '(^tools:|,)[[:space:]]*Agent([[:space:]]*(,|$))' \
    || { echo "software-architector.md: no bare Agent grant" >&2; return 1; }
  if printf '%s\n' "$tools" | grep -qE 'Agent\([a-z-]+:'; then
    echo "software-architector.md: literal Agent(plugin:agent) grant remains" >&2
    return 1
  fi
}

# DV, SR and QA run long Opus/Sonnet contexts, where a bare Agent grant loads the whole agent
# directory into every turn; they list their targets instead. The list must cover every matrix
# default for the role, or a default dispatch would be refused.
grant_covers() {
  local f="$1" alias="$2" target tools
  tools="$(grep -E '^tools:' "$(contract_source "$PLUGIN_ROOT/$f")")"
  target="$(matrix_target "$alias")"
  [ -n "$target" ] || { echo "no matrix target for corpflow:$alias" >&2; return 1; }
  printf '%s\n' "$tools" | grep -qF "Agent($target)" \
    || { echo "$f: Agent($target) (corpflow:$alias) not granted" >&2; return 1; }
}

@test "grants: DV, SR and QA list every matrix default for their role, no bare Agent" {
  local f p
  for f in agents/developer.md agents/security-reviewer.md agents/qa-engineer.md; do
    if grep -E '^tools:' "$(contract_source "$PLUGIN_ROOT/$f")" | grep -qE '(^tools:|,)[[:space:]]*Agent([[:space:]]*(,|$))'; then
      echo "$f: bare Agent grant" >&2; return 1
    fi
  done
  for p in $DEV_PLUGINS; do grant_covers agents/developer.md "$p"; done
  for p in $PLATFORMS; do
    grant_covers agents/security-reviewer.md "$p-security-auditor"
    grant_covers agents/qa-engineer.md "$p-test-generator"
  done
  for p in apple android; do grant_covers agents/qa-engineer.md "$p-ui-verifier"; done
}

@test "grants: the coverage check fails on a dropped target (twin)" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/agents" "$root/$(dirname "$MATRIX")"
  cp "$PLUGIN_ROOT/$MATRIX" "$root/$MATRIX"
  sed 's/Agent(ai-engineer:ai-engineer), //' "$PLUGIN_ROOT/agents/developer.md" > "$root/agents/developer.md"
  PLUGIN_ROOT="$root" run grant_covers agents/developer.md ai-engineer
  assert_failure
  PLUGIN_ROOT="$root" run grant_covers agents/developer.md apple-developer
  assert_success
}

@test "grants: /worktask carries a bare Agent grant, since a stage row may name any plugin's agent" {
  local tools
  tools="$(grep -E '^allowed-tools:' "$PLUGIN_ROOT/skills/worktask/SKILL.md")"
  [ -n "$tools" ] || { echo "skills/worktask/references/workflow.md: no allowed-tools line" >&2; return 1; }
  printf '%s\n' "$tools" | grep -qE '(^allowed-tools:|,)[[:space:]]*Agent([[:space:]]*(,|$))' \
    || { echo "skills/worktask/references/workflow.md: no bare Agent grant" >&2; return 1; }
  if printf '%s\n' "$tools" | grep -qE 'Agent\([a-z-]+:'; then
    echo "skills/worktask/references/workflow.md: literal Agent(plugin:agent) grant remains" >&2
    return 1
  fi
}

@test "copy: developer.md common-rows table matches matrix entry targets" {
  local p target row
  for p in $DEV_PLUGINS; do
    target="$(matrix_target "$p")"
    row="$(grep -E "^\| (apple|android|web|systems|backend|ai) \| \`$target\`" "$PLUGIN_ROOT/agents/developer.md" || true)"
    [ -n "$row" ] || { echo "developer.md common rows missing $target" >&2; return 1; }
  done
}

@test "copy: software-architector.md architect table matches matrix" {
  local p target
  for p in $PLATFORMS; do
    target="$(matrix_target "${p}-architect")"
    grep -qE "^\| $p \| \`$target\`" "$PLUGIN_ROOT/agents/software-architector.md" \
      || { echo "software-architector.md row for $p != $target" >&2; return 1; }
  done
}

@test "copy: security-reviewer.md auditor subsections match matrix" {
  local p target
  for p in $PLATFORMS; do
    target="$(matrix_target "${p}-security-auditor")"
    grep -qF "#### $p — \`$target\`" "$PLUGIN_ROOT/agents/security-reviewer.md" \
      || { echo "security-reviewer.md subsection for $p != $target" >&2; return 1; }
  done
}

@test "copy: qa-engineer.md test-generator list matches matrix" {
  local p target
  for p in $PLATFORMS; do
    target="$(matrix_target "${p}-test-generator")"
    grep -qF "$p → \`$target\`" "$PLUGIN_ROOT/agents/qa-engineer.md" \
      || { echo "qa-engineer.md entry for $p != $target" >&2; return 1; }
  done
}

@test "copy: qa-engineer.md ui-verifier table matches matrix rows" {
  # The QA copy is the whole table row, not just the target, so the Platform
  # column cannot drift either. Non-empty guard: two empty greps compare equal.
  # Backticks are literal markdown code spans, not command substitution.
  # shellcheck disable=SC2016
  local pattern='^\| `corpflow:[a-z]+-ui-verifier` \|' matrix qa
  matrix="$(grep -E "$pattern" "$PLUGIN_ROOT/$MATRIX")"
  qa="$(grep -E "$pattern" "$PLUGIN_ROOT/agents/qa-engineer.md")"
  [ -n "$matrix" ] || { echo "no ui-verifier rows in $MATRIX" >&2; return 1; }
  [ "$qa" = "$matrix" ] \
    || { printf 'qa-engineer.md rows:\n%s\nmatrix rows:\n%s\n' "$qa" "$matrix" >&2; return 1; }
}

@test "copy: plugin-protocols.md role cells match matrix basenames" {
  # The protocols tables carry unqualified agent names per plugin section; the
  # stale-android-names drift lived exactly here. Check each plugin's section
  # names the matrix basename in its DR/SR/QA rows (AR row for the architect).
  local protocols="$PLUGIN_ROOT/skills/cross-plugin-handoff/references/plugin-protocols.md"
  local p plat target base section
  set -- $PLATFORMS
  for p in $DEV_PLUGINS; do
    plat="$1"; shift
    # Section text: from this plugin's H2 to the next H2.
    section="$(awk -v h="## $p Plugin" '
      $0 == h {on=1; next} on && /^## / {exit} on {print}' "$protocols")"
    [ -n "$section" ] || { echo "no section for $p in plugin-protocols.md" >&2; return 1; }
    for role in architect:AR security-auditor:SR test-generator:QA code-fixer:DR; do
      target="$(matrix_target "${plat}-${role%%:*}")"
      base="${target##*:}"
      printf '%s\n' "$section" | grep -qE "^\| ${role##*:}[a-z-]* \| ${base}( |$)" \
        || { echo "plugin-protocols.md $p ${role##*:} row != $base" >&2; return 1; }
    done
  done
}

@test "lockstep: matrix dev-plugin set equals cross-plugin-refs SIBLINGS and the publish regex" {
  local matrix_plugins siblings p
  matrix_plugins="$(matrix_rows | awk '{print $2}' | cut -d: -f1 | sort -u \
    | grep -v -e debugging-toolkit -e security-scanning)"
  siblings="$(printf '%s\n' $DEV_PLUGINS | sort)"
  [ "$matrix_plugins" = "$siblings" ] \
    || { printf 'matrix plugins:\n%s\nexpected:\n%s\n' "$matrix_plugins" "$siblings" >&2; return 1; }
  # The publish-pl-issue alternation must contain every matrix dev plugin
  # (full lockstep with the support list is asserted in cross-plugin-refs.bats).
  for p in $DEV_PLUGINS; do
    grep -q "|$p|" "$PLUGIN_ROOT/skills/worktask/scripts/publish-pl-issue-lib.sh" \
      || { echo "$p missing from publish-pl-issue-lib.sh alternation" >&2; return 1; }
  done
}
