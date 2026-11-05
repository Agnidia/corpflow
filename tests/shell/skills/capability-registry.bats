#!/usr/bin/env bats
# Contract tests for skills/request-plan/scripts/capability-registry.sh
# Contracts (from source):
#   Enumerates commands/*.md, agents/*.md, skills/*/SKILL.md, hooks/*.sh,
#     skills/*/scripts/*.{sh,py} and benchmark/harness/**/*.py (tests excluded),
#     one line each.
#   Line shape: "<path> — <description>", em-dash separated.
#   Description source per class: markdown = frontmatter `description:` ONLY;
#     shell = `@description` when present, else the first comment block after the
#     shebang; python = the module docstring's summary paragraph.
#   A multi-line folded description collapses to one line.
#   An asset with no description is omitted rather than emitted half-formed.
#   tests/, evals/, skills/*/references/ and skills/shared/ are never enumerated —
#     the eval corpus grounds its remaining search cases there.
#   stdout closes with a fixed trailer naming those excluded CLASSES and no file,
#     so the list is not read as a complete inventory of the repo.
#   Runs from any cwd: it resolves the plugin root from BASH_SOURCE.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/request-plan/scripts/capability-registry.sh"

# The registry is a pure function of the tree and every inventory case below asks a
# different question of the SAME output, so it is executed once per file rather than
# once per case. The enumeration walks six globs, a find over benchmark/harness and a
# Python interpreter, so re-running it per case was most of this suite's wall time and
# bought no coverage: ten identical executions can only agree.
#
# Cases that vary the INVOCATION (a different cwd, a mutated tree) still run their own.
setup_file() {
  load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
  REGISTRY_OUT="$BATS_FILE_TMPDIR/registry.out"
  bash "$PLUGIN_ROOT/skills/request-plan/scripts/capability-registry.sh" > "$REGISTRY_OUT"
  export REGISTRY_OUT
}

# Populates $output/$lines/$status from the one capture, in the shape bats' own `run`
# would leave them, so the assertions below are unchanged by the caching.
use_registry() {
  status=0
  output="$(cat "$REGISTRY_OUT")"
  lines=()
  local _l
  while IFS= read -r _l; do lines+=("$_l"); done < "$REGISTRY_OUT"
}

# stdout closes with a fixed trailer naming the excluded CLASSES (never a file).
# It is not an inventory line, so every inventory assertion below is scoped past
# it — otherwise the honesty marker reads as a malformed capability.
TRAILER_PREFIX="## not enumerated"

is_trailer() {
  case "$1" in "${TRAILER_PREFIX}"*) return 0 ;; *) return 1 ;; esac
}

# --- inventory ---------------------------------------------------------------

@test "inventory: emits every asset class, one line each" {
  use_registry
  # Every class must contribute. A single class silently dropping out is the failure
  # that matters here: the skill reads this list INSTEAD of searching, so a missing
  # class is a capability the planner can no longer find at all. A line count alone
  # passes while a whole class emits nothing, so each is asserted separately.
  local class
  for class in 'commands/[^/]+\.md' 'agents/[^/]+\.md' 'skills/[^/]+/SKILL\.md' \
               'hooks/[^/]+\.sh' 'skills/[^/]+/scripts/[^/]+\.sh' \
               'benchmark/harness/.+\.py'; do
    printf '%s\n' "${lines[@]}" | grep -qE "^${class} — ." \
      || fail "no line for class ${class}"
  done
  # Floor sits below the live count with room for churn, and far enough above the
  # markdown-only count that dropping a whole class cannot pass.
  [ "${#lines[@]}" -ge 120 ] || fail "only ${#lines[@]} capabilities listed; expected >= 120"
}

@test "inventory: every line carries a path and an em-dash separated description" {
  use_registry
  local bad=0
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    is_trailer "$l" && continue
    case "$l" in
      *.md\ —\ ?*|*.sh\ —\ ?*|*.py\ —\ ?*) ;;
      *) bad=$((bad + 1)); echo "malformed: $l" >&2 ;;
    esac
  done
  [ "$bad" -eq 0 ] || fail "$bad line(s) not in '<path> — <description>' shape"
}

@test "inventory: every listed path resolves in the tree" {
  use_registry
  local missing=0 p
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    is_trailer "$l" && continue
    p="${l%% — *}"
    [ -f "${PLUGIN_ROOT}/${p}" ] || { missing=$((missing + 1)); echo "unresolved: $p" >&2; }
  done
  [ "$missing" -eq 0 ] || fail "$missing listed path(s) do not exist"
}

@test "inventory: a skill that nests its scripts one level deeper is still listed" {
  # skills/*/scripts/ is a flat glob and skills/shared/milestone-helpers/ is not flat,
  # so this class was silently absent. It is shared CODE, which the shared-canon
  # exclusion below does not cover.
  use_registry
  printf '%s\n' "${lines[@]}" | grep -qE '^skills/[^/]+/[^/]+/scripts/[^/]+\.sh — .' \
    || fail "no nested skills/*/*/scripts/*.sh line"
}

@test "inventory: the deliberately-unlisted directories stay unlisted" {
  # Not tidiness. The eval corpus grounds its replacement `buried` cases on exactly
  # these directories, so an over-broad glob here destroys the search signal the
  # registry extension already spent most of. Note the exclusion is skills/shared/*.md
  # — shared CANON — and not shared code, which is a capability like any other.
  use_registry
  local leaked=0 p
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    # The trailer NAMES these directories on purpose; it lists no path in them.
    is_trailer "$l" && continue
    p="${l%% — *}"
    case "$p" in
      tests/*|evals/*|skills/*/references/*|skills/shared/*.md|*/tests/*)
        leaked=$((leaked + 1)); echo "should not be listed: $p" >&2 ;;
    esac
  done
  [ "$leaked" -eq 0 ] || fail "$leaked path(s) from a deliberately-unlisted directory"
}

# --- the excluded-classes trailer ---------------------------------------------

@test "trailer: stdout closes by naming the classes it does not enumerate" {
  # The list is complete by construction for the six classes it covers, and silent
  # about the rest — which reads as "complete, full stop". The trailer is the only
  # marker in stdout that anything was left out.
  use_registry
  local trailer="${lines[$((${#lines[@]} - 1))]}"
  is_trailer "$trailer" \
    || fail "last stdout line is not the excluded-classes trailer: $trailer"
  local class
  for class in 'skills/\*/references/' 'skills/shared/\*.md' 'tests/' 'evals/'; do
    printf '%s\n' "$trailer" | grep -q -- "$class" \
      || fail "trailer does not name the excluded class: $class"
  done
}

# Prints every stdin token that is neither a glob nor a bare directory — i.e. every
# token that could name one concrete file. Globbing stays off: `skills/shared/*.md`
# must be compared as itself, not as whatever it happens to expand to today.
non_class_tokens() {
  local tok was_noglob=1
  case "$-" in *f*) ;; *) was_noglob=0; set -f ;; esac
  while read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *'*'*|*/) ;;
      *) printf '%s\n' "$tok" ;;
    esac
  done
  [ "$was_noglob" -eq 1 ] || set +f
}

@test "trailer: names classes only, never a file — the exclusion stays an exclusion" {
  # The whole point of not enumerating these directories is that eval cases ground
  # there; a trailer naming one FILE hands back exactly the lookup the exclusion
  # prevents. Class-level globs and bare directories only.
  use_registry
  local trailer="${lines[$((${#lines[@]} - 1))]}"
  local toks bad
  toks="$(printf '%s\n' "${trailer#*: }" | tr ',' '\n' | tr -d ' ')"
  [ "$(printf '%s\n' "$toks" | grep -c .)" -ge 4 ] \
    || fail "fewer than 4 trailer tokens collected; the splitter regressed"
  bad="$(printf '%s\n' "$toks" | non_class_tokens)"
  [ -z "$bad" ] || fail "trailer names something file-shaped, not a class:
$bad"
}

@test "the class-only check can actually fail" {
  # Non-vacuity for the PREDICATE: a checker that accepts everything would pass the
  # test above whatever the trailer said.
  local bad
  bad="$(printf '%s\n' 'skills/shared/*.md' 'tests/' 'skills/worktask/references/testing-strategy.md' \
           | non_class_tokens)"
  [ "$bad" = "skills/worktask/references/testing-strategy.md" ] \
    || fail "checker did not single out the file-shaped token; got: ${bad:-<nothing>}"
}

# --- description extraction --------------------------------------------------

@test "description: stops at the next frontmatter key, never folding one in" {
  # The awk collects until the next `key:` or the closing fence. Without that
  # guard a description absorbs `model:`/`tools:` and the registry reads as noise.
  use_registry
  local leaked=0 checked=0 l
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    is_trailer "$l" && continue
    # Markdown only. The leak this guards is desc_markdown running past the fence into
    # `model:`/`tools:`; desc_shell and desc_python have no frontmatter to run past, so a
    # sentinel matched there is prose — `effort:` is also an ordinary English word, and
    # scanning shell headers for it failed a correct description in #360.
    case "${l%% — *}" in *.md) ;; *) continue ;; esac
    checked=$((checked + 1))
    # Inspect only the description half; a PATH may legitimately contain a colon.
    case "${l#* — }" in
      *allowed-tools:*|*argument-hint:*|*"model:"*|*"version:"*|*"effort:"*|*"tools:"*)
        leaked=$((leaked + 1)); echo "leaked key: $l" >&2 ;;
    esac
  done
  # Without a floor the markdown filter could silently match nothing and pass vacuously.
  [ "$checked" -ge 40 ] || fail "non-vacuity: only $checked markdown descriptions inspected"
  [ "$leaked" -eq 0 ] || fail "$leaked description(s) absorbed a later frontmatter key"
}

@test "description: a leaked frontmatter key in a markdown asset is still caught" {
  # Non-vacuity twin for the markdown filter above: the guard must still fire on the
  # shape it exists for, or scoping it to .md would have quietly disabled it.
  local line="agents/planted.md — does a thing model: sonnet"
  case "${line%% — *}" in *.md) ;; *) fail "the .md filter rejected a markdown path" ;; esac
  case "${line#* — }" in
    *"model:"*) ;;
    *) fail "the sentinel no longer matches a genuine folded key" ;;
  esac
}

@test "description: no body heading leaks past the frontmatter fence" {
  use_registry
  # A leaked body would drag a markdown heading onto the line; frontmatter has none.
  # Asserted per line, not over $output: `.` matches a newline inside `[[ =~ ]]`, so a
  # whole-output regex pairs an em-dash on one line with the trailer's `##` on another.
  local l
  for l in "${lines[@]}"; do
    [ -z "$l" ] && continue
    is_trailer "$l" && continue
    if printf '%s\n' "$l" | grep -qE -- '— .*#{1,6} '; then
      fail "a body heading leaked into a description: $l"
    fi
  done
  return 0
}

@test "description: a multi-line folded description collapses to one line" {
  use_registry
  # One line per asset: the count of emitted lines must equal the count of paths.
  # Scoped past the trailer, which carries no path by design.
  local paths inventory
  inventory="$(printf '%s\n' "${lines[@]}" | grep -vc "^${TRAILER_PREFIX}" || true)"
  paths="$(printf '%s\n' "${lines[@]}" | grep -cE '\.(md|sh|py) — ' || true)"
  [ "$paths" -eq "$inventory" ] \
    || fail "$inventory inventory lines but only $paths carry a path — a description wrapped"
}

@test "description: markdown stops at a YAML comment line after description" {
  # A pipeline-only skill records its G3 answer as a `#` comment directly above
  # `disable-model-invocation:`, which can sit right after `description:`.
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' '---' \
                'name: planted' \
                'description: What the skill is for.' \
                '# G3: a comment that must not be folded in.' \
                'disable-model-invocation: true' \
                '---' \
                '# Body' > "$wd/SKILL.md"
  run_script_env --cwd "$wd" --source "$SCRIPT" desc_markdown "$wd/SKILL.md"
  assert_success
  assert_output "What the skill is for."
}

@test "description: shell takes the first comment block after the shebang" {
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' '#!/usr/bin/env bash' \
                '# First line of the block.' \
                '# Second line of the same block.' \
                '#' \
                '# A later paragraph that must not be folded in.' \
                'echo hi' > "$wd/plain.sh"
  run_script_env --cwd "$wd" --source "$SCRIPT" desc_shell "$wd/plain.sh"
  assert_success
  assert_output --partial "First line of the block."
  assert_output --partial "Second line of the same block."
  refute_output --partial "later paragraph"
}

@test "description: shell prefers an explicit @description over its neighbours" {
  # append-labels.sh opens with `@file`, so a naive first-block reader emits the
  # filename as the description. The tag is what the file declared; take it.
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' '#!/usr/bin/env bash' \
                '# @file        thing.sh' \
                '# @description What the thing is for,' \
                '#              continued on a hanging indent.' \
                '#' \
                '# Not part of the description.' \
                'echo hi' > "$wd/tagged.sh"
  run_script_env --cwd "$wd" --source "$SCRIPT" desc_shell "$wd/tagged.sh"
  assert_success
  assert_output --partial "What the thing is for, continued on a hanging indent."
  refute_output --partial "thing.sh"
  refute_output --partial "Not part of the description"
}

@test "description: python takes the module docstring's summary paragraph" {
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' '"""Summary that wraps' \
                'onto a second physical line.' \
                '' \
                'Body paragraph that must not be folded in.' \
                '"""' \
                'X = 1' > "$wd/mod.py"
  run_script_env --cwd "$wd" --source "$SCRIPT" desc_python "$wd/mod.py"
  assert_success
  assert_output --partial "Summary that wraps"
  assert_output --partial "onto a second physical line."
  refute_output --partial "Body paragraph"
}

@test "description: no description means no line at all, not a half-formed one" {
  # The emit() contract for markdown; the executable classes must not diverge from
  # it, or the registry starts listing paths with nothing said about them.
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$wd/silent.sh"
  printf '%s\n' 'X = 1' > "$wd/silent.py"

  run_script_env --cwd "$wd" --source "$SCRIPT" desc_shell "$wd/silent.sh"
  assert_success
  assert_output ""

  run_script_env --cwd "$wd" --source "$SCRIPT" desc_python "$wd/silent.py"
  assert_success
  assert_output ""

  # …and an empty description must produce no line, not a bare path with a dangling dash.
  run_script_env --cwd "$wd" --source "$SCRIPT" emit_line "silent.sh" ""
  assert_success
  assert_output ""
  # Non-vacuity: the same call with a description does emit, so "" above means the
  # guard fired rather than the harness swallowing everything.
  run_script_env --cwd "$wd" --source "$SCRIPT" emit_line "silent.sh" "something"
  assert_success
  assert_output "silent.sh — something"
}

# --- robustness ---------------------------------------------------------------

@test "cwd: resolves the plugin root regardless of the working directory" {
  # It cd's to a root derived from BASH_SOURCE. Invoked from elsewhere it must
  # still enumerate, or every caller has to know where the plugin lives.
  run_script_env --cwd "$BATS_TEST_TMPDIR" "$SCRIPT"
  assert_success
  assert_output --partial "/SKILL.md"
}
