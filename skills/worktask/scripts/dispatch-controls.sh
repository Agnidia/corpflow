#!/usr/bin/env bash
# @description Validate optional dispatch controls before ledger writes or process launch.
# Missing fields preserve runtime defaults; explicit nulls cannot erase a pinned control.
_CF_DISPATCH_CONTROLS_JQ='
  def dispatch_controls_valid:
    def integer_between($lo; $hi): type == "number" and floor == . and . >= $lo and . <= $hi;
    . as $meta | type == "object" and
    (if has("auto_compact_window") then .auto_compact_window | integer_between(100000;1000000) else true end) and
    (if has("retry_watchdog") then .retry_watchdog | type == "boolean" else true end) and
    (all(["retry_watchdog_max_wait_ms", "retry_watchdog_max_usage_limit_wait_ms", "overloaded_retry_max_delay_ms"][];
      . as $key | if $meta | has($key) then $meta[$key] | integer_between(1;2147483647) else true end)) and
    (if has("retry_watchdog_max_wait_ms") or has("retry_watchdog_max_usage_limit_wait_ms")
      then .retry_watchdog == true else true end)
;
'

dispatch_controls_validate() {
  [ "$1" != "{}" ] || return 0
  printf '%s' "$1" | jq -e "${_CF_DISPATCH_CONTROLS_JQ} dispatch_controls_valid" >/dev/null 2>&1
}

dispatch_controls_present() {
  [ "$1" != "{}" ] || return 1
  printf '%s' "$1" | jq -e 'has("auto_compact_window") or has("retry_watchdog") or
    has("retry_watchdog_max_wait_ms") or has("retry_watchdog_max_usage_limit_wait_ms") or
    has("overloaded_retry_max_delay_ms")' >/dev/null 2>&1
}
