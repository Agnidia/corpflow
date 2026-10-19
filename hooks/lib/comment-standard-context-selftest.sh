#!/usr/bin/env bash
# comment-standard-context self-test body — sourced by hooks/comment-standard-context.sh under --self-test only,
# never on the hook dispatch path. Sourced, not executed, so it sees every
# helper the caller already defined; it owns the exit for this invocation.
# Indentation is the caller's — kept byte-identical so this stays a pure move.

  _st_passed=0
  _agent_a="agentA_selftest_$$"
  _agent_b="agentB_selftest_$$"
  _agent_c="agentC_selftest_$$"
  trap 'rm -f "${TMPDIR:-/tmp}/corpflow-comment-standard-${_agent_a}" "${TMPDIR:-/tmp}/corpflow-comment-standard-${_agent_b}" "${TMPDIR:-/tmp}/corpflow-comment-standard-${_agent_c}"' EXIT

  _emits_context() {
    printf '%s' "$1" | jq -e '
      .hookSpecificOutput.hookEventName == "PostToolUse"
      and (.hookSpecificOutput.additionalContext | length > 0)
    ' >/dev/null 2>&1
  }

  # 1. First touch by agent A injects.
  _emits_context "$(run_hook "$(selftest_payload "$_agent_a")")" || {
    echo "comment-standard-context: self-test FAIL (agent A got no injection) ($_st_passed passed, 1 failed)"
    exit 1
  }

  _st_passed=$((_st_passed + 1))

  # 2. Agent B — SAME session_id, different transcript — must ALSO inject.
  #    Regression guard: a session-keyed sentinel silently skipped every
  #    subagent after the first, so one worktask got one reminder.
  _emits_context "$(run_hook "$(selftest_payload "$_agent_b")")" || {
    echo "comment-standard-context: self-test FAIL (agent B suppressed by agent A's sentinel) ($_st_passed passed, 1 failed)"
    exit 1
  }

  _st_passed=$((_st_passed + 1))

  # 3. Agent A again — same transcript — stays silent (once per agent).
  if _emits_context "$(run_hook "$(selftest_payload "$_agent_a")")"; then
    echo "comment-standard-context: self-test FAIL (agent A injected twice) ($_st_passed passed, 1 failed)"
    exit 1
  fi

  _st_passed=$((_st_passed + 1))

  # 4. A shell path must inject: shell sat outside the extension gate. Fresh
  #    agent key — injection fires once per agent.
  _emits_context "$(run_hook "$(selftest_payload "$_agent_c" /tmp/deploy.sh)")" || {
    echo "comment-standard-context: self-test FAIL (shell path got no injection) ($_st_passed passed, 1 failed)"
    exit 1
  }

  _st_passed=$((_st_passed + 1))

  echo "comment-standard-context: self-test OK ($_st_passed passed, 0 failed)"
  exit 0
