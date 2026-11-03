#!/usr/bin/env bats
# Advisory duplicate-issue pre-flight for skills/worktask/references/workflow.md § Step 2a.
# Contract (skills/gh-issue-dedup § Two tiers):
#   - A PARAPHRASED open issue is surfaced, which the exact-title auto-bind misses.
#   - Every failure path (no gh, no auth, no remote, API error, garbage response,
#     timeout, zero hits) prints a proceed result and exits 0 — this step is on the
#     entry path of every worktask and must never block one.
#   - Unattended routings (non-interactive, /megatask, --emergency) never reach the
#     question, and an already-anchored .context/ is a resume, not a first run.
#   - It is advisory: nothing is written, linked or commented anywhere.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/preflight-issue-scan.sh"

GOAL="Stop duplicate GitHub issues from open worktasks"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/bin"

  # Three open issues: one paraphrase of $GOAL, one weaker paraphrase, one unrelated.
  cat > "$WD/issues.json" <<'JSON'
[{"number":42,"title":"Duplicate GitHub issues opened by overlapping worktasks","url":"https://github.com/o/r/issues/42"},
 {"number":88,"title":"Prevent duplicate issues when a worktask starts","url":"https://github.com/o/r/issues/88"},
 {"number":7,"title":"Add dark mode to settings","url":"https://github.com/o/r/issues/7"}]
JSON

  # The scan fetches open and closed as two separate pools, so the fake serves
  # ISSUES_JSON filtered by the requested --state; entries without a state are
  # open. GH_CLOSED_EXIT fails only the closed call.
  cat > "$WD/bin/gh" <<'EOS'
#!/usr/bin/env bash
state=open
prev=""
for a in "$@"; do
  [ "$prev" = "--state" ] && state="$a"
  prev="$a"
done
case "$1" in
  auth)  exit "${GH_AUTH_EXIT:-0}" ;;
  issue)
    case "$2" in
      list)
        if [ -n "${GH_LIST_SLEEP:-}" ]; then sleep "$GH_LIST_SLEEP"; fi
        if [ "$state" = "closed" ] && [ -n "${GH_CLOSED_EXIT:-}" ]; then
          exit "$GH_CLOSED_EXIT"
        fi
        if [ -n "${GH_LIST_STDOUT:-}" ]; then printf '%s\n' "$GH_LIST_STDOUT"; fi
        if [ -z "${GH_LIST_STDOUT:-}" ] && [ "${GH_LIST_EXIT:-0}" = "0" ]; then
          jq -c --arg s "$state" \
            '[ .[] | select(((.state // "open") | ascii_downcase) == $s) ]' \
            "${ISSUES_JSON:?}"
        fi
        exit "${GH_LIST_EXIT:-0}" ;;
    esac ;;
esac
exit 0
EOS

  # Guard 'remote present' without a real repo; GIT_REMOTE_EXIT=1 removes it.
  cat > "$WD/bin/git" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "remote" ]; then
  [ "${GIT_REMOTE_EXIT:-0}" = "0" ] || exit 1
  echo "git@github.com:o/r.git"; exit 0
fi
exit 0
EOS
  chmod +x "$WD/bin/gh" "$WD/bin/git"

  RUN() { # [ENV=VAL ...] -- [script args...]
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    cd "$WD"
    run env PATH="$WD/bin:$PATH" ISSUES_JSON="$WD/issues.json" \
      ${envs[@]+"${envs[@]}"} bash "$PLUGIN_ROOT/$SCRIPT" "$@"
  }
  KV() { printf '%s\n' "$output" | sed -n "s/^$1=//p" | tail -n 1; }
}

@test "paraphrased open issues are surfaced, ranked, and unrelated ones are not" {
  RUN -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "shown" ]
  [ "$(KV candidates)" = "2" ]
  local cands first
  cands="$(printf '%s\n' "$output" | sed -n 's/^candidate=//p')"
  # Most likely first; the unrelated issue never appears at all.
  first="$(printf '%s\n' "$cands" | head -1)"
  [ "$(jq -r '.number' <<< "$first")" = "42" ]
  [ "$(jq -rs 'map(.number) | sort | join(",")' <<< "$cands")" = "42,88" ]
}

@test "candidate lines are compact JSON carrying number, url, title and score" {
  RUN -- --goal "$GOAL"
  assert_success
  local first
  first="$(printf '%s\n' "$output" | sed -n 's/^candidate=//p' | head -1)"
  [ "$(jq -r '.url' <<< "$first")" = "https://github.com/o/r/issues/42" ]
  [ "$(jq -r '.title' <<< "$first")" = "Duplicate GitHub issues opened by overlapping worktasks" ]
  [ "$(jq -r '.score >= 2' <<< "$first")" = "true" ]
  # One line per candidate: a title full of separators must not split a record.
  [ "$(printf '%s\n' "$first" | wc -l | tr -d ' ')" = "1" ]
}

@test "no keyword overlap → result=none, not a prompt" {
  RUN -- --goal "Migrate the Metal renderer to a compute pipeline"
  assert_success
  [ "$(KV result)" = "none" ]
  [ "$(KV candidates)" = "0" ]
  [ "$(KV reason)" = "no_candidates" ]
}

@test "advisory only: a scan writes nothing at all" {
  RUN -- --goal "$GOAL"
  assert_success
  run find "$WD" -newer "$WD/issues.json" -type f -not -path "$WD/bin/*"
  assert_output ""
}

@test "failure paths all proceed: gh missing, unauthenticated, or no remote" {
  run_script_env --cwd "$WD" --hide gh "$SCRIPT" --goal "$GOAL"
  assert_success
  assert_output --partial "reason=gh_not_installed"

  RUN GH_AUTH_EXIT=1 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=auth_missing"
  assert_output --partial "result=skipped"

  RUN GIT_REMOTE_EXIT=1 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=no_remote"
}

@test "failure paths all proceed: API error and malformed response" {
  RUN GH_LIST_EXIT=1 -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "skipped" ]
  [ "$(KV reason)" = "search_failed" ]

  RUN GH_LIST_STDOUT="not json at all" -- --goal "$GOAL"
  assert_success
  [ "$(KV reason)" = "search_failed" ]

  RUN GH_LIST_STDOUT="[]" -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "none" ]
}

@test "a hung gh is bounded by the timeout and still proceeds" {
  RUN GH_LIST_SLEEP=30 PREFLIGHT_SCAN_TIMEOUT=2 -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "skipped" ]
  [ "$(KV reason)" = "search_failed" ]
}

@test "unattended routings never reach the question" {
  RUN CORPFLOW_NONINTERACTIVE=1 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=non_interactive"

  RUN MILESTONE_MODE=1 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=milestone_mode"

  RUN INCIDENT_MODE=1 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=incident_mode"

  # A megatask per-issue workspace is detected by workspace.json alone.
  printf '{}\n' > "$WD/workspace.json"
  RUN -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=milestone_mode"
  rm -f "$WD/workspace.json"

  # …and through WORKSPACE_ROOT when the shell stands elsewhere, as a /megatask subagent's
  # does before its `cd`: Step 2a's question is never reached.
  mkdir -p "$WD/wt"
  printf '{}\n' > "$WD/wt/workspace.json"
  RUN WORKSPACE_ROOT="$WD/wt" -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=milestone_mode"
  refute_output --partial "result=shown"
}

@test "opt-outs: --no-gh-issue, PREFLIGHT_ISSUE_SCAN=0, and --limit 0" {
  RUN -- --no-gh-issue --goal "$GOAL"
  assert_success
  assert_output --partial "reason=opted_out"

  RUN PREFLIGHT_ISSUE_SCAN=0 -- --goal "$GOAL"
  assert_success
  assert_output --partial "reason=opted_out"

  RUN -- --goal "$GOAL" --limit 0
  assert_success
  assert_output --partial "reason=opted_out"
}

@test "an already-anchored .context/ is a resume, so the scan self-skips" {
  mkdir -p "$WD/.context"
  printf '{"version":1,"url":"https://github.com/o/r/issues/42","number":42}\n' \
    > "$WD/.context/gh-issue.json"
  RUN -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "skipped" ]
  [ "$(KV reason)" = "already_anchored" ]
}

@test "a goal with no scannable keywords skips instead of scanning everything" {
  RUN -- --goal "update the changes"
  assert_success
  [ "$(KV result)" = "skipped" ]
  [ "$(KV reason)" = "no_keywords" ]

  RUN -- --goal ""
  assert_success
  assert_output --partial "reason=no_keywords"
}

@test "--limit caps the candidate list" {
  RUN -- --goal "$GOAL" --limit 1
  assert_success
  [ "$(KV candidates)" = "1" ]
  local emitted
  emitted="$(printf '%s\n' "$output" | sed -n 's/^candidate=//p' | wc -l | tr -d ' ')"
  [ "$emitted" = "1" ]
}

@test "usage errors are loud (exit 2), runtime outcomes are not" {
  RUN -- --goal
  [ "$status" -eq 2 ]

  RUN --
  [ "$status" -eq 2 ]

  RUN -- --goal "$GOAL" --limit abc
  [ "$status" -eq 2 ]

  RUN -- --bogus
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# R11/#10 — a closed match is a prior-run signal, not a comment candidate.
# The open-only pool made the most valuable hit this scan can produce ("this
# task already ran") structurally invisible.
# ---------------------------------------------------------------------------

@test "R11: open and closed are fetched as two pools, each with the state field" {
  # One `--state all` pool is newest-first across both classes, so a busy closed
  # backlog evicts every open issue and the open-duplicate check goes blind.
  cd "$WD"
  cat > "$WD/bin/gh" <<'EOS'
#!/usr/bin/env bash
[ "$1" = "auth" ] && exit 0
printf '%s\n' "$*" >> "$FLAGLOG"
printf '[]\n'
EOS
  chmod +x "$WD/bin/gh"
  FLAGLOG="$WD/flags" PATH="$WD/bin:$PATH" \
    bash "$PLUGIN_ROOT/$SCRIPT" --goal "$GOAL" > /dev/null 2>&1 || true
  run cat "$WD/flags"
  assert_output --partial "--state open"
  assert_output --partial "--state closed"
  refute_output --partial "--state all"
  assert_output --partial "number,title,url,state"
  [ "$(grep -c -- '--limit 100' "$WD/flags")" = "2" ]
}

@test "R11: a failed closed pool degrades to empty instead of skipping the scan" {
  # The closed pool only ADDS the prior-run hint; dropping the whole scan with it
  # would also lose the open-duplicate check the open pool already answered.
  RUN GH_CLOSED_EXIT=1 -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "shown" ]
  [ "$(KV candidates)" = "2" ]
  [ "$(KV priors)" = "0" ]
}

@test "R11: a closed-only match takes the prior-run branch, not the comment branch" {
  cd "$WD"
  cat > "$WD/closed.json" <<'JSON'
[{"number":1,"title":"Duplicate GitHub issues opened by overlapping worktasks",
  "url":"https://github.com/o/r/issues/1","state":"CLOSED"}]
JSON
  ISSUES_JSON="$WD/closed.json" PATH="$WD/bin:$PATH" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --goal "$GOAL"
  assert_success
  assert_output --partial "result=prior-run"
  assert_output --partial "reason=closed_match"
  assert_output --partial "candidates=0"
  assert_output --partial "priors=1"
  # A closed issue must NEVER reach the caller's "use one of the existing issues"
  # arm: binding a context to it would anchor the run to an issue this run can
  # neither comment on nor close.
  refute_output --partial "candidate="
}

@test "R11: an open match keeps the result=shown contract byte-for-byte" {
  cd "$WD"
  cat > "$WD/mixed.json" <<'JSON'
[{"number":1,"title":"Duplicate GitHub issues opened by overlapping worktasks",
  "url":"https://github.com/o/r/issues/1","state":"CLOSED"},
 {"number":2,"title":"Prevent duplicate issues when a worktask starts",
  "url":"https://github.com/o/r/issues/2","state":"OPEN"}]
JSON
  ISSUES_JSON="$WD/mixed.json" PATH="$WD/bin:$PATH" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --goal "$GOAL"
  assert_success
  assert_output --partial "result=shown"
  assert_output --partial "candidates=1"
  assert_output --partial '"number":2'
  assert_output --partial "priors=1"
  assert_output --partial '"number":1'
}

@test "R11: lowercase state spellings are classified identically" {
  cd "$WD"
  cat > "$WD/lower.json" <<'JSON'
[{"number":1,"title":"Duplicate GitHub issues opened by overlapping worktasks",
  "url":"https://github.com/o/r/issues/1","state":"closed"}]
JSON
  ISSUES_JSON="$WD/lower.json" PATH="$WD/bin:$PATH" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --goal "$GOAL"
  assert_success
  assert_output --partial "result=prior-run"
}

@test "R11: zero matches still print result=none — the arm order is unchanged" {
  cd "$WD"
  printf '[]\n' > "$WD/empty.json"
  ISSUES_JSON="$WD/empty.json" PATH="$WD/bin:$PATH" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --goal "$GOAL"
  assert_success
  assert_output --partial "result=none"
  assert_output --partial "reason=no_candidates"
}

# --- scrub: candidate and prior text passes through skills/shared/scripts/path-scrub.sh --

# _scan_tree <missing|failing> -> path of a plugin-shaped copy of the scan whose
# path-scrub.sh is absent, or present but failing, so the fail-closed arm runs
# without an env seam that could point the scan at an arbitrary file to source.
_scan_tree() {
  local root="$WD/tree-$1"
  mkdir -p "$root/skills/worktask/scripts" "$root/skills/shared/scripts"
  cp "$PLUGIN_ROOT/$SCRIPT" "$root/skills/worktask/scripts/"
  if [ "$1" = "failing" ]; then
    printf '%s\n' 'CORPFLOW_HOST_PATH_ERE="/(Users)/"' 'corpflow_path_scrub() { return 1; }' \
      > "$root/skills/shared/scripts/path-scrub.sh"
  fi
  printf '%s' "$root/skills/worktask/scripts/preflight-issue-scan.sh"
}

@test "scrub: a host path in a candidate or prior title leaves the scan as [local-path]" {
  cat > "$WD/issues.json" <<'JSON'
[{"number":42,"title":"Duplicate GitHub issues opened by overlapping worktasks in /Users/alice/src/app","url":"https://github.com/o/r/issues/42"},
 {"number":9,"title":"Duplicate GitHub issues from worktasks under /home/bob/work","url":"https://github.com/o/r/issues/9","state":"CLOSED"}]
JSON
  RUN -- --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "shown" ]
  [ "$(KV priors)" = "1" ]
  assert_output --partial '[local-path]'
  refute_output --partial '/Users/alice'
  refute_output --partial '/home/bob'
  assert_output --partial '"url":"https://github.com/o/r/issues/42"'
}

@test "scrub: path-scrub.sh missing -> skipped/scrub_unavailable, no candidate or prior lines" {
  local s
  s="$(_scan_tree missing)"
  cd "$WD"
  run env PATH="$WD/bin:$PATH" ISSUES_JSON="$WD/issues.json" bash "$s" --goal "$GOAL"
  assert_success
  [ "$(KV result)" = "skipped" ]
  [ "$(KV reason)" = "scrub_unavailable" ]
  refute_output --partial 'candidate='
  refute_output --partial 'prior='
}

@test "scrub: a scrub that fails at runtime also prints no candidates" {
  local s
  s="$(_scan_tree failing)"
  cd "$WD"
  run env PATH="$WD/bin:$PATH" ISSUES_JSON="$WD/issues.json" bash "$s" --goal "$GOAL"
  assert_success
  [ "$(KV reason)" = "scrub_unavailable" ]
  refute_output --partial 'candidate='
}
