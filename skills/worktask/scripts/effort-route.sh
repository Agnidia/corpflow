#!/usr/bin/env bash
# @description effort-route.sh — the route decision: whether a dispatch runs in-process with
#   the stamped tier on the Agent tool's `effort` parameter, or headless at that tier.
#   Pure: reads only its arguments and CORPFLOW_HEADLESS_ROUTE, writes nothing, spawns
#   nothing. headless-dispatch.sh consumes its `route` field; the orchestrator's Step 6 loop,
#   Step C.0a resolver and Step C.3 batch resolver all call this before choosing a surface.
#
#   Explicit dispatch controls require the headless opt-in; they cannot survive an
#   in-process fallback. Without controls, haiku skips effort and other models follow the opt-in.
#   The agent's own `effort:` frontmatter plays no part: the Agent call's `effort` outranks it,
#   so there is no baseline to compare against.
#
#   Symbols: none exported — this file is a CLI, never sourced (unlike effort-ladder.sh).
#
# @exitcode 2 usage error or invalid enum value
#
# Minimum shell: bash 3.2+ (macOS default) — no associative arrays, no `local -n`.

set -euo pipefail

_ER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=effort-ladder.sh
. "${_ER_DIR}/effort-ladder.sh"

# Model aliases the route function accepts. `haiku` is here (it is a valid alias, just one
# effort ignores), `fable` too — the matrix's MODEL_ENUM omits it, but effort-ladder.sh's
# EFFORT_FULL_LADDER_RE already treats it as a full-ladder model, so this file's own enum
# must agree rather than re-derive a second list that could drift from it.
_ER_MODEL_ENUM_RE='^(opus|sonnet|haiku|fable)$'
_ER_AGENT_ID_RE='^[a-z0-9-]+:[a-z0-9-]+$'

usage() {
  cat >&2 << 'EOF2'
usage:
  effort-route.sh --agent <plugin:agent> --model <alias> --requested <tier> [--dispatch-controls <metadata-json>]

Prints one JSON route-decision line and exits 0, or exits 2 with an
error on stderr before printing anything. CORPFLOW_HEADLESS_ROUTE=on
routes every non-haiku dispatch headless; the default keeps it
in-process on the Agent tool's effort parameter.
EOF2
  exit 2
}

AGENT=""
MODEL=""
REQUESTED=""
CONTROLS='{}'
. "${_ER_DIR}/dispatch-controls.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --dispatch-controls) CONTROLS="${2:-}"; shift 2 ;;
    --requested) REQUESTED="${2:-}"; shift 2 ;;
    -h | --help) usage ;;
    *)
      printf >&2 'effort-route.sh: unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

[ -n "$AGENT" ] && [ -n "$MODEL" ] && [ -n "$REQUESTED" ] || usage

# --- validation before anything else is computed (fail closed before the spawn) -------------
if ! [[ "$AGENT" =~ $_ER_AGENT_ID_RE ]]; then
  printf >&2 'effort-route.sh: invalid agent id: %s\n' "$AGENT"
  exit 2
fi
if ! [[ "$MODEL" =~ $_ER_MODEL_ENUM_RE ]]; then
  printf >&2 'effort-route.sh: invalid model: %s\n' "$MODEL"
  exit 2
fi
if ! effort_rank "$REQUESTED" > /dev/null 2>&1; then
  printf >&2 'effort-route.sh: invalid requested effort: %s\n' "$REQUESTED"
  exit 2
fi

dispatch_controls_validate "$CONTROLS" || { printf >&2 'invalid dispatch controls\n'; exit 2; }
if dispatch_controls_present "$CONTROLS"; then
  [ "${CORPFLOW_HEADLESS_ROUTE:-}" = "on" ] || { printf >&2 'dispatch controls require CORPFLOW_HEADLESS_ROUTE=on\n'; exit 2; }
  ROUTE="headless"
  TRANSPORT="dispatch-flag"
  REASON="dispatch_controls"
elif [ "$MODEL" = "haiku" ]; then
  ROUTE="inproc"
  TRANSPORT="none"
  REASON="model_ignores_effort"
elif [ "${CORPFLOW_HEADLESS_ROUTE:-}" = "on" ]; then
  ROUTE="headless"
  TRANSPORT="dispatch-flag"
  REASON="headless_opt_in"
else
  ROUTE="inproc"
  TRANSPORT="agent-param"
  REASON="inproc_default"
fi

if command -v jq > /dev/null 2>&1; then
  jq -cn \
    --arg agent "$AGENT" --arg model "$MODEL" --arg requested "$REQUESTED" \
    --arg route "$ROUTE" --arg transport "$TRANSPORT" --arg reason "$REASON" \
    '{agent:$agent, model:$model, requested:$requested, route:$route,
      effort_transport:$transport, reason:$reason}'
else
  # jq-less degraded form: every value here already passed an enum/regex gate above, so a
  # bare printf cannot break the literal the way an unvalidated string would.
  printf '{"agent":"%s","model":"%s","requested":"%s","route":"%s","effort_transport":"%s","reason":"%s"}\n' \
    "$AGENT" "$MODEL" "$REQUESTED" "$ROUTE" "$TRANSPORT" "$REASON"
fi
