#!/usr/bin/env bash
# Codex-specific value translation. Path resolution belongs to corpflow-base.sh.

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'codex-runtime.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

[ -n "${_CORPFLOW_CODEX_RUNTIME_LIB:-}" ] && return 0
_CORPFLOW_CODEX_RUNTIME_LIB=1

# Resolve a provider-neutral Corpflow model tier to the concrete Codex model.
corpflow_codex_model() {
  case "${1:-}" in
    haiku) printf '%s' 'gpt-6-luna' ;;
    sonnet) printf '%s' 'gpt-6.1-terra' ;;
    opus) printf '%s' 'gpt-6.1-sol' ;;
    fable) printf '%s' 'gpt-6-astra' ;;
    *) return 2 ;;
  esac
}

# Emit the provider-neutral dispatch fields after Codex-only model translation. The effort value
# is deliberately copied byte-for-byte: model selection must never silently change reasoning.
corpflow_codex_dispatch_json() {
  local model_requested="${1:-}" effort="${2:-}" model_resolved
  [ -n "$model_requested" ] && [ -n "$effort" ] || return 2
  model_resolved=$(corpflow_codex_model "$model_requested") || return $?
  command -v jq >/dev/null 2>&1 || return 127
  jq -cn \
    --arg model_requested "$model_requested" \
    --arg model_resolved "$model_resolved" \
    --arg effort "$effort" \
    '{model_requested:$model_requested,model_resolved:$model_resolved,effort:$effort}'
}

# Stable Codex task name: cf_<lowercase stage id>_<attempt>, within the tool's name grammar.
corpflow_codex_task_name() {
  local task_id="${1:-}" attempt="${2:-1}" normalized
  [ -n "$task_id" ] || return 2
  normalized=$(printf '%s' "$task_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')
  case "$attempt" in ''|*[!0-9]*) return 2 ;; esac
  printf 'cf_%s_%s' "${normalized:0:48}" "$attempt"
}
