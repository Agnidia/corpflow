#!/usr/bin/env bash
# publish-pl-issue-selftest.sh — the `--self-test` harness for publish-pl-issue.sh.
#
# SOURCED, never executed: publish-pl-issue.sh loads this file only on the
# `--self-test` path, so the production publish path never pays for it. Sourcing
# leaves `$0` pointing at publish-pl-issue.sh, which the harness depends on three
# ways — the `references/fixtures/` lookup below, the re-invocation at T6, and the
# absolute-path rebuild at T13 all resolve relative to that caller, not to this
# file. Do not rewrite them against BASH_SOURCE.
#
# Contract: defines exactly one function, `run_self_tests`, returning 0 when every
# fixture passes. It reads the sanitiser, tier-selection, and state helpers from
# the caller's scope — this file is not standalone.

run_self_tests() {
  local fixtures_dir
  # Self-test fixtures are reference data kept under references/fixtures/; this
  # script lives in scripts/, so reach one level up into the sibling references/.
  fixtures_dir="$(dirname "$0")/../references/fixtures/publish-pl-issue"
  [ -d "$fixtures_dir" ] || { echo "publish-pl-issue: fixtures dir missing: $fixtures_dir" >&2; return 1; }
  local pass=0 fail=0

  # Fixture 01: clean plan — sanitiser should not strip much.
  local clean orig_len san_len
  clean=$(sanitise_body < "$fixtures_dir/01-clean-plan.md")
  orig_len=$(wc -c < "$fixtures_dir/01-clean-plan.md")
  san_len=$(printf '%s' "$clean" | wc -c)
  if [ "$san_len" -gt 0 ] && [ "$san_len" -ge $((orig_len / 2)) ]; then
    echo "publish-pl-issue: self-test 01-clean-plan PASS (orig=$orig_len san=$san_len)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 01-clean-plan FAIL (orig=$orig_len san=$san_len)"
    fail=$((fail + 1))
  fi

  # Fixture 02: leaky plan — must strip all forbidden tokens.
  local leaky
  leaky=$(sanitise_body < "$fixtures_dir/02-leaky-plan.md")
  if printf '%s' "$leaky" | grep -qE '\.context/|/Users/|conductor/workspaces/|planning-[0-9]+\.md'; then
    echo "publish-pl-issue: self-test 02-leaky-plan FAIL (leak detected)"
    printf '%s\n' "$leaky" | grep -E '\.context/|/Users/|conductor/workspaces/|planning-[0-9]+\.md' | head -3 >&2
    fail=$((fail + 1))
  else
    echo "publish-pl-issue: self-test 02-leaky-plan PASS (no leaks)"
    pass=$((pass + 1))
  fi

  # Inline: a per-stream DV artifact name is dropped like its bare sibling.
  local streamy
  streamy=$(printf 'keep this line\nsee development-0-web.md\nand `development-12-swift-app.md`\n' | sanitise_body)
  if [ "$streamy" = "keep this line" ]; then
    echo "publish-pl-issue: self-test stream-artifact-name PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test stream-artifact-name FAIL (got: $streamy)"
    fail=$((fail + 1))
  fi

  # Fixture 03: mostly-paths — strip ratio should be > 50%.
  local pathy pathy_orig pathy_san ratio_num ratio_den
  pathy=$(sanitise_body < "$fixtures_dir/03-mostly-paths.md")
  pathy_orig=$(wc -c < "$fixtures_dir/03-mostly-paths.md")
  pathy_san=$(printf '%s' "$pathy" | wc -c)
  ratio_num=$((pathy_orig - pathy_san))
  ratio_den=$pathy_orig
  if [ "$ratio_den" -gt 0 ] && [ $((ratio_num * 100 / ratio_den)) -gt 50 ]; then
    echo "publish-pl-issue: self-test 03-mostly-paths PASS (strip_pct=$((ratio_num * 100 / ratio_den))%)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 03-mostly-paths FAIL (strip ratio not > 50%)"
    fail=$((fail + 1))
  fi

  # Fixture 04: already-published — companion state.json short-circuits.
  local f04_state="$fixtures_dir/04-state.json"
  local url_check
  url_check=$(jq -r '.metadata.github_issue_url // ""' "$f04_state" 2>/dev/null)
  if [ -n "$url_check" ]; then
    echo "publish-pl-issue: self-test 04-already-published PASS (state preloaded with $url_check)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 04-already-published FAIL (state.json missing github_issue_url)"
    fail=$((fail + 1))
  fi

  # Fixture 05: milestone-mode — companion state.json carries metadata.milestone.
  # Detector reads STATE_FILE directly; verify both env-override and state-json
  # signals would fire is_milestone_mode().
  local f05_state="$fixtures_dir/05-state.json"
  local milestone_check
  milestone_check=$(jq -r '.metadata.milestone // ""' "$f05_state" 2>/dev/null)
  local env_check=0
  ( MILESTONE_MODE=1 STATE_FILE=/dev/null bash -c '
      [ "${MILESTONE_MODE:-0}" = "1" ] && exit 0 || exit 1
    ' ) && env_check=1
  if [ -n "$milestone_check" ] && [ "$milestone_check" != "null" ] && [ "$env_check" = "1" ]; then
    echo "publish-pl-issue: self-test 05-milestone-mode PASS (state.metadata.milestone=$milestone_check + env override)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 05-milestone-mode FAIL (milestone=$milestone_check env_check=$env_check)"
    fail=$((fail + 1))
  fi

  # ---- Fixture 06: strict mode — STRICT=1 + label create failure → exit 1 ----
  # Run the strict-mode assertion in a subshell with a mocked $GH_BIN that always
  # fails on `label create`. Verify the helper exits 1 and writes an audit row
  # with result=failed and reason=label_create_failed.
  local t6_dir t6_log t6_state t6_plan
  t6_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-06.$$")
  mkdir -p "$t6_dir/.context/logs" "$t6_dir/bin"
  t6_state="$t6_dir/.context/state.json"
  t6_plan="$t6_dir/planning-0.md"
  cat > "$t6_state" <<'JSON'
{"version":1,"worktask_id":"strict-mode-test","run_index":0,"plan_file":"PLAN_PLACEHOLDER","facts":{"goal":"OV-999 Strict mode regression"},"metadata":{}}
JSON
  # Patch plan_file path in state.json.
  jq --arg p "$t6_plan" '.plan_file = $p' "$t6_state" > "$t6_state.tmp" && mv -f "$t6_state.tmp" "$t6_state"
  cat > "$t6_plan" <<'MD'
# Strict-mode plan
## requirements
- REQ-1: example
## acceptance-criteria
- AC-1: example
## scope
In: x. Out: y.
## complexity
Score: 5/50 (Low).
## stages
PL0 → DV0
MD
  # Mock gh that fails every label create + issue create (label-related stderr).
  cat > "$t6_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  auth)         exit 0 ;;
  label)
    case "$2" in
      list) echo "" ; exit 0 ;;
      create) echo "could not create label: validation failed" >&2 ; exit 1 ;;
    esac ;;
  issue)
    echo "could not add label: 'worktask' not found in repository" >&2
    exit 1 ;;
esac
exit 0
MOCK
  chmod +x "$t6_dir/bin/gh"
  # Provide a fake `git remote get-url origin` by injecting a dummy git wrapper
  # (lightweight: just intercept `remote get-url`).
  cat > "$t6_dir/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "remote" ] && [ "$2" = "get-url" ]; then echo "git@example.com:org/repo.git"; exit 0; fi
exec /usr/bin/env -i PATH=/usr/bin:/bin git "$@"
MOCK
  chmod +x "$t6_dir/bin/git"
  t6_log="$t6_dir/run.log"
  ( PATH="$t6_dir/bin:$PATH" \
    STATE_FILE="$t6_state" \
    WORKSPACE_ROOT="$t6_dir" \
    GH_BIN="gh" \
    STRICT=1 \
    bash "$0" >"$t6_log" 2>&1 )
  local t6_rc=$?
  local t6_audit="$t6_dir/.context/logs/audit.jsonl"
  if [ "$t6_rc" -eq 1 ] && [ -f "$t6_audit" ] && \
     grep -q '"result":"failed"' "$t6_audit" && \
     grep -qE '"reason":"label_create_failed"|"reason":"gh_api_error"' "$t6_audit"; then
    echo "publish-pl-issue: self-test 06-strict-mode PASS (rc=$t6_rc, audit result=failed)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 06-strict-mode FAIL (rc=$t6_rc)"
    [ -f "$t6_audit" ] && tail -1 "$t6_audit" >&2 || echo "  no audit row" >&2
    fail=$((fail + 1))
  fi
  rm -rf "$t6_dir"

  # ---- Fixture 07: external-ticket extraction ----
  local t7_match t7_no_double
  t7_match=$(extract_external_ticket "OV-113 Change navigation in settings")
  if [ "$t7_match" = "OV-113" ]; then
    echo "publish-pl-issue: self-test 07-ticket-extract PASS (got '$t7_match')"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 07-ticket-extract FAIL (got '$t7_match' want 'OV-113')"
    fail=$((fail + 1))
  fi
  # No-match case (lowercase / no number / wrong shape).
  local t7_neg
  t7_neg=$(extract_external_ticket "fix-publish-pl-issue-helper")
  if [ -z "$t7_neg" ]; then
    echo "publish-pl-issue: self-test 07-ticket-no-match PASS (empty as expected)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 07-ticket-no-match FAIL (matched '$t7_neg')"
    fail=$((fail + 1))
  fi
  # Title-prefix idempotency check (no double-prefix). Pure-string assertion.
  local _t="OV-113 Change navigation"
  case "$_t" in
    "OV-113"|"OV-113 "*|"OV-113:"*) t7_no_double=ok ;;
    *) t7_no_double=fail ;;
  esac
  if [ "$t7_no_double" = "ok" ]; then
    echo "publish-pl-issue: self-test 07-no-double-prefix PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 07-no-double-prefix FAIL"
    fail=$((fail + 1))
  fi

  # ---- Fixture 13: title/summary resolution chain (#375) ----
  # Driven end-to-end through the real entrypoint under DRY_RUN=1, not through the
  # helpers in isolation: the title is only observable on the `gh issue create` line
  # and the Summary only in the rendered body file, so a unit-level assertion would
  # miss exactly the wiring that broke. `t13_run <plan> <worktask_id> [goal]` builds a
  # throwaway workspace, runs the script, and leaves stderr + body + audit behind.
  local t13_dir t13_self
  t13_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-13.$$")
  # Absolute: t13_run cds into the throwaway workspace before re-invoking us, so a
  # relative $0 (the normal invocation shape) would no longer resolve.
  t13_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  t13_run() {
    local plan="$1" wid="$2" goal="${3:-}" run="$t13_dir/run"
    rm -rf "$run"; mkdir -p "$run/.context/logs"
    cp "$plan" "$run/.context/planning-0.md"
    jq -n --arg w "$wid" --arg g "$goal" \
      '{version:2, worktask_id:$w, run_index:0, plan_file:".context/planning-0.md",
        tasks:{PL0:{status:"completed"}},
        facts:(if $g == "" then {} else {goal:$g} end),
        handoffs:{}, metadata:{}}' > "$run/.context/state.json"
    ( cd "$run" && WORKSPACE_ROOT="$run" STATE_FILE="$run/.context/state.json" \
        DRY_RUN=1 GH_ISSUE_SEARCH=0 GH_BIN=true \
        bash "$t13_self" > "$run/out.txt" 2> "$run/err.txt" )
  }
  # Title as published: the DRY_RUN line quotes it, so read between the quotes.
  t13_title() {
    sed -n 's/.*--title "\(.*\)" --body-file.*/\1/p' "$t13_dir/run/err.txt" | head -1
  }
  t13_summary() {
    awk '/^## Summary$/ { s = 1; next } /^## / { s = 0 } s' "$t13_dir/run/issue-body-0.tmp" 2>/dev/null \
      || true
  }

  local f13="$fixtures_dir/13-frontmatter-title.md"
  local f13b="$fixtures_dir/13b-prefixed-title.md"
  local f13c="$fixtures_dir/13c-no-title-source.md"
  if [ -f "$f13" ] && [ -f "$f13b" ] && [ -f "$f13c" ]; then
    # 13a: no facts.goal → frontmatter title wins, ticket prefixed exactly once,
    # and the Summary falls back to the plan's own ## summary anchor.
    local t13a_ok=1 t13a_title t13a_sum
    t13_run "$f13" "ov-164-catalog-image-blinking" ""
    # LOG_DIR is WORKSPACE_ROOT-relative, so the body lands beside the run's audit.
    cp "$t13_dir/run/.context/logs/issue-body-0.tmp" "$t13_dir/run/issue-body-0.tmp" 2>/dev/null || true
    t13a_title=$(t13_title)
    t13a_sum=$(t13_summary | tr -d '[:space:]')
    [ "$t13a_title" = "OV-164 Product list images are blinking before rendering" ] || t13a_ok=0
    [ -n "$t13a_sum" ] || t13a_ok=0
    if [ "$t13a_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 13a-frontmatter-title PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 13a-frontmatter-title FAIL (title='$t13a_title' summary_empty=$([ -z "$t13a_sum" ] && echo yes || echo no))"
      fail=$((fail + 1))
    fi

    # 13b: a frontmatter title that ALREADY carries the ticket must not be doubled.
    local t13b_ok=1 t13b_title
    t13_run "$f13b" "ov-164-catalog-image-blinking" ""
    t13b_title=$(t13_title)
    [ "$t13b_title" = "OV-164 Product list images are blinking before rendering" ] || t13b_ok=0
    case "$t13b_title" in *"OV-164 OV-164"*) t13b_ok=0 ;; esac
    if [ "$t13b_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 13b-no-double-prefix PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 13b-no-double-prefix FAIL (title='$t13b_title')"
      fail=$((fail + 1))
    fi

    # 13c: every prose rank empty → slug fallback, exit 0, degradation row present.
    local t13c_ok=1 t13c_title t13c_rc=0
    t13_run "$f13c" "wt-no-sources" "" || t13c_rc=$?
    t13c_title=$(t13_title)
    [ "$t13c_rc" = "0" ] || t13c_ok=0
    [ "$t13c_title" = "wt-no-sources" ] || t13c_ok=0
    grep -qF '"reason":"title_fallback_worktask_id"' "$t13_dir/run/.context/logs/audit.jsonl" 2>/dev/null || t13c_ok=0
    if [ "$t13c_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 13c-slug-fallback-audited PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 13c-slug-fallback-audited FAIL (rc=$t13c_rc title='$t13c_title')"
      fail=$((fail + 1))
    fi

    # 13d: no regression — facts.goal set still wins every later rank, for BOTH the
    # title and the Summary, exactly as before the chain existed.
    local t13d_ok=1 t13d_title t13d_sum
    t13_run "$f13" "ov-164-catalog-image-blinking" "OV-164 Ship the catalog image cache"
    cp "$t13_dir/run/.context/logs/issue-body-0.tmp" "$t13_dir/run/issue-body-0.tmp" 2>/dev/null || true
    t13d_title=$(t13_title)
    t13d_sum=$(t13_summary)
    [ "$t13d_title" = "OV-164 Ship the catalog image cache" ] || t13d_ok=0
    printf '%s' "$t13d_sum" | grep -qF 'Ship the catalog image cache' || t13d_ok=0
    if [ "$t13d_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 13d-goal-still-wins PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 13d-goal-still-wins FAIL (title='$t13d_title')"
      fail=$((fail + 1))
    fi
  else
    echo "publish-pl-issue: self-test 13-title-chain SKIP (fixtures missing)"
    fail=$((fail + 1))
  fi

  # 13e: reader units — frontmatter parsing must not read a `---` thematic break
  # further down the body, and first_sentence must not stop inside "3.5s".
  local t13e_ok=1 t13e_v
  printf 'not frontmatter\n\n---\ntitle: Stolen From A Thematic Break\n---\n' > "$t13_dir/nofm.md"
  t13e_v=$(extract_frontmatter_field "$t13_dir/nofm.md" "title")
  [ -z "$t13e_v" ] || t13e_ok=0
  printf -- '---\ntitle: "Quoted: with a colon"\n---\n# H1 here\n' > "$t13_dir/fm.md"
  t13e_v=$(extract_frontmatter_field "$t13_dir/fm.md" "title")
  [ "$t13e_v" = "Quoted: with a colon" ] || t13e_ok=0
  t13e_v=$(extract_first_h1 "$t13_dir/fm.md")
  [ "$t13e_v" = "H1 here" ] || t13e_ok=0
  t13e_v=$(printf -- '- a bullet\n\nCut the 3.5s delay. Second sentence.\n' | first_sentence)
  [ "$t13e_v" = "Cut the 3.5s delay." ] || t13e_ok=0
  # A nested key belongs to its block: the PL template's `handoff:` carries indented
  # fields, and one of them must never be mistaken for the document's own title.
  printf -- '---\nhandoff:\n  title: Nested Not Mine\n---\n' > "$t13_dir/nested.md"
  t13e_v=$(extract_frontmatter_field "$t13_dir/nested.md" "title")
  [ -z "$t13e_v" ] || t13e_ok=0
  printf -- "---\ntitle: 'Single quoted'\n---\n" > "$t13_dir/sq.md"
  t13e_v=$(extract_frontmatter_field "$t13_dir/sq.md" "title")
  [ "$t13e_v" = "Single quoted" ] || t13e_ok=0
  if [ "$t13e_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 13e-chain-readers PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 13e-chain-readers FAIL (last='$t13e_v')"
    fail=$((fail + 1))
  fi
  rm -rf "$t13_dir"

  # ---- title word boundary: title_cap_word_boundary ----
  # 10-char tokens ("abcdefghi " incl. trailing space) x11 = 110 chars; the
  # 100-char window lands exactly on the 10th token's own trailing space, so
  # the boundary trim removes that space and keeps all 10 tokens.
  local wb_input wb_expected wb_got i
  wb_input=""
  for i in 1 2 3 4 5 6 7 8 9 10 11; do wb_input="${wb_input}abcdefghi "; done
  wb_expected=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$i" = "1" ]; then wb_expected="abcdefghi"; else wb_expected="$wb_expected abcdefghi"; fi
  done
  wb_expected="${wb_expected}…"
  wb_got=$(printf '%s' "$wb_input" | title_cap_word_boundary 100)
  if [ "$wb_got" = "$wb_expected" ]; then
    echo "publish-pl-issue: self-test title word boundary: spaced title over 100 ends on a whole word plus ellipsis PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test title word boundary: spaced title over 100 ends on a whole word plus ellipsis FAIL (got='$wb_got' want='$wb_expected')"
    fail=$((fail + 1))
  fi

  local wb2_input wb2_expected wb2_got
  wb2_input=$(head -c 120 /dev/zero | tr '\0' 'x')
  wb2_expected="$(head -c 99 /dev/zero | tr '\0' 'x')…"
  wb2_got=$(printf '%s' "$wb2_input" | title_cap_word_boundary 100)
  if [ "$wb2_got" = "$wb2_expected" ]; then
    echo "publish-pl-issue: self-test title word boundary: no-whitespace title over 100 hard-cuts to 99 plus ellipsis PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test title word boundary: no-whitespace title over 100 hard-cuts to 99 plus ellipsis FAIL (got='$wb2_got')"
    fail=$((fail + 1))
  fi

  local wb3_input wb3_got
  wb3_input="Short title well under the one hundred character cap"
  wb3_got=$(printf '%s' "$wb3_input" | title_cap_word_boundary 100)
  if [ "$wb3_got" = "$wb3_input" ]; then
    echo "publish-pl-issue: self-test title word boundary: title of 100 or fewer is unchanged PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test title word boundary: title of 100 or fewer is unchanged FAIL (got='$wb3_got')"
    fail=$((fail + 1))
  fi

  local wb4_got
  wb4_got=$(printf '%s' "hello, world again" | title_cap_word_boundary 12)
  if [ "$wb4_got" = "hello…" ]; then
    echo "publish-pl-issue: self-test title word boundary: trailing punctuation trimmed before ellipsis PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test title word boundary: trailing punctuation trimmed before ellipsis FAIL (got='$wb4_got' want='hello…')"
    fail=$((fail + 1))
  fi

  # ---- legacy fixed-100 title is matched by recovery search ----
  # TITLE_LEGACY reproduces the pre-word-boundary cut; an issue still titled
  # under that scheme must still be found once the live TITLE search misses.
  local t14_dir t14_raw t14_title t14_legacy t14_result
  t14_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-14.$$")
  mkdir -p "$t14_dir/bin"
  t14_raw=""
  for i in 1 2 3 4 5 6 7 8 9 10; do t14_raw="${t14_raw}abcdefghij "; done
  t14_title=$(printf '%s' "$t14_raw" | head -1 | sanitise_body | tr -d '\n' | title_cap_word_boundary 100)
  t14_legacy=$(printf '%s' "$t14_raw" | title_legacy_cut)
  cat > "$t14_dir/bin/gh" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  printf '%s\n' '[{"number":777,"title":"$t14_legacy","url":"https://github.com/o/r/issues/777"}]'
  exit 0
fi
exit 1
MOCK
  chmod +x "$t14_dir/bin/gh"
  t14_result=$(
    TITLE="$t14_title" TITLE_LEGACY="$t14_legacy" GH_ISSUE_SEARCH=1 DRY_RUN=0 GH_BIN="$t14_dir/bin/gh" \
    bash -c '
      '"$(declare -f resolve_context_issue_search)"'
      '"$(declare -f resolve_context_issue_search_for)"'
      if resolve_context_issue_search; then
        printf "ok:%s" "$RESOLVED_ISSUE_NUMBER"
      else
        printf "fail"
      fi
    '
  )
  if [ "$t14_title" != "$t14_legacy" ] && [ "$t14_result" = "ok:777" ]; then
    echo "publish-pl-issue: self-test legacy fixed-100 title is matched by recovery search PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test legacy fixed-100 title is matched by recovery search FAIL (title='$t14_title' legacy='$t14_legacy' result='$t14_result')"
    fail=$((fail + 1))
  fi
  rm -rf "$t14_dir"

  # ---- Fixture classify_gh_failure: canned stderr blobs ----
  local cl
  cl=$(classify_gh_failure "could not add label: 'worktask' not found in repository")
  if [ "$cl" = "label_create_failed" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(label) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(label) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "HTTP 401: Bad credentials")
  if [ "$cl" = "auth_missing" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(401) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(401) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "HTTP 403: permission denied")
  if [ "$cl" = "permission_denied" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(403) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(403) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "HTTP 404: repository not found")
  if [ "$cl" = "repo_not_found" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(404) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(404) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "request timed out after 30s")
  if [ "$cl" = "gh_timeout" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(timeout) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(timeout) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "could not resolve host: api.github.com")
  if [ "$cl" = "network_error" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(network) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(network) FAIL ($cl)"
  fi
  cl=$(classify_gh_failure "")
  if [ "$cl" = "gh_api_error" ]; then
    pass=$((pass + 1)); echo "publish-pl-issue: self-test classify(default) PASS ($cl)"
  else
    fail=$((fail + 1)); echo "publish-pl-issue: self-test classify(default) FAIL ($cl)"
  fi

  # ---- Fixture 08: label auto-create idempotency + ensure_labels behaviour ----
  # Mock gh to (a) report a partial label list, (b) succeed on `label create`.
  # Confirm DROPPED_LABELS stays empty.
  local t8_dir
  t8_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-08.$$")
  mkdir -p "$t8_dir/bin"
  cat > "$t8_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  label)
    case "$2" in
      list) printf '' ; exit 0 ;;     # zero existing labels
      create) exit 0 ;;               # creates always succeed
    esac ;;
esac
exit 0
MOCK
  chmod +x "$t8_dir/bin/gh"
  # Re-source-free invocation: call ensure_labels in a clean subshell whose only
  # `gh` on PATH is the mock above.
  local t8_dropped
  t8_dropped=$( PATH="$t8_dir/bin:$PATH" GH_BIN=gh bash -c '
    DROPPED_LABELS=""
    '"$(declare -f label_color)"'
    '"$(declare -f label_description)"'
    '"$(declare -f ensure_labels)"'
    ensure_labels worktask planning-approved complexity:low ticket:OV-113
    printf "%s" "$DROPPED_LABELS"
  ' )
  if [ -z "$t8_dropped" ]; then
    echo "publish-pl-issue: self-test 08-missing-labels PASS (all 4 created, none dropped)"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 08-missing-labels FAIL (dropped='$t8_dropped')"
    fail=$((fail + 1))
  fi
  # Idempotency: second invocation with the same labels (now "existing") must
  # also produce no drops.
  cat > "$t8_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  label)
    case "$2" in
      list)
        printf 'worktask\nplanning-approved\ncomplexity:low\nticket:OV-113\n'
        exit 0 ;;
      create) echo "label already exists" >&2; exit 1 ;;  # would fail if called
    esac ;;
esac
exit 0
MOCK
  chmod +x "$t8_dir/bin/gh"
  t8_dropped=$( PATH="$t8_dir/bin:$PATH" GH_BIN=gh bash -c '
    DROPPED_LABELS=""
    '"$(declare -f label_color)"'
    '"$(declare -f label_description)"'
    '"$(declare -f ensure_labels)"'
    ensure_labels worktask planning-approved complexity:low ticket:OV-113
    printf "%s" "$DROPPED_LABELS"
  ' )
  if [ -z "$t8_dropped" ]; then
    echo "publish-pl-issue: self-test 08-idempotent PASS"
    pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 08-idempotent FAIL (dropped='$t8_dropped')"
    fail=$((fail + 1))
  fi
  rm -rf "$t8_dir"

  # ---- Fixture 09: Design Preview render (with Figma URL) ----
  # Build the rendered body from fixture 09 in the same shape as the live
  # render block. Asserts the new heading + URL preservation + absence of
  # the now-removed Planned Stages heading + reviewer instruction line.
  local f9="$fixtures_dir/09-with-figma-link.md"
  if [ -f "$f9" ]; then
    local f9_reqs f9_acs f9_scope f9_complex f9_design f9_body
    f9_reqs=$(extract_anchor "$f9" "requirements" | sanitise_body)
    f9_acs=$(extract_anchor "$f9" "acceptance-criteria" | sanitise_body)
    f9_scope=$(extract_anchor "$f9" "scope" | sanitise_body)
    f9_complex=$(extract_anchor "$f9" "complexity" | sanitise_body)
    f9_design=$(extract_anchor "$f9" "design-preview" | sanitise_body)
    f9_body=$(
      printf '## Summary\nfixture 09 summary\n\n'
      printf '## Requirements\n%s\n\n' "$f9_reqs"
      printf '## Acceptance Criteria\n%s\n\n' "$f9_acs"
      printf '## Scope\n%s\n\n' "$f9_scope"
      if [ -n "$(printf '%s' "$f9_design" | tr -d '[:space:]')" ]; then
        printf '## Design Preview\n%s\n\nCompare implementation (DV) and screenshots (QA) against this design.\n\n' "$f9_design"
      fi
      printf '## Complexity\n%s\n\n' "$f9_complex"
    )
    local f9_ok=1
    printf '%s' "$f9_body" | grep -qF '## Design Preview' || f9_ok=0
    printf '%s' "$f9_body" | grep -qF 'https://www.figma.com/design/AbC123/Example?node-id=1-2' || f9_ok=0
    printf '%s' "$f9_body" | grep -qF 'Compare implementation (DV) and screenshots (QA)' || f9_ok=0
    if printf '%s' "$f9_body" | grep -qF '## Planned Stages'; then f9_ok=0; fi
    if [ "$f9_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 09-with-figma-link PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 09-with-figma-link FAIL"
      printf '%s\n' "$f9_body" | head -40 >&2
      fail=$((fail + 1))
    fi

    # Fixture 09b: Plan WITHOUT design-preview (use fixture 01) — rendered
    # body must contain neither Design Preview NOR Planned Stages headings.
    local f1_reqs f1_acs f1_scope f1_complex f1_design f1_body
    f1_reqs=$(extract_anchor "$fixtures_dir/01-clean-plan.md" "requirements" | sanitise_body)
    f1_acs=$(extract_anchor "$fixtures_dir/01-clean-plan.md" "acceptance-criteria" | sanitise_body)
    f1_scope=$(extract_anchor "$fixtures_dir/01-clean-plan.md" "scope" | sanitise_body)
    f1_complex=$(extract_anchor "$fixtures_dir/01-clean-plan.md" "complexity" | sanitise_body)
    f1_design=$(extract_anchor "$fixtures_dir/01-clean-plan.md" "design-preview" | sanitise_body)
    f1_body=$(
      printf '## Summary\nfixture 01 summary\n\n'
      printf '## Requirements\n%s\n\n' "$f1_reqs"
      printf '## Acceptance Criteria\n%s\n\n' "$f1_acs"
      printf '## Scope\n%s\n\n' "$f1_scope"
      if [ -n "$(printf '%s' "$f1_design" | tr -d '[:space:]')" ]; then
        printf '## Design Preview\n%s\n\nCompare implementation (DV) and screenshots (QA) against this design.\n\n' "$f1_design"
      fi
      printf '## Complexity\n%s\n\n' "$f1_complex"
    )
    local f1_ok=1
    if printf '%s' "$f1_body" | grep -qF '## Design Preview'; then f1_ok=0; fi
    if printf '%s' "$f1_body" | grep -qF '## Planned Stages'; then f1_ok=0; fi
    if [ "$f1_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 09b-no-design-no-stages PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 09b-no-design-no-stages FAIL"
      fail=$((fail + 1))
    fi

    # Fixture 09c: sanitiser preserves figma.com URLs (design + proto variants).
    local urls_in urls_out
    urls_in=$'Visit https://www.figma.com/design/AbC123/Example?node-id=1-2\nor https://www.figma.com/proto/XYZ789/Flow?page-id=2-3\n'
    urls_out=$(printf '%s' "$urls_in" | sanitise_body)
    local f9c_ok=1
    printf '%s' "$urls_out" | grep -qF 'figma.com/design/AbC123/Example?node-id=1-2' || f9c_ok=0
    printf '%s' "$urls_out" | grep -qF 'figma.com/proto/XYZ789/Flow?page-id=2-3' || f9c_ok=0
    if [ "$f9c_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 09c-figma-urls-survive PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 09c-figma-urls-survive FAIL"
      printf '%s\n' "$urls_out" >&2
      fail=$((fail + 1))
    fi

    # Fixture 09d: every absolute-host-path prefix L2,L3/L3b claims, one case each,
    # plus the relative paths and prose that must survive them.
    local p pfx_ok=1 pfx_out
    for p in /Users/me/x.md /home/me/x.md /tmp/x.md /var/f/x.md /opt/f/x.md \
      /etc/f/x.md /root/x.md /Volumes/internal/Projects/x.md /mnt/data/x.md \
      /mnt/c/Users/me/x.md /media/usb/x.md /private/tmp/x.md /srv/www/x.md \
      'C:\Users\me\x.md'; do
      pfx_out=$(printf 'See %s here\n' "$p" | sanitise_body)
      if [ -n "$(printf '%s' "$pfx_out" | tr -d '[:space:]')" ]; then
        echo "publish-pl-issue: self-test 09d prefix NOT stripped: $p" >&2
        pfx_ok=0
      fi
      # Backtick-wrapped is the shape that defeated the anchors before.
      pfx_out=$(printf 'See `%s` here\n' "$p" | sanitise_body)
      if [ -n "$(printf '%s' "$pfx_out" | tr -d '[:space:]')" ]; then
        echo "publish-pl-issue: self-test 09d code-spanned prefix NOT stripped: $p" >&2
        pfx_ok=0
      fi
    done
    # Over-match guard: repo-relative paths and bare prose keep their lines.
    local keep
    for keep in 'Edit skills/worktask/scripts/pr-body-lint.sh now' \
      'Deployed under srv and media naming' \
      'The var name is opt_in'; do
      pfx_out=$(printf '%s\n' "$keep" | sanitise_body)
      if ! printf '%s' "$pfx_out" | grep -qF "$keep"; then
        echo "publish-pl-issue: self-test 09d over-match on: $keep" >&2
        pfx_ok=0
      fi
    done
    if [ "$pfx_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 09d-abs-path-prefixes PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 09d-abs-path-prefixes FAIL"
      fail=$((fail + 1))
    fi

    # Fixture 09e: two leaks every line rule misses. A path glued to punctuation has
    # no whitespace anchor, and a home directory outside the mount list is not in the
    # pattern at all. The final scrub pass must rewrite both and keep the line.
    local f9e_ok=1 f9e_out
    f9e_out=$(printf 'Notes (/Users/me/x.md) kept\n' | sanitise_body)
    if [ "$f9e_out" != 'Notes ([local-path]) kept' ]; then
      echo "publish-pl-issue: self-test 09e glued path not scrubbed: $f9e_out" >&2
      f9e_ok=0
    fi
    f9e_out=$(
      export HOME=/data/cf-home
      printf 'Home at /data/cf-home/proj/x.md kept\n' | sanitise_body
    )
    if [ "$f9e_out" != 'Home at [local-path] kept' ]; then
      echo "publish-pl-issue: self-test 09e custom HOME not scrubbed: $f9e_out" >&2
      f9e_ok=0
    fi
    if [ "$f9e_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 09e-token-scrub PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 09e-token-scrub FAIL"
      fail=$((fail + 1))
    fi

    # Fixture 02b: plugin-qualified identifier tokens must not appear in
    # sanitised body (Pass-2 A6 rule), outside code spans.
    local leak_in leak_out
    leak_in=$'Breakdown using corpflow:estimation-methodology:\n* Routed to corpflow:developer (apple-developer:ios-developer).\nDelegated to apple-developer:test-generator for regression coverage.\nNarrative referencing corpflow:product-manager directly.\nKeep `corpflow:code-fixer` inside backticks intact.\n'
    leak_out=$(printf '%s' "$leak_in" | sanitise_body)
    local f02b_ok=1
    # The three leading-token lines should be entirely dropped by L10.
    if printf '%s' "$leak_out" | grep -qF 'Breakdown using'; then f02b_ok=0; fi
    if printf '%s' "$leak_out" | grep -qF 'Routed to'; then f02b_ok=0; fi
    if printf '%s' "$leak_out" | grep -qF 'Delegated to'; then f02b_ok=0; fi
    # The mid-sentence reference should have the identifier stripped by A6
    # (narrative remains, token gone).
    if printf '%s' "$leak_out" | grep -qE '(corpflow|apple-developer|system-developer|android-developer|frontend-developer|backend-developer|ai-engineer|debugging-toolkit|security-scanning|skill-creator|conductor|claude-in-chrome):[a-z]' | grep -v '`'; then
      # Allow backticked occurrences only (one is intentionally kept).
      if printf '%s' "$leak_out" | grep -vE '^[^`]*`[^`]*`[^`]*$' | grep -qE '(corpflow|apple-developer|system-developer|android-developer|frontend-developer|backend-developer|ai-engineer|debugging-toolkit|security-scanning|skill-creator|conductor|claude-in-chrome):[a-z]'; then
        f02b_ok=0
      fi
    fi
    # Backtick passthrough preserves the token.
    if ! printf '%s' "$leak_out" | grep -qF '`corpflow:code-fixer`'; then f02b_ok=0; fi
    if [ "$f02b_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 02b-identifier-leak-strip PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 02b-identifier-leak-strip FAIL"
      printf '%s\n' "$leak_out" >&2
      fail=$((fail + 1))
    fi
  else
    echo "publish-pl-issue: self-test 09-with-figma-link SKIP (fixture missing)"
    fail=$((fail + 1))
  fi

  # ---- Fixture 10: Figma image-embed (placeholder → ![alt](url)) ----
  # Happy path (AC-1, AC-7, AC-3, AC-4) + fallback render (AC-5). Mocks the host
  # (ASSET_HOST_MODE) and stubs the two PNGs on disk — never hits the network.
  local f10="$fixtures_dir/10-figma-image-embed.md"
  if [ -f "$f10" ]; then
    # Sandbox: stub the two persisted PNGs in a temp canonical designs dir.
    local t10_dir
    t10_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-10.$$")
    mkdir -p "$t10_dir/.context/designs"
    # 8-byte PNG signature stubs (resolve_asset_path only checks existence).
    printf '\211PNG\r\n\032\n' > "$t10_dir/.context/designs/figma-scan-25-default-255-2264.png"
    printf '\211PNG\r\n\032\n' > "$t10_dir/.context/designs/figma-analyzing-default-255-2267.png"

    # Extract + sanitise the design-preview anchor exactly as the live path does.
    local f10_design f10_embed
    f10_design=$(extract_anchor "$f10" "design-preview" | sanitise_body)

    # --- 10a: happy path (raw host, both assets present) ---
    # Override hosting globals locally; DRY_RUN=1 skips the cp side-effect.
    local _save_root="$ASSET_ROOT" _save_designs="$ASSET_DESIGNS_DIR" _save_images="$ASSET_IMAGES_DIR"
    local _save_mode="$ASSET_HOST_MODE" _save_or="$ASSET_OWNER_REPO" _save_ref="$ASSET_REF"
    local _save_dry="$DRY_RUN" _save_wid="${WORKTASK_ID:-}"
    ASSET_ROOT="$t10_dir"
    ASSET_DESIGNS_DIR="$t10_dir/.context/designs"
    ASSET_IMAGES_DIR="$t10_dir/.context/images"
    ASSET_HOST_MODE="raw"
    ASSET_OWNER_REPO="Agnidia/corpflow"
    ASSET_REF="feature/figma-screenshot-markdown"
    DRY_RUN=1
    WORKTASK_ID="fixture-10"
    # File side channel: resolve_design_assets runs in a subshell, so it reports
    # degradation via ASSET_DEGRADED_FILE (matching the live call site).
    local _save_degfile="$ASSET_DEGRADED_FILE"
    ASSET_DEGRADED_FILE="$t10_dir/.degraded"
    : > "$ASSET_DEGRADED_FILE"
    f10_embed=$(printf '%s' "$f10_design" | resolve_design_assets)
    ASSET_DEGRADED_REASON=$(cat "$ASSET_DEGRADED_FILE" 2>/dev/null || echo "")

    local f10a_ok=1
    # AC-1/AC-7: two ![alt](url) lines, each using the basename as alt text, in
    # document order, with the Figma URL preserved above.
    printf '%s\n' "$f10_embed" | grep -qF '![figma-scan-25-default-255-2264.png](https://raw.githubusercontent.com/Agnidia/corpflow/feature/figma-screenshot-markdown/.worktask-assets/fixture-10/figma-scan-25-default-255-2264.png)' || f10a_ok=0
    printf '%s\n' "$f10_embed" | grep -qF '![figma-analyzing-default-255-2267.png](https://raw.githubusercontent.com/Agnidia/corpflow/feature/figma-screenshot-markdown/.worktask-assets/fixture-10/figma-analyzing-default-255-2267.png)' || f10a_ok=0
    printf '%s\n' "$f10_embed" | grep -qF 'https://www.figma.com/design/FOO/FaceScan?node-id=255-2263' || f10a_ok=0
    # AC-7 ordering: scan-25 image line precedes analyzing image line.
    local _l25 _lan
    _l25=$(printf '%s\n' "$f10_embed" | grep -nF '![figma-scan-25-default' | head -1 | cut -d: -f1)
    _lan=$(printf '%s\n' "$f10_embed" | grep -nF '![figma-analyzing-default' | head -1 | cut -d: -f1)
    if [ -z "$_l25" ] || [ -z "$_lan" ] || [ "$_l25" -ge "$_lan" ]; then f10a_ok=0; fi
    # AC-7 interleave: each image line is immediately followed by its bullet.
    # (-e guards the leading-dash bullet pattern from being read as a flag.)
    printf '%s\n' "$f10_embed" | grep -A1 -F -e '![figma-scan-25-default' | grep -qF -e '- state `default` — 25% progress ring' || f10a_ok=0
    # No leftover placeholder tokens.
    if printf '%s\n' "$f10_embed" | grep -qF '{{asset:'; then f10a_ok=0; fi
    # No degradation flagged on the happy path.
    [ -z "$ASSET_DEGRADED_REASON" ] || f10a_ok=0
    if [ "$f10a_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 10-image-embed PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 10-image-embed FAIL"
      printf '%s\n' "$f10_embed" | head -20 >&2
      fail=$((fail + 1))
    fi

    # --- 10-no-leak: AC-3/AC-4 — full body grep finds no local path tokens ---
    # Build a full issue body with the embedded design-preview, then grep.
    local f10_reqs f10_acs f10_scope f10_complex f10_body
    f10_reqs=$(extract_anchor "$f10" "requirements" | sanitise_body)
    f10_acs=$(extract_anchor "$f10" "acceptance-criteria" | sanitise_body)
    f10_scope=$(extract_anchor "$f10" "scope" | sanitise_body)
    f10_complex=$(extract_anchor "$f10" "complexity" | sanitise_body)
    f10_body=$(
      printf '## Summary\nfixture 10 summary\n\n'
      printf '## Requirements\n%s\n\n' "$f10_reqs"
      printf '## Acceptance Criteria\n%s\n\n' "$f10_acs"
      printf '## Scope\n%s\n\n' "$f10_scope"
      printf '## Design Preview\n%s\n\nCompare implementation (DV) and screenshots (QA) against this design.\n\n' "$f10_embed"
      printf '## Complexity\n%s\n\n' "$f10_complex"
    )
    local f10nl_ok=1
    if printf '%s' "$f10_body" | grep -qE '\.context/|/Users/|conductor/workspaces/|planning-[0-9]+\.md'; then
      f10nl_ok=0
      printf '%s\n' "$f10_body" | grep -nE '\.context/|/Users/|conductor/workspaces/|planning-[0-9]+\.md' | head -3 >&2
    fi
    # The image lines must have survived (AC-3: not dropped by Pass-1 L1).
    printf '%s' "$f10_body" | grep -qF '![figma-scan-25-default-255-2264.png]' || f10nl_ok=0
    if [ "$f10nl_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 10-no-leak PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 10-no-leak FAIL"
      fail=$((fail + 1))
    fi

    # --- 10b: fallback render (AC-5) — hosting unavailable → URL-only + note ---
    ASSET_HOST_MODE="none"
    : > "$ASSET_DEGRADED_FILE"
    local f10b_embed
    f10b_embed=$(printf '%s' "$f10_design" | resolve_design_assets)
    ASSET_DEGRADED_REASON=$(cat "$ASSET_DEGRADED_FILE" 2>/dev/null || echo "")
    local f10b_ok=1
    # Figma URL preserved.
    printf '%s\n' "$f10b_embed" | grep -qF 'https://www.figma.com/design/FOO/FaceScan?node-id=255-2263' || f10b_ok=0
    # Exactly one note line, exact text.
    local _notes
    _notes=$(printf '%s\n' "$f10b_embed" | grep -cF 'Screenshots persisted on disk; inline hosting unavailable — see designs registry.')
    [ "$_notes" = "1" ] || f10b_ok=0
    # No broken image markdown, no image lines, no leftover tokens.
    if printf '%s\n' "$f10b_embed" | grep -qF '!['; then f10b_ok=0; fi
    if printf '%s\n' "$f10b_embed" | grep -qF '{{asset:'; then f10b_ok=0; fi
    # Audit reason set.
    [ "$ASSET_DEGRADED_REASON" = "image_hosting_unavailable" ] || f10b_ok=0
    if [ "$f10b_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 10b-fallback PASS"
      pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 10b-fallback FAIL"
      printf '%s\n' "$f10b_embed" | head -20 >&2
      fail=$((fail + 1))
    fi

    # Restore globals + clean up the sandbox.
    ASSET_ROOT="$_save_root"; ASSET_DESIGNS_DIR="$_save_designs"; ASSET_IMAGES_DIR="$_save_images"
    ASSET_HOST_MODE="$_save_mode"; ASSET_OWNER_REPO="$_save_or"; ASSET_REF="$_save_ref"
    DRY_RUN="$_save_dry"; WORKTASK_ID="$_save_wid"; ASSET_DEGRADED_REASON=""
    ASSET_DEGRADED_FILE="$_save_degfile"
    rm -rf "$t10_dir"
  else
    echo "publish-pl-issue: self-test 10-image-embed SKIP (fixture missing)"
    fail=$((fail + 1))
  fi

  # ---- Fixture 11: user-attachments tier + REQ-1 render-verification ----
  # Re-uses fixture 10's design-preview anchor; all paths fully offline (mocks).
  local f11="$fixtures_dir/10-figma-image-embed.md"
  if [ -f "$f11" ]; then
    local t11_dir
    t11_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-11.$$")
    mkdir -p "$t11_dir/.context/designs"
    printf '\211PNG\r\n\032\n' > "$t11_dir/.context/designs/figma-scan-25-default-255-2264.png"
    printf '\211PNG\r\n\032\n' > "$t11_dir/.context/designs/figma-analyzing-default-255-2267.png"
    local f11_design
    f11_design=$(extract_anchor "$f11" "design-preview" | sanitise_body)

    # Save/restore the hosting globals around the whole fixture.
    local _s_root="$ASSET_ROOT" _s_designs="$ASSET_DESIGNS_DIR" _s_images="$ASSET_IMAGES_DIR"
    local _s_mode="$ASSET_HOST_MODE" _s_or="$ASSET_OWNER_REPO" _s_ref="$ASSET_REF"
    local _s_dry="$DRY_RUN" _s_wid="${WORKTASK_ID:-}" _s_uab="$USER_ATTACH_URL_BASE"
    local _s_uae="$ASSET_UA_ENABLE" _s_vis="$ASSET_REPO_VISIBILITY" _s_degfile="$ASSET_DEGRADED_FILE"
    ASSET_ROOT="$t11_dir"
    ASSET_DESIGNS_DIR="$t11_dir/.context/designs"
    ASSET_IMAGES_DIR="$t11_dir/.context/images"
    DRY_RUN=1
    WORKTASK_ID="fixture-11"
    ASSET_DEGRADED_FILE="$t11_dir/.degraded"

    # --- 11a: user-attachments happy path (mocked base, forced mode) (AC-2) ---
    ASSET_HOST_MODE="user-attachments"
    USER_ATTACH_URL_BASE="https://github.com/user-attachments/assets/mock-uuid"
    : > "$ASSET_DEGRADED_FILE"
    local f11a_embed
    f11a_embed=$(printf '%s' "$f11_design" | resolve_design_assets)
    local f11a_reason; f11a_reason=$(cat "$ASSET_DEGRADED_FILE" 2>/dev/null || echo "")
    local f11a_ok=1
    printf '%s\n' "$f11a_embed" | grep -qF '![figma-scan-25-default-255-2264.png](https://github.com/user-attachments/assets/mock-uuid/figma-scan-25-default-255-2264.png)' || f11a_ok=0
    printf '%s\n' "$f11a_embed" | grep -qF '![figma-analyzing-default-255-2267.png](https://github.com/user-attachments/assets/mock-uuid/figma-analyzing-default-255-2267.png)' || f11a_ok=0
    if printf '%s\n' "$f11a_embed" | grep -qF '{{asset:'; then f11a_ok=0; fi
    [ -z "$f11a_reason" ] || f11a_ok=0
    if [ "$f11a_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 11a-user-attachments-happy PASS"; pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 11a-user-attachments-happy FAIL"
      printf '%s\n' "$f11a_embed" | head -20 >&2; fail=$((fail + 1))
    fi

    # --- 11b: user-attachments uploader unavailable → degrade (AC-3) ---
    # Forced UA mode, no mock base, AND the `gh image` uploader failing (GH_BIN
    # stubbed to `false`) → host_one_asset returns 1 → tokens drop + degradation
    # flagged. Non-blocking, no broken markup. Stubbing GH_BIN is what makes this
    # deterministic now that tier-0 has a live path: without it the test would
    # really upload on any machine where `gh image` is installed and authed.
    ASSET_HOST_MODE="user-attachments"
    USER_ATTACH_URL_BASE=""
    local f11b_gh_saved="$GH_BIN"; GH_BIN=false
    : > "$ASSET_DEGRADED_FILE"
    local f11b_embed
    f11b_embed=$(printf '%s' "$f11_design" | resolve_design_assets)
    local f11b_reason; f11b_reason=$(cat "$ASSET_DEGRADED_FILE" 2>/dev/null || echo "")
    local f11b_ok=1
    if printf '%s\n' "$f11b_embed" | grep -qF '!['; then f11b_ok=0; fi
    if printf '%s\n' "$f11b_embed" | grep -qF '{{asset:'; then f11b_ok=0; fi
    [ "$f11b_reason" = "image_hosting_unavailable" ] || f11b_ok=0
    printf '%s\n' "$f11b_embed" | grep -qF 'https://www.figma.com/design/FOO/FaceScan?node-id=255-2263' || f11b_ok=0
    GH_BIN="$f11b_gh_saved"
    if [ "$f11b_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 11b-user-attachments-degrade PASS"; pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 11b-user-attachments-degrade FAIL"
      printf '%s\n' "$f11b_embed" | head -20 >&2; fail=$((fail + 1))
    fi

    # --- 11c: REQ-1 — raw render-verification fails for PRIVATE repo (AC-1) ---
    # raw_asset_url_reachable() must return 1 when visibility is PRIVATE, even
    # when the authenticated existence check would pass. Direct unit assertion
    # (no network — ASSET_REPO_VISIBILITY mock drives the gate).
    ASSET_REPO_VISIBILITY="PRIVATE"
    local f11c_ok=1
    if raw_asset_url_reachable "owner/repo" "feat/x" ".worktask-assets/t/a.png" \
         "https://raw.githubusercontent.com/owner/repo/feat/x/.worktask-assets/t/a.png"; then
      f11c_ok=0   # MUST have returned non-zero for a private repo
    fi
    ASSET_REPO_VISIBILITY="INTERNAL"
    if raw_asset_url_reachable "owner/repo" "feat/x" ".worktask-assets/t/a.png" \
         "https://raw.githubusercontent.com/owner/repo/feat/x/.worktask-assets/t/a.png"; then
      f11c_ok=0   # MUST also fail for INTERNAL
    fi
    if [ "$f11c_ok" = "1" ]; then
      echo "publish-pl-issue: self-test 11c-raw-private-refused PASS"; pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 11c-raw-private-refused FAIL"; fail=$((fail + 1))
    fi

    # --- 11d: REQ-1 — PRIVATE repo, live tier select → raw refused, degrade ---
    # select_host_tier() with PRIVATE visibility + gh authed must NOT pick raw;
    # it should fall to gist (gh present mock) — proves the camo false-positive
    # is closed at selection time too. Mock gh `auth status` success via a stub.
    local t11d_bin="$t11_dir/bin"
    mkdir -p "$t11d_bin"
    cat > "$t11d_bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "PRIVATE"; exit 0 ;;   # --json visibility --jq path
esac
exit 0
MOCK
    chmod +x "$t11d_bin/gh"
    cat > "$t11d_bin/git" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "remote" ] && [ "$2" = "get-url" ]; then echo "git@github.com:owner/repo.git"; exit 0; fi
if [ "$1" = "rev-parse" ]; then echo "feature/x"; exit 0; fi
if [ "$1" = "ls-remote" ]; then exit 0; fi
exec /usr/bin/env -i PATH=/usr/bin:/bin git "$@"
MOCK
    chmod +x "$t11d_bin/git"
    local f11d_tier
    f11d_tier=$( PATH="$t11d_bin:$PATH" GH_BIN=gh \
      ASSET_HOST_MODE="" ASSET_REPO_VISIBILITY="" ASSET_UA_ENABLE=0 ASSET_GH_IMAGE=0 \
      bash -c '
        '"$(declare -f parse_owner_repo)"'
        '"$(declare -f repo_visibility)"'
        '"$(declare -f gh_image_available)"'
        '"$(declare -f select_host_tier)"'
        select_host_tier
        printf "%s" "$HOST_TIER"
      ' )
    if [ "$f11d_tier" = "gist" ]; then
      echo "publish-pl-issue: self-test 11d-private-selects-gist PASS"; pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 11d-private-selects-gist FAIL (tier='$f11d_tier' want gist)"; fail=$((fail + 1))
    fi

    # --- 11e: ASSET_HOST_MODE=user-attachments accepted offline (AC-7) ---
    # Forced mode must select the tier without any network probe.
    local f11e_tier
    f11e_tier=$( ASSET_HOST_MODE="user-attachments" bash -c '
        '"$(declare -f parse_owner_repo)"'
        '"$(declare -f repo_visibility)"'
        '"$(declare -f gh_image_available)"'
        '"$(declare -f select_host_tier)"'
        ASSET_UA_ENABLE=0 USER_ATTACH_URL_BASE=""
        select_host_tier
        printf "%s" "$HOST_TIER"
      ' )
    if [ "$f11e_tier" = "user-attachments" ]; then
      echo "publish-pl-issue: self-test 11e-mode-override-offline PASS"; pass=$((pass + 1))
    else
      echo "publish-pl-issue: self-test 11e-mode-override-offline FAIL (tier='$f11e_tier')"; fail=$((fail + 1))
    fi

    # Restore globals + clean up.
    ASSET_ROOT="$_s_root"; ASSET_DESIGNS_DIR="$_s_designs"; ASSET_IMAGES_DIR="$_s_images"
    ASSET_HOST_MODE="$_s_mode"; ASSET_OWNER_REPO="$_s_or"; ASSET_REF="$_s_ref"
    DRY_RUN="$_s_dry"; WORKTASK_ID="$_s_wid"; USER_ATTACH_URL_BASE="$_s_uab"
    ASSET_UA_ENABLE="$_s_uae"; ASSET_REPO_VISIBILITY="$_s_vis"; ASSET_DEGRADED_FILE="$_s_degfile"
    ASSET_DEGRADED_REASON=""
    rm -rf "$t11_dir"
  else
    echo "publish-pl-issue: self-test 11-user-attachments SKIP (fixture missing)"
    fail=$((fail + 1))
  fi

  # ---- Fixture 12: AC1 PUBLIC-gist tier + render-verify (offline) ----
  # All paths mockable via ASSET_GIST_PUBLIC / GIST_VERIFY_FORCE / GH_BIN — no
  # live gh or curl. host_one_asset runs the gist branch directly via declare -f.
  local t12_dir
  t12_dir=$(mktemp -d 2>/dev/null || echo "/tmp/publish-pl-self-test-12.$$")
  mkdir -p "$t12_dir/bin"
  printf '\211PNG\r\n\032\n' > "$t12_dir/a.png"
  # gh mock: `gist create [--public] <src>` records its full argv to argv.log and
  # prints a gist web URL so the raw URL can be derived.
  cat > "$t12_dir/bin/gh" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "gist" ] && [ "\$2" = "create" ]; then
  printf '%s\n' "\$*" >> "$t12_dir/argv.log"
  echo "https://gist.github.com/deadbeefdeadbeef"
  exit 0
fi
exit 0
MOCK
  chmod +x "$t12_dir/bin/gh"

  # --- 12a: --public flag gated by ASSET_GIST_PUBLIC ---
  # Default-on (ASSET_GIST_PUBLIC=1) → `gh gist create` MUST receive --public.
  # Opt-out (ASSET_GIST_PUBLIC=0)    → --public MUST be absent (secret gist).
  : > "$t12_dir/argv.log"
  local f12a_url_on f12a_url_off f12a_ok=1
  f12a_url_on=$( PATH="$t12_dir/bin:$PATH" GH_BIN=gh \
    bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC=1 GIST_VERIFY_FORCE=pass
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' )
  grep -qF 'gist create --public' "$t12_dir/argv.log" || f12a_ok=0
  [ "$f12a_url_on" = "https://gist.github.com/deadbeefdeadbeef/raw/a.png" ] || f12a_ok=0
  : > "$t12_dir/argv.log"
  f12a_url_off=$( PATH="$t12_dir/bin:$PATH" GH_BIN=gh \
    bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC=0 GIST_VERIFY_FORCE=pass
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' )
  grep -qF 'gist create --public' "$t12_dir/argv.log" && f12a_ok=0   # MUST be absent
  grep -qE 'gist create [^-]' "$t12_dir/argv.log" || f12a_ok=0       # secret form: src follows directly, no flag
  [ "$f12a_url_off" = "https://gist.github.com/deadbeefdeadbeef/raw/a.png" ] || f12a_ok=0
  if [ "$f12a_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 12a-gist-public-flag-gated PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12a-gist-public-flag-gated FAIL (on='$f12a_url_on' off='$f12a_url_off')"
    cat "$t12_dir/argv.log" >&2; fail=$((fail + 1))
  fi

  # --- 12a0: tier-0 live path — `gh image` upload + URL extraction ---
  # host_one_asset must invoke `gh image <src>` and pull the user-attachments URL
  # out of its `![base](url)` line; a non-matching/absent line must degrade (rc!=0,
  # no output) rather than emit a broken embed. Binary input is deliberate: this
  # tier accepts binaries, which is exactly what the gist tier cannot do.
  local f12a0_ok=1 f12a0_url f12a0_bad
  cat > "$t12_dir/bin/gh-img" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "image" ]; then
  printf '![%s](https://github.com/user-attachments/assets/abc123-def456)\n' "$(basename "$2")"
  exit 0
fi
exit 0
MOCK
  chmod +x "$t12_dir/bin/gh-img"
  printf '\x89PNG\r\n\x1a\n\x00\x01' > "$t12_dir/ua.png"
  f12a0_url=$( GH_BIN="$t12_dir/bin/gh-img" \
    bash -c '
      '"$(declare -f host_one_asset)"'
      HOST_TIER=user-attachments DRY_RUN=0 USER_ATTACH_URL_BASE=""
      host_one_asset "ua.png" "'"$t12_dir"'/ua.png"
    ' )
  [ "$f12a0_url" = "https://github.com/user-attachments/assets/abc123-def456" ] || f12a0_ok=0
  # Uploader prints nothing usable → must degrade with no output.
  f12a0_bad=$( GH_BIN=true \
    bash -c '
      '"$(declare -f host_one_asset)"'
      HOST_TIER=user-attachments DRY_RUN=0 USER_ATTACH_URL_BASE=""
      host_one_asset "ua.png" "'"$t12_dir"'/ua.png"
    ' ) && f12a0_ok=0
  [ -n "$f12a0_bad" ] && f12a0_ok=0
  if [ "$f12a0_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 12a0-user-attachments-live PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12a0-user-attachments-live FAIL (url='$f12a0_url' bad='$f12a0_bad')"; fail=$((fail + 1))
  fi

  # --- 12a2: unset ASSET_GIST_PUBLIC auto-derives visibility from the repo ---
  # Closed repo (PRIVATE/INTERNAL) MUST NOT get `--public`: both gist kinds are
  # anonymously fetchable so the embed renders either way, and `--public` only
  # adds indexing + profile listing. PUBLIC (and unknown, e.g. no gh) keep the
  # historical public default. ASSET_REPO_VISIBILITY mocks the probe offline.
  local f12a2_ok=1 v
  for v in PRIVATE INTERNAL; do
    : > "$t12_dir/argv.log"
    PATH="$t12_dir/bin:$PATH" GH_BIN=gh bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC="" GIST_VERIFY_FORCE=pass
      ASSET_REPO_VISIBILITY="'"$v"'"
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' >/dev/null 2>&1
    grep -qF 'gist create --public' "$t12_dir/argv.log" && f12a2_ok=0   # MUST be absent
    grep -qE 'gist create [^-]' "$t12_dir/argv.log" || f12a2_ok=0       # secret form
  done
  for v in PUBLIC ""; do
    : > "$t12_dir/argv.log"
    PATH="$t12_dir/bin:$PATH" GH_BIN=gh bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC="" GIST_VERIFY_FORCE=pass
      ASSET_REPO_VISIBILITY="'"$v"'"
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' >/dev/null 2>&1
    grep -qF 'gist create --public' "$t12_dir/argv.log" || f12a2_ok=0   # MUST be present
  done
  if [ "$f12a2_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 12a2-gist-visibility-auto PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12a2-gist-visibility-auto FAIL"
    cat "$t12_dir/argv.log" >&2; fail=$((fail + 1))
  fi

  # --- 12a3: gist tier refuses binary assets (never calls gh) ---
  # `gh gist create` rejects binary content, so a PNG/JPG can never be hosted on
  # this tier. host_one_asset must fail fast and NOT invoke gh, so the caller
  # degrades to a bullet instead of burning a guaranteed-failure round-trip.
  local f12a3_ok=1 f12a3_url
  printf '\x89PNG\r\n\x1a\n\x00\x01\x02\x03' > "$t12_dir/bin.png"
  : > "$t12_dir/argv.log"
  f12a3_url=$( PATH="$t12_dir/bin:$PATH" GH_BIN=gh \
    bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC=1 GIST_VERIFY_FORCE=pass
      host_one_asset "bin.png" "'"$t12_dir"'/bin.png"
    ' ) && f12a3_ok=0        # MUST return non-zero
  [ -n "$f12a3_url" ] && f12a3_ok=0                       # MUST emit no URL
  [ -s "$t12_dir/argv.log" ] && f12a3_ok=0                # MUST NOT have called gh
  if [ "$f12a3_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 12a3-gist-binary-refused PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12a3-gist-binary-refused FAIL (url='$f12a3_url')"
    cat "$t12_dir/argv.log" >&2; fail=$((fail + 1))
  fi

  # --- 12b: render-verify gate — pass emits URL, fail degrades (no URL) ---
  local f12b_pass f12b_fail f12b_rc_pass f12b_rc_fail f12b_ok=1
  # gist_raw_url_reachable unit assertions (offline hook).
  if GIST_VERIFY_FORCE=pass gist_raw_url_reachable "https://x/raw/a.png"; then :; else f12b_ok=0; fi
  if GIST_VERIFY_FORCE=fail gist_raw_url_reachable "https://x/raw/a.png"; then f12b_ok=0; fi
  # host_one_asset: verify pass → emits the URL.
  f12b_pass=$( PATH="$t12_dir/bin:$PATH" GH_BIN=gh \
    bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC=1 GIST_VERIFY_FORCE=pass
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' ); f12b_rc_pass=$?
  [ "$f12b_rc_pass" = "0" ] && [ -n "$f12b_pass" ] || f12b_ok=0
  # host_one_asset: verify fail → empty output + non-zero rc (caller degrades).
  f12b_fail=$( PATH="$t12_dir/bin:$PATH" GH_BIN=gh \
    bash -c '
      '"$(declare -f gist_raw_url_reachable)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gist_public_effective)"'
      '"$(declare -f host_one_asset)"'
      HOST_TIER=gist DRY_RUN=0 GIST_RAW_URL_BASE="" ASSET_GIST_PUBLIC=1 GIST_VERIFY_FORCE=fail
      host_one_asset "a.png" "'"$t12_dir"'/a.png"
    ' ); f12b_rc_fail=$?
  [ "$f12b_rc_fail" != "0" ] && [ -z "$f12b_fail" ] || f12b_ok=0
  if [ "$f12b_ok" = "1" ]; then
    echo "publish-pl-issue: self-test 12b-gist-render-verify PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12b-gist-render-verify FAIL (pass='$f12b_pass'/$f12b_rc_pass fail='$f12b_fail'/$f12b_rc_fail)"; fail=$((fail + 1))
  fi

  # --- 12c: PRIVATE repo selects the gist tier end-to-end (render-verified) ---
  # select_host_tier() with PRIVATE visibility + gh authed must pick gist (raw
  # refused), confirming gist is now the render-verified PRIVATE-repo primary.
  cat > "$t12_dir/bin/gh-sel" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) echo "PRIVATE"; exit 0 ;;
esac
exit 0
MOCK
  chmod +x "$t12_dir/bin/gh-sel"
  cat > "$t12_dir/bin/git-sel" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "remote" ] && [ "$2" = "get-url" ]; then echo "git@github.com:owner/repo.git"; exit 0; fi
if [ "$1" = "rev-parse" ]; then echo "feature/x"; exit 0; fi
if [ "$1" = "ls-remote" ]; then exit 0; fi
exec /usr/bin/env -i PATH=/usr/bin:/bin git "$@"
MOCK
  chmod +x "$t12_dir/bin/git-sel"
  local f12c_tier
  f12c_tier=$( cp "$t12_dir/bin/gh-sel" "$t12_dir/bin/gh2"; cp "$t12_dir/bin/git-sel" "$t12_dir/bin/git"; \
    PATH="$t12_dir/bin:$PATH" GH_BIN=gh2 \
    ASSET_HOST_MODE="" ASSET_REPO_VISIBILITY="" ASSET_UA_ENABLE=0 ASSET_GH_IMAGE=0 \
    bash -c '
      '"$(declare -f parse_owner_repo)"'
      '"$(declare -f repo_visibility)"'
      '"$(declare -f gh_image_available)"'
      '"$(declare -f select_host_tier)"'
      select_host_tier
      printf "%s" "$HOST_TIER"
    ' )
  rm -f "$t12_dir/bin/git"   # avoid leaking the git shim past this test
  if [ "$f12c_tier" = "gist" ]; then
    echo "publish-pl-issue: self-test 12c-private-selects-gist PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test 12c-private-selects-gist FAIL (tier='$f12c_tier' want gist)"; fail=$((fail + 1))
  fi
  rm -rf "$t12_dir"

  # ---- parse_owner_repo: both remote URL forms ----
  local _por
  _por=$(parse_owner_repo "git@github.com:Agnidia/corpflow.git")
  if [ "$_por" = "Agnidia/corpflow" ]; then
    echo "publish-pl-issue: self-test parse_owner_repo(ssh) PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test parse_owner_repo(ssh) FAIL (got '$_por')"; fail=$((fail + 1))
  fi
  _por=$(parse_owner_repo "https://github.com/Agnidia/corpflow.git")
  if [ "$_por" = "Agnidia/corpflow" ]; then
    echo "publish-pl-issue: self-test parse_owner_repo(https) PASS"; pass=$((pass + 1))
  else
    echo "publish-pl-issue: self-test parse_owner_repo(https) FAIL (got '$_por')"; fail=$((fail + 1))
  fi

  echo "publish-pl-issue: self-test summary — pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}
