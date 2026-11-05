#!/usr/bin/env bats
# Contract test for skill references in agents/ and commands/ — the sibling of
# cross-plugin-refs.bats, for references that stay inside this plugin.
#
# Caught in practice, from the first paired live run's stage transcripts:
#   - agents/developer.md ordered `Skill("dv-screenshot-capture")` while its
#     `tools:` omitted Skill. The DV stage made zero Skill calls and hand-wrote
#     its own capture script three times, reimplementing the adapter chain
#     skills/dv-screenshot-capture already ships.
#   - agents/stakeholder.md ordered `Skill("self-improvement")` with the same
#     omission, so the mandatory ST retrospective silently never ran.
#   - agents/technical-lead.md called `Skill("dev-code-review")`, which names a
#     command; skills/dev-code-review/ does not exist and never did. Historical:
#     both that call and the command are gone — the command is now
#     commands/tech-code-review.md and the callers name the file, not a skill.
# Every one of these passed the whole suite. Nothing read a `tools:` line
# against the body that depended on it.
#
# The predicates are expressed over each occurrence rather than as a frozen file
# list, for the reason plugin-root-refs.bats states: a list goes red on any doc
# edit without the protected property regressing. Each is driven here against a
# synthetic tree that plants the violation, so the checker itself is falsifiable.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

# A `Skill(` inside a markdown table cell is reference documentation — the
# worktask entry-point row in agents/workflow-engineer.md is the standing case.
# Outside a table it is an instruction the agent must be able to carry out.
_imperative_skill_lines() {
  grep -n 'Skill(' "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*\|' || true
}

_grants_skill() {
  awk '/^tools:/{print; exit}' "$1" | grep -qE '(^|[ ,:])Skill([ ,]|$)'
}

# ungranted_skill_calls <plugin-root>
# One line per agent that orders a Skill call its `tools:` cannot serve.
ungranted_skill_calls() {
  local root="$1" f
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'agents/*.md'); do
      [ -n "$(_imperative_skill_lines "$f")" ] || continue
      _grants_skill "$f" || printf '%s\n' "$f"
    done
    return 0 )
}

# Emit every skill name named by a `Skill(...)` call, plugin prefix stripped.
# Only the FIRST quoted argument is the target -- later ones are call arguments
# (`platform="apple"`), and reading them as targets is a false positive. Template
# metavariables (`<command>`, `${embedded_cmd}`) are placeholders, not targets.
# skills/ is in the glob because the defect that motivated this file lived there:
# skills/worktask/references/orchestration.md ordered a skill that does not exist, and a collector
# scoped to agents/ + commands/ silently no-opped on it.
collect_skill_targets() {
  ( cd "$1" || return 1
    git ls-files -z -- 'agents/*.md' 'commands/*.md' 'skills/**/*.md' \
      | xargs -0 grep -hoE 'Skill\(\{?[^)]*' 2>/dev/null \
      | sed -nE 's/[^"]*"([^"]+)".*/\1/p' \
      | sed -E 's/^[a-z][a-z0-9-]*://' \
      | grep -v '[<>${}]' \
      | LC_ALL=C sort -u )
}

# dangling_skill_targets <plugin-root> — targets with no skills/<name>/ directory.
dangling_skill_targets() {
  local root="$1" s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -d "$root/skills/$s" ] || printf '%s\n' "$s"
  done <<< "$(collect_skill_targets "$root")"
  return 0
}

# Emit every `skills/<name>/…` path cited in agents/ or commands/, trailing
# sentence punctuation stripped.
collect_skill_paths() {
  ( cd "$1" || return 1
    git ls-files -z -- 'agents/*.md' 'commands/*.md' \
      | xargs -0 grep -hoE 'skills/[a-z0-9-]+/[A-Za-z0-9._/-]+' 2>/dev/null \
      | sed -E 's/[.,;:]+$//' \
      | LC_ALL=C sort -u )
}

# dangling_skill_paths <plugin-root> — cited paths that are neither file nor dir.
dangling_skill_paths() {
  local root="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || printf '%s\n' "$p"
  done <<< "$(collect_skill_paths "$root")"
  return 0
}

# missing_paths_block <plugin-root>
# An agent citing a plugin-root-relative path without saying what that path is
# relative to sends the model hunting: PL spent 14 of its 17 Bash calls in the
# live run locating plugin files, one of them a `find /`. The block under
# `## Plugin paths` must point at the canonical ladder, so the resolution rule
# lives in one file instead of drifting across per-agent copies.
missing_paths_block() {
  local root="$1" f
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'agents/*.md'); do
      grep -qE 'skills/[a-z0-9-]+/' "$f" || continue
      awk '/^## Plugin paths$/{p=1; next} p && /^## /{exit} p' "$f" \
        | grep -qF 'skills/shared/plugin-root-resolution.md' || printf '%s\n' "$f"
    done
    return 0 )
}

# --- state-patch executability ------------------------------------------------
# The same defect class as the ungranted Skill calls above, found the same way: ten
# agents were told to run `state-patch.sh` while holding no `bash` grant, so every
# one of them silently skipped its ledger patch. An agent satisfies this predicate
# by holding a grant that can execute the tool OR by documenting the Edit-direct
# fallback it *can* execute -- an instruction it cannot carry out either way is the
# violation.

_orders_state_patch() {
  grep -qE '^Run `(bash \$\{CLAUDE_PLUGIN_ROOT\}/skills/worktask/scripts/state-patch\.sh|state-patch\.sh)' "$1" 2>/dev/null
}

_grants_state_patch() {
  local tools
  tools="$(awk '/^tools:/{print; exit}' "$1")"
  printf '%s' "$tools" | grep -qE '(^|[ ,:])Bash([ ,]|$)' && return 0
  printf '%s' "$tools" | grep -qE 'Bash\(bash (\$\{CLAUDE_PLUGIN_ROOT\}/)?skills/worktask/scripts/state-patch\.sh[ :]'
}

_documents_state_patch_fallback() {
  # The fallback is only real if the agent can also execute IT.
  grep -qF 'patch `.context/state.json` yourself with `Edit`' "$1" 2>/dev/null \
    && awk '/^tools:/{print; exit}' "$1" | grep -qE '(^|[ ,:])Edit([ ,]|$)'
}

# unexecutable_state_patch_orders <plugin-root>
# One line per agent ordered to run the patch tool with neither a usable grant nor
# an executable documented alternative.
unexecutable_state_patch_orders() {
  local root="$1" f
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'agents/*.md'); do
      _orders_state_patch "$f" || continue
      _grants_state_patch "$f" && continue
      _documents_state_patch_fallback "$f" && continue
      printf '%s\n' "$f"
    done
    return 0 )
}

# --- path-scoped Bash grants --------------------------------------------------
# A grant like `Bash(bash skills/foo/scripts/bar.sh:*)` names a file by path. When
# that file moves or is deleted the grant does not error -- it simply never matches,
# so the agent silently loses the capability. Nothing else in the suite reads these
# paths against the filesystem.

# Emit every plugin-root-relative script path named inside a `Bash(...)` grant on a
# `tools:` or `allowed-tools:` line.
collect_bash_grant_paths() {
  ( cd "$1" || return 1
    git ls-files -z -- 'agents/*.md' 'commands/*.md' \
      | xargs -0 grep -hE '^(tools|allowed-tools):' 2>/dev/null \
      | grep -oE 'Bash\([^)]*\)' \
      | grep -oE '(agents|commands|hooks|skills|tests)/[A-Za-z0-9._/-]+\.(sh|py)' \
      | LC_ALL=C sort -u )
}

# dangling_bash_grant_paths <plugin-root> — granted paths with no file behind them.
dangling_bash_grant_paths() {
  local root="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$root/$p" ] || printf '%s\n' "$p"
  done <<< "$(collect_bash_grant_paths "$root")"
  return 0
}

# A plugin tree that satisfies every predicate; prints its root.
mk_skill_layout() {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'agents/developer.md:---\ntools: Read, Skill, Bash\n---\n\n## Plugin paths\n\nPaths are plugin-root-relative; resolve per `skills/shared/plugin-root-resolution.md`.\n\n## Body\n\nRun `Skill({skill: "corpflow:capture"})`; canon in `skills/capture/SKILL.md`.\n' \
    --file 'agents/router.md:---\ntools: Read\n---\n\n| Entry | `Skill({skill:"corpflow:capture"})` |\n' \
    --file 'skills/capture/SKILL.md:x\n' \
    --file 'skills/shared/plugin-root-resolution.md:x\n' >/dev/null
  printf '%s\n' "$root"
}

# --- predicate behaviour (always runs) ---------------------------------------

@test "resolver: a well-formed tree trips no predicate" {
  local root
  root="$(mk_skill_layout)"
  run ungranted_skill_calls "$root"; assert_output ""
  run dangling_skill_targets "$root"; assert_output ""
  run dangling_skill_paths "$root"; assert_output ""
  run missing_paths_block "$root"; assert_output ""
}

@test "resolver: an ordered Skill call without the grant is named" {
  local root
  root="$(mk_skill_layout)"
  # Drop the grant, leaving the body's instruction in place.
  printf -- '---\ntools: Read, Bash\n---\n\n## Plugin paths\n\nx\n\n`Skill({skill: "corpflow:capture"})`\n' \
    > "$root/agents/developer.md"
  run ungranted_skill_calls "$root"
  assert_output --partial "agents/developer.md"
}

@test "resolver: a documentation-only Skill mention in a table needs no grant" {
  local root
  root="$(mk_skill_layout)"
  run ungranted_skill_calls "$root"
  refute_output --partial "agents/router.md"
}

@test "resolver: a Skill target with no skills/<name>/ directory is named" {
  local root
  root="$(mk_skill_layout)"
  rm -rf "$root/skills/capture"
  run dangling_skill_targets "$root"
  assert_output --partial "capture"
}

@test "resolver: a Skill target naming a command, not a skill, is named" {
  # The live defect, since fixed: `Skill("dev-code-review")` against a file that
  # was only ever commands/dev-code-review.md. Driven against a synthetic tree,
  # so the name below describes the fixture, not anything at HEAD.
  local root
  root="$(mk_skill_layout)"
  mkdir -p "$root/commands"; : > "$root/commands/code-review.md"
  printf -- '---\ntools: Read, Skill\n---\n\n## Plugin paths\n\nx\n\n`Skill("code-review")`\n' \
    > "$root/agents/developer.md"
  run dangling_skill_targets "$root"
  assert_output --partial "code-review"
}

@test "resolver: a dangling skills/<name>/… path citation is named" {
  local root
  root="$(mk_skill_layout)"
  rm -f "$root/skills/capture/SKILL.md"
  run dangling_skill_paths "$root"
  assert_output --partial "skills/capture/SKILL.md"
}

@test "resolver: an agent citing plugin paths without the block is named" {
  local root
  root="$(mk_skill_layout)"
  printf -- '---\ntools: Read, Skill\n---\n\n## Body\n\nCanon in `skills/capture/SKILL.md`.\n' \
    > "$root/agents/developer.md"
  run missing_paths_block "$root"
  assert_output --partial "agents/developer.md"
}

@test "resolver: a Plugin paths block that skips the canonical ladder is named" {
  local root
  root="$(mk_skill_layout)"
  printf -- '---\ntools: Read\n---\n\n## Plugin paths\n\nPaths are plugin-root-relative.\n\n## Body\n\nCanon in `skills/capture/SKILL.md`; ladder in `skills/shared/plugin-root-resolution.md`.\n' \
    > "$root/agents/developer.md"
  run missing_paths_block "$root"
  assert_output --partial "agents/developer.md"
}

# --- this repo (always runs) -------------------------------------------------

@test "contract: every ordered Skill call in this repo has its grant" {
  run ungranted_skill_calls "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: every Skill target in this repo names a real skill" {
  local targets
  # Guard the collector: this plugin genuinely invokes skills, so an empty set
  # means the pattern regressed rather than that the repo became clean.
  targets="$(collect_skill_targets "$PLUGIN_ROOT")"
  [ -n "$targets" ]
  run dangling_skill_targets "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: every skills/<name>/… citation in this repo resolves" {
  local paths
  paths="$(collect_skill_paths "$PLUGIN_ROOT")"
  [ -n "$paths" ]
  run dangling_skill_paths "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: every agent citing plugin paths carries the resolution pointer" {
  run missing_paths_block "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: no agent in this repo is ordered to run state-patch.sh it cannot execute" {
  # Guard the collector before asserting emptiness: 13 agents order this tool, so a
  # zero-sized candidate set means the matcher regressed, not that the repo is clean.
  local ordering
  ordering="$(cd "$PLUGIN_ROOT" && for f in $(git ls-files -- 'agents/*.md'); do
    _orders_state_patch "$f" && printf '%s\n' "$f"; done || true)"
  [ "$(printf '%s\n' "$ordering" | grep -c .)" -ge 13 ]
  run unexecutable_state_patch_orders "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: every path-scoped Bash grant in this repo names a real file" {
  # Guard the collector first: this plugin genuinely ships path-scoped grants, so an
  # empty candidate set means the matcher regressed, not that the repo went clean.
  local granted
  granted="$(collect_bash_grant_paths "$PLUGIN_ROOT")"
  [ -n "$granted" ]
  run dangling_bash_grant_paths "$PLUGIN_ROOT"
  assert_output ""
}

@test "resolver: a path-scoped Bash grant naming a missing file is named" {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'agents/live.md:---\ntools: Read, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *)\n---\n\nx\n' \
    --file 'commands/moved.md:---\nallowed-tools: Read, Bash(skills/gone/scripts/vanished.sh)\n---\n\nx\n' \
    --file 'skills/worktask/scripts/state-patch.sh:#!/usr/bin/env bash\n' \
    >/dev/null
  run dangling_bash_grant_paths "$root"
  assert_output --partial "skills/gone/scripts/vanished.sh"
  refute_output --partial "state-patch.sh"
}

@test "resolver: an agent ordered to patch state with neither grant nor fallback is named" {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'agents/blocked.md:---\ntools: Read, Write\n---\n\nRun `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage AR --prev PL`.\n' \
    --file 'agents/granted.md:---\ntools: Read, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *)\n---\n\nRun `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage DC --prev QA`.\n' \
    --file 'agents/fallback.md:---\ntools: Read, Edit\n---\n\nRun `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage ST --prev FN`; if it cannot run, patch `.context/state.json` yourself with `Edit`.\n' \
    >/dev/null
  run unexecutable_state_patch_orders "$root"
  assert_output --partial "agents/blocked.md"
  refute_output --partial "agents/granted.md"
  refute_output --partial "agents/fallback.md"
}

# --- ordered scripts vs. their grants ----------------------------------------
# The sibling defect of the ungranted Skill calls above, one layer down: a body
# orders `bash skills/<x>/scripts/<y>.sh` while the file's grant line names neither
# that path nor bare Bash, so the order is unexecutable and silently skipped. Five
# worktask scripts and three megatask scripts shipped that way.
#
# `hooks/*.sh` is deliberately out of scope: hook scripts are dispatched by the
# runtime from .claude-plugin/plugin.json, never ordered by a body, so a hooks/ path
# in prose is documentation by construction.

# Emit every skills/… script path this file *orders*, one per line. Three forms
# count as an order; a path in a table cell, a blockquote, or plain prose does not,
# and a directory-less basename is out of reach of any path-scoped grant anyway.
_ordered_script_paths() {
  awk '
    function is_interp(t) { return (t == "bash" || t == "sh" || t == "source" || t == ".") }
    { line = $0 }
    line ~ /^[[:space:]]*```/ { infence = !infence; next }
    line ~ /^[[:space:]]*\|/  { next }
    line ~ /^[[:space:]]*>/   { next }
    {
      code = (infence || line ~ /^    [^[:space:]]/)
      rest = line
      while (match(rest, /skills\/[a-z0-9-]+\/[A-Za-z0-9._\/-]+\.sh/)) {
        path = substr(rest, RSTART, RLENGTH)
        pre  = substr(rest, 1, RSTART - 1)
        rest = substr(rest, RSTART + RLENGTH)
        order = 0
        # F3 variable-rooted: building "$VAR/skills/…" has no purpose but execution.
        if (pre ~ /\$[A-Za-z_][A-Za-z0-9_]*\/$/ || pre ~ /\$\{[A-Za-z_][A-Za-z0-9_]*\}\/$/) order = 1
        # F1 interpreter-prefixed: nearest preceding word token, backticks, quotes
        # and "$(" acting as separators rather than tokens.
        if (!order) {
          n = split(pre, tok, /[^A-Za-z0-9._\/-]+/)
          for (i = n; i >= 1; i--) if (tok[i] != "") { if (is_interp(tolower(tok[i]))) order = 1; break }
        }
        # F2 code-position: first token of a line inside a code block, after the
        # control and assignment prefixes that can legally precede a command.
        if (!order && code) {
          head = line
          sub(/^[[:space:]]+/, "", head)
          changed = 1
          while (changed) {
            changed = 0
            if (sub(/^[^A-Za-z0-9._$\/-]+/, "", head)) changed = 1
            if (sub(/^\$\(/, "", head)) changed = 1
            if (sub(/^(if|then|else)[[:space:]]+/, "", head)) changed = 1
            if (sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", head)) changed = 1
          }
          if (index(head, path) == 1) order = 1
        }
        if (order) print path
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

_grant_line() {
  awk 'NR > 1 && /^---[[:space:]]*$/ { exit } /^(tools|allowed-tools):/ { print }' "$1"
}

# ungranted_script_orders <plugin-root>
# One `<file> -> <path>` row per ordered script the file's grant line cannot execute.
ungranted_script_orders() {
  local root="$1" f grants p
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'agents/*.md' 'commands/*.md'); do
      grants="$(_grant_line "$f")"
      # E1: an unrestricted execution grant serves every order in the file.
      printf '%s' "$grants" | grep -qE '(^|[ ,:])Bash([ ,]|$)' && continue
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # E2: agents ordering the ledger patcher are owned by
        # unexecutable_state_patch_orders, whose Edit-direct fallback exemption
        # would be contradicted by a second row here.
        if [ "$p" = "skills/worktask/scripts/state-patch.sh" ]; then
          case "$f" in agents/*) continue ;; esac
        fi
        case "$grants" in *"$p"*) continue ;; esac
        printf '%s -> %s\n' "$f" "$p"
      done <<< "$(_ordered_script_paths "$f")"
    done
    return 0 )
}

# --- related: entries that resolve to nothing --------------------------------
# A `related:` entry is a reading order for the next agent. Seven entries across two
# skills named a bare basename that resolves against no root at all, so the reading
# order silently pointed nowhere.

# Entries live in the FRONTMATTER only: an unterminated extraction reads body bullet
# lists as entries and reports ~120 false positives.
_related_entries() {
  awk 'NR > 1 && /^---[[:space:]]*$/ { exit }
       /^related:/ { flag = 1; next }
       flag && /^[a-zA-Z_-]+:/ { exit }
       flag && /^[[:space:]]*-[[:space:]]/ { print }' "$1" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/^"//; s/"$//'
}

@test "contract: standalone command dependencies use public entry points" {
  local entries
  entries="$(_related_entries "$PLUGIN_ROOT/commands/test-plan.md")"
  [[ "$entries" != *skills/worktask/* ]]
  entries="$(_related_entries "$PLUGIN_ROOT/commands/milestone.md")"
  [[ "$entries" != *skills/worktask/* ]]
  [[ "$entries" == *commands/megatask.md* ]]
  entries="$(_related_entries "$PLUGIN_ROOT/commands/request-plan.md")"
  [[ "$entries" != *skills/worktask/references/* ]]
  [[ "$entries" == *skills/worktask/SKILL.md* ]]
}

@test "contract: optimize-command examples target command definitions" {
  local examples path count=0
  examples="$(awk '/^## Examples$/ {inside=1; next} inside && /^## / {exit} inside {print}' \
    "$PLUGIN_ROOT/commands/optimize-command.md")"
  while IFS= read -r path; do
    [[ "$path" == commands/*.md ]]
    [ -f "$PLUGIN_ROOT/$path" ]
    count=$((count + 1))
  done < <(printf '%s\n' "$examples" | awk '$1 == "/optimize-command" && $2 !~ /^(<|--)/ {print $2}')
  [ "$count" -ge 3 ]
}

@test "contract: cc-update command samples resolve to command definitions" {
  local name count=0
  while IFS= read -r name; do
    [ -f "$PLUGIN_ROOT/commands/$name.md" ]
    count=$((count + 1))
  done < <(grep -oE -- '--command [a-z][a-z-]+' "$PLUGIN_ROOT/commands/cc-update.md" | awk '{print $2}')
  [ "$count" -ge 1 ]
  run grep -F 'command file basename (e.g. `prompt-audit`)' "$PLUGIN_ROOT/commands/cc-update.md"
  assert_success
}

@test "contract: create-agent reserves handoff protocols for stage owners" {
  local file="$PLUGIN_ROOT/commands/create-agent.md"
  run grep -E '^\| Worktask Integration \|' "$file"
  assert_failure
  run grep -F '### Handoff Protocol (stage owners only)' "$file"
  assert_success
  run grep -F 'Do not add this section to a support agent:' "$file"
  assert_success
  run grep -F 'it carries a DV-scoped Handoff Protocol gated on that mode.' "$file"
  assert_success
}

@test "contract: prompt-audit retains planning rules without the stale disclosure example" {
  local file="$PLUGIN_ROOT/commands/prompt-audit.md"
  run grep -F 'Orchestrator Execution Loop' "$file"
  assert_failure
  run grep -F '### Planning-Stage Rules' "$file"
  assert_success
  run grep -F 'skills/worktask/references/pl0-procedure.md' "$file"
  assert_success
}

# dangling_related_targets <plugin-root>
# One `<file> -> <entry>` row per entry resolving neither file-relative nor from the
# plugin root. Agents carry no related: block today; the predicate is vacuous there
# by design, so an agent that grows one is covered without a scope edit.
dangling_related_targets() {
  local root="$1" f d e p
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'skills/*/SKILL.md' 'skills/*/*/SKILL.md' 'agents/*.md' 'commands/*.md'); do
      d="$(dirname "$f")"
      while IFS= read -r e; do
        case "$e" in ''|http*|\$*) continue ;; esac
        p="${e%%#*}"
        { [ -e "$d/$p" ] || [ -e "$p" ]; } || printf '%s -> %s\n' "$f" "$e"
      done <<< "$(_related_entries "$f")"
    done
    return 0 )
}

# A tree whose every script order is granted; prints its root. The negative controls
# are inline: a table-cell citation, a prose citation, and a hooks/ path.
mk_script_order_layout() {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'commands/run.md:---\nallowed-tools: Read, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/patch.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/rank.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed.sh *)\n---\n\nRun `bash skills/worktask/scripts/patch.sh --stage DV`.\n\n```bash\nskills/worktask/scripts/rank.sh --goal x\n```\n\nHELPER="$PLUGIN_ROOT/skills/worktask/scripts/seed.sh"\n\n| Script | `skills/worktask/scripts/audit.sh` |\n\nReachability is described in `skills/worktask/scripts/audit.sh`.\n\nThe runtime dispatches `bash hooks/state-merge.sh` itself.\n' \
    --file 'agents/free.md:---\ntools: Read, Bash\n---\n\nRun `bash skills/worktask/scripts/audit.sh --all`.\n' \
    --file 'skills/worktask/scripts/patch.sh:#!/usr/bin/env bash\n' \
    --file 'skills/worktask/scripts/rank.sh:#!/usr/bin/env bash\n' \
    --file 'skills/worktask/scripts/seed.sh:#!/usr/bin/env bash\n' \
    --file 'skills/worktask/scripts/audit.sh:#!/usr/bin/env bash\n' >/dev/null
  printf '%s\n' "$root"
}

# A tree whose every related: entry resolves; prints its root. The negative control
# is a body bullet list that looks exactly like a frontmatter entry.
mk_related_layout() {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'skills/alpha/SKILL.md:---\nname: alpha\nrelated:\n  - ../beta/SKILL.md\n  - commands/go.md\n  - references/notes.md#anchor\nversion: 1\n---\n\n## Body\n\n  - nowhere.md\n  - also-nowhere.md\n' \
    --file 'skills/alpha/references/notes.md:x\n' \
    --file 'skills/beta/SKILL.md:---\nname: beta\n---\n\nx\n' \
    --file 'commands/go.md:---\nallowed-tools: Read\n---\n\nx\n' >/dev/null
  printf '%s\n' "$root"
}

# --- predicate behaviour: ordered scripts (always runs) ----------------------

@test "resolver: a well-formed script-order tree trips no predicate" {
  local root
  root="$(mk_script_order_layout)"
  run ungranted_script_orders "$root"
  assert_output ""
}

@test "resolver: an ordered bash skills/… script with no matching grant is named" {
  local root
  root="$(mk_script_order_layout)"
  sed -i.bak 's|, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/patch.sh \*)||' "$root/commands/run.md"
  run ungranted_script_orders "$root"
  assert_output "commands/run.md -> skills/worktask/scripts/patch.sh"
}

@test "resolver: an interpreter-less skills/… order in a code block with no grant is named" {
  local root
  root="$(mk_script_order_layout)"
  sed -i.bak 's|, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/rank.sh \*)||' "$root/commands/run.md"
  run ungranted_script_orders "$root"
  assert_output "commands/run.md -> skills/worktask/scripts/rank.sh"
}

@test "resolver: a \$PLUGIN_ROOT-rooted script order with no grant is named" {
  local root
  root="$(mk_script_order_layout)"
  sed -i.bak 's|, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed.sh \*)||' "$root/commands/run.md"
  run ungranted_script_orders "$root"
  assert_output "commands/run.md -> skills/worktask/scripts/seed.sh"
}

@test "resolver: a script path cited in prose or a table needs no grant" {
  # audit.sh appears in commands/run.md twice -- once in a table cell, once in a
  # sentence about reachability -- and is granted nowhere in that file.
  local root
  root="$(mk_script_order_layout)"
  run ungranted_script_orders "$root"
  refute_output --partial "audit.sh"
}

@test "resolver: a bare Bash grant exempts the file from the script-order predicate" {
  local root
  root="$(mk_script_order_layout)"
  run ungranted_script_orders "$root"
  refute_output --partial "agents/free.md"
}

@test "resolver: a hooks/ script path in a body needs no grant" {
  local root
  root="$(mk_script_order_layout)"
  run ungranted_script_orders "$root"
  refute_output --partial "hooks/"
}

# --- predicate behaviour: related: targets (always runs) ---------------------

@test "resolver: a well-formed related: tree trips no predicate" {
  local root
  root="$(mk_related_layout)"
  run dangling_related_targets "$root"
  assert_output ""
}

@test "resolver: a related: entry resolving to no file is named" {
  local root
  root="$(mk_related_layout)"
  sed -i.bak 's|  - ../beta/SKILL.md|  - beta.md|' "$root/skills/alpha/SKILL.md"
  run dangling_related_targets "$root"
  assert_output "skills/alpha/SKILL.md -> beta.md"
}

@test "resolver: a related: entry resolved file-relative needs no repo-root twin" {
  # ../beta/SKILL.md exists only relative to skills/alpha/, never from the root.
  local root
  root="$(mk_related_layout)"
  run dangling_related_targets "$root"
  refute_output --partial "beta"
}

@test "resolver: a related: entry with a #anchor suffix resolves to its file" {
  local root
  root="$(mk_related_layout)"
  run dangling_related_targets "$root"
  refute_output --partial "notes.md"
}

@test "resolver: a body bullet outside the frontmatter is not a related: entry" {
  local root
  root="$(mk_related_layout)"
  run dangling_related_targets "$root"
  refute_output --partial "nowhere.md"
}

# --- this repo (always runs) -------------------------------------------------

@test "contract: every script this repo orders is covered by its file's grant" {
  # Guard the collector before asserting emptiness: this plugin genuinely orders
  # scripts from its bodies, so an empty candidate set means the three order forms
  # regressed, not that the repo went clean.
  local ordered
  ordered="$(cd "$PLUGIN_ROOT" && for f in $(git ls-files -- 'agents/*.md' 'commands/*.md'); do
    _ordered_script_paths "$f"; done)"
  [ "$(printf '%s\n' "$ordered" | grep -c .)" -ge 10 ]
  run ungranted_script_orders "$PLUGIN_ROOT"
  assert_output ""
}

@test "contract: every related: entry in this repo resolves to a file" {
  local entries
  entries="$(cd "$PLUGIN_ROOT" && for f in $(git ls-files -- 'skills/*/SKILL.md' 'skills/*/*/SKILL.md'); do
    _related_entries "$f"; done)"
  [ "$(printf '%s\n' "$entries" | grep -c .)" -ge 10 ]
  run dangling_related_targets "$PLUGIN_ROOT"
  assert_output ""
}

# --- frontmatter validity and user-invoked targets -------------------------------

# A plain YAML scalar cannot carry `: ` or end in `:`. Such a value makes the whole
# frontmatter unparseable, and the loader then drops the file without an error, so
# the skill or agent silently disappears. Quoted, block (`|`, `>`) and flow values
# are exempt because YAML allows the colon inside them.
unquoted_frontmatter_colons() {
  local f
  ( cd "$1" || return 1
    for f in $(git ls-files -- 'agents/*.md' 'commands/*.md' 'skills/*/SKILL.md' 'skills/*/*/SKILL.md'); do
      awk -v f="$f" '
        NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
        /^---[[:space:]]*$/ { exit }
        /^[A-Za-z0-9_-]+:[[:space:]]/ {
          v = $0; sub(/^[A-Za-z0-9_-]+:[[:space:]]+/, "", v)
          if (v ~ /^["\047|>\[{]/) next
          if (index(v, ": ") || v ~ /:[[:space:]]*$/) print f ":" NR ": " $1
        }' "$f"
    done
    return 0 )
}

# Names a skill answers to when its frontmatter sets disable-model-invocation: true:
# the frontmatter `name` and the directory basename.
user_invoked_skills() {
  local f
  ( cd "$1" || return 1
    for f in $(git ls-files -- 'skills/*/SKILL.md' 'skills/*/*/SKILL.md'); do
      awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
           /^---[[:space:]]*$/ { exit }
           /^disable-model-invocation:[[:space:]]*true[[:space:]]*$/ { hit = 1 }
           /^name:[[:space:]]/ { n = $2; gsub(/["\047]/, "", n) }
           END { if (hit) { if (n != "") print n; exit 0 } exit 1 }' "$f" \
        && basename "$(dirname "$f")"
    done | LC_ALL=C sort -u
    return 0 )
}

# user_invoked_skill_calls <plugin-root>
# One `<file>:<line> -> <skill>` row per imperative Skill() call whose target only a
# user may invoke. The runtime refuses that call, so the instruction can never run.
user_invoked_skill_calls() {
  local root="$1" blocked f l n c t
  blocked="$(user_invoked_skills "$root")"
  [ -n "$blocked" ] || return 0
  ( cd "$root" || return 1
    for f in $(git ls-files -- 'agents/*.md' 'commands/*.md' 'skills/**/*.md'); do
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        n="${l%%:*}"
        while IFS= read -r c; do
          t="$(printf '%s\n' "$c" | sed -nE 's/[^"]*"([^"]+)".*/\1/p' | sed -E 's/^[a-z][a-z0-9-]*://')"
          [ -n "$t" ] && printf '%s\n' "$blocked" | grep -qxF "$t" \
            && printf '%s:%s -> %s\n' "$f" "$n" "$t"
        done <<< "$(printf '%s\n' "${l#*:}" | grep -oE 'Skill\(\{?[^)]*')"
      done <<< "$(_imperative_skill_lines "$f")"
    done
    return 0 )
}

# A tree that trips neither predicate; prints its root. Negative controls: a quoted
# and a folded value carrying `: `, and a table-cell Skill() mention of the
# user-invoked skill.
mk_frontmatter_layout() {
  local root
  root="$(mk_tmpworkdir)"
  mk_git_fixture --dir "$root" \
    --file 'skills/manual/SKILL.md:---\nname: manual\ndescription: "Run by hand: never by a model"\ndisable-model-invocation: true\n---\n\nx\n' \
    --file 'skills/auto/SKILL.md:---\nname: auto\ndescription: >\n  Folded: still valid\n---\n\nx\n' \
    --file 'agents/caller.md:---\nname: caller\ntools: Read, Skill\n---\n\nRun `Skill("corpflow:auto")`.\n\n| Entry | `Skill("manual")` |\n' >/dev/null
  printf '%s\n' "$root"
}

@test "resolver: a well-formed frontmatter tree trips neither predicate" {
  local root
  root="$(mk_frontmatter_layout)"
  run unquoted_frontmatter_colons "$root"; assert_output ""
  run user_invoked_skill_calls "$root"; assert_output ""
}

@test "resolver: an unquoted frontmatter value containing ': ' is named" {
  local root
  root="$(mk_frontmatter_layout)"
  printf -- '---\nname: auto\ndescription: Use when: the user asks\n---\n\nx\n' \
    > "$root/skills/auto/SKILL.md"
  run unquoted_frontmatter_colons "$root"
  assert_output "skills/auto/SKILL.md:3: description:"
}

@test "resolver: an imperative Skill() call into a user-invoked skill is named" {
  local root
  root="$(mk_frontmatter_layout)"
  printf -- '---\nname: caller\ntools: Read, Skill\n---\n\nRun `Skill({skill: "corpflow:manual"})`.\n' \
    > "$root/agents/caller.md"
  run user_invoked_skill_calls "$root"
  assert_output "agents/caller.md:6 -> manual"
}

@test "contract: every top-level frontmatter value in this repo is valid YAML on colons" {
  run unquoted_frontmatter_colons "$PLUGIN_ROOT"
  assert_output ""
}

# Guarded non-vacuous: the repo must hold at least one user-invoked skill, or the
# empty output below proves nothing.
@test "contract: no imperative Skill() call in this repo targets a user-invoked skill" {
  [ -n "$(user_invoked_skills "$PLUGIN_ROOT")" ]
  run user_invoked_skill_calls "$PLUGIN_ROOT"
  assert_output ""
}
