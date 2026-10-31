#!/usr/bin/env bash
# attach-visual-evidence-selftest.sh — the `--self-test` harness for attach-visual-evidence.sh.
#
# SOURCED, never executed: attach-visual-evidence.sh loads this file only on the `--self-test`
# path, so the production path never pays for it. Sourcing leaves the caller's
# `$0` and every function it has already defined in scope — this file reads the
# caller's helpers and is not standalone.
#
# Contract: defines `run_self_tests`, returning 0 when every case passes.

# ---------- self-test -------------------------------------------------------
run_self_tests() {
  local pass=0 fail=0
  local self="$0"

  _mk_sandbox() { # echoes a fresh sandbox dir with .context/{logs,images/<wid>}
    local td; td=$(mktemp -d)
    mkdir -p "$td/.context/logs" "$td/.context/images/wid-test"
    printf '{"version":1,"worktask_id":"wid-test","run_index":0,"metadata":{"requires_screenshots":true,"github_issue_url":"https://github.com/o/r/issues/9"}}' \
      > "$td/.context/state.json"
    printf '%s' "$td"
  }
  _manifest_with_captures() { # $1=dir : write a 2-capture manifest + dummy PNGs
    local d="$1/.context/images/wid-test"
    cat > "$d/screenshots.md" <<'MD'
# Screenshots — wid-test
| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |
|---|------|------|-------|----------|---------|---------|----------|------------|
| 01 | home | dv-01-home.png | 1000 | apple | apple_adapter | home screen | 2026-01-01T00:00:00Z | — |
| 02 | diff | dv-02-diff.txt | 0 | all | cli_fallback | tool_missing | 2026-01-01T00:00:00Z | — |
MD
    printf 'x' > "$d/dv-01-home.png"
  }
  _ok()   { echo "attach-visual-evidence: $1 PASS"; pass=$((pass+1)); }
  _fail() { echo "attach-visual-evidence: $1 FAIL${2:+ — $2}"; fail=$((fail+1)); }

  # GH mock: records calls, simulates `issue view` (marker presence via file) and
  # `issue comment`. Marker store = $GH_MARKER_DIR/<target> (per-issue). The mock also answers
  # `pr view` for the completion resolver/summary:
  #   $GH_PR_BODY    → PR body for keyword scan + title/body fallback
  #   $GH_PR_REFS    → space-separated issue numbers for closingIssuesReferences
  #   $GH_PR_TITLE   → PR title (title,body fallback)
  #   $GH_NO_CURRENT_PR → a ref-less `pr view` fails; $GH_PR_BODY_<n>/$GH_PR_TITLE_<n> → data
  #                   for PR <n>; $GH_CALL_LOG → file receiving every `pr view` argv
  #   $GH_FAIL_ISSUES→ space-separated issue numbers whose `issue comment` fails
  _mk_gh() { # $1=dir
    cat > "$1/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Per-target marker store path. target = the issue ref/number ($3).
_store() {
  # Per-issue marker file under $GH_MARKER_DIR. With the dir unset there is no
  # per-target store, so sink to /dev/null rather than composing /dev/null/<target>,
  # which is ENOTDIR and would make every read and write in the mock fail.
  if [ -z "${GH_MARKER_DIR:-}" ]; then
    printf '/dev/null'
    return 0
  fi
  printf '%s/%s' "$GH_MARKER_DIR" "$(printf '%s' "${1:-_}" | tr '/:' '__')"
}
case "$1 $2" in
  "pr view")
    [ -n "${GH_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_CALL_LOG"
    # Ref-less call = the checkout's branch PR (the ledger pr_url is the fallback). GH_NO_CURRENT_PR=1 → none.
    case "${3:-}" in
      --*) [ -n "${GH_NO_CURRENT_PR:-}" ] && exit 1 ;;
      *)   # per-ref data: GH_PR_BODY_<n>, GH_PR_TITLE_<n> (n = trailing number of the ref)
           _n=${3##*/}; _b="GH_PR_BODY_$_n"; _t="GH_PR_TITLE_$_n"
           if [ -n "${!_b:-}" ] || [ -n "${!_t:-}" ]; then
             GH_PR_BODY=${!_b:-}; GH_PR_TITLE=${!_t:-}
           fi ;;
    esac
    # Determine which --json field was asked for.
    if printf '%s' "$*" | grep -q 'closingIssuesReferences'; then
      for n in ${GH_PR_REFS:-}; do printf '%s\n' "$n"; done
    elif printf '%s' "$*" | grep -q 'title,body'; then
      printf '%s\n\n%s\n' "${GH_PR_TITLE:-}" "${GH_PR_BODY:-}"
    else
      # --json body
      printf '%s\n' "${GH_PR_BODY:-}"
    fi
    exit 0 ;;
  "issue view")
    # --json comments --jq ... : echo stored comment bodies for this target.
    s=$(_store "$3"); [ -f "$s" ] && cat "$s"
    exit 0 ;;
  "issue comment")
    # Simulated failure for selected issues (f12).
    for f in ${GH_FAIL_ISSUES:-}; do [ "$f" = "$3" ] && exit 1; done
    body=$(cat); s=$(_store "$3"); printf '%s\n' "$body" >> "$s"
    echo "https://github.com/o/r/issues/$3#comment-1"; exit 0 ;;
  "repo view") echo "${GH_ORIGIN_REPO:-o/r}"; exit 0 ;;
  "auth status") exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$1/bin/gh"
  }

  # ---- f1: --emit pr with captures + mock raw tier → hosted URLs, no broken ![]()
  local d1; d1=$(_mk_sandbox); _manifest_with_captures "$d1"
  local out1
  out1=$(STATE_FILE="$d1/.context/state.json" WORKSPACE_ROOT="$d1" \
         ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
         bash "$self" --emit pr 2>/dev/null)
  if printf '%s' "$out1" | grep -q '^## Visual evidence' && \
     printf '%s' "$out1" | grep -q '^!\[dv-01 home screen\](https://raw.githubusercontent.com/' && \
     ! printf '%s' "$out1" | grep -qE '\]\(\)|\]\(\.context/'; then
    _ok "f1-emit-pr-hosted"
  else
    _fail "f1-emit-pr-hosted" "$(printf '%s' "$out1" | head -8 | tr '\n' '~')"
  fi
  # .txt placeholder must be a bullet, never an embed.
  if printf '%s' "$out1" | grep -q '^- dv-02-diff.txt' && \
     ! printf '%s' "$out1" | grep -q '!\[.*dv-02-diff.txt'; then
    _ok "f1-txt-bullet"
  else
    _fail "f1-txt-bullet"
  fi
  rm -rf "$d1"

  # ---- f2: --emit pr PRIVATE + no gist mock → none-tier note, zero ![](
  local d2; d2=$(_mk_sandbox); _manifest_with_captures "$d2"
  local out2
  out2=$(STATE_FILE="$d2/.context/state.json" WORKSPACE_ROOT="$d2" \
         ASSET_HOST_MODE=none ASSET_REPO_VISIBILITY=PRIVATE DRY_RUN=1 \
         bash "$self" --emit pr 2>/dev/null)
  if printf '%s' "$out2" | grep -q '^## Visual evidence' && \
     printf '%s' "$out2" | grep -qi 'inline hosting unavailable' && \
     ! printf '%s' "$out2" | grep -qE '!\['; then
    _ok "f2-private-none-tier"
  else
    _fail "f2-private-none-tier" "$(printf '%s' "$out2" | head -8 | tr '\n' '~')"
  fi
  rm -rf "$d2"

  # ---- f3: --emit pr with skip-rationale manifest → empty stdout + skipped row
  local d3; d3=$(_mk_sandbox)
  cat > "$d3/.context/images/wid-test/screenshots.md" <<'MD'
# Screenshots — wid-test

> Skipped: `metadata.requires_screenshots = false`. Rationale: no UI.
MD
  local out3
  out3=$(STATE_FILE="$d3/.context/state.json" WORKSPACE_ROOT="$d3" \
         ASSET_HOST_MODE=raw DRY_RUN=1 bash "$self" --emit pr 2>/dev/null)
  if [ -z "$out3" ] && grep -q '"reason":"no_captures"' "$d3/.context/logs/audit.jsonl" 2>/dev/null; then
    _ok "f3-skip-manifest-empty"
  else
    _fail "f3-skip-manifest-empty" "out='${out3:0:40}'"
  fi
  rm -rf "$d3"

  # ---- f4: --post issue first run → one comment + ok row
  local d4; d4=$(_mk_sandbox); _manifest_with_captures "$d4"
  mkdir -p "$d4/bin"; _mk_gh "$d4"
  local mdir4="$d4/markers"; mkdir -p "$mdir4"
  ( PATH="$d4/bin:$PATH" STATE_FILE="$d4/.context/state.json" WORKSPACE_ROOT="$d4" \
    GH_BIN=gh GH_MARKER_DIR="$mdir4" ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
    bash "$self" --post issue >/dev/null 2>&1 )
  if grep -q '"action":"visual_evidence_issue_commented"' "$d4/.context/logs/audit.jsonl" 2>/dev/null && \
     grep -q '"result":"ok"' "$d4/.context/logs/audit.jsonl" 2>/dev/null && \
     grep -rqF "<!-- visual-evidence:wid-test:0 -->" "$mdir4"; then
    _ok "f4-post-issue-first"
  else
    _fail "f4-post-issue-first" "$(tail -1 "$d4/.context/logs/audit.jsonl" 2>/dev/null)"
  fi

  # ---- f5: --post issue second run, marker present → skipped/already_published
  ( PATH="$d4/bin:$PATH" STATE_FILE="$d4/.context/state.json" WORKSPACE_ROOT="$d4" \
    GH_BIN=gh GH_MARKER_DIR="$mdir4" ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
    bash "$self" --post issue >/dev/null 2>&1 )
  local marker_count; marker_count=$(cat "$mdir4"/* 2>/dev/null | grep -cF "<!-- visual-evidence:wid-test:0 -->")
  if [ "$marker_count" -eq 1 ] && \
     grep -q '"reason":"already_published"' "$d4/.context/logs/audit.jsonl" 2>/dev/null; then
    _ok "f5-post-issue-idempotent"
  else
    _fail "f5-post-issue-idempotent" "marker_count=$marker_count"
  fi
  rm -rf "$d4"

  # ---- f6: --post issue without github_issue_url → deferred/no_issue_url
  local d6; d6=$(_mk_sandbox); _manifest_with_captures "$d6"
  # strip the url
  jq 'del(.metadata.github_issue_url)' "$d6/.context/state.json" > "$d6/.context/state.json.t" \
    && mv "$d6/.context/state.json.t" "$d6/.context/state.json"
  mkdir -p "$d6/bin"; _mk_gh "$d6"
  ( PATH="$d6/bin:$PATH" STATE_FILE="$d6/.context/state.json" WORKSPACE_ROOT="$d6" \
    GH_BIN=gh ASSET_HOST_MODE=raw DRY_RUN=1 bash "$self" --post issue >/dev/null 2>&1 )
  if grep -q '"result":"deferred"' "$d6/.context/logs/audit.jsonl" 2>/dev/null && \
     grep -q '"reason":"no_issue_url"' "$d6/.context/logs/audit.jsonl" 2>/dev/null; then
    _ok "f6-post-issue-no-url"
  else
    _fail "f6-post-issue-no-url" "$(tail -1 "$d6/.context/logs/audit.jsonl" 2>/dev/null)"
  fi
  rm -rf "$d6"

  # ---- f7: .txt placeholder + oversize rows → bullets only, zero broken ![](
  local d7; d7=$(_mk_sandbox)
  local dd="$d7/.context/images/wid-test"
  cat > "$dd/screenshots.md" <<'MD'
# Screenshots — wid-test
| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |
|---|------|------|-------|----------|---------|---------|----------|------------|
| 01 | diff | dv-01-diff.txt | 0 | all | cli_fallback | tool_missing | 2026-01-01T00:00:00Z | — |

## Out-of-budget files (link-only)

- oversize/dv-02-big.png: 740000 after quantize, exceeds 500 KB
MD
  local out7
  out7=$(STATE_FILE="$d7/.context/state.json" WORKSPACE_ROOT="$d7" \
         ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
         bash "$self" --emit pr 2>/dev/null)
  if printf '%s' "$out7" | grep -q '^- dv-01-diff.txt' && \
     printf '%s' "$out7" | grep -q '^- oversize/dv-02-big.png' && \
     ! printf '%s' "$out7" | grep -qE '!\['; then
    _ok "f7-bullets-no-embed"
  else
    _fail "f7-bullets-no-embed" "$(printf '%s' "$out7" | tr '\n' '~')"
  fi
  rm -rf "$d7"

  # ---- f8: resolve_related_issues — keyword-only / refs-only / union+dedup ----
  # Drive the resolver directly via declare -f with a gh mock on PATH. All
  # offline (GH_PR_BODY / GH_PR_REFS mocks).
  local d8; d8=$(_mk_sandbox); mkdir -p "$d8/bin"; _mk_gh "$d8"
  _resolve() { # $1=body $2=refs ; echoes resolver output (sorted unique ints)
    PATH="$d8/bin:$PATH" GH_BIN=gh GH_PR_BODY="$1" GH_PR_REFS="$2" \
      WORKTASK_ID=wid-test RUN_INDEX=0 \
      bash -c '
        GH_BIN=gh
        '"$(declare -f resolve_related_issues)"'
        resolve_related_issues ""
      '
  }
  local r_kw r_refs r_union f8_ok=1
  r_kw=$(_resolve "Closes #10"$'\n'"Fixes #12" "")
  [ "$(printf '%s' "$r_kw" | tr '\n' ' ')" = "10 12" ] || f8_ok=0
  r_refs=$(_resolve "no keywords here" "12 15")
  [ "$(printf '%s' "$r_refs" | tr '\n' ' ')" = "12 15" ] || f8_ok=0
  r_union=$(_resolve "Closes #10" "12 10")
  [ "$(printf '%s' "$r_union" | tr '\n' ' ')" = "10 12" ] || f8_ok=0
  if [ "$f8_ok" = "1" ]; then
    _ok "f8-resolve-union-dedup"
  else
    _fail "f8-resolve-union-dedup" "kw='$(printf '%s' "$r_kw" | tr '\n' ',')' refs='$(printf '%s' "$r_refs" | tr '\n' ',')' union='$(printf '%s' "$r_union" | tr '\n' ',')'"
  fi
  rm -rf "$d8"

  # ---- f9: --post completion first run → one comment per issue + ok rows ----
  local d9; d9=$(_mk_sandbox); _manifest_with_captures "$d9"
  mkdir -p "$d9/bin" "$d9/markers"; _mk_gh "$d9"
  ( PATH="$d9/bin:$PATH" STATE_FILE="$d9/.context/state.json" WORKSPACE_ROOT="$d9" \
    GH_BIN=gh GH_MARKER_DIR="$d9/markers" GH_PR_BODY="Closes #10"$'\n'"Fixes #12" GH_PR_REFS="" \
    ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
    bash "$self" --post completion >/dev/null 2>&1 )
  local f9_ok=1
  [ -f "$d9/markers/10" ] && grep -qF "<!-- completion-summary:wid-test:0:10 -->" "$d9/markers/10" || f9_ok=0
  [ -f "$d9/markers/12" ] && grep -qF "<!-- completion-summary:wid-test:0:12 -->" "$d9/markers/12" || f9_ok=0
  local ok_rows; ok_rows=$(grep -c '"action":"completion_summary_commented".*"result":"ok"' "$d9/.context/logs/audit.jsonl" 2>/dev/null || echo 0)
  [ "${ok_rows:-0}" -eq 2 ] || f9_ok=0
  if [ "$f9_ok" = "1" ]; then
    _ok "f9-completion-first-run"
  else
    _fail "f9-completion-first-run" "ok_rows=$ok_rows $(tail -2 "$d9/.context/logs/audit.jsonl" 2>/dev/null | tr '\n' '~')"
  fi

  # ---- f10: --post completion second run → idempotent, no duplicate ----
  ( PATH="$d9/bin:$PATH" STATE_FILE="$d9/.context/state.json" WORKSPACE_ROOT="$d9" \
    GH_BIN=gh GH_MARKER_DIR="$d9/markers" GH_PR_BODY="Closes #10"$'\n'"Fixes #12" GH_PR_REFS="" \
    ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
    bash "$self" --post completion >/dev/null 2>&1 )
  local f10_ok=1 m10 m12 already
  m10=$(grep -cF "<!-- completion-summary:wid-test:0:10 -->" "$d9/markers/10")
  m12=$(grep -cF "<!-- completion-summary:wid-test:0:12 -->" "$d9/markers/12")
  [ "$m10" -eq 1 ] && [ "$m12" -eq 1 ] || f10_ok=0   # still exactly one each
  already=$(grep -c '"reason":"already_published"' "$d9/.context/logs/audit.jsonl" 2>/dev/null || echo 0)
  [ "${already:-0}" -ge 2 ] || f10_ok=0
  if [ "$f10_ok" = "1" ]; then
    _ok "f10-completion-idempotent"
  else
    _fail "f10-completion-idempotent" "m10=$m10 m12=$m12 already=$already"
  fi
  rm -rf "$d9"

  # ---- f11: requires_screenshots=false → summary-only comment, no image refs ----
  local d11; d11=$(_mk_sandbox)
  jq '.metadata.requires_screenshots=false' "$d11/.context/state.json" > "$d11/.context/state.json.t" \
    && mv "$d11/.context/state.json.t" "$d11/.context/state.json"
  mkdir -p "$d11/bin" "$d11/markers"; _mk_gh "$d11"
  ( PATH="$d11/bin:$PATH" STATE_FILE="$d11/.context/state.json" WORKSPACE_ROOT="$d11" \
    GH_BIN=gh GH_MARKER_DIR="$d11/markers" GH_PR_BODY="Closes #10" GH_PR_REFS="" DRY_RUN=1 \
    bash "$self" --post completion >/dev/null 2>&1 )
  local f11_ok=1
  [ -f "$d11/markers/10" ] || f11_ok=0
  # Summary present (heading), but NO image embeds and NO hosting note spam.
  grep -qF "## Worktask completed" "$d11/markers/10" || f11_ok=0
  grep -qE '!\[' "$d11/markers/10" && f11_ok=0
  grep -qi 'inline hosting unavailable' "$d11/markers/10" && f11_ok=0
  grep -qF "## Visual evidence" "$d11/markers/10" && f11_ok=0
  if [ "$f11_ok" = "1" ]; then
    _ok "f11-completion-summary-only"
  else
    _fail "f11-completion-summary-only" "$(cat "$d11/markers/10" 2>/dev/null | tr '\n' '~')"
  fi
  rm -rf "$d11"

  # ---- f12: gh failure on one issue → continue to others, exit 0 ----
  local d12; d12=$(_mk_sandbox); _manifest_with_captures "$d12"
  mkdir -p "$d12/bin" "$d12/markers"; _mk_gh "$d12"
  ( PATH="$d12/bin:$PATH" STATE_FILE="$d12/.context/state.json" WORKSPACE_ROOT="$d12" \
    GH_BIN=gh GH_MARKER_DIR="$d12/markers" GH_PR_BODY="Closes #10"$'\n'"Fixes #12" GH_PR_REFS="" \
    GH_FAIL_ISSUES="12" \
    ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
    bash "$self" --post completion >/dev/null 2>&1 )
  local f12_rc=$?
  local f12_ok=1
  [ "$f12_rc" -eq 0 ] || f12_ok=0                          # non-blocking exit 0
  [ -f "$d12/markers/10" ] || f12_ok=0                     # issue #10 succeeded
  grep -q '"issue":10,"reason":"commented"' "$d12/.context/logs/audit.jsonl" 2>/dev/null || f12_ok=0
  grep -q '"issue":12,"reason":"gh_error"' "$d12/.context/logs/audit.jsonl" 2>/dev/null || f12_ok=0
  if [ "$f12_ok" = "1" ]; then
    _ok "f12-completion-gh-failure-continues"
  else
    _fail "f12-completion-gh-failure-continues" "rc=$f12_rc $(grep completion_summary "$d12/.context/logs/audit.jsonl" 2>/dev/null | tr '\n' '~')"
  fi
  rm -rf "$d12"

  # ---- f13: --emit pr twice reuses the first emission; --force re-hosts
  local d13; d13=$(_mk_sandbox); _manifest_with_captures "$d13"
  local e13a e13b e13c
  e13a=$(STATE_FILE="$d13/.context/state.json" WORKSPACE_ROOT="$d13" \
         ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
         bash "$self" --emit pr 2>/dev/null)
  e13b=$(STATE_FILE="$d13/.context/state.json" WORKSPACE_ROOT="$d13" \
         ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
         bash "$self" --emit pr 2>/dev/null)
  e13c=$(STATE_FILE="$d13/.context/state.json" WORKSPACE_ROOT="$d13" \
         ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
         bash "$self" --emit pr --force 2>/dev/null)
  local f13_ok=1
  [ -n "$e13a" ] || f13_ok=0
  [ "$e13a" = "$e13b" ] || f13_ok=0                                  # same URLs replayed
  [ "$e13a" = "$e13c" ] || f13_ok=0                                  # --force still emits
  [ -s "$d13/.context/logs/visual-evidence-pr-wid-test-0.md" ] || f13_ok=0
  grep -q '"result":"reused"' "$d13/.context/logs/audit.jsonl" 2>/dev/null || f13_ok=0
  [ "$(grep -c '"result":"reused"' "$d13/.context/logs/audit.jsonl" 2>/dev/null)" = "1" ] || f13_ok=0
  if [ "$f13_ok" = "1" ]; then
    _ok "f13-emit-pr-idempotent"
  else
    _fail "f13-emit-pr-idempotent" "$(grep visual_evidence_pr_emitted "$d13/.context/logs/audit.jsonl" 2>/dev/null | tr '\n' '~')"
  fi
  rm -rf "$d13"

  # ---- f14: per-task manifests union; a tool_missing row is a bullet, never an embed
  local d14; d14=$(_mk_sandbox)
  local i14="$d14/.context/images/wid-test"
  printf 'x' > "$i14/dv-DV0-01-home.png"
  printf '| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |\n|---|---|---|---|---|---|---|---|---|\n| 01 | home | dv-DV0-01-home.png | 1 | web | w | stream zero | t | — |\n' > "$i14/screenshots-DV0.md"
  printf '| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |\n|---|---|---|---|---|---|---|---|---|\n| 01 | diff | — | 0 | backend | cli_fallback | tool_missing: silicon(absent) | t | — |\n' > "$i14/screenshots-DV1.md"
  local out14
  out14=$(STATE_FILE="$d14/.context/state.json" WORKSPACE_ROOT="$d14" \
          ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
          bash "$self" --emit pr 2>/dev/null)
  if printf '%s' "$out14" | grep -q '^!\[dv-01 stream zero\](https://raw.githubusercontent.com/' && \
     printf '%s' "$out14" | grep -q '^- tool_missing: silicon(absent) — nothing captured' && \
     ! printf '%s' "$out14" | grep -q '!\[.*tool_missing'; then
    _ok "f14-union-tool-missing-bullet"
  else
    _fail "f14-union-tool-missing-bullet" "$(printf '%s' "$out14" | head -8 | tr '\n' '~')"
  fi
  rm -rf "$d14"

  # ---- f15: --validate-manifest --task-id rejects a text file named .png
  local d15; d15=$(mktemp -d)
  printf 'not an image' > "$d15/dv-DV0-01-fake.png"
  printf '| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |\n|---|---|---|---|---|---|---|---|---|\n| 01 | fake | dv-DV0-01-fake.png | 1 | web | w | c | t | — |\n' > "$d15/screenshots-DV0.md"
  local out15 rc15=0
  out15=$(bash "$self" --validate-manifest "$d15/screenshots-DV0.md" --task-id DV0 2>/dev/null) || rc15=$?
  if [ "$rc15" -eq 1 ] && printf '%s' "$out15" | grep -q 'mime:dv-DV0-01-fake.png'; then
    _ok "f15-task-id-mime"
  else
    _fail "f15-task-id-mime" "rc=$rc15 $(printf '%s' "$out15" | tr '\n' '~')"
  fi
  rm -rf "$d15"


  # ---- f16-f21: ledger pr_url fallback (#519) ----
  # Sandbox builders and runner for the ledger pr_url cases. _run_completion takes the
  # case dir, env assignments, then `-- <args>` for --post completion.
  _mk_ledger_case() { # $1=pr_url ; echoes dir
    local d; d=$(_mk_sandbox)
    jq --arg u "$1" 'if $u=="" then . else .metadata.pr_url=$u end | .metadata.requires_screenshots=false' \
      "$d/.context/state.json" > "$d/.context/state.json.t" && mv "$d/.context/state.json.t" "$d/.context/state.json"
    mkdir -p "$d/bin" "$d/markers"; _mk_gh "$d"
    printf '%s' "$d"
  }
  _run_completion() { # $1=dir, rest: env assignments, then optional args after --
    local d="$1"; shift
    local envs=() args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift; args=("$@")
    ( env PATH="$d/bin:$PATH" STATE_FILE="$d/.context/state.json" WORKSPACE_ROOT="$d" \
        GH_BIN=gh GH_MARKER_DIR="$d/markers" GH_CALL_LOG="$d/calls.log" DRY_RUN=1 ${envs[@]+"${envs[@]}"} \
        bash "$self" --post completion ${args[@]+"${args[@]}"} >/dev/null 2>&1 )
  }
  _issues_commented() { find "$1/markers" -type f -exec basename {} \; 2>/dev/null | sort -n | tr '\n' ' '; }

  local d16; d16=$(_mk_ledger_case "https://github.com/o/r/pull/19")
  _run_completion "$d16" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10"
  if [ "$(_issues_commented "$d16")" = "10 " ] && \
     [ "$(grep -cF '<!-- completion-summary:wid-test:0:10 -->' "$d16/markers/10")" -eq 1 ] && \
     [ "$(grep -c '"action":"completion_summary_commented".*"result":"ok"' "$d16/.context/logs/audit.jsonl")" -eq 1 ] && \
     ! grep -q no_related_issues "$d16/.context/logs/audit.jsonl"; then
    _ok "f16-completion-ledger-fallback"
  else
    _fail "f16-completion-ledger-fallback" "$(_issues_commented "$d16") $(tail -1 "$d16/.context/logs/audit.jsonl" 2>/dev/null)"
  fi
  rm -rf "$d16"

  local d17; d17=$(_mk_ledger_case "")
  _run_completion "$d17" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10"; local rc17=$?
  if [ "$rc17" -eq 0 ] && [ -z "$(_issues_commented "$d17")" ] && \
     [ "$(grep -c '"result":"skipped".*"reason":"no_related_issues"' "$d17/.context/logs/audit.jsonl")" -eq 1 ]; then
    _ok "f17-completion-no-ledger-ref"
  else
    _fail "f17-completion-no-ledger-ref" "rc=$rc17 $(tail -1 "$d17/.context/logs/audit.jsonl" 2>/dev/null)"
  fi
  rm -rf "$d17"

  local d18; d18=$(_mk_ledger_case "19")
  _run_completion "$d18" GH_PR_BODY="Closes #12" GH_PR_BODY_19="Closes #10"
  if [ "$(_issues_commented "$d18")" = "12 " ]; then
    _ok "f18-completion-current-branch-wins"
  else
    _fail "f18-completion-current-branch-wins" "$(_issues_commented "$d18")"
  fi
  rm -rf "$d18"

  local d19; d19=$(_mk_ledger_case "19")
  _run_completion "$d19" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10" GH_PR_BODY_21="Closes #14" -- 21
  if [ "$(_issues_commented "$d19")" = "14 " ]; then
    _ok "f19-completion-argument-wins"
  else
    _fail "f19-completion-argument-wins" "$(_issues_commented "$d19")"
  fi
  rm -rf "$d19"

  # f22: a hostile <pr-ref> ARGUMENT is dropped like a hostile ledger value.
  local d22; d22=$(_mk_ledger_case "")
  _run_completion "$d22" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10" -- '--repo=evil/x'; local rc22=$?
  if [ "$rc22" -eq 0 ] && [ -z "$(_issues_commented "$d22")" ] && \
     ! grep -qF -- 'evil' "$d22/calls.log" 2>/dev/null && \
     grep -q '"reason":"no_related_issues"' "$d22/.context/logs/audit.jsonl"; then
    _ok "f22-completion-argument-validated"
  else
    _fail "f22-completion-argument-validated" "rc=$rc22 $(cat "$d22/calls.log" 2>/dev/null | tr '\n' '~')"
  fi
  rm -rf "$d22"

  local d22b; d22b=$(_mk_ledger_case "")
  _run_completion "$d22b" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10" -- $'--repo=evil/x\n19'; local rc22b=$?
  if [ "$rc22b" -eq 0 ] && [ -z "$(_issues_commented "$d22b")" ] && \
     ! grep -qF -- 'evil' "$d22b/calls.log" 2>/dev/null && \
     grep -q '"reason":"no_related_issues"' "$d22b/.context/logs/audit.jsonl"; then
    _ok "f22b-completion-multiline-argument-validated"
  else
    _fail "f22b-completion-multiline-argument-validated" "rc=$rc22b"
  fi
  rm -rf "$d22b"

  # f24: a foreign-repo PR URL (ledger value or argument) counts as absent; origin match is case-insensitive.
  local d24 rc24 d24b rc24b d24c
  d24=$(_mk_ledger_case "https://github.com/other/repo/pull/19")
  _run_completion "$d24" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10"; rc24=$?
  d24b=$(_mk_ledger_case "")
  _run_completion "$d24b" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10" -- https://github.com/other/repo/pull/19; rc24b=$?
  d24c=$(_mk_ledger_case "https://github.com/O/R/pull/19")
  _run_completion "$d24c" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10"
  if [ "$rc24" -eq 0 ] && [ "$rc24b" -eq 0 ] && \
     [ -z "$(_issues_commented "$d24")" ] && [ -z "$(_issues_commented "$d24b")" ] && \
     ! grep -q 'other/repo' "$d24/calls.log" 2>/dev/null && \
     grep -q '"reason":"no_related_issues"' "$d24/.context/logs/audit.jsonl" && \
     grep -q '"reason":"no_related_issues"' "$d24b/.context/logs/audit.jsonl" && \
     [ "$(_issues_commented "$d24c")" = "10 " ]; then
    _ok "f24-completion-foreign-repo-url-dropped"
  else
    _fail "f24-completion-foreign-repo-url-dropped" "$(_issues_commented "$d24")|$(_issues_commented "$d24b")|$(_issues_commented "$d24c")"
  fi
  rm -rf "$d24" "$d24b" "$d24c"

  # f23: the current-branch PR exists but closes nothing → the ledger PR still wins.
  local d23; d23=$(_mk_ledger_case "19")
  _run_completion "$d23" GH_PR_BODY="no keywords" GH_PR_BODY_19="Closes #10"
  if [ "$(_issues_commented "$d23")" = "10 " ]; then
    _ok "f23-completion-empty-branch-pr-falls-through"
  else
    _fail "f23-completion-empty-branch-pr-falls-through" "$(_issues_commented "$d23")"
  fi
  rm -rf "$d23"

  local f20_ok=1 v20 d20 rc20
  # The two-line value has a valid last line: a per-line matcher would accept it.
  for v20 in '--repo=evil/x' '19; touch pwned' $'--repo=evil/x\n19'; do
    d20=$(_mk_ledger_case "$v20")
    _run_completion "$d20" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10"; rc20=$?
    [ "$rc20" -eq 0 ] || f20_ok=0
    [ -z "$(_issues_commented "$d20")" ] || f20_ok=0
    [ ! -e "$d20/pwned" ] && [ ! -e pwned ] || f20_ok=0
    grep -qF -- "${v20%%$'\n'*}" "$d20/calls.log" 2>/dev/null && f20_ok=0
    grep -q '"reason":"no_related_issues"' "$d20/.context/logs/audit.jsonl" || f20_ok=0
    rm -rf "$d20"
  done
  if [ "$f20_ok" = "1" ]; then
    _ok "f20-completion-ledger-ref-validated"
  else
    _fail "f20-completion-ledger-ref-validated"
  fi

  local d21; d21=$(_mk_ledger_case "https://github.com/o/r/pull/19")
  _run_completion "$d21" GH_NO_CURRENT_PR=1 GH_PR_BODY_19="Closes #10" GH_PR_TITLE_19=RIGHT GH_PR_TITLE=WRONG
  if grep -q RIGHT "$d21/markers/10" 2>/dev/null && ! grep -q WRONG "$d21/markers/10" 2>/dev/null; then
    _ok "f21-completion-summary-uses-ledger-pr"
  else
    _fail "f21-completion-summary-uses-ledger-pr" "$(tr '\n' '~' < "$d21/markers/10" 2>/dev/null)"
  fi
  rm -rf "$d21"

  echo "attach-visual-evidence: self-test summary — pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}
