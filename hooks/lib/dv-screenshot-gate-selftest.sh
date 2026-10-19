#!/usr/bin/env bash
# dv-screenshot-gate self-test body — sourced by hooks/dv-screenshot-gate.sh under --self-test only,
# never on the hook dispatch path. It sees every helper the caller defined and owns the exit.

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT
_fail=0
_st_cases=0
_hdr='| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |
|---|------|------|-------|----------|---------|---------|----------|------------|'

# _st_ctx <name> <platform> <tasks-json> [dispatched-json] [metadata-json] -> prints the ctx dir
_st_ctx() {
  local c="$_tmp/$1/.context" rows="${4:-}" meta="${5:-}"
  [ -n "$rows" ] || rows='[]'
  [ -n "$meta" ] || meta='{}'
  mkdir -p "$c/images/wid-st"
  jq -n --arg p "$2" --argjson tasks "$3" --argjson rows "$rows" --argjson meta "$meta" \
    '{version: 2, worktask_id: "wid-st", platform: $p, metadata: $meta, tasks: $tasks,
      facts: {dispatched_agents: $rows}}' > "$c/state.json"
  printf '%s' "$c"
}

_st_png() { printf '\211PNG\r\n\032\nselftest' > "$1"; }

_st_row() { # <manifest> <row>
  printf '%s\n%s\n' "$_hdr" "$2" > "$1"
}

_st_expect_block() { # <label> <stdout> <ctx> <block_kind>
  _st_cases=$((_st_cases + 1))
  if ! printf '%s' "$2" | jq -e '.decision == "block" and .hookSpecificOutput.hookEventName == "SubagentStop"' > /dev/null 2>&1 \
    || ! tail -n 1 "$3/logs/audit.jsonl" 2> /dev/null | jq -e --arg k "$4" '.action == "screenshot_gate_block" and .metadata.block_kind == $k' > /dev/null 2>&1; then
    echo "dv-screenshot-gate: self-test FAIL ($1: expected block $4)"
    _fail=$((_fail + 1))
  fi
}

_st_expect_pass() { # <label> <stdout> <ctx>
  _st_cases=$((_st_cases + 1))
  if [ -n "$2" ] || ! tail -n 1 "$3/logs/audit.jsonl" 2> /dev/null | jq -e '.action == "screenshot_gate_pass"' > /dev/null 2>&1; then
    echo "dv-screenshot-gate: self-test FAIL ($1: expected pass)"
    _fail=$((_fail + 1))
  fi
}

_bash_dev='{"agent_type":"system-developer:bash-developer","agent_id":"agt_x","session_id":"sess"}'
_web_dv0='{"DV0":{"status":"in_progress","metadata":{"stage":"DV","agent":"system-developer:bash-developer","platform":"web"}}}'

# Prose-only manifest on a web stream, resolved without a dispatched_agents row.
_c=$(_st_ctx prose web "$_web_dv0")
printf '# Screenshots\n\nHeadless, nothing captured.\n' > "$_c/images/wid-st/screenshots-DV0.md"
_st_expect_block prose-only "$(run_gate "$_bash_dev" "$_c")" "$_c" no_captures

# The same manifest with an unreferenced capture beside it.
_c=$(_st_ctx beside web "$_web_dv0")
printf '# Screenshots\n\nHeadless, nothing captured.\n' > "$_c/images/wid-st/screenshots-DV0.md"
_st_png "$_c/images/wid-st/dv-DV0-01-x.png"
_st_expect_block images-beside "$(run_gate "$_bash_dev" "$_c")" "$_c" invalid_evidence

# A tool_missing-only manifest passes on backend with no metadata.preflight, and blocks on web.
_tm_row='| 01 | diff | — | 0 | backend | cli_fallback | tool_missing: silicon(absent), magick(absent), convert(absent) | 2026-01-01T00:00:00Z | — |'
_c=$(_st_ctx backend backend '{"DV0":{"status":"in_progress","metadata":{"agent":"system-developer:bash-developer","platform":"backend"}}}')
_st_row "$_c/images/wid-st/screenshots-DV0.md" "$_tm_row"
_st_expect_pass tool-missing-backend "$(run_gate "$_bash_dev" "$_c")" "$_c"
_c=$(_st_ctx tmweb web "$_web_dv0")
_st_row "$_c/images/wid-st/screenshots-DV0.md" "$_tm_row"
_st_expect_block tool-missing-web "$(run_gate "$_bash_dev" "$_c")" "$_c" tool_missing_ui

# Two streams: only DV0 captured, so DV1's stop blocks and DV0's passes.
_c=$(_st_ctx streams web '{"DV0":{"status":"in_progress","metadata":{"platform":"web"}},"DV1":{"status":"in_progress","metadata":{"platform":"web"}}}' \
  '[{"task_id":"DV0","stage":"DV","agent_id":"agt_dv0"},{"task_id":"DV1","stage":"DV","agent_id":"agt_dv1"}]')
_st_png "$_c/images/wid-st/dv-DV0-01-home.png"
_st_row "$_c/images/wid-st/screenshots-DV0.md" '| 01 | home | dv-DV0-01-home.png | 16 | web | web/playwright | home | 2026-01-01T00:00:00Z | — |'
_st_expect_block other-stream "$(run_gate '{"agent_type":"corpflow:developer","agent_id":"agt_dv1"}' "$_c")" "$_c" no_captures
_st_expect_pass own-stream "$(run_gate '{"agent_type":"corpflow:developer","agent_id":"agt_dv0"}' "$_c")" "$_c"

# A text file renamed .png is not an image.
_c=$(_st_ctx mime web "$_web_dv0")
printf 'plain text\n' > "$_c/images/wid-st/dv-DV0-01-fake.png"
_st_row "$_c/images/wid-st/screenshots-DV0.md" '| 01 | fake | dv-DV0-01-fake.png | 11 | web | web/playwright | fake | 2026-01-01T00:00:00Z | — |'
_out=$(run_gate "$_bash_dev" "$_c")
_st_expect_block mime "$_out" "$_c" invalid_evidence
printf '%s' "$_out" | jq -e '.reason | test("mime:")' > /dev/null 2>&1 \
  || { echo "dv-screenshot-gate: self-test FAIL (mime: reason)"; _fail=$((_fail + 1)); }
_st_cases=$((_st_cases + 1))

# A non-DV agent stopping is a no-op: no output, no row.
_c=$(_st_ctx noop web "$_web_dv0")
_out=$(run_gate '{"agent_type":"corpflow:qa-engineer","agent_id":"agt_qa"}' "$_c")
if [ -n "$_out" ] || [ -e "$_c/logs/audit.jsonl" ]; then
  echo "dv-screenshot-gate: self-test FAIL (non-DV agent: expected no-op)"
  _fail=$((_fail + 1))
fi
_st_cases=$((_st_cases + 1))

if [ "$_fail" -ne 0 ]; then
  echo "dv-screenshot-gate: self-test FAIL ($(($_st_cases - _fail)) passed, $_fail failed)"
  exit 1
fi
echo "dv-screenshot-gate: self-test OK ($_st_cases passed, 0 failed)"
exit 0
