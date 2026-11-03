#!/usr/bin/env bash
# tests/lib/test_helper.bash — common setup for every .bats file in this suite.
#
# FROZEN API (per .context/analyzing-0.md#convention). DV0a/DV0b/DV0c code their
# .bats files against exactly this surface; do NOT change names/semantics without
# a coordinated re-freeze.
#
# Every test file begins with:
#     load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
# (from tests/shell/<group>/<name>.bats the relative path is ../../lib/...)
#
# Exposed to every test file after the load:
#   $PLUGIN_ROOT  — absolute repo root (resolved from this file's location)
#   $FIXTURES     — absolute tests/fixtures dir
#   run_script <relpath-from-PLUGIN_ROOT> [args...]
#                 — runs the target script via `run` (sets $status/$output/$lines);
#                   bash for *.sh, python3 for *.py, direct exec otherwise.
#   mk_tmpworkdir — prints an mktemp -d dir under BATS_TMPDIR; auto-removed in
#                   the default teardown (tracked in _TEST_HELPER_TMPDIRS).
#   run_script_env [OPTS] <target> [args...]
#                 — additive sibling of run_script: --cwd/--env/--unset/--path/
#                   --stub-path/--hide/--stdin-*/--separate-stderr/--source.
#                   Never mutates the caller's PWD, PATH or environment.
#   assert_audit_row <action> [...] — assert a .context/logs/audit.jsonl row.
#                   Locals + `jq -e` only; never runs `run`, so $output survives.
#   stub_cmd/stub_log — recording test doubles on $STUB_BIN; stub_log reports
#                   argv/count without disturbing $output/$status.
#   mock_gh       — routed `gh` double built on stub_cmd.
#   mk_state_fixture <outfile> [jq-filter...] — canonical state.json + mutations.
#   mk_git_fixture [OPTS] — deterministic throwaway git repo; prints its path.

# --- vendor: bats-support + bats-assert -------------------------------------
# Resolve this helper's own directory robustly (BATS_TEST_DIRNAME is the dir of
# the running .bats file, which differs per group; ${BASH_SOURCE} is this file).
_TEST_HELPER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TEST_HELPER_VENDOR="${_TEST_HELPER_LIB_DIR}/../vendor"

# Declared once here so `run --separate-stderr` is a supported form rather than a
# BW02 warning in every file that uses it. Vendored bats is 1.11.0.
bats_require_minimum_version 1.5.0

load "${_TEST_HELPER_VENDOR}/bats-support/load.bash"
load "${_TEST_HELPER_VENDOR}/bats-assert/load.bash"

# --- exposed absolute paths --------------------------------------------------
# PLUGIN_ROOT = repo root = parent of tests/. tests/lib/ -> ../../ is the root.
export PLUGIN_ROOT="$(cd "${_TEST_HELPER_LIB_DIR}/../.." && pwd)"
export FIXTURES="${PLUGIN_ROOT}/tests/fixtures"

# A runner shell that exported one of these before invoking bats must never steer a
# fixture-less test into a real ledger; each suite that needs one declares it itself.
unset CONTEXT_DIR WORKSPACE_ROOT CLAUDE_PROJECT_DIR

# Same rule for the operator's config dir: a real user-scope CORPFLOW.md (model-matrix-lib.sh
# corpflow_md_locate) must never reach a test. Points at a dir nothing creates; a suite that
# exercises the config dir sets or unsets CLAUDE_CONFIG_DIR itself.
export CLAUDE_CONFIG_DIR="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/corpflow-test-claude-config"

# --- run_script: dispatch a target under `run` -------------------------------
# Usage: run_script skills/foo/scripts/bar.sh --flag value
# Sets $status/$output/$lines (it wraps bats `run`). The first arg is a path
# RELATIVE to PLUGIN_ROOT; remaining args pass through verbatim.
run_script() {
  local rel="$1"; shift
  local abs="${PLUGIN_ROOT}/${rel}"
  case "$rel" in
    *.py)  run python3 "$abs" "$@" ;;
    *.sh)  run bash    "$abs" "$@" ;;
    *)     run         "$abs" "$@" ;;
  esac
}

# --- mk_tmpworkdir: isolated scratch dir, auto-cleaned -----------------------
# Prints an absolute mktemp -d under BATS_TMPDIR. Registered for teardown.
_TEST_HELPER_TMPDIRS=()
mk_tmpworkdir() {
  local base="${BATS_TMPDIR:-${TMPDIR:-/tmp}}"
  local d
  d="$(mktemp -d "${base%/}/worktask-test.XXXXXX")"
  _TEST_HELPER_TMPDIRS+=("$d")
  printf '%s\n' "$d"
}

# --- stub infrastructure -----------------------------------------------------
# One scratch root per test holds every stub, farm and call log.
_TEST_HELPER_STUBDIR=""

# The --hide farm links these from the real PATH. A missing REQUIRED entry is a
# hard failure: falling back to the real PATH would silently defeat --hide.
_STUB_FARM_REQUIRED=(bash sh env cat sed grep awk tr cut date mkdir rm mv cp ln \
                     ls find head tail wc sort uniq chmod mktemp dirname \
                     basename printf touch)
_STUB_FARM_OPTIONAL=(git python3 jq realpath readlink stat od cmp xargs diff tee \
                     sleep id uname)

_stub_init() {
  if [ -z "$_TEST_HELPER_STUBDIR" ]; then
    local base="${BATS_TMPDIR:-${TMPDIR:-/tmp}}"
    _TEST_HELPER_STUBDIR="$(mktemp -d "${base%/}/worktask-stub.XXXXXX")"
    mkdir -p "$_TEST_HELPER_STUBDIR/bin" "$_TEST_HELPER_STUBDIR/farm" \
             "$_TEST_HELPER_STUBDIR/log"
    export STUB_BIN="$_TEST_HELPER_STUBDIR/bin"
    export STUB_FARM="$_TEST_HELPER_STUBDIR/farm"
    export STUB_PATH="$STUB_BIN:$PATH"
  fi
  return 0
}

_stub_link_tool() {
  local tool="$1" src
  src="$(command -v "$tool" 2>/dev/null)" || return 1
  # Shell builtins resolve to a bare name; the child shell already supplies them.
  case "$src" in
    /*) ln -sf "$src" "$STUB_FARM/$tool" ;;
  esac
  return 0
}

# Rebuilds $STUB_FARM as the allowlist minus every name passed in.
_stub_build_farm() {
  _stub_init
  rm -rf "$STUB_FARM"
  mkdir -p "$STUB_FARM"
  local tool h hidden
  for tool in "${_STUB_FARM_REQUIRED[@]}"; do
    hidden=0
    for h in "$@"; do
      if [ "$tool" = "$h" ]; then hidden=1; fi
    done
    if [ "$hidden" -eq 1 ]; then continue; fi
    if ! _stub_link_tool "$tool"; then
      fail "run_script_env --hide: required tool '$tool' not on PATH — install it or extend _STUB_FARM_REQUIRED"
    fi
  done
  for tool in "${_STUB_FARM_OPTIONAL[@]}"; do
    hidden=0
    for h in "$@"; do
      if [ "$tool" = "$h" ]; then hidden=1; fi
    done
    if [ "$hidden" -eq 1 ]; then continue; fi
    if ! _stub_link_tool "$tool"; then continue; fi
  done
  return 0
}

# stub_cmd <name> [--exit N] [--stdout TEXT] [--stderr TEXT] [--body 'shell']
#                 [--record-stdin]
# Installs a recording double on $STUB_BIN; reach it with --stub-path/--hide.
stub_cmd() {
  _stub_init
  local name="$1"; shift
  local exit_code=0 out='' err='' body='' record_stdin=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --exit)         exit_code="$2"; shift 2 ;;
      --stdout)       out="$2"; shift 2 ;;
      --stderr)       err="$2"; shift 2 ;;
      --body)         body="$2"; shift 2 ;;
      --record-stdin) record_stdin=1; shift ;;
      *) fail "stub_cmd: unknown option '$1'" ;;
    esac
  done

  local script="$STUB_BIN/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'LOGDIR=%q\n' "$_TEST_HELPER_STUBDIR/log"
    printf 'NAME=%q\n' "$name"
    printf 'printf "%%s\\n" "$*" >> "$LOGDIR/$NAME.log"\n'
    printf 'CALL=$(wc -l < "$LOGDIR/$NAME.log" | tr -d " ")\n'
    printf 'printf "%%s\\0" "$@" > "$LOGDIR/$NAME.argv.$CALL"\n'
    if [ "$record_stdin" -eq 1 ]; then
      printf 'cat > "$LOGDIR/$NAME.stdin.$CALL"\n'
    fi
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      if [ -n "$out" ]; then printf 'printf "%%s\\n" %q\n' "$out"; fi
      if [ -n "$err" ]; then printf 'printf "%%s\\n" %q >&2\n' "$err"; fi
      printf 'exit %s\n' "$exit_code"
    fi
  } > "$script"
  chmod +x "$script"
  return 0
}

# stub_log <name> | --argv <name> [--call N] | --count <name>
# Prints to stdout and never calls `run`, so $output/$status/$stderr survive.
stub_log() {
  local mode=lines name='' call=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --argv)  mode=argv;  shift ;;
      --count) mode=count; shift ;;
      --call)  call="$2";  shift 2 ;;
      *)       name="$1";  shift ;;
    esac
  done
  local logdir="${_TEST_HELPER_STUBDIR:-}/log"
  local logfile="$logdir/$name.log"
  case "$mode" in
    count)
      if [ -f "$logfile" ]; then wc -l < "$logfile" | tr -d ' '; else printf '0\n'; fi ;;
    argv)
      local f="$logdir/$name.argv.$call"
      if [ -f "$f" ]; then tr '\0' '\n' < "$f"; fi ;;
    *)
      if [ -f "$logfile" ]; then cat "$logfile"; fi ;;
  esac
  return 0
}

# mock_gh [--route 'ARGV-PREFIX=EXIT:STDOUT']... [--default-exit N]
#         [--default-stdout TEXT]
# Routes match the space-joined argv prefix; assert calls with `stub_log gh`.
mock_gh() {
  _stub_init
  local default_exit=0 default_stdout='' r prefix rest
  local routes_file="$_TEST_HELPER_STUBDIR/gh.routes"
  : > "$routes_file"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --route)
        r="$2"; shift 2
        prefix="${r%%=*}"; rest="${r#*=}"
        printf '%s\t%s\t%s\n' "$prefix" "${rest%%:*}" "${rest#*:}" >> "$routes_file" ;;
      --default-exit)   default_exit="$2"; shift 2 ;;
      --default-stdout) default_stdout="$2"; shift 2 ;;
      *) fail "mock_gh: unknown option '$1'" ;;
    esac
  done

  local body
  body="$(printf 'ROUTES=%q\nDEFOUT=%q\nDEFEXIT=%q\n' \
            "$routes_file" "$default_stdout" "$default_exit")
ARGV=\"\$*\"
while IFS=\$'\\t' read -r p e o; do
  case \"\$ARGV\" in
    \"\$p\"*) if [ -n \"\$o\" ]; then printf '%s\\n' \"\$o\"; fi; exit \"\$e\" ;;
  esac
done < \"\$ROUTES\"
if [ -n \"\$DEFOUT\" ]; then printf '%s\\n' \"\$DEFOUT\"; fi
exit \"\$DEFEXIT\""

  stub_cmd gh --body "$body"
  return 0
}

# --- run_script_env ----------------------------------------------------------
# Additive sibling of run_script (which is a frozen API). Every environment
# change is applied to the child only; the caller's PWD/PATH/env are untouched.
run_script_env() {
  local cwd='' stdin_mode=devnull stdin_val='' sep_stderr=0 source_lib=''
  local path_val='' use_stub_path=0
  local envs=() unsets=() hides=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cwd)            cwd="$2"; shift 2 ;;
      --env)            envs+=("$2"); shift 2 ;;
      --unset)          unsets+=("$2"); shift 2 ;;
      --path)           path_val="$2"; shift 2 ;;
      --stub-path)      use_stub_path=1; shift ;;
      --hide)           hides+=("$2"); shift 2 ;;
      --stdin-string)   stdin_mode='string'; stdin_val="$2"; shift 2 ;;
      --stdin-file)     stdin_mode='file';   stdin_val="$2"; shift 2 ;;
      --stdin-inherit)  stdin_mode='inherit'; shift ;;
      --separate-stderr) sep_stderr=1; shift ;;
      --source)         source_lib="$2"; shift 2 ;;
      --)               shift; break ;;
      -*)               fail "run_script_env: unknown option '$1'" ;;
      *)                break ;;
    esac
  done

  local target="$1"; shift

  local path_final=''
  if [ "${#hides[@]}" -gt 0 ]; then
    _stub_build_farm "${hides[@]}"
    path_final="$STUB_BIN:$STUB_FARM"
  elif [ "$use_stub_path" -eq 1 ]; then
    _stub_init
    path_final="$STUB_BIN:$PATH"
  elif [ -n "$path_val" ]; then
    path_final="$path_val"
  fi

  local envprefix=() item
  if [ "${#unsets[@]}" -gt 0 ]; then
    for item in "${unsets[@]}"; do envprefix+=(-u "$item"); done
  fi
  if [ -n "$path_final" ]; then envprefix+=("PATH=$path_final"); fi
  if [ "${#envs[@]}" -gt 0 ]; then
    for item in "${envs[@]}"; do envprefix+=("$item"); done
  fi

  if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
    fail "run_script_env: --cwd '$cwd' is not a directory"
  fi

  local cmd=()
  if [ "${#envprefix[@]}" -gt 0 ]; then cmd+=(env "${envprefix[@]}"); fi

  if [ -n "$source_lib" ]; then
    # Target is a function name exposed by the sourced library, not a path.
    cmd+=(bash -c \
      'if [ -n "$1" ]; then cd "$1" || exit 125; fi; shift; . "$1" || exit 127; shift; "$@"' \
      _ "$cwd" "$PLUGIN_ROOT/$source_lib" "$target" "$@")
  else
    local abs
    case "$target" in
      /*)      abs="$target" ;;
      ./*|../*) if [ -n "$cwd" ]; then abs="$cwd/$target"; else abs="$PWD/$target"; fi ;;
      *)       abs="$PLUGIN_ROOT/$target" ;;
    esac
    if [ -n "$cwd" ]; then
      cmd+=(bash -c 'cd "$1" || exit 125; shift; exec "$@"' _ "$cwd")
    fi
    case "$target" in
      *.py) cmd+=(python3 "$abs") ;;
      *.sh) cmd+=(bash "$abs") ;;
      *)    cmd+=("$abs") ;;
    esac
    cmd+=("$@")
  fi

  if [ "$sep_stderr" -eq 1 ]; then
    case "$stdin_mode" in
      string)  run --separate-stderr "${cmd[@]}" <<< "$stdin_val" ;;
      file)    run --separate-stderr "${cmd[@]}" < "$stdin_val" ;;
      inherit) run --separate-stderr "${cmd[@]}" ;;
      *)       run --separate-stderr "${cmd[@]}" < /dev/null ;;
    esac
  else
    case "$stdin_mode" in
      string)  run "${cmd[@]}" <<< "$stdin_val" ;;
      file)    run "${cmd[@]}" < "$stdin_val" ;;
      inherit) run "${cmd[@]}" ;;
      *)       run "${cmd[@]}" < /dev/null ;;
    esac
  fi
  return 0
}

# --- assert_audit_row --------------------------------------------------------
# assert_audit_row <action> [--file F] [--actor A] [--subject S] [--result R]
#                  [--meta KEY=VALUE]... [--jq FILTER] [--count N | --absent]
# Locals + `jq -e` only — calling `run` here would clobber the $output the
# caller is still asserting against.
assert_audit_row() {
  local action="$1"; shift
  local file="${AUDIT_LOG:-${WD:-.}/.context/logs/audit.jsonl}"
  local actor='' subject='' result='' extra='' want_count='' absent=0
  local metas=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file)    file="$2"; shift 2 ;;
      --actor)   actor="$2"; shift 2 ;;
      --subject) subject="$2"; shift 2 ;;
      --result)  result="$2"; shift 2 ;;
      --meta)    metas+=("$2"); shift 2 ;;
      --jq)      extra="$2"; shift 2 ;;
      --count)   want_count="$2"; shift 2 ;;
      --absent)  absent=1; shift ;;
      *) fail "assert_audit_row: unknown option '$1'" ;;
    esac
  done

  if [ ! -f "$file" ]; then
    if [ "$absent" -eq 1 ]; then return 0; fi
    fail "assert_audit_row: audit log not found: $file"
  fi

  local jqargs=(--arg action "$action")
  local filter='.action == $action'
  if [ -n "$actor" ];   then jqargs+=(--arg actor "$actor");     filter="$filter and (.actor == \$actor)"; fi
  if [ -n "$subject" ]; then jqargs+=(--arg subject "$subject"); filter="$filter and (.subject == \$subject)"; fi
  if [ -n "$result" ];  then jqargs+=(--arg result "$result");   filter="$filter and (.result == \$result)"; fi

  local m k v i=0
  if [ "${#metas[@]}" -gt 0 ]; then
    for m in "${metas[@]}"; do
      k="${m%%=*}"; v="${m#*=}"
      jqargs+=(--arg "mk$i" "$k" --arg "mv$i" "$v")
      filter="$filter and ((.metadata[\$mk$i] | tostring) == \$mv$i)"
      i=$((i + 1))
    done
  fi
  if [ -n "$extra" ]; then filter="$filter and ($extra)"; fi

  local count
  count="$(jq -s "${jqargs[@]}" "[.[] | select($filter)] | length" "$file" 2>/dev/null)" \
    || fail "assert_audit_row: jq failed on $file (filter: $filter)"

  if [ "$absent" -eq 1 ]; then
    if [ "$count" -ne 0 ]; then
      fail "assert_audit_row: expected no '$action' row, found $count
filter: $filter
$(cat "$file")"
    fi
    return 0
  fi
  if [ -n "$want_count" ]; then
    if [ "$count" -ne "$want_count" ]; then
      fail "assert_audit_row: expected $want_count '$action' row(s), found $count
filter: $filter
$(cat "$file")"
    fi
    return 0
  fi
  if [ "$count" -lt 1 ]; then
    fail "assert_audit_row: no '$action' row matched
filter: $filter
$(cat "$file")"
  fi
  return 0
}

# --- fixtures ----------------------------------------------------------------
# mk_state_fixture <outfile> [jq-filter...]
# Writes the canonical ledger, then applies each filter in order. facts.goal is
# deliberately absent — branch-name.sh's no-goal arm depends on its absence.
mk_state_fixture() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  printf '%s\n' '{"version":1,"worktask_id":"wt-test","plan_file":".context/planning-0.md","platform":"all","run_index":0,"stages":{},"facts":{"files_modified":[],"tests_added":[],"decisions":[],"open_questions":[],"verdicts":{}},"handoffs":{},"metadata":{}}' > "$out"
  local f tmp="$out.mkstate.tmp"
  for f in "$@"; do
    if [ -z "$f" ]; then continue; fi
    jq "$f" "$out" > "$tmp" || fail "mk_state_fixture: jq filter failed: $f"
    mv -f "$tmp" "$out"
  done
  printf '%s\n' "$out"
  return 0
}

# mk_multitask_ledger <outfile> [--run-index N] [--task ID:QUESTIONS:DECISIONS[:RESOLVED]]...
# Writes a v2 ledger owned by several tasks at once — the shape the per-task ledger clamps
# partition on, and the one a single-task fixture cannot express.
#   QUESTIONS become sw-<ID>-1..n, the first RESOLVED of them answered. Their `.stage` is the
#   BARE code, as the FN gate's grouping expects; the clamp reads the task id out of the id.
#   DECISIONS become <lowercased-id>-1..n stamped `.stage: <ID>`, the full task id the
#   decisions ring partitions on.
mk_multitask_ledger() {
  local out="$1"; shift
  local run_index=0
  local specs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-index) shift; run_index="${1:-0}"; shift ;;
      --task) shift; specs+=("${1:-}"); shift ;;
      *) fail "mk_multitask_ledger: unknown arg: $1" ;;
    esac
  done
  mkdir -p "$(dirname "$out")"
  local spec_json
  spec_json=$(printf '%s\n' ${specs[@]+"${specs[@]}"} | jq -R -s -c '
    split("\n") | map(select(length > 0) | split(":"))
    | map({id: .[0], q: ((.[1] // "0") | tonumber), d: ((.[2] // "0") | tonumber),
           r: ((.[3] // "0") | tonumber)})') \
    || fail "mk_multitask_ledger: could not parse --task specs"
  jq -n --argjson t "$spec_json" --argjson ri "$run_index" '
    { version: 2, worktask_id: "multitask-fixture", plan_file: ".context/planning-0.md",
      platform: "all", run_index: $ri,
      tasks: ($t | map({key: .id, value: {status: "in_progress"}}) | from_entries),
      facts: {
        files_modified: [], tests_added: [], verdicts: {},
        decisions: [ $t[] as $x | range(1; $x.d + 1) as $i
                     | {id: (($x.id | ascii_downcase) + "-" + ($i | tostring)),
                        summary: "s", ref: "x.md#y", stage: $x.id} ],
        open_questions: [ $t[] as $x | range(1; $x.q + 1) as $i
                     | {id: ("sw-" + $x.id + "-" + ($i | tostring)), class: "decision",
                        ref: "x.md#elicitation-sweep", blocks_next_stage: false,
                        stage: ($x.id | sub("[0-9]+$"; "")),
                        status: (if $i <= $x.r then "resolved" else "open" end)}
                       + (if $i <= $x.r then {resolution: "answered"} else {} end) ] },
      handoffs: {} }' > "$out" || fail "mk_multitask_ledger: jq failed"
  printf '%s\n' "$out"
  return 0
}

# mk_git_fixture [--dir DIR] [--branch NAME] [--file PATH:CONTENT]...
#                [--commit MSG] [--stage PATH]... [--modify PATH:CONTENT]...
#                [--remote URL]
# Prints the repo dir. Fixed identity/dates keep two runs byte-identical.
# --file stages; --modify leaves the change in the working tree.
mk_git_fixture() {
  local dir='' branch='main' remote='' ops=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)    dir="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --remote) remote="$2"; shift 2 ;;
      --file|--modify|--stage|--commit) ops+=("$1" "$2"); shift 2 ;;
      *) fail "mk_git_fixture: unknown option '$1'" ;;
    esac
  done
  if [ -z "$dir" ]; then dir="$(mk_tmpworkdir)"; fi
  mkdir -p "$dir"

  local G=(git -C "$dir" -c user.name=t -c user.email=t@t \
           -c commit.gpgsign=false -c core.hooksPath=/dev/null)
  if ! "${G[@]}" init -q -b "$branch" 2>/dev/null; then
    "${G[@]}" init -q || fail "mk_git_fixture: git init failed in $dir"
    "${G[@]}" checkout -q -b "$branch" || fail "mk_git_fixture: git checkout -b $branch failed"
  fi
  if [ -n "$remote" ]; then
    "${G[@]}" remote add origin "$remote" || fail "mk_git_fixture: git remote add failed"
  fi

  local i=0 op val p c
  while [ "$i" -lt "${#ops[@]}" ]; do
    op="${ops[$i]}"; val="${ops[$((i + 1))]}"; i=$((i + 2))
    case "$op" in
      --file|--modify)
        p="${val%%:*}"; c="${val#*:}"
        mkdir -p "$dir/$(dirname "$p")"
        printf '%b' "$c" > "$dir/$p"
        if [ "$op" = "--file" ]; then
          "${G[@]}" add -- "$p" || fail "mk_git_fixture: git add failed for $p"
        fi ;;
      --stage)
        "${G[@]}" add -- "$val" || fail "mk_git_fixture: git add failed for $val" ;;
      --commit)
        GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
          "${G[@]}" commit -q -m "$val" || fail "mk_git_fixture: git commit failed" ;;
    esac
  done

  printf '%s\n' "$dir"
  return 0
}

# Default teardown. A test file that defines its own teardown() SHOULD call
# `_test_helper_cleanup` to retain auto-cleanup of mk_tmpworkdir dirs.
_test_helper_cleanup() {
  local d
  for d in "${_TEST_HELPER_TMPDIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  _TEST_HELPER_TMPDIRS=()
  if [ -n "${_TEST_HELPER_STUBDIR:-}" ] && [ -d "$_TEST_HELPER_STUBDIR" ]; then
    rm -rf "$_TEST_HELPER_STUBDIR"
  fi
  _TEST_HELPER_STUBDIR=""
}

teardown() {
  _test_helper_cleanup
}

# Contract assertions can span leaves; only the marked canonical bodies form this test view.
contract_source() {
  local source="$1" rel out module
  if ! grep -q '<!-- canonical-module: ' "$source" 2>/dev/null; then
    printf '%s' "$source"
    return
  fi
  out="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/contract-source.XXXXXX")"
  out="$out/$(basename "$source")"
  while IFS= read -r rel; do
    module="$(dirname "$source")/$rel"
    [ -f "$module" ] || return 1
    awk '/^<!-- canonical-body:start -->$/ { body=1; next }
         body { print }' "$module" >> "$out"
  done < <(sed -n 's/.*<!-- canonical-module: \(.*\) -->.*/\1/p' "$source")
  printf '%s' "$out"
}
export -f contract_source
