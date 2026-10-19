#!/usr/bin/env bash
# test-execution-gate — PreToolUse gate for skills/shared/testing-strategy.md
# § Test-Execution Authority: only DV (scoped) and QA (scoped + full) may run
# tests, and an already-recorded run is denied while the tree is unchanged.
#
# Stage comes from .context/state.json alone, never agent identity or env, so a
# nested delegate inherits the in-progress stage. The Agent branch only observes:
# a dispatch prompt quoting the ban names every runner, so matching prose there
# would refuse to dispatch the stages that implement the policy.
#
# Exits 0 always; the decision travels in hookSpecificOutput.permissionDecision,
# so a malformed emission fails OPEN. Hatches are process env only and cannot be
# reached from a command string: CORPFLOW_TEST_GATE=off, CORPFLOW_TEST_DEDUPE=off.
#
# No `set -e`: a false compound test is control flow here, and aborting mid-
# classification would turn a fail-open backstop closed. `set -f` is load-bearing
# — the xcodebuild and gradle scans word-split an unquoted fragment on purpose.
#
# --self-test body: lib/test-execution-gate-selftest.sh.
set -u
set -f

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

# Guarded source of the shared hook library (AD-2). This file has no `set -e`, so
# the save/restore is a no-op today; the idiom is kept identical across all four
# consumers so it stays correct if that ever changes. `[ -f ]` alone is not
# enough: a TRUNCATED library is a syntax error, which `||` cannot rescue.
#
# The probe names the LAST symbol the library defines, so a rename and a mid-file
# truncation are both caught. A silently missing symbol here would disarm the
# gate, which is why degradation is announced rather than inferred.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac
LIB_DEGRADED=0
command -v corpflow_hook_audit_row > /dev/null 2>&1 || LIB_DEGRADED=1

# Same guarded-source idiom for the suppression library. Its absence degrades
# suppression alone — no classifier arm calls into it, so authority enforcement
# is unaffected — and so this one does not raise LIB_DEGRADED. Two guards keep
# that claim true: dedupe_decide checks the symbol and returns (allow), and its
# single call site checks before evaluating the library-valued arguments.
_DEDUPE_LIB="$(dirname "$0")/lib/dedupe-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/lib/dedupe-lib.sh
[ -f "$_DEDUPE_LIB" ] && . "$_DEDUPE_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

# The assignment strip the Bash classifier runs lives beside the audit redaction it
# shares a threat with. The include guard is cleared first: inherited from the environment
# it would stop the real library loading.
_CMDHEAD_LIB="${_DEDUPE_LIB%/dedupe-lib.sh}/command-head-lib.sh"
unset _CORPFLOW_CMDHEAD_LIB
_CF_OPTS=$-
set +e
# shellcheck source=hooks/lib/command-head-lib.sh
[ -f "$_CMDHEAD_LIB" ] && . "$_CMDHEAD_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac
# Fallback, not a second source of truth: with the library absent the gate keeps classifying
# rather than failing open, so deleting one file is no off-switch outside the documented
# CORPFLOW_TEST_GATE hatch. Its pattern must stay identical to the library's _ASSIGN_RE: a
# looser one leaves a quoted value's fragment in head position, hiding the runner behind it
# and turning a deny into an allow (test-execution-gate.bats pins the parity). The
# degradation is announced once the context root is known, below.
CMDHEAD_FALLBACK=0
if ! command -v strip_assignments > /dev/null 2>&1; then
  CMDHEAD_FALLBACK=1
  strip_assignments() {
    local _s _next
    local _re='^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:blank:]]+'
    _s="$1"
    while :; do
      case "$_s" in
        env\ *) _s="${_s#env }" ;;
        *)
          [[ $_s =~ $_re ]] || break
          _next="${_s#"${BASH_REMATCH[0]}"}"
          [ "$_next" != "$_s" ] || break
          _s="$_next"
          ;;
      esac
    done
    printf '%s' "$_s"
  }
fi

# Remediation prose for the three denial classes lives in references/, not inline: it is
# operator guidance rather than logic, and every constraint on its wording is recorded beside
# it. Read on a deny path only, so the allow path stays fork-free. Sections are delimited by
# `<!-- id -->` markers and joined with single spaces.
#
# Degrades, never fails closed: an unreadable document leaves the condition clause alone. A
# gate that cannot find its help text must still deny — and must not deny harder than it would
# with the text present.
_DENY_DOC="$(dirname "$0")/references/test-execution-denials.md"

deny_help() {
  [ -r "$_DENY_DOC" ] || return 0
  awk -v id="$1" '
    $0 == "<!-- " id " -->" { on = 1; next }
    on && /^<!-- / { exit }
    on { buf = (buf == "" ? $0 : buf " " $0) }
    END { gsub(/  +/, " ", buf); sub(/^ +/, "", buf); sub(/ +$/, "", buf); print buf }
  ' "$_DENY_DOC" 2> /dev/null
}

# deny_reason <condition-clause> <section-id> -> the clause, plus the section when it loads.
deny_reason() {
  local _help
  _help=$(deny_help "$2")
  if [ -n "$_help" ]; then printf '%s %s' "$1" "$_help"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------
# RUNNERS — parity counterpart of testing-strategy.md's canonical list;
# test-authority-matrix.bats asserts the two agree. Matched against the head
# token after wrapper-stripping.
#
# MULTI_PURPOSE_RUNNERS is the subset with non-test shapes (`swift build`,
# `go build`), where the subcommand must name "test" — for gradle, a task
# containing "test" — before anything classifies as test execution.
# ---------------------------------------------------------------------------
RUNNERS="bats swift pytest ctest cargo jest vitest playwright rspec gradle gradlew python python3 go make npx uvx pnpm yarn bunx xcodebuild dotnet npm node"
MULTI_PURPOSE_RUNNERS="swift cargo go npm pnpm yarn dotnet xcodebuild gradle gradlew node make"

# Known bypasses, all allow-direction: $(...)/backticks/here-docs are not
# segment-split; `find -exec`, `xargs`, and a renamed or written-then-executed
# runner never reach head position; `env -i`, `\pytest`, and `bash -c'x'` (no
# space) are not unwrapped; `nice`, `stdbuf`, `caffeinate` and `sudo` are not
# stripped as wrappers, nor is a `{ ...; }` group; a `timeout` option outside
# the grammar in _gate_timeout_step is read as the duration; nesting past
# MAX_RECURSE_DEPTH classifies not_test rather than recursing unboundedly;
# `npm test --dry-run` classifies build_only while npm still runs the script.
# This hook is a backstop — tool-grant narrowing and the orchestrator's ban
# banner are the controls without gaps.

# ---------------------------------------------------------------------------
# The one wrapper definition read by both classify_segment and the fast-path
# scanner: if the two drift, the scanner heads on a wrapper, finds nothing
# gateable and allows what the classifier would deny.
#
# GATE_LAUNCHERS — prefixes stripped so the real runner reaches head position;
# `_` joins a two-word phrase. GATE_TIMEOUT_WRAPPERS take options and a duration
# before the command (_gate_timeout_step). GATE_SHELLS are chased through `-c`.
# ---------------------------------------------------------------------------
GATE_LAUNCHERS="env npx uvx uv_run pnpm_exec yarn_dlx bunx time nohup command exec"
GATE_TIMEOUT_WRAPPERS="timeout gtimeout"
GATE_SHELLS="sh bash zsh dash ksh"

# Scanner skip set: every one-word launcher, plus the first word of a two-word
# one unless it is a runner itself (`pnpm test` must head on pnpm).
GATE_SCAN_SKIP=""
for _gate_l in $GATE_LAUNCHERS; do
  case "$_gate_l" in
    *_*) case " $RUNNERS " in *" ${_gate_l%%_*} "*) continue ;; esac ;;
  esac
  GATE_SCAN_SKIP="$GATE_SCAN_SKIP ${_gate_l%%_*}"
done
unset _gate_l

# _gate_timeout_step <token> — advances GATE_TMO over timeout's arguments:
# "opt" reading options, "arg" the next token is an option's value, "" once the
# duration is consumed and the wrapped command starts.
_gate_timeout_step() {
  if [ "$GATE_TMO" = arg ]; then GATE_TMO=opt; return 0; fi
  case "$1" in
    -s|-k|--signal|--kill-after) GATE_TMO=arg ;;
    -s?*|-k?*|--signal=*|--kill-after=*|--preserve-status|--foreground|-v|--verbose|--) GATE_TMO=opt ;;
    *) GATE_TMO="" ;;
  esac
  return 0
}

# _gate_strip_parens <string> -> sets PARENLESS to <string> without its leading
# `(` run and trailing `)` run. One regex match per side: stripping a character
# per iteration, or a `${x%%[!(]*}` glob, is quadratic on bash 3.2.
_GATE_LPAREN_RE='^[(]+'
_GATE_RPAREN_RE='[)]+$'
_gate_strip_parens() {
  PARENLESS="$1"
  if [[ $PARENLESS =~ $_GATE_LPAREN_RE ]]; then PARENLESS="${PARENLESS:${#BASH_REMATCH[0]}}"; fi
  if [[ $PARENLESS =~ $_GATE_RPAREN_RE ]]; then
    PARENLESS="${PARENLESS:0:$((${#PARENLESS} - ${#BASH_REMATCH[0]}))}"
  fi
}

# _gate_strip_wrappers <segment> -> sets STRIPPED to the segment with every
# leading subshell `(`, trailing `)`, VAR=value, launcher and timeout wrapper
# removed, repeated until none remains.
_gate_strip_wrappers() {
  local _s="$1" _prev _l _p _tok
  while :; do
    _prev="$_s"
    _gate_strip_parens "$_s"
    _trim "$PARENLESS"; _s="$TRIMMED"
    # Every pass: a wrapper or `(` can expose an assignment the scanner already skips.
    _s="$(strip_assignments "$_s")"
    for _l in $GATE_LAUNCHERS; do
      _p="${_l//_/ } "
      case "$_s" in "$_p"*) _s="${_s#"$_p"}"; _trim "$_s"; _s="$TRIMMED" ;; esac
    done
    _tok="${_s%% *}"
    case " $GATE_TIMEOUT_WRAPPERS " in
      *" ${_tok##*/} "*)
        GATE_TMO=opt
        while [ -n "$GATE_TMO" ] && [ -n "$_s" ]; do
          if [ "$_s" = "$_tok" ]; then _s=""; else _s="${_s#"$_tok"}"; _trim "$_s"; _s="$TRIMMED"; fi
          _tok="${_s%% *}"
          [ -n "$_s" ] && _gate_timeout_step "$_tok"
        done
        if [ -n "$_s" ]; then
          if [ "$_s" = "$_tok" ]; then _s=""; else _s="${_s#"$_tok"}"; _trim "$_s"; _s="$TRIMMED"; fi
        fi
        GATE_TMO=""
        ;;
    esac
    [ "$_s" != "$_prev" ] || break
  done
  STRIPPED="$_s"
}

# ---------------------------------------------------------------------------
# _trim <string> -> sets TRIMMED to the string without surrounding whitespace.
# Assigns to a global rather than echoing: `x=$(f)` forks a subshell even for a
# shell function, and this runs on the hot path of every classified command.
# ---------------------------------------------------------------------------
_trim() {
  local _t="$1"
  _t="${_t#"${_t%%[![:space:]]*}"}"
  TRIMMED="${_t%"${_t##*[![:space:]]}"}"
}

# ---------------------------------------------------------------------------
# _gradle_subcmd / _xcodebuild_subcmd <rest> -> 0 when the invocation executes
# tests, 1 when it does not. Both set _rest_effective to <rest> minus the
# consumed action token, so the caller's selector check judges only what follows.
#
# Return code plus a global, not an echoed value: `x=$(f)` forks, and these sit
# on the hot path of every classified command.
# ---------------------------------------------------------------------------
_gradle_subcmd() {
  local _rest="$1" _task="" _skipv=0 _tok
  # The task is FOUND, not read from first position: gradle accepts options
  # before tasks (`gradle -p . test`), where a first-token read sees `-p` and
  # lets a full run through as scoped. `-p` values are skipped so a dir named
  # `test-utils` is not mistaken for the task; an unlisted flag's value still
  # can be — the allow direction. The value-taking options of the strip below are
  # skipped here too, or `--console plain test` reads `plain` as the task.
  for _tok in $_rest; do
    if [ "$_skipv" -eq 1 ]; then _skipv=0; continue; fi
    case "$_tok" in
      -p|--project-dir|--console|--max-workers|--warning-mode|-g|--gradle-user-home|-b|--build-file|-c|--settings-file|-I|--init-script|--project-cache-dir) _skipv=1 ;;
      -*) : ;;
      *) _task="$_tok"; break ;;
    esac
  done
  # Task names containing "test" that only build it — assembleAndroidTest,
  # installDebugAndroidTest, compileDebugUnitTest* — execute nothing, and
  # denying them would break the build-only promise.
  case "$_task" in
    install*|assemble*|compile*) return 1 ;;
  esac
  case "$_rest" in
    *[Tt]est*) : ;;
    *) return 1 ;;
  esac
  # The task token is dropped from what the caller's selector check sees. rc is
  # ignored on purpose: a gradle invocation with no task word still classifies,
  # and _consume_action reports "not found" for it.
  _consume_action "$_rest" "$_task" || :
  return 0
}

# _consume_action <rest> <word>... -> 0 when one of <word> appears as a WHOLE
# token in <rest>, with _rest_effective set to <rest> minus that first match.
# Word-exact by construction: a substring match would fire on `-scheme MyTests`.
# Return code plus a global, never an echoed value: `x=$(f)` forks, and this is on
# the hot path of every classified command.
_consume_action() {
  local _rest="$1" _found=0 _tok _word
  shift
  _rest_effective=""
  for _tok in $_rest; do
    if [ "$_found" -eq 0 ]; then
      for _word in "$@"; do
        [ "$_tok" = "$_word" ] && { _found=1; break; }
      done
      [ "$_found" -eq 1 ] && continue
    fi
    _rest_effective="$_rest_effective $_tok"
  done
  [ "$_found" -eq 1 ] || return 1
  return 0
}

_xcodebuild_subcmd() {
  # xcodebuild puts its ACTION after the options (`xcodebuild -scheme A test`),
  # so the first-token read used for every other multi-purpose runner sees
  # `-scheme` and lets a real test run through. `build-for-testing` compiles
  # without running, so it is not an action here. Residual, accepted: an option
  # value that is literally `test` reads as the action — a false deny, the safe
  # direction.
  _consume_action "$1" test test-without-building
}

_make_subcmd() {
  local _rest="$1" _tok
  # `make` is a project's general task runner, so only a target that NAMES test
  # or coverage work is test execution — the same task-name rule gradle gets.
  # `make testdata` therefore classifies as a test run: a false deny is the safe
  # direction for a backstop, and the alternative is parsing the Makefile.
  for _tok in $_rest; do
    case "$_tok" in
      -*) : ;;
      *[Tt]est*|*overage*) return 0 ;;
    esac
  done
  return 1
}

_node_subcmd() {
  # `node script.js` executes a script, not a test suite; only the built-in
  # runner's `--test` switch makes it test execution. Word-exact, and
  # `--test-name-pattern` alone does NOT qualify — it narrows a run it cannot
  # start, so accepting it would deny ordinary script execution.
  _consume_action "$1" --test
}

# ---------------------------------------------------------------------------
# tokenize_quoted <string> -> fills TOKENIZED_ARGV, splitting on UNQUOTED
# whitespace only, so a quoted multi-word value stays one token. Surrounding
# quotes are dropped; the value itself is never interpreted.
#
# Returns 1 on an unterminated quote, which the caller MUST treat as "strip
# nothing" — a half-parsed list can drop the token that makes a run scoped. No
# eval, xargs, or sentinel byte: this parses an untrusted string inside a
# security control. Backslash-escaped whitespace still splits, leaving a
# positional that classifies scoped — the allow direction.
# ---------------------------------------------------------------------------
tokenize_quoted() {
  local _s="$1" _i=0 _n=${#1} _ch _cur="" _open=0 _q=""
  TOKENIZED_ARGV=()
  while [ "$_i" -lt "$_n" ]; do
    _ch="${_s:$_i:1}"
    _i=$((_i + 1))
    if [ -n "$_q" ]; then
      if [ "$_ch" = "$_q" ]; then _q=""; else _cur="$_cur$_ch"; fi
      continue
    fi
    case "$_ch" in
      \'|\") _q="$_ch"; _open=1 ;;
      # $'\t' is parser-expanded; $(printf '\t') would fork per character.
      ' '|$'\t')
        [ "$_open" -eq 1 ] && { TOKENIZED_ARGV[${#TOKENIZED_ARGV[@]}]="$_cur"; _cur=""; _open=0; }
        ;;
      *) _cur="$_cur$_ch"; _open=1 ;;
    esac
  done
  [ -z "$_q" ] || { TOKENIZED_ARGV=(); return 1; }
  [ "$_open" -eq 1 ] && TOKENIZED_ARGV[${#TOKENIZED_ARGV[@]}]="$_cur"
  return 0
}

# ---------------------------------------------------------------------------
# _gate_redirect <token> -> rc 0 when <token> is a shell redirection
# (`2>&1`, `>f`, `2>/dev/null`, `&>f`, `>>f`, `<f`, `<<<x`). Sets
# _GATE_REDIR_TARGET to 0 when the operator stands alone (`>` `f`), so the NEXT
# token is its target, and to 1 when the target is attached.
#
# The segment splitter keeps `>&`/`&>` inside one segment on purpose, so a
# redirect reaches the selector check as an ordinary word; without this it reads
# as a positional and `swift test 2>&1` classifies as scoped. Runner-independent:
# no test runner takes a redirect as an argument.
# ---------------------------------------------------------------------------
_GATE_REDIR_RE='^([0-9]*(>>?|<<?<?|>&|<&)|&>{1,2})(.*)$'
_gate_redirect() {
  [[ $1 =~ $_GATE_REDIR_RE ]] || return 1
  if [ -z "${BASH_REMATCH[3]}" ]; then _GATE_REDIR_TARGET=0; else _GATE_REDIR_TARGET=1; fi
  return 0
}

# ---------------------------------------------------------------------------
# _gate_runner_flag <head> <token> -> how strip_nonselecting_flags treats a flag
# that configures a run and never narrows it. rc:
#   0  drop the token alone (valueless flag, or `--flag=value`)
#   1  drop the token and its value, unless that value starts with `-`
#   3  drop the token and its value unconditionally (`-Xswiftc -warn...`)
#   2  not listed: keep it
#
# Only a flag whose runner-side meaning is "how to run" belongs here. A flag that
# narrows the run (`--filter`, `-k`, `-m`, `--tests`, `-p <package>` on cargo,
# `--shard`) must stay out so its value survives as the selector. An unlisted
# flag keeps the allow direction: it survives, classifies scoped, never denies.
# ---------------------------------------------------------------------------
_gate_runner_flag() {
  local _h="$1" _t="$2" _n _v=1
  _n="${_t%%=*}"
  [ "$_n" = "$_t" ] || _v=0
  case "$_h" in
    swift)
      case "$_n" in
        -Xswiftc|-Xcc|-Xcxx|-Xlinker) [ "$_v" -eq 1 ] && return 3; return 0 ;;
        --package-path|--scratch-path|--build-path|--cache-path|-j|--jobs|--sanitize|--triple|--sdk|--toolchain|--arch|--num-workers|--build-system|--xunit-output|--swift-sdk)
          return "$_v" ;;
      esac
      case "$_t" in
        -j?*) return 0 ;;
        --parallel|--no-parallel|--enable-code-coverage|--skip-build|--verbose|-v|--vv|--disable-sandbox|--enable-swift-testing|--disable-swift-testing|--enable-xctest|--disable-xctest)
          return 0 ;;
      esac
      ;;
    cargo)
      # The positional is a test-name filter, so it stays; `-p/--package`,
      # `--lib`, `--test`, `--bins`, `--doc` and `--exclude` narrow the run.
      case "$_n" in
        --manifest-path|--target-dir|--profile|--target|--features|-F|-j|--jobs|--color|--message-format|--test-threads|--config)
          return "$_v" ;;
      esac
      case "$_t" in
        -j?*) return 0 ;;
        --|--workspace|--all|--all-features|--no-default-features|--no-fail-fast|--locked|--offline|--frozen|--keep-going|-q|--quiet|-v|-vv|--verbose|--nocapture|--show-output)
          return 0 ;;
      esac
      ;;
    go)
      # A package pattern (`./pkg`, `./...`) is a positional selector and stays.
      # Every value below is a number, duration or path, and would otherwise
      # read as one: `go test -count 1` is the whole suite.
      case "$_n" in
        -count|-timeout|-parallel|-p|-cpu|-tags|-mod|-coverprofile|-covermode|-coverpkg|-exec|-vet|-shuffle|-o|-outputdir|-ldflags|-gcflags)
          return "$_v" ;;
      esac
      case "$_t" in
        -v|-race|-cover|-short|-failfast|-json|-x|-a|-trimpath|-work) return 0 ;;
      esac
      ;;
    pytest|"python -m pytest")
      # A positional path or node id is a selector and stays; `-m <expr>` and
      # `-k` narrow the run and stay out of this list.
      case "$_n" in
        -p|-o|--override-ini|-n|--numprocesses|--maxfail|--tb|--color|--junitxml|--junit-xml|--basetemp|--rootdir|--confcutdir|--durations|--durations-min|--log-level|--log-cli-level|--capture|--show-capture|--dist|--import-mode|--cache-dir|-W|--timeout|-r|--cov-report|--cov-config|--html|--randomly-seed|--report-log)
          return "$_v" ;;
      esac
      case "$_t" in
        -r?*) return 0 ;;
        -x|-q|-qq|-v|-vv|-vvv|-s|-l|--showlocals|--exitfirst|--quiet|--verbose|--disable-warnings|--no-header|--no-summary|--strict-markers|--strict-config)
          return 0 ;;
      esac
      ;;
    jest|vitest|npm|pnpm|yarn)
      # `npm test -- <jest flags>`: the flags after `--` belong to the runner.
      case "$_n" in
        --maxWorkers|-w|--workers|--testTimeout|--reporters|--reporter|--outputFile|--coverageDirectory|--rootDir|--cacheDirectory|--testEnvironment|--environment|--env)
          return "$_v" ;;
      esac
      case "$_t" in
        --ci|--coverage|--runInBand|-i|--colors|--no-colors|--color|--no-color|--verbose|--silent|--forceExit|--detectOpenHandles|--passWithNoTests|--no-cache|--no-watch|--globals|--useStderr)
          return 0 ;;
        # `vitest run` is the non-watch spelling of the same suite, not a file.
        run|--run) [ "$_h" = vitest ] && return 0 ;;
      esac
      ;;
    bats)
      case "$_n" in -j|--jobs) return "$_v" ;; esac
      case "$_t" in --tap|-T|--timing|--print-output-on-failure) return 0 ;; esac
      ;;
    gradle|gradlew)
      # -D<prop> is a JVM system property, like -P<prop> already stripped.
      case "$_n" in
        --console|--max-workers|--warning-mode|-g|--gradle-user-home|-b|--build-file|--settings-file|-I|--init-script|--project-cache-dir)
          return "$_v" ;;
      esac
      case "$_t" in
        -D?*) return 0 ;;
        --info|--debug|--warn|--quiet|-q|-i|-d|-w|-s|-S|--stacktrace|--full-stacktrace|--no-daemon|--daemon|--parallel|--no-parallel|--offline|--continue|--rerun-tasks|--build-cache|--no-build-cache|--configuration-cache|--no-configuration-cache|--refresh-dependencies|--scan|--no-scan|--watch-fs|--no-watch-fs)
          return 0 ;;
      esac
      ;;
    xcodebuild)
      # `KEY=VALUE` is a build setting (CODE_SIGNING_ALLOWED=NO), never a
      # selector; `-only-testing:X` has no `=` and cannot match.
      case "$_t" in
        [A-Za-z_]*=*) return 0 ;;
        -disableAutomaticPackageResolution|-skipPackagePluginValidation|-skipMacroValidation|-onlyUsePackageVersionsFromResolvedFile|-retry-tests-on-failure|-hideShellScriptEnvironment|-allowProvisioningDeviceRegistration)
          return 0 ;;
        -jobs|-parallel-testing-worker-count|-enableCodeCoverage|-test-iterations|-testLanguage|-testRegion|-clonedSourcePackagesDirPath|-archivePath|-target|-destination-timeout|-test-timeouts-enabled|-enableAddressSanitizer|-enableThreadSanitizer|-enableUndefinedBehaviorSanitizer)
          return 1 ;;
      esac
      ;;
  esac
  return 2
}

# ---------------------------------------------------------------------------
# strip_nonselecting_flags <head> <rest> -> <rest> minus the flags the runner
# carries on every invocation, so a surviving positional means the caller
# narrowed the run rather than that the runner needs flags to start at all.
#
# Fail direction is load-bearing: an unlisted flag survives, classifies scoped,
# and degrades to allow — never to a false deny. Value-consuming arms therefore
# refuse to eat a token beginning with `-`, so `-scheme -only-testing:X` leaves
# the selector standing. Token-walked, not sed: a regex cannot express that
# guard, keep a quoted value whole, or match adjacent switches on one pass.
# ---------------------------------------------------------------------------
strip_nonselecting_flags() {
  local _h="$1" _in="$2" _out="" _tok _skip=0 _rskip=0 _sk
  # Unbalanced quoting -> strip nothing, which classifies scoped and allows.
  tokenize_quoted "$_in" || { printf '%s' "$_in"; return; }
  for _tok in ${TOKENIZED_ARGV[@]+"${TOKENIZED_ARGV[@]}"}; do
    # A redirect is not an argument, and neither is its target. Checked ahead of
    # the value skip below, and leaving it pending: a redirect between a flag and
    # its value must not consume the value.
    if [ "$_rskip" -eq 1 ]; then _rskip=0; continue; fi
    if _gate_redirect "$_tok"; then
      [ "$_GATE_REDIR_TARGET" -eq 0 ] && _rskip=1
      continue
    fi
    if [ "$_skip" -ne 0 ]; then
      _sk="$_skip"
      _skip=0
      # 2 = the flag takes a value that may itself start with `-`.
      [ "$_sk" -eq 2 ] && continue
      case "$_tok" in
        -*) : ;;
        *) continue ;;
      esac
    fi
    case "$_h" in
      xcodebuild)
        # -only-testing: is xcodebuild's only true selector; the rest is
        # routine. -testPlan is deliberately NOT a selector — a plan is whole,
        # and a project's default plan usually IS the full suite.
        case "$_tok" in
          -project|-workspace|-scheme|-destination|-resultBundlePath|-derivedDataPath|-sdk|-arch|-toolchain|-xcconfig|-configuration|-testPlan|-parallel-testing-enabled|-maximum-concurrent-test-simulator-destinations)
            _skip=1; continue ;;
          -quiet|-verbose|-parallelizeTargets|-showBuildTimingSummary|-allowProvisioningUpdates)
            continue ;;
        esac
        ;;
      dotnet)
        # The solution/project positional names WHAT to build, not which tests
        # to run. Guarded against a flag spelled `--x.sln` by the `-*` arm.
        case "$_tok" in
          -*) : ;;
          *.sln|*.csproj|*.fsproj) continue ;;
        esac
        ;;
      gradle|gradlew)
        case "$_tok" in
          -p|--project-dir) _skip=1; continue ;;
          -P*) continue ;;   # -Pkey=value: a build property, never a selector
        esac
        ;;
      npm|pnpm|yarn)
        # `--` is the script/args separator, not an argument.
        case "$_tok" in
          --|--ci|--run|--silent|--watch|--watch=*) continue ;;
        esac
        ;;
      node)
        # How a Node test run is CONFIGURED, never which tests it selects.
        # `--test-name-pattern` and `--test-only` are genuine selectors and
        # deliberately survive this arm.
        case "$_tok" in
          --test-reporter|--test-reporter-destination|--test-concurrency)
            _skip=1; continue ;;
          --test-reporter=*|--test-reporter-destination=*|--test-concurrency=*)
            continue ;;
        esac
        ;;
      rspec)
        # RSpec's `-c` is --colour, VALUELESS — not the `-c <value>` config
        # flag it is on swift/pytest/jest. Listed here, ahead of the shared
        # arm below, so it is dropped rather than consuming the spec file that
        # follows it and turning a scoped run into a full one.
        case "$_tok" in
          -c|--color|--colour|--no-color|--no-colour) continue ;;
        esac
        ;;
    esac
    # Configuration flags and their values, per runner (see _gate_runner_flag).
    _gate_runner_flag "$_h" "$_tok"
    case "$?" in
      0) continue ;;
      1) _skip=1; continue ;;
      3) _skip=2; continue ;;
    esac
    # Runner-independent: a build configuration is not a test selection.
    #
    # `-c` takes a value on swift/pytest/jest/vitest/gradle/dotnet but is
    # VALUELESS on bats (--count), go (compile-only) and rspec (--colour), each
    # handled BEFORE this arm. A value-consuming arm applied to a valueless flag
    # eats the next token and turns a scoped run into a full-suite deny. Any
    # flag added here needs the same per-runner check.
    case "$_tok" in
      -c|--config|--configuration) _skip=1; continue ;;
      --release) continue ;;
    esac
    # An empty token (a literal "" on the command line) is still an argument;
    # a marker keeps it from vanishing into a full-run verdict.
    [ -n "$_tok" ] || { _out="$_out ''"; continue; }
    _out="$_out $_tok"
  done
  printf '%s' "$_out"
}

# ---------------------------------------------------------------------------
# _gate_split_legacy <command> -> fills GATE_SEGS, splitting on EVERY separator
# byte with no regard for quoting. Kept as the fail-closed fallback for a
# command _gate_split_segments cannot parse: an over-split can only surface a
# runner (deny direction), never hide one.
#
# Fork-free: bash substitution patterns are globs, where & ; | are all literal,
# so literal passes replace one alternation regex. Order matters — && and ||
# are consumed before the single-character passes can split them. A bare `&`
# (background) splits too, as in the scanner; the redirect forms `>&`, `<&`
# and `&>` are parked on control bytes first so `2>&1` stays one segment.
#
# Here-doc bodies are dropped first, because this split is mostly reached through
# an apostrophe in a body (`it's`), and the body's lines would then classify as
# commands. Fail-closed: a body ends at the first line whose trimmed text is the
# delimiter, which is never after bash's terminator, so only lines bash reads as
# data are dropped. Every doubt aborts the strip and splits the original string:
# an unquoted-word miss (`<<\EOF`, `<<E"O"F`), an all-digit word (`$((1<<2))`), a
# continued operator line, a newline inside quotes while a body waits, an open
# body or quote at the end. `#` at a word start skips its line. Known blind spots,
# each needing a crafted later line and a balanced end state to hide a runner:
# ANSI-C `$'…\'…'` quotes and quotes nested in `$(…)` or in a backtick substitution
# spanning lines mislead the quote scan; a word-start `#` inside `${…}` (`${x/ #/}`)
# reads as a comment bash does not have; arithmetic `<<` with an identifier operand
# (`$((1<<n))`, `(( a << b ))`) reads as a here-doc operator.
# ---------------------------------------------------------------------------
_gate_split_legacy() {
  local _norm="$1" _seg
  case "$_norm" in
    *'<<'*)
      # Byte indexing, as in gate_head_tokens: every character acted on is ASCII.
      # Linear in the input: every read is a window of at most _win bytes at offset _i,
      # never the rest of the string, and text outside bodies is copied to _out in
      # slices (at each body start and at the end) rather than chunk by chunk. A
      # chunk cut at a window edge resumes in the same state on the next pass.
      local _lc_had=0 _lc_old="" _s="$1" _n _i=0 _ch _w _j _qc _q="" _out="" _from=0 _pend="" \
        _hd="" _ok=1 _prev=$'\n' _ln _win=1024
      local _re_plain=$'^[^\\\'"#<\n]+' _re_sq="^[^']+" _re_dq='^[^"\]+' _re_word='^[A-Za-z0-9_]+'
      [ -n "${LC_ALL+x}" ] && { _lc_had=1; _lc_old="$LC_ALL"; }
      LC_ALL=C
      _n=${#_s}
      while [ "$_i" -lt "$_n" ]; do
        if [ -n "$_hd" ]; then
          # The whole body in one pass: the rest is copied once per body, not once per
          # line, and read line by line to the terminator. Body lines are dropped, not
          # blanked: the split below skips empty lines, so the segments are the same.
          # Only a line holding the delimiter can trim to it, so most lines skip _trim.
          while IFS= read -r _ln; do
            _i=$((_i + ${#_ln} + 1))
            case "$_ln" in
              *"$_hd"*)
                _trim "$_ln"
                [ "$TRIMMED" != "$_hd" ] || { _hd=""; break; }
                ;;
            esac
          done <<< "${_s:$_i}"
          # The here-string adds a newline the input may not end with.
          [ "$_i" -le "$_n" ] || _i=$_n
          [ -z "$_hd" ] || _i=$_n
          _from=$_i
          continue
        fi
        if [ -n "$_q" ]; then
          if [ "$_q" = "'" ]; then
            if [[ ${_s:$_i:$_win} =~ $_re_sq ]]; then _w="${BASH_REMATCH[0]}"; else _w="'"; _q=""; fi
          elif [[ ${_s:$_i:$_win} =~ $_re_dq ]]; then
            _w="${BASH_REMATCH[0]}"
          elif [ "${_s:$_i:1}" = '"' ]; then
            _w='"'; _q=""
          else
            _w="${_s:$_i:2}"
          fi
          if [ -n "$_pend" ]; then
            case "$_w" in *$'\n'*) _ok=0; break ;; esac
          fi
          _i=$((_i + ${#_w})); _prev=x
          continue
        fi
        if [[ ${_s:$_i:$_win} =~ $_re_plain ]]; then
          _w="${BASH_REMATCH[0]}"; _i=$((_i + ${#_w})); _prev="${_w: -1}"
          continue
        fi
        _ch="${_s:$_i:1}"
        case "$_ch" in
          \\)
            _w="${_s:$_i:2}"
            if [ "$_w" = $'\\\n' ] && [ -n "$_pend" ]; then _ok=0; break; fi
            _i=$((_i + ${#_w})); _prev=x
            ;;
          \'|\") _q="$_ch"; _i=$((_i + 1)); _prev=x ;;
          '#')
            case "$_prev" in
              $'\n'|' '|$'\t'|';'|'|'|'&'|'(')
                # Skip to the end of the line; the newline arm then takes the newline.
                while [ "$_i" -lt "$_n" ]; do
                  _w="${_s:$_i:$_win}"
                  case "$_w" in *$'\n'*) _w="${_w%%$'\n'*}"; _i=$((_i + ${#_w})); break ;; esac
                  _i=$((_i + ${#_w}))
                done
                ;;
              *) _i=$((_i + 1)); _prev=x ;;
            esac
            ;;
          '<')
            if [ "${_s:$_i:3}" = '<<<' ]; then
              _i=$((_i + 3)); _prev=x
            elif [ "${_s:$_i:2}" = '<<' ]; then
              _j=$((_i + 2))
              [ "${_s:$_j:1}" != '-' ] || _j=$((_j + 1))
              while :; do
                case "${_s:$_j:1}" in ' '|$'\t') _j=$((_j + 1)) ;; *) break ;; esac
              done
              _qc=""
              case "${_s:$_j:1}" in \'|\") _qc="${_s:$_j:1}"; _j=$((_j + 1)) ;; esac
              if [[ ${_s:$_j:$_win} =~ $_re_word ]]; then _w="${BASH_REMATCH[0]}"; else _ok=0; break; fi
              case "$_w" in *[!0-9]*) ;; *) _ok=0; break ;; esac
              _j=$((_j + ${#_w}))
              if [ -n "$_qc" ]; then
                [ "${_s:$_j:1}" = "$_qc" ] || { _ok=0; break; }
                _j=$((_j + 1))
              fi
              case "${_s:$_j:1}" in
                '' | ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '<' | '>' | ')') ;;
                *) _ok=0; break ;;
              esac
              # The last operator on a line names the delimiter tracked.
              _pend="$_w"
              _i=$_j; _prev=x
            else
              _i=$((_i + 1)); _prev=x
            fi
            ;;
          *)
            _i=$((_i + 1)); _prev=$'\n'
            if [ -n "$_pend" ]; then
              _hd="$_pend"; _pend=""
              _out="$_out${_s:$_from:$((_i - _from))}"
            fi
            ;;
        esac
      done
      [ -z "$_hd$_pend$_q" ] || _ok=0
      if [ "$_lc_had" -eq 1 ]; then LC_ALL="$_lc_old"; else unset LC_ALL; fi
      [ "$_ok" -eq 0 ] || _norm="$_out${_s:$_from}"
      ;;
  esac
  _norm="${_norm//&&/$'\n'}"
  _norm="${_norm//||/$'\n'}"
  _norm="${_norm//;/$'\n'}"
  _norm="${_norm//|/$'\n'}"
  _norm="${_norm//>&/$'\001'}"
  _norm="${_norm//<&/$'\002'}"
  _norm="${_norm//&>/$'\003'}"
  _norm="${_norm//&/$'\n'}"
  _norm="${_norm//$'\001'/>&}"
  _norm="${_norm//$'\002'/<&}"
  _norm="${_norm//$'\003'/&>}"
  GATE_SEGS=()
  while IFS= read -r _seg; do
    [ -n "$_seg" ] || continue
    GATE_SEGS[${#GATE_SEGS[@]}]="$_seg"
  done <<EOF
$_norm
EOF
  return 0
}

# ---------------------------------------------------------------------------
# _gate_split_segments <command> -> fills GATE_SEGS with the command split on
# UNQUOTED, UNESCAPED separators only: && || ; | & and newline. A separator
# inside '...' or "..." or after a backslash belongs to the surrounding word,
# so `grep "a|swift test|b" f` is one segment, not three.
#
# Returns 1 on an unterminated quote and leaves GATE_SEGS empty; the caller MUST
# then fall back to _gate_split_legacy, because a half-parsed command may hide
# a runner behind a quote that never closes. Not parsed, deliberately: command
# substitution, backticks, here-docs (see the bypass note above RUNNERS).
#
# Backslash-newline is NOT swallowed as a continuation: the backslash is kept
# and the newline still splits, exactly as the legacy split did, so a
# continued runner line keeps classifying the way it always has.
# ---------------------------------------------------------------------------
# One run of characters that cannot change parser state, per quote context.
# A backslash is literal inside a bracket expression.
_GATE_SPLIT_PLAIN_RE=$'^[^\\\'";|&\n]+'
_GATE_SPLIT_SQ_RE="^[^']+"
_GATE_SPLIT_DQ_RE='^[^"\]+'
_gate_split_segments() {
  local _s="$1" _n=${#1} _i=0 _ch _nx _q="" _seg="" _redir
  GATE_SEGS=()
  while [ "$_i" -lt "$_n" ]; do
    if [ "$_q" = "'" ]; then
      if [[ ${_s:$_i} =~ $_GATE_SPLIT_SQ_RE ]]; then
        _seg="$_seg${BASH_REMATCH[0]}"
        _i=$((_i + ${#BASH_REMATCH[0]}))
      else
        _seg="$_seg'"; _q=""; _i=$((_i + 1))
      fi
      continue
    fi
    if [ "$_q" = '"' ]; then
      if [[ ${_s:$_i} =~ $_GATE_SPLIT_DQ_RE ]]; then
        _seg="$_seg${BASH_REMATCH[0]}"
        _i=$((_i + ${#BASH_REMATCH[0]}))
      elif [ "${_s:$_i:1}" = '"' ]; then
        _seg="$_seg\""; _q=""; _i=$((_i + 1))
      else
        # A backslash escapes the next character in double quotes, so `\"`
        # does not close the string.
        _seg="$_seg${_s:$_i:2}"; _i=$((_i + 2))
      fi
      continue
    fi
    if [[ ${_s:$_i} =~ $_GATE_SPLIT_PLAIN_RE ]]; then
      _seg="$_seg${BASH_REMATCH[0]}"
      _i=$((_i + ${#BASH_REMATCH[0]}))
      continue
    fi
    _ch="${_s:$_i:1}"
    _nx="${_s:$((_i + 1)):1}"
    _i=$((_i + 1))
    case "$_ch" in
      \\)
        if [ -z "$_nx" ] || [ "$_nx" = $'\n' ]; then
          _seg="$_seg$_ch"
        else
          _seg="$_seg$_ch$_nx"; _i=$((_i + 1))
        fi
        ;;
      \'|\") _q="$_ch"; _seg="$_seg$_ch" ;;
      '&')
        # `>&`, `<&` and `&>` are redirections, but `&&` still separates even
        # after a redirect byte — the legacy split's pass order.
        _redir=0
        if [ "$_nx" != '&' ]; then
          [ "$_nx" = '>' ] && _redir=1
          case "$_seg" in *'>'|*'<') _redir=1 ;; esac
        fi
        if [ "$_redir" -eq 1 ]; then
          _seg="$_seg$_ch"
        else
          [ -z "$_seg" ] || GATE_SEGS[${#GATE_SEGS[@]}]="$_seg"
          _seg=""
          [ "$_nx" = '&' ] && _i=$((_i + 1))
        fi
        ;;
      *)
        # ; | newline
        [ -z "$_seg" ] || GATE_SEGS[${#GATE_SEGS[@]}]="$_seg"
        _seg=""
        ;;
    esac
  done
  if [ -n "$_q" ]; then
    GATE_SEGS=()
    return 1
  fi
  [ -z "$_seg" ] || GATE_SEGS[${#GATE_SEGS[@]}]="$_seg"
  return 0
}

# ---------------------------------------------------------------------------
# classify_cmd <command string> -> echoes: full_test_run | scoped_test_run |
#                                          build_only | not_test
# Pure function of the command string. No I/O.
# ---------------------------------------------------------------------------
classify_cmd() {
  _classify_cmd_at "$1" 0
}

# _classify_cmd_at <command> <depth>: split, classify each segment at <depth>,
# keep the strongest verdict. Also the entry for the inner string of `bash -c`,
# itself a whole command line: a runner after a separator inside it must still
# surface now that the outer split no longer cuts through the quotes around it.
_classify_cmd_at() {
  local _cmd="$1" _depth="$2" _old_ifs _result _seg _class

  _old_ifs="$IFS"
  _result="not_test"
  # Command substitution, backticks, and here-docs are NOT split — a documented,
  # accepted hole (see the bypass note above RUNNERS).
  _gate_split_segments "$_cmd" || _gate_split_legacy "$_cmd"
  # The list is expanded once, before the loop, so the recursion below
  # overwriting GATE_SEGS cannot disturb this iteration.
  for _seg in ${GATE_SEGS[@]+"${GATE_SEGS[@]}"}; do
    _class=$(classify_segment "$_seg" "$_depth")
    case "$_class" in
      full_test_run) _result="full_test_run" ;;
      scoped_test_run) [ "$_result" = "not_test" ] || [ "$_result" = "build_only" ] && _result="scoped_test_run" ;;
      build_only) [ "$_result" = "not_test" ] && _result="build_only" ;;
    esac
    [ "$_result" = "full_test_run" ] && break
  done
  IFS="$_old_ifs"
  printf '%s' "$_result"
}

# classify_segment <segment> [<depth>]: strip leading VAR=value / env
# wrappers, a launcher/no-op prefix, recurse into `bash -c '...'` up to
# MAX_RECURSE_DEPTH levels, then match the head token against RUNNERS.
# depth is capped, not "depth 1 only" as an earlier version of this comment
# claimed — `bash -c 'bash -c "pytest"'` genuinely chases two levels; without
# a hard cap, recursion is bounded only by the ~10k-character command-length
# limit CC itself enforces (CWE-674), which is thousands of `sed` forks and
# real latency on a single tool call, not a crash, but not "depth 1" either.
MAX_RECURSE_DEPTH=2
classify_segment() {
  local _seg _depth _head_full _head _rest _inner _mod _padded _subcmd _rest_for_selection _rest_effective _second

  _seg="$1"
  _depth="${2:-0}"
  if [ "$_depth" -ge "$MAX_RECURSE_DEPTH" ]; then
    printf 'not_test'; return
  fi

  # trim leading/trailing whitespace
  _trim "$_seg"; _seg="$TRIMMED"
  [ -n "$_seg" ] || { printf 'not_test'; return; }

  _seg="$(strip_assignments "$_seg")"
  [ -n "$_seg" ] || { printf 'not_test'; return; }

  # `npx jest` must classify on `jest`, `timeout 60 pytest` on `pytest`.
  _gate_strip_wrappers "$_seg"; _seg="$STRIPPED"
  [ -n "$_seg" ] || { printf 'not_test'; return; }

  _head_full="${_seg%% *}"
  _head="${_head_full##*/}"
  _rest="${_seg#"$_head_full"}"

  # bash -c '...' / sh -c '...' (and the -lc/-ec/-xc combined-short-option
  # spellings, e.g. `bash -lc '...'`) wraps a real command in a string;
  # recurse into it up to MAX_RECURSE_DEPTH.
  case " $GATE_SHELLS " in
    *" $_head "*)
      case "$_rest" in
        *" -c "*|*" -lc "*|*" -ec "*|*" -xc "*)
          _inner="${_rest#*c }"
          _inner="${_inner#\'}"
          _inner="${_inner%\'}"
          _inner="${_inner#\"}"
          _inner="${_inner%\"}"
          _classify_cmd_at "$_inner" "$((_depth + 1))"
          return
          ;;
      esac
      ;;
  esac

  # python[3] -m <module> collapses to "python -m <module>". A bare
  # `python3 script.py` (no `-m pytest`/`-m unittest`) is not a recognized
  # test invocation at all — it is script execution, not test execution —
  # so it classifies `not_test` rather than being treated as a runner merely
  # because the interpreter's name happens to be in RUNNERS. Without this,
  # every `python3 <anything>.py` at a banned stage would falsely deny.
  if [ "$_head" = "python3" ] || [ "$_head" = "python" ]; then
    case "$_rest" in
      *" -m "*)
        _mod="${_rest#*-m }"
        _mod="${_mod%% *}"
        case "$_mod" in
          pytest|unittest) _head="python -m $_mod"; _rest="${_rest#*"$_mod"}" ;;
          *) printf 'not_test'; return ;;
        esac
        ;;
      *) printf 'not_test'; return ;;
    esac
  fi

  # run-tests.sh DOES have a selection surface: --changed drives the change→test
  # matrix (tests/selection/matrix.tsv), so arguments decide the class. Bare stays
  # full_test_run. Padded-segment matching, anchored on _head_full, mirrors the
  # build-test arm below — an unanchored match would fire on `cat run-tests.sh`.
  # The >50% widening cap is NOT enforced here: only run-tests.sh knows the
  # selection size, and this hook must stay a cheap PreToolUse classifier.
  _padded=" $_seg "
  case "$_head_full" in
    */run-tests.sh|run-tests.sh)
      case "$_padded" in
        *' --print-selection '*) printf 'build_only'; return ;;
        *' --changed '*|*' --base '*|*' --only '*) printf 'scoped_test_run'; return ;;
        *) printf 'full_test_run'; return ;;
      esac
      ;;
  esac
  case "$_seg" in
    make\ test|make\ coverage|make\ test-ios) printf 'full_test_run'; return ;;
    make\ test\ *|make\ coverage\ *|make\ test-ios\ *) printf 'full_test_run'; return ;;
    *unittest\ discover*) printf 'full_test_run'; return ;;
  esac

  # /<plugin>:build-test in command-string form (Bash rarely spells it this
  # way — the Skill branch in run_gate is the primary path). Anchored to
  # _head_full like every other runner: an unanchored substring match against
  # the whole segment would also fire on `cat docs/build-test.md` or
  # `git log --grep=build-test` — neither executes anything, both must stay
  # allowed since build-only verification is permitted everywhere.
  case "$_head_full" in
    build-test|*/build-test|*:build-test)
      case "$_padded" in
        *' --no-test '*|*' --count '*|*' --dry-run '*|*' --collect-only '*|*' --list-tests '*|*' --list '*)
          printf 'build_only'; return ;;
        *)
          printf 'full_test_run'; return ;;
      esac
      ;;
  esac

  case " $RUNNERS " in
    *" $_head "*) : ;;
    *)
      case "$_head" in
        python\ -m\ *) : ;;
        *) printf 'not_test'; return ;;
      esac
      ;;
  esac

  # Multi-purpose runners also have build-only shapes (`swift build`,
  # `./gradlew assembleDebug`), so a bare head match would falsely deny them at
  # a banned stage and break the build-only-everywhere promise. Require the
  # "test" subcommand — for gradle, any task NAME containing "test".
  #
  # _rest_effective drops the consumed subcommand token so the selector check
  # below judges only what follows; otherwise "test" itself reads as a
  # positional selector and `swift test` misclassifies as scoped.
  _rest_effective="$_rest"
  case " $MULTI_PURPOSE_RUNNERS " in
    *" $_head "*)
      case "$_head" in
        gradle|gradlew)
          _gradle_subcmd "$_rest" || { printf 'not_test'; return; }
          ;;
        xcodebuild)
          _xcodebuild_subcmd "$_rest" || { printf 'not_test'; return; }
          ;;
        node)
          _node_subcmd "$_rest" || { printf 'not_test'; return; }
          ;;
        make)
          _make_subcmd "$_rest" || { printf 'not_test'; return; }
          ;;
        *)
          _trim "$_rest"; _subcmd="${TRIMMED%% *}"
          case "$_subcmd" in
            test) _rest_effective="$(printf '%s' "$_rest" | sed -E 's/^[[:space:]]*test//')" ;;
            # `npm run test` / `pnpm run test` / `yarn run test` is the other
            # common package.json-script invocation shape for the same
            # thing `npm test` says directly — accept "run test" as an
            # equivalent subcommand pair for these three heads only.
            run)
              case "$_head" in
                npm|pnpm|yarn)
                  _second="$(printf '%s' "$_rest" | sed -E 's/^[[:space:]]*run[[:space:]]+//')"
                  _second="${_second%% *}"
                  case "$_second" in
                    test) _rest_effective="$(printf '%s' "$_rest" | sed -E 's/^[[:space:]]*run[[:space:]]+test//')" ;;
                    *) printf 'not_test'; return ;;
                  esac
                  ;;
                *) printf 'not_test'; return ;;
              esac
              ;;
            *) printf 'not_test'; return ;;
          esac
          ;;
      esac
      ;;
  esac

  # Build-only / collection-only flags override execution classification.
  # Token-exact (padded) matches only — a substring match would let `--list`
  # fire on `--listener` and misclassify a real invocation as build-only.
  #
  # Bare `-c` is build-only ONLY for bats (its count flag); elsewhere it is a
  # configuration flag (`swift test -c release` executes tests), and treating it
  # as build-only would let one flag bypass the DV full-suite deny below.
  case "$_padded" in
    *' --no-test '*|*' --dry-run '*|*' --collect-only '*|*' --list-tests '*|*' --list '*|*' --no-run '*|*' -N '*|*' --show-only '*|*' --listTests '*|*' --co '*)
      printf 'build_only'; return ;;
  esac
  if [ "$_head" = "bats" ]; then
    case "$_padded" in
      *' -c '*|*' --count '*) printf 'build_only'; return ;;
    esac
  fi
  # `go test -c` COMPILES a test binary and runs nothing, so it is build-only
  # work — permitted at every stage, unconditionally. Go's `-c` is VALUELESS,
  # unlike the `-c <value>` of swift/pytest/jest/vitest/gradle/dotnet, so
  # without this carve-out the shared value-consuming strip eats the following
  # token (or runs off the end of the line), empties the argument list and
  # classifies a compile as a full suite.
  if [ "$_head" = "go" ]; then
    case "$_padded" in
      *' -c '*) printf 'build_only'; return ;;
    esac
  fi

  # Selection-argument predicate, shared with agents/developer.md D2 and
  # agents/qa-engineer.md Q1's own scoped/full test-run counters: a command
  # carrying >=1 test-selection flag (or, below, a trailing positional
  # test-target argument) classifies scoped_test_run, otherwise full_test_run.
  case "$_seg" in
    *" -f "*|*"--filter"*|*" -k "*|*"-only-testing:"*|*" -run "*|*"--testcase"*|*"::"*|*"-gtest_filter"*|*" -R "*|*" -g "*|*" -t "*|*"--tests "*)
      printf 'scoped_test_run'; return ;;
  esac
  # A trailing positional path also counts as a selection (`bats tests/foo.bats`);
  # without it DV's own bare `bats <file>` would read as full and deny DV its own
  # run. A whole-tree argument (`pytest tests/`) therefore reads as scoped — a
  # deliberate policy limit, not a gap specific to this hook.
  #
  # Configuration flags are stripped first, or `swift test -c release` reads as
  # scoped and slips past the DV full-suite deny. Same for the per-runner table:
  # xcodebuild/gradle/dotnet require non-selecting flags to run at all, so every
  # executable invocation would otherwise carry an argument and read as scoped.
  _rest_for_selection="$(strip_nonselecting_flags "$_head" "$_rest_effective")"
  _trim "$_rest_for_selection"
  if [ -n "$TRIMMED" ]; then
    printf 'scoped_test_run'; return
  fi
  printf 'full_test_run'
}

# ---------------------------------------------------------------------------
# Stage resolution is corpflow_active_stage from the shared hook library: it
# echoes the single in_progress stage code, or empty for every ambiguity — no
# state.json, no jq, an unparseable file, zero or more than one stage in
# progress, or an unrecognized token. An empty result is this hook's signal to
# allow unconditionally: there is no reliable "who is acting" answer, and
# guessing wrong in the deny direction would deadlock an unrelated session.
#
# CTX resolution goes through the shared corpflow_context_root ladder: it is
# the anti-evasion invariant against cwd/CLAUDE_PROJECT_DIR guesses, so this
# consumer must not narrow back to CLAUDE_PROJECT_DIR-only. Degraded (library
# untrustworthy), it falls back to declared roots only.
# ---------------------------------------------------------------------------

# emit_deny <reason> — the PreToolUse deny document, written once. rc 1 when jq
# could not build it, which every caller must treat as "say nothing and allow":
# a hook that prints a half-formed document is worse than a hook that abstains.
emit_deny() {
  local _doc
  _doc=$(jq -cn --arg reason "$1" '
    {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}
  ') || return 1
  printf '%s\n' "$_doc"
  return 0
}

# _ledger_read <ctx> <fallback> -> 0 with _LEDGER_FILE set when the session
# ledger is readable AND jq is present; otherwise prints <fallback> and returns 1.
#
# The fallback stays each caller's argument: "cannot tell" is the empty string for
# the two authority reads (which must fail open) and the literal `unknown` for the
# mode read (which is denial text). Unifying them would change what a caller says
# when the ledger is unreadable.
_ledger_read() {
  _LEDGER_FILE="$1/state.json"
  [ -f "$_LEDGER_FILE" ] && command -v jq > /dev/null 2>&1 && return 0
  printf '%s' "$2"
  return 1
}

# ---------------------------------------------------------------------------
# ledger_settled <ctx> -> "settled" when the ledger positively says NOBODY is
# acting: state.json parses, .tasks is a non-empty object, zero in_progress.
# Empty for every other shape.
#
# Split from corpflow_active_stage's single empty answer: "cannot tell" (no state.json,
# no jq, unparseable, >1 in_progress) must fail open, while "nobody is acting"
# is not an ambiguity — no stage holds test authority then. Reads the SESSION's
# ledger under CLAUDE_PROJECT_DIR, so cd'ing elsewhere does not evade it.
# ---------------------------------------------------------------------------
ledger_settled() {
  local _ctx="$1" _state _counts _n_stages _n_active
  _ledger_read "$_ctx" '' || return
  _state="$_LEDGER_FILE"

  # Both counts in ONE jq: they read the same file for the same decision, and a
  # second invocation costs more than the comparison it feeds.
  _counts=$(jq -r '
    if (.tasks|type=="object")
    then "\(.tasks|length) \(.tasks | to_entries | map(select(.value.status=="in_progress")) | length)"
    else "0 0" end
  ' "$_state" 2>/dev/null) || { printf ''; return; }
  _n_stages="${_counts%% *}"
  _n_active="${_counts##* }"

  case "$_n_stages" in ''|*[!0-9]*) printf ''; return ;; esac
  case "$_n_active" in ''|*[!0-9]*) printf ''; return ;; esac
  [ "$_n_stages" -gt 0 ] && [ "$_n_active" -eq 0 ] && printf 'settled'
  return 0
}

# ---------------------------------------------------------------------------
# ledger_remediation_stage <ctx> -> the stage code of the one settled stage
# carrying an unresolved `no-go` verdict, or empty.
#
# Authority reserved to an in_progress stage leaves NOBODY holding it between a
# verification stage's two passes: the pipeline can fix a QA blocker but not
# verify the fix, and the only working remedy was to misreport the ledger. A
# recorded `no-go` IS that stage's open blocker, so its authority persists until
# the verdict flips. Deliberately not a dedicated ledger field: a field for this
# is one any agent could set to grant itself authority, whereas a `no-go` costs
# the stage its own passing verdict.
#
# Ambiguity resolves to empty and the settled deny stands. This arm widens what
# the gate permits, so unlike the fail-open classification path its unresolvable
# direction is the closed one.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# resolved_test_mode <ctx> -> the run's metadata.test_mode, or "unset (resolves
# to scoped)" when absent, or "unknown" when the ledger cannot be read.
#
# Read for the DENIAL TEXT ONLY — never for the decision. Stage authority and
# test_mode are two independent mechanisms that can each refuse the same command,
# and a denial naming only one left the caller unable to tell which had fired.
# ---------------------------------------------------------------------------
resolved_test_mode() {
  local _ctx="$1" _state _mode
  _ledger_read "$_ctx" 'unknown' || return
  _state="$_LEDGER_FILE"
  _mode=$(jq -r '.metadata.test_mode // ""' "$_state" 2>/dev/null) || { printf 'unknown'; return; }
  case "$_mode" in
    full|scoped|build-only) printf '%s' "$_mode" ;;
    "") printf 'unset (resolves to scoped)' ;;
    *) printf 'unknown' ;;
  esac
}

# ---------------------------------------------------------------------------
# controls_in_force <ctx> <stage> <arm> -> the controls OTHER than <arm> that
# would still refuse this command, as one trailing sentence. Empty when there is
# nothing left to name.
#
# Denial text only, never a decision input — the same contract resolved_test_mode
# carries. Three mechanisms can each refuse one command, and a denial naming only
# the one that fired sends the caller to build an incomplete remedy: in a single
# run four stages escalated that way, each proposing a fix the arm nobody named
# would have refused again. The gate knows all three of its own arms; the agent
# knows none of them.
# ---------------------------------------------------------------------------
controls_in_force() {
  local _ctx="$1" _stage="$2" _arm="$3" _parts=""

  # No holder exists on the settled arm, and the authority arm IS the holder
  # check, so naming it there would restate the clause it follows.
  case "$_arm" in
    authority | settled) : ;;
    *) _parts="test-execution authority (held by stage '$_stage')" ;;
  esac

  if [ "$_arm" != "dedupe" ]; then
    if [ "${CORPFLOW_TEST_DEDUPE:-}" = "off" ]; then
      _parts="${_parts:+$_parts; }redundant-run suppression (off for this session)"
    else
      _parts="${_parts:+$_parts; }redundant-run suppression (on)"
    fi
  fi

  # The authority clause already quotes the mode inline; never say it twice.
  if [ "$_arm" != "authority" ]; then
    _parts="${_parts:+$_parts; }resolved test mode '$(resolved_test_mode "$_ctx")'"
  fi

  [ -n "$_parts" ] || return 0
  printf ' Still in force, and NOT cleared by satisfying the above: %s. Each is a separate mechanism.' \
    "$_parts"
}

ledger_remediation_stage() {
  local _ctx="$1" _state _codes
  _ledger_read "$_ctx" '' || return
  _state="$_LEDGER_FILE"
  _codes=$(jq -r '
    if (.tasks|type=="object")
    then [ .tasks | to_entries[]
           | select(.value.verdict == "no-go")
           | (.key | sub("[0-9]+$"; "")) ] | unique | .[]
    else empty end
  ' "$_state" 2>/dev/null) || { printf ''; return; }
  case "$_codes" in
    [A-Z][A-Z]) printf '%s' "$_codes" ;;
    *) printf '' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Redundant-run suppression. Keyed on the TREE, never on an outcome: PreToolUse
# fires before the command, so a pass is unknowable here. Any edit changes the
# fingerprint and re-enables the run — protect that property in any change here.
#
# Keeps its OWN sentinels; never reads the full_test_run / scoped_test_run audit
# rows, which agent-coordination binds as audit-only. Fail-open throughout: an
# empty answer anywhere means "cannot tell", and the caller allows.
# ---------------------------------------------------------------------------

# tree_fingerprint, run_index_of, dedupe_key, dedupe_pending_key, dedupe_lookup,
# dedupe_invocation and the marker lifecycle live in hooks/lib/dedupe-lib.sh,
# sourced above and shared verbatim with the PostToolUse companion. See that
# file for why.

# dedupe_decide <ctx> <stage> <class> <invocation> <cmd_head> <tool> <root>
# Echoes a deny for a run already RECORDED against this tree; otherwise marks
# this one pending and echoes nothing. Always returns 0 — the decision travels
# in stdout, and every unresolvable input allows.
#
# Marking pending rather than recording is the correction: PreToolUse fires
# before any result exists, so a run that aborted having executed nothing used to
# claim its fingerprint permanently. hooks/test-execution-promote.sh promotes the
# marker only once the tool actually produced a result.
dedupe_decide() {
  local _ctx="$1" _stage="$2" _class="$3" _inv="$4" _head="$5" _tool="$6" _root="${7:-.}"
  local _fp _n _key _pkey _prior _sentinel _reason _p_rest _p_stage _p_ts _p_ev

  # Suppression library absent, stubbed or truncated: enforce authority, skip
  # suppression. Same fail-open direction as an unresolvable fingerprint.
  command -v dedupe_key > /dev/null 2>&1 || return 0

  # Same shape as the CORPFLOW_TEST_GATE hatch above, and the same reason for
  # it: a control switching off must not be silent, but the note is written
  # once per .context/ so the common path never pays for it.
  if [ "${CORPFLOW_TEST_DEDUPE:-}" = "off" ]; then
    if [ -f "$_ctx/state.json" ]; then
      _sentinel="$_ctx/logs/.dedupe-off-noted"
      if [ ! -f "$_sentinel" ]; then
        mkdir -p "$_ctx/logs" 2>/dev/null && : > "$_sentinel" 2>/dev/null
        write_audit_row "$_ctx" "test_dedupe_disabled" '{"vector":"CORPFLOW_TEST_DEDUPE"}'
      fi
    fi
    return 0
  fi

  _fp=$(tree_fingerprint "$_root")
  [ -n "$_fp" ] || return 0          # no git, no repo, no shasum — cannot tell
  _n=$(run_index_of "$_ctx")
  [ -n "$_n" ] || return 0           # no resolvable run — nothing to key on
  _key=$(dedupe_key "$_class" "$_inv" "$_fp" "$_n")
  [ -n "$_key" ] || return 0

  _prior=$(dedupe_lookup "$_ctx" "$_key")
  if [ -z "$_prior" ]; then
    _pkey=$(dedupe_pending_key "$_class" "$_inv" "$_n")
    [ -n "$_pkey" ] || return 0
    dedupe_mark_pending "$_ctx" "$_pkey" "$_key" "$_stage"
    return 0
  fi

  # Explicit three-field split, never the `%% */#* ` pair the two-field sentinel
  # used: on three fields that pair silently hands back the wrong slices. A
  # marker written before the evidence token joined the grammar carries only two,
  # and `_p_ev` then equals the whole remainder — the same no-op guard
  # dedupe_promote uses — so a stale marker reports its evidence as unrecorded
  # instead of quoting a timestamp as a result.
  _p_stage="${_prior%% *}"
  _p_rest="${_prior#* }"
  _p_ts="${_p_rest%% *}"
  _p_ev="${_p_rest#* }"
  [ "$_p_ev" != "$_p_rest" ] || _p_ev="unrecorded"

  # A prior that executed NOTHING is not a result this run could reproduce, so
  # suppressing against it refuses the only run that could still produce one —
  # which is how a platform reached a merge decision with zero tests executed and
  # every stage downstream reading a verdict that said only "denied".
  #
  # Recognise evidence of EXECUTION, not merely of a record existing: `bundle:`
  # and `errtext:` each mean a runner produced a result or printed its failures,
  # and a non-zero `tests:` is a count off its own summary line. Everything else —
  # `tests:0`, the `discovered:` token promote writes for a bare enumeration,
  # the legacy `unrecorded` marker, and any shape this grammar does not cover —
  # is no result at all. Unparseable takes the same arm as zero deliberately: a
  # token nobody can read cannot be cited either.
  #
  # `output:` is NOT on the list. It is minted for any non-empty response with no
  # parseable count, so `error: no such module Foo` earns `output:38B` — a run
  # that executed nothing, which then denies every retry that could still execute
  # something. A byte count is evidence that a tool SPOKE, never that a suite RAN,
  # and suppression must cite a result the denied run could only reproduce.
  case "$_p_ev" in
    bundle:?* | errtext:?* | tests:[1-9]*) : ;;
    *)
      write_audit_row "$_ctx" "test_dedupe_skipped_zero_prior" \
        "$(jq -cn --arg st "$_stage" --arg tool "$_tool" --arg head "$_head" \
            --arg class "$_class" --arg prior "$_prior" --arg ev "$_p_ev" --arg n "$_n" \
            '{stage:$st, tool:$tool, command_head:$head, classification:$class,
              prior_run:$prior, prior_evidence:$ev, run_index:$n}')"
      return 0
      ;;
  esac

  # Naming the prior run is what makes this actionable: the caller's next move is to CITE that
  # run, not to find a way around the gate. Naming its EVIDENCE is what makes the citation
  # checkable — a denial that cannot say what the run it protects produced is the symptom that
  # cost an hour of diagnosis. Remediation: references/test-execution-denials.md.
  _reason=$(deny_reason "This exact test invocation already ran during run_index $_n (stage: $_p_stage, at $_p_ts, evidence: $_p_ev) against a byte-identical tree, so it can only reproduce the result already on record (skills/shared/testing-strategy.md § Test-Execution Authority).$(controls_in_force "$_ctx" "$_stage" dedupe)" dedupe)
  emit_deny "$_reason" || return 0

  write_audit_row "$_ctx" "test_execution_deduped" \
    "$(jq -cn --arg st "$_stage" --arg tool "$_tool" --arg head "$_head" \
        --arg class "$_class" --arg prior "$_prior" --arg ev "$_p_ev" --arg n "$_n" \
        '{stage:$st, tool:$tool, command_head:$head, classification:$class,
          prior_run:$prior, prior_evidence:$ev, run_index:$n}')"
  return 0
}

# ---------------------------------------------------------------------------
# gate_head_tokens <command> -> sets HEAD_TOKENS to the head token of every
# unquoted segment, space-joined.
#
# Structure, not raw text. A substring scan of the whole command denied a file
# write whose PAYLOAD merely named runners: JSON and prose carrying `;` or `|`
# read exactly like a second command, and a here-doc body reads like a script.
# Nothing that only *mentions* a runner can reach head position here.
#
# Fork-free single pass, so the fast path stays in the same cost class as the
# glob match it replaces. Assignments, `env` and launcher wrappers do not end the
# search, mirroring classify_segment's own stripping; a token carrying a quoted
# space is folded to underscores rather than dropped, since no runner name has
# one and the join must stay word-splittable.
#
# Fail direction: an unparsed shape yields no gateable head and ALLOWS, matching
# every other unresolvable input in this hook.
# ---------------------------------------------------------------------------
# Characters the scanner treats specially; any other run is copied verbatim.
_GATE_WORD_RE="^[^[:space:]\\\\'\";|&<]+"
gate_head_tokens() {
  # Byte indexing: under a UTF-8 locale `${_s:i:1}` walks from the start each time.
  # Every character the scanner acts on is ASCII, so the tokens are unchanged.
  local _lc_had=0 _lc_old=""
  [ -n "${LC_ALL+x}" ] && { _lc_had=1; _lc_old="$LC_ALL"; }
  LC_ALL=C
  local _s="$1" _n=${#1} _i=0 _ch _q="" _cur="" _want=1 _hd="" _inhd=0 _line="" _pend="" _lnch=""
  HEAD_TOKENS=""
  GATE_TMO=""
  while [ "$_i" -lt "$_n" ]; do
    _ch="${_s:$_i:1}"
    _i=$((_i + 1))
    if [ "$_inhd" -eq 1 ]; then
      if [ "$_ch" = $'\n' ]; then
        _trim "$_line"
        [ "$TRIMMED" = "$_hd" ] && { _inhd=0; _hd=""; _want=1; _lnch=""; GATE_TMO=""; }
        _line=""
      else
        _line="$_line$_ch"
      fi
      continue
    fi
    if [ -n "$_q" ]; then
      if [ "$_ch" = "$_q" ]; then _q=""; else _cur="$_cur$_ch"; fi
      continue
    fi
    case "$_ch" in
      \\)
        [ "$_i" -lt "$_n" ] && { _cur="$_cur${_s:$_i:1}"; _i=$((_i + 1)); }
        ;;
      \'|\") _q="$_ch" ;;
      ' '|$'\t')
        _gate_emit_head
        ;;
      ';'|'|'|'&'|$'\n')
        _gate_emit_head
        _want=1
        _lnch=""
        GATE_TMO=""
        if [ "$_ch" = $'\n' ] && [ -n "$_pend" ]; then
          _hd="$_pend"; _pend=""; _inhd=1; _line=""
        fi
        ;;
      '<')
        # `<<[-][quote]DELIM` opens a here-doc whose body is data, never commands.
        if [ "${_s:$_i:1}" = '<' ]; then
          _i=$((_i + 1))
          [ "${_s:$_i:1}" = '-' ] && _i=$((_i + 1))
          case "${_s:$_i:1}" in \'|\") _i=$((_i + 1)) ;; esac
          _pend=""
          while [ "$_i" -lt "$_n" ]; do
            case "${_s:$_i:1}" in
              [A-Za-z0-9_]) _pend="$_pend${_s:$_i:1}"; _i=$((_i + 1)) ;;
              *) break ;;
            esac
          done
          case "${_s:$_i:1}" in \'|\") _i=$((_i + 1)) ;; esac
        fi
        _gate_emit_head
        ;;
      *)
        # Take the whole run of plain characters at once: one append per run,
        # not per character, keeps a 20k-character token linear.
        if [[ ${_s:$((_i - 1))} =~ $_GATE_WORD_RE ]]; then
          _cur="$_cur${BASH_REMATCH[0]}"
          _i=$((_i - 1 + ${#BASH_REMATCH[0]}))
        else
          _cur="$_cur$_ch"
        fi
        ;;
    esac
  done
  _gate_emit_head
  if [ "$_lc_had" -eq 1 ]; then LC_ALL="$_lc_old"; else unset LC_ALL; fi
  return 0
}

# _gate_emit_head — gate_head_tokens' accumulator flush. A separate function only
# because the scanner reaches it from five arms; it reads and writes the
# scanner's locals by dynamic scope (_cur, _want, _lnch).
#
# Skips exactly what _gate_strip_wrappers strips, from the same definitions:
# GATE_SCAN_SKIP words, the second word of a two-word GATE_LAUNCHERS phrase
# (`_lnch` remembers the first), timeout's options and duration, and a
# subshell's parentheses. test-execution-gate.bats asserts the two agree.
_gate_emit_head() {
  [ -n "$_cur" ] || return 0
  if [ "$_want" -eq 1 ]; then
    if [ -n "$GATE_TMO" ]; then
      _gate_timeout_step "$_cur"
      _cur=""
      return 0
    fi
    _gate_strip_parens "$_cur"; _cur="$PARENLESS"
    [ -n "$_cur" ] || return 0
    case " $GATE_LAUNCHERS " in
      *" ${_lnch}_${_cur} "*) _lnch="" ;;
      *)
        case " $GATE_TIMEOUT_WRAPPERS " in
          *" ${_cur##*/} "*) GATE_TMO=opt; _lnch="" ;;
          *)
            case " $GATE_SCAN_SKIP " in
              *" $_cur "*) _lnch="$_cur" ;;
              *)
                case "$_cur" in
                  [A-Za-z_]*=*) ;;
                  *) HEAD_TOKENS="$HEAD_TOKENS ${_cur// /_}"; _want=0; _lnch="" ;;
                esac
                ;;
            esac
            ;;
        esac
        ;;
    esac
  fi
  _cur=""
  return 0
}

# gate_head_is_gateable <token> -> 0 when this head could classify as test
# execution. Shell heads are members because classify_segment recurses into
# `bash -c '...'`; dropping them would silently retire that arm.
gate_head_is_gateable() {
  local _t="${1##*/}"
  case "$_t" in
    build-test|*:build-test|run-tests.sh|*:run-tests.sh) return 0 ;;
  esac
  case " $RUNNERS $GATE_SHELLS " in
    *" $_t "*) return 0 ;;
  esac
  return 1
}

# gate_classify_payload <payload> <tool> -> "<class><TAB><command_head>", or
# returns 1 when the payload is out of scope (the caller allows).
#
# One definition, called by run_gate and by the PostToolUse companion: the two
# hooks must derive the same class for the same payload or every pending marker
# is orphaned and suppression stops working, silently.
# ---------------------------------------------------------------------------
gate_classify_payload() {
  local _payload="$1" _tool="$2" _class _cmd _cmd_head _stripped _skill_cmd _tok _gateable

  case "$_tool" in
    mcp__*test*)
      # Classifying on tool *name* alone is deny-direction only: a
      # read-only tool like `mcp__*__list_tests` also matches and would be
      # denied at a banned stage even though it never executes anything.
      # Acceptable because the failure mode is "an extra deny", never a
      # missed one, and the alternative (parsing MCP tool semantics) isn't
      # worth the cost for what is already a narrow, rare tool surface.
      _class="scoped_test_run"
      _cmd_head="$_tool"
      ;;
    Bash)
      _cmd=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
      [ -n "$_cmd" ] || return 1
      # Prefilter (fast path): a command none of whose segment heads is a runner
      # cannot classify as test execution, so it never enters classify_cmd.
      gate_head_tokens "$_cmd"
      _gateable=0
      for _tok in $HEAD_TOKENS; do
        gate_head_is_gateable "$_tok" && { _gateable=1; break; }
      done
      [ "$_gateable" -eq 1 ] || return 1
      _class=$(classify_cmd "$_cmd")
      # command_head is telemetry, not classification input, and is derived from
      # the WHOLE command while classify_cmd works per segment — so a secret can
      # sit in an early segment while a later one classifies (`SECRET="a b";
      # pytest tests/`), which stripping VAR=value does not cover. Bounded
      # structurally instead: _cmd_head may only ever be a token already
      # recognized as a runner name; anything else is redacted.
      _trim "$_cmd"
      _stripped="$(strip_assignments "$TRIMMED")"
      _cmd_head="${_stripped%% *}"
      _cmd_head="${_cmd_head##*/}"
      _cmd_head="$(redact_unless_known_head "$_cmd_head")"
      ;;
    Skill)
      # The Skill payload carries its flags in a SEPARATE `args` field
      # ({skill, args}), not appended to the skill name — reading the name
      # alone loses `--no-test` and denies DR its sanctioned compile-check.
      # Recombined into one string so the build-only carve-out below matches
      # the same way it does for the command-string form.
      #
      # Recombined HERE rather than by calling dedupe_invocation: authority must
      # not depend on the suppression library, whose absence would otherwise make
      # this arm return 1 and allow a full-suite Skill at a banned stage. The
      # duplicated expression cannot orphan a marker — the key stays whatever
      # dedupe_invocation derives, and both hooks derive it from that one copy.
      _skill_cmd=$(printf '%s' "$_payload" | jq -r '
        [(.tool_input.command // .tool_input.skill // empty), (.tool_input.args // empty)]
        | map(if type == "array" then (map(tostring) | join(" ")) else tostring end)
        | map(select(length > 0)) | join(" ") | select(length > 0)
      ' 2>/dev/null)
      case "$_skill_cmd" in
        *build-test*--no-test*|*build-test*--count*|*build-test*--dry-run*) return 1 ;;
        *build-test*)
          # The Skill branch had NO scoped outcome: every build-test invocation that was
          # not a declared no-op read as a full run, so a DV stage holding scoped authority
          # could never invoke the platform build-test command at all. Padded and anchored
          # so a bare word inside a path cannot match.
          #
          # Deliberately WIDER than the Bash branch's run-tests.sh arm, which is not the
          # same subject: that arm classifies this repo's own suite, whose documented flags
          # are --changed and --base, while /<plugin>:build-test fans out to xcodebuild,
          # gradle and friends where --filter and -only-testing: are the scoping flags.
          # Narrowing this list to match would read a genuinely scoped platform run as a
          # full one and hand it authority it was not granted.
          case " $_skill_cmd " in
            *' --changed '*|*' --base '*|*' --only '*|*' --filter '*|*' -only-testing:'*|*' --tests '*)
              _class="scoped_test_run" ;;
            *) _class="full_test_run" ;;
          esac
          ;;
        *) return 1 ;;  # deterministic build-test rule only — never a prose scan
      esac
      # Same allow-list as the Bash branch (SR2-M1): the whole skill command can
      # carry a secret-bearing flag, so _cmd_head must be bounded to a known
      # token on every branch, not just one.
      _cmd_head="${_skill_cmd%% *}"
      _cmd_head="${_cmd_head##*/}"
      _cmd_head="$(redact_unless_known_head "$_cmd_head")"
      ;;
    *) return 1 ;;
  esac

  [ -n "${_class:-}" ] || return 1  # classification indeterminate — allow
  printf '%s\t%s' "$_class" "$_cmd_head"
  return 0
}

# gate_ctx <ctx dir or empty> [payload] -> the given dir, else the resolved context root;
# rc 1 when unresolved ("no worktask here"). Resolution forks git and the
# resolver, so run_gate asks only once a payload is known to need a ledger.
gate_ctx() {
  local _c="${1:-}"
  if [ -z "$_c" ]; then
    # The hook inherits the session's roots, never the per-issue Bash prefix, so
    # only the payload can name the issue whose ledger holds this call's authority.
    if command -v corpflow_bind_payload > /dev/null 2>&1; then
      corpflow_bind_payload "${2:-}"
    fi
    _c=$(corpflow_context_root)
    [ -n "$_c" ] || return 1
    # A degraded strip still enforces, so it is announced rather than blocked on.
    if [ "${CMDHEAD_FALLBACK:-0}" -eq 1 ] && [ -f "$_c/state.json" ]; then
      echo "test-execution-gate: $_CMDHEAD_LIB unusable — assignment strip degraded to the inline fallback" >&2
      mkdir -p "$_c/logs" 2>/dev/null && : > "$_c/logs/.corpflow-lib-missing" 2>/dev/null
    fi
  fi
  printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# run_gate <payload json> <ctx dir or empty> -> echoes decision JSON (deny) or nothing
# (allow/observe). Appends an audit row for a deny or an Agent observation.
# Parameterized over .context/ so every branch is fixture-reachable, per the
# dv-screenshot-gate.sh idiom (run_gate <payload> <ctx>).
# ---------------------------------------------------------------------------
run_gate() {
  local _payload="$1" _ctx="$2"
  local _tool _stage _settled _subagent _prompt _matched _class _cmd_head _ident
  local _reason _sentinel

  # Process-env hatch, checked first: cheapest check, and a control switching
  # off must not be silent. The [ -f ] sentinel notes it once per .context/ so
  # only the rare hatch path pays for an audit row. Gated on state.json existing
  # at all — otherwise a shell-profile-wide CORPFLOW_TEST_GATE=off would
  # materialize .context/logs/ in every unrelated directory the user opens.
  if [ "${CORPFLOW_TEST_GATE:-}" = "off" ]; then
    _ctx=$(gate_ctx "$_ctx" "$_payload") || return 0
    [ -f "$_ctx/state.json" ] || return 0
    _sentinel="$_ctx/logs/.gate-off-noted"
    if [ ! -f "$_sentinel" ]; then
      mkdir -p "$_ctx/logs" 2>/dev/null && : > "$_sentinel" 2>/dev/null
      write_audit_row "$_ctx" "test_gate_disabled" '{"vector":"CORPFLOW_TEST_GATE"}'
    fi
    return 0
  fi

  command -v jq >/dev/null 2>&1 || return 0

  _tool=$(printf '%s' "$_payload" | jq -r '.tool_name // empty' 2>/dev/null)
  [ -n "$_tool" ] || return 0  # unparseable payload or missing tool_name — allow

  case "$_tool" in
    Bash|Skill) ;;
    Agent)
      # OBSERVE-ONLY: a dispatch prompt quoting the ban names every runner, so
      # matching prose would refuse to dispatch the stages that implement the
      # policy.
      #
      # Resolve the stage BEFORE touching the filesystem. No resolvable stage
      # means no worktask is in flight — the common case in a repo where the
      # plugin is merely installed — and such a session must see zero side
      # effects: no directory creation, no log growth.
      _ctx=$(gate_ctx "$_ctx" "$_payload") || return 0
      _stage=$(corpflow_active_stage "$_ctx")
      if [ -n "$_stage" ]; then
        _subagent=$(printf '%s' "$_payload" | jq -r '.tool_input.subagent_type // "unknown"' 2>/dev/null)
        # Truncate to a short bounded length before it ever reaches the log —
        # this is untrusted payload data, and the audit row exists to record
        # a stable agent identifier, not to accept an arbitrarily long string.
        _subagent="${_subagent:0:64}"
        _prompt=$(printf '%s' "$_payload" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
        _matched=$(first_runner_token "$_prompt")
        if [ -n "$_matched" ]; then
          write_audit_row "$_ctx" "test_delegation_observed" \
            "$(jq -cn --arg st "$_subagent" --arg tok "$_matched" '{subagent_type:$st, matched_token:$tok}')"
        fi
      fi
      return 0
      ;;
    *)
      # Any tool this hook doesn't otherwise recognize is out of scope,
      # except an MCP tool whose own name says "test" — the tool *name* is
      # the classifier there (see the mcp__*test* case below), so widening
      # the matcher to include it costs no parsing at all.
      case "$_tool" in
        mcp__*test*) ;;
        *) return 0 ;;
      esac
      ;;
  esac

  # Class and command_head come from the shared classifier so the PostToolUse
  # companion cannot derive a different key for the same payload.
  _ident="$(gate_classify_payload "$_payload" "$_tool")" || return 0
  _class="${_ident%%$'\t'*}"
  _cmd_head="${_ident#*$'\t'}"
  case "$_class" in
    not_test|build_only) return 0 ;;
  esac
  _ctx=$(gate_ctx "$_ctx" "$_payload") || return 0

  # Stage resolution runs only once the command is known to be a test run.
  # Classification never reads the stage, and the overwhelming majority of tool
  # calls are not tests, so resolving first made every ordinary Bash call pay
  # jq to learn something it then discarded.
  #
  # A settled ledger is a deny, not an allow — see ledger_settled(). The sentinel
  # is not a stage code, so it can never match the DV/QA authority arms below; it
  # only selects its own deny reason.
  _stage=$(corpflow_active_stage "$_ctx")
  _settled=""
  if [ -z "$_stage" ]; then
    [ "$(ledger_settled "$_ctx")" = "settled" ] || return 0  # cannot tell — allow
    _stage=$(ledger_remediation_stage "$_ctx")
    if [ -z "$_stage" ]; then
      _settled=1
      _stage="(none in progress)"
    fi
  fi

  # DV is allowed scoped test execution but denied a full-suite run — this
  # is the one mechanical check that actually enforces DV's authority limit
  # (everything else here is about who is denied outright). QA is exempt
  # from this branch by design: it is the pipeline's sole full-suite gate.
  if [ "$_stage" = "DV" ] || [ "$_stage" = "QA" ]; then
    if [ "$_stage" = "DV" ] && [ "$_class" = "full_test_run" ]; then
      : # fall through to deny
    else
      # Authority said yes. The only remaining question is whether this exact
      # run already happened against this exact tree — asked here, on the allow
      # path alone, so suppression can never widen what the gate permits.
      #
      # Guarded again at the call site: the arguments are command substitutions
      # of library functions, which shells evaluate before dedupe_decide's own
      # guard can run, so a missing library would print `command not found` onto
      # the hook's stderr on every allowed run.
      if command -v dedupe_key > /dev/null 2>&1; then
        dedupe_decide "$_ctx" "$_stage" "$_class" \
          "$(dedupe_invocation "$_payload" "$_tool" "$_cmd_head")" \
          "$_cmd_head" "$_tool" "$(dedupe_root "$_payload")"
      fi
      return 0
    fi
  fi

  # Banned stage (or DV-full): DENY. Each reason is a condition clause naming what is true
  # right now, plus the remediation section for its class; the constraints on that wording live
  # with it in references/test-execution-denials.md.
  if [ -n "$_settled" ]; then
    _reason=$(deny_reason "No stage is in progress — this worktask is finished, or the loop is between stages, so nobody holds test-execution authority (skills/shared/testing-strategy.md § Test-Execution Authority).$(controls_in_force "$_ctx" "$_stage" settled)" settled)
  else
  _reason=$(deny_reason "Stage '$_stage' has no test-execution authority for a ${_class} (skills/shared/testing-strategy.md § Test-Execution Authority); the run's resolved test mode is '$(resolved_test_mode "$_ctx")', which is a SEPARATE mechanism — this refusal is the authority check, not the mode.$(controls_in_force "$_ctx" "$_stage" authority)" authority)
  fi
  emit_deny "$_reason" || return 0

  write_audit_row "$_ctx" "test_execution_blocked" \
    "$(jq -cn --arg st "$_stage" --arg tool "$_tool" --arg head "$_cmd_head" --arg class "$_class" \
      '{stage:$st, tool:$tool, command_head:$head, class:$class}')"
  return 0
}

# OBSERVE_TOKENS — the Agent-branch telemetry set, deliberately narrower than
# RUNNERS: "go", "make", "python", "python3", "swift" are common English
# words / adjectives and would make first_runner_token fire on ordinary
# delegation prose ("go ahead", "make the change", "a swift fix"). Excluding
# them keeps the observe row's `matched_token` meaningful telemetry rather
# than near-constant noise; scoped/deny classification (which does need
# those heads) is unaffected — this set is Agent-observation-only.
OBSERVE_TOKENS="bats pytest ctest cargo jest vitest playwright rspec gradle gradlew xcodebuild dotnet npm pnpm yarn npx uvx bunx"

# redact_unless_known_head <token> -> echoes the token unchanged if it is a
# member of RUNNERS/build-test/run-tests.sh/env, else echoes "redacted".
# command_head is telemetry, not classification input; the invariant this
# hook maintains is that it is ALWAYS one of those known tokens or the
# literal "redacted" — never an unbounded fragment of the original command —
# regardless of which tool branch (Bash or Skill) produced it. Shared so a
# future third branch can't reopen the same hole by skipping the allow-list.
redact_unless_known_head() {
  local _tok="$1"
  case " $RUNNERS build-test run-tests.sh env " in
    *" $_tok "*) printf '%s' "$_tok" ;;
    *) printf 'redacted' ;;
  esac
}

# first_runner_token <text> -> echoes the first OBSERVE_TOKENS token found in
# free text as its OWN word (word-boundary matched, not a bare substring
# scan — an unanchored scan would match "go" inside "algorithm" and fire on
# nearly every prompt). Used only for the Agent branch's observe-only
# telemetry, never for a deny decision.
first_runner_token() {
  local _text="$1" _tok
  for _tok in $OBSERVE_TOKENS; do
    if printf '%s' "$_text" | grep -Eq "(^|[^[:alnum:]_])${_tok}([^[:alnum:]_]|\$)" 2>/dev/null; then
      printf '%s' "$_tok"
      return
    fi
  done
  printf ''
}

# write_audit_row <ctx> <action> <metadata json> — binds this hook's actor onto
# the shared appender. The deny JSON is always printed BEFORE this is called, so
# a logging failure (unwritable dir, no `date`, disk full) can never swallow a
# legitimate deny. Never logs the full command — command_head only, since the
# full command can carry a secret token or a path that shouldn't land in a
# committed log file. Subject and task_id are both the in-progress ledger key, or
# the none/unknown sentinel when there is no single one.
write_audit_row() {
  local _tid
  _tid=$(corpflow_audit_task_id "${1:-}")
  corpflow_hook_audit_row --ctx "${1:-}" --actor hook:test-execution-gate \
    --action "${2:-}" --result ok --subject "$_tid" --task-id "$_tid" --meta "${3:-}"
}

# ---------------------------------------------------------------------------
# --lib-only: define everything, dispatch nothing. hooks/test-execution-promote.sh
# sources this file so the two hooks share ONE classifier and one key derivation
# rather than two that can drift apart. `return` outside a sourced file is an
# error, so the exit is the fallback for a direct invocation.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317 # `return` outside a function fails when executed directly, so the exit IS reached
case "${1:-}" in
  --lib-only) return 0 2>/dev/null || exit 0 ;;
esac

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------
# The body lives in lib/ — it is test code, and this file is a hot-path gate.
# Sourced only here, never on the dispatch path below, so no TEST code is loaded
# at hook time.
#
# This is no longer a claim that the dispatch path resolves NO sibling path: the
# shared hook library is sourced at the top of this file on every invocation.
# That is deliberate and guarded — see the AD-2 idiom there — and the property
# that still holds, and that matters, is narrower: the only sibling loaded on the
# dispatch path is the library, under a guard that survives an absent, stubbed or
# truncated file, and this test body is never among them.
#
# Unlike the dispatch path this arm fails CLOSED: a self-test that cannot find
# its cases must report a failure, never "OK".
if [ "$SELF_TEST" -eq 1 ]; then
  _selftest_body="$(dirname "$0")/lib/test-execution-gate-selftest.sh"
  if [ ! -f "$_selftest_body" ]; then
    echo "test-execution-gate: self-test body missing at $_selftest_body" >&2
    exit 1
  fi
  . "$_selftest_body"
fi

# ---------------------------------------------------------------------------
# Live invocation. Builtin `read -r -d ''` (not $(cat), which forks) per the
# zero-fork fast path.
# ---------------------------------------------------------------------------
IFS= read -r -d '' PAYLOAD || true
[ -n "${PAYLOAD:-}" ] || exit 0  # empty/unreadable stdin — nothing to gate

# Degraded: the gate cannot resolve who is acting, so it enforces nothing and
# allows. That is announced, not inferred — this is the only consumer with a
# channel back to the model, so the notice rides in-band on the first allow.
# Signalling is library-free (stderr + a zero-byte sentinel), because the audit
# appender is IN the library. Gated on an existing ledger and made once-per-ctx
# by a marker, so a degraded hook in an unrelated session stays silent and
# creates nothing.
#
# The once-per-ctx key is this gate's OWN marker, not the shared sentinel: every
# other degraded hook writes the shared one too, so keying on it would mute this
# notice for good whenever a model-switch or state-merge hook fired first — and
# this is the only consumer that can reach the model at all. The shared sentinel
# is still written, for the consumers that read it.
if [ "$LIB_DEGRADED" -eq 1 ]; then
  echo "test-execution-gate: shared library unusable at $_LIB — test authority not enforced" >&2
  # Declared roots only; the ladder's git/resolver ranks live in this library.
  CTX=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    CTX="${WORKSPACE_ROOT}/.context"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    CTX="${CLAUDE_PROJECT_DIR}/.context"
  fi
  [ -n "$CTX" ] || exit 0
  _NOTICE_MARK="$CTX/logs/.corpflow-lib-missing.test-execution-gate"
  if [ -f "$CTX/state.json" ] && [ ! -f "$_NOTICE_MARK" ]; then
    mkdir -p "$CTX/logs" 2>/dev/null && : > "$CTX/logs/.corpflow-lib-missing" 2>/dev/null
    : > "$_NOTICE_MARK" 2>/dev/null
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg m "test-execution gate degraded — authority not enforced. The shared hook library at $_LIB is absent, stubbed or truncated, so test-execution authority is NOT being checked this session. Treat every allow as unverified and tell a human." '
        {hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}
      ' 2>/dev/null || true
    fi
  fi
  exit 0
fi

# The context root resolves inside run_gate, after classification: nearly every call is not a
# test run, and an unresolved root is "no worktask here" — allow, enforce nothing, create nothing.
run_gate "$PAYLOAD" ""
exit 0
