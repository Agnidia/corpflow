#!/usr/bin/env bash
# doc-option-check-selftest.sh — the `--self-test` harness for doc-option-check.sh.
#
# SOURCED, never executed: the entrypoint loads it only on `--self-test`, and it reads the
# caller's $SELF. Contract: defines `run_self_test`, which exits 0 when every case passes.

selftest_case() { # <label> <expected rc> <stdout must contain, or "" for empty> <cmd>...
  local label="$1" want_rc="$2" want_out="$3" rc out
  shift 3
  set +e
  out=$("$@" 2> /dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    printf >&2 '%s: FAIL (rc=%s, want %s)\n' "$label" "$rc" "$want_rc"
    exit 1
  fi
  if [ -z "$want_out" ] && [ -n "$out" ]; then
    printf >&2 '%s: FAIL (stdout not empty: %s)\n' "$label" "$out"
    exit 1
  fi
  case "$out" in
    *"$want_out"*) printf '%s: ok\n' "$label"; _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1)) ;;
    *)
      printf >&2 '%s: FAIL (stdout lacks %s: %s)\n' "$label" "$want_out" "$out"
      exit 1
      ;;
  esac
}

# shellcheck disable=SC2016  # fixture text: backticks and $NAME must reach the doc unexpanded
run_self_test() {
  local td tree
  _SELFTEST_PASSED=0
  td=$(mktemp -d "${TMPDIR:-/tmp}/doc-option-check-selftest.XXXXXX")
  # shellcheck disable=SC2064  # expand $td now so the trap removes the right dir
  trap "rm -rf -- '${td}'" EXIT
  tree="$td/tree"
  mkdir -p "$tree/docs"
  printf 'Set `API_BIND` first.\n' > "$tree/docs/undefined.md"
  printf 'Set `API_PORT` first.\n' > "$tree/docs/defined.md"
  printf 'See [x](/etc/hosts).\n' > "$tree/docs/outside.md"
  printf 'See [x](gone.md).\n' > "$tree/docs/missing.md"
  printf 'Refs `origin/develop`, `refs/heads/x`, `Agnidia/corpflow`, `github.com/Agnidia/x`, `a|b/c`, `(x)/y`, `skills/...` and `^docs/[a-z]+`.\n' > "$tree/docs/notpaths.md"
  printf '#!/usr/bin/env bash\nprintf "%%s" "$API_PORT"\n' > "$tree/run.sh"
  printf 'See `docs/a"b\\c/d.md`.\n' > "$tree/docs/hostile.md"
  git -C "$tree" init -q .
  git -C "$tree" add -- .

  selftest_case 'S1: undefined env var is a finding' 1 '"name":"API_BIND","doc":"docs/undefined.md","line":1,"reason":"undefined"' \
    bash "$SELF" --tree "$tree" "$tree/docs/undefined.md"
  selftest_case 'S2: defined env var is clean' 0 '' \
    bash "$SELF" --tree "$tree" "$tree/docs/defined.md"
  selftest_case 'S3: link outside the tree is a finding' 1 '"check":"assigned-tree","kind":"path","name":"/etc/hosts"' \
    bash "$SELF" --tree "$tree" "$tree/docs/outside.md"
  selftest_case 'S4: absent in-tree link is missing' 1 '"reason":"missing"' \
    bash "$SELF" --tree "$tree" "$tree/docs/missing.md"
  selftest_case 'S5: unresolved tree exits 3' 3 '' \
    bash "$SELF" --tree "$td/no-such-tree" "$tree/docs/defined.md"
  selftest_case 'S6: refs, slugs, hosts and regex fragments are not paths' 0 '' \
    bash "$SELF" --tree "$tree" "$tree/docs/notpaths.md"
  selftest_case 'S7: a JSON-hostile path under a real dir is still a finding' 1 '"name":"docs/a\"b\\c/d.md"' \
    bash "$SELF" --tree "$tree" "$tree/docs/hostile.md"
  selftest_case 'S8: --allow-path exempts an exact missing path' 0 '' \
    bash "$SELF" --tree "$tree" --allow-path docs/gone.md "$tree/docs/missing.md"

  printf 'self-test: ALL PASS (%d passed, 0 failed)\n' "$_SELFTEST_PASSED"
  exit 0
}
