#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="skills/worktask/scripts/dispatch-controls.sh"

validate() {
  bash -c '. "$1"; dispatch_controls_validate "$2"' bash "$PLUGIN_ROOT/$LIB" "$1"
}

present() {
  bash -c '. "$1"; dispatch_controls_present "$2"' bash "$PLUGIN_ROOT/$LIB" "$1"
}

@test "absent controls preserve defaults and unrelated metadata" {
  local metadata
  for metadata in '{}' '{"stage":"DV","effort":"high"}'; do
    run validate "$metadata"
    assert_success
    assert_output ""
    run present "$metadata"
    assert_failure
    assert_output ""
  done
}

@test "compaction windows accept both bounds and reject invalid types and outliers" {
  local value
  for value in 100000 200000 1000000; do
    run validate "{\"auto_compact_window\":$value}"
    assert_success
  done
  for value in 99999 1000001 100000.5 null true '"200000"'; do
    run validate "{\"auto_compact_window\":$value}"
    assert_failure
  done
}

@test "watchdog limits require an explicitly enabled watchdog" {
  local key metadata
  for key in retry_watchdog_max_wait_ms retry_watchdog_max_usage_limit_wait_ms; do
    for metadata in "{\"$key\":100}" "{\"$key\":100,\"retry_watchdog\":false}"; do
      run validate "$metadata"
      assert_failure
    done
    run validate "{\"$key\":100,\"retry_watchdog\":true}"
    assert_success
  done
}

@test "retry delays accept integer bounds and reject zero negative fractional and excessive waits" {
  local key value
  for key in retry_watchdog_max_wait_ms retry_watchdog_max_usage_limit_wait_ms overloaded_retry_max_delay_ms; do
    for value in 1 2147483647; do
      run validate "{\"$key\":$value,\"retry_watchdog\":true}"
      assert_success
    done
    for value in 0 -1 1.5 2147483648 null '"100"'; do
      run validate "{\"$key\":$value,\"retry_watchdog\":true}"
      assert_failure
    done
  done
}

@test "explicit false remains configured and null cannot erase any pinned control" {
  local key
  run validate '{"retry_watchdog":false}'
  assert_success
  run present '{"retry_watchdog":false}'
  assert_success
  for key in auto_compact_window retry_watchdog retry_watchdog_max_wait_ms retry_watchdog_max_usage_limit_wait_ms overloaded_retry_max_delay_ms; do
    run validate "{\"$key\":null}"
    assert_failure
    run present "{\"$key\":null}"
    assert_success
  done
}

@test "non-object and malformed metadata fail validation without output" {
  local metadata
  for metadata in '[]' null false '"metadata"' '{"retry_watchdog":"true"}' '{"auto_compact_window":'; do
    run validate "$metadata"
    assert_failure
    assert_output ""
  done
}
