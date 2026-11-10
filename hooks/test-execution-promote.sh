#!/usr/bin/env bash
# test-execution-promote — PostToolUse companion of hooks/test-execution-gate.sh.
#
# Registered on PostToolUseFailure as well: a non-zero runner exit is delivered
# as an error tool result, which fires that event INSTEAD of PostToolUse, so a
# PostToolUse-only registration would leave every failing run unrecorded.
#
# The gate is a PreToolUse hook, so it fires before any result exists: recording
# a run's fingerprint there let an invocation that aborted having executed
# nothing claim that fingerprint permanently, and every later attempt against the
# same tree was denied on the strength of a run that produced no evidence. The
# gate now writes only a `.pending` marker; this hook promotes it to a real
# sentinel once the tool actually produced a result, and deletes it otherwise.
#
# It computes NOTHING of its own: the gate is sourced with --lib-only so the
# classifier, the invocation derivation and the key are the same definitions the
# gate itself used. Two independent derivations would orphan every marker and
# disable suppression silently — the failure this design exists to prevent.
#
# Exits 0 always and emits no decision. A PostToolUse hook cannot un-run the
# tool, and a promotion failure only means the next identical run is allowed.
set -u
set -f

_GATE="$(dirname "$0")/test-execution-gate.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/test-execution-gate.sh
[ -f "$_GATE" ] && . "$_GATE" --lib-only
case "$_CF_OPTS" in *e*) set -e ;; esac
command -v gate_classify_payload > /dev/null 2>&1 || exit 0
command -v dedupe_pending_key > /dev/null 2>&1 || exit 0

# Sourced explicitly rather than relied on as a side effect of --lib-only
# above, which exists only to share the classifier.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac
command -v corpflow_context_root > /dev/null 2>&1 || exit 0

# EVIDENCE_BASENAME_MAX — the bundle rung's own bound, far below the token's
# outer 120. A genuine results artifact is named like `Run-2026-09-08.xcresult`
# or `junit.xml`; a sentence needs room. See tool_evidence_token's security note.
EVIDENCE_BASENAME_MAX=48

# evidence_bundle_basename <candidate> <base dir> -> prints the basename to cite,
# or nothing. The candidate must name something that EXISTS, must be a known
# results shape, and must survive a charset narrower than the token's own.
#
# Existence is the load-bearing test and it is checked on the host that just ran
# the tool, at the moment it returned. It is what turns "print a string" into
# "create a file on this machine with that name", which is a different capability
# and not one a response body has on its own. A fabricated path is not repeated
# in any form: the rung declines and the ladder falls through to a derived
# numeric, which is the fail-open direction everywhere else in this library.
#
# A relative candidate is resolved against the payload's own cwd, because the
# hook's cwd is not the tool's — without that, every relative bundle path would
# decline and the rung would serve absolute paths only.
evidence_bundle_basename() {
  local _cand="$1" _base="$2" _abs
  case "$_cand" in
    /*) _abs="$_cand" ;;
    *)  [ -n "$_base" ] || return 1
        _abs="$_base/$_cand" ;;
  esac
  [ -e "$_abs" ] || return 1
  _base="${_abs##*/}"
  # Directory separators are already gone with the basename, which is most of
  # what a sentence needs; `:` and `+` go with them so the cited name cannot
  # mimic the token's own grammar.
  case "$_base" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#_base}" -le "$EVIDENCE_BASENAME_MAX" ] || return 1
  # `*.log` is deliberately absent: DV writes `.context/logs/build-*.log` for BUILD
  # verification (skills/worktask/references/stage-contracts.md § DV), and admitting it here cited
  # a build as a test result at the one rung nothing downstream re-checks. A results
  # shape is a format a runner emits for RESULTS; a log is a transcript of anything.
  case "$_base" in
    *.xcresult | *.xcodebuild | *.trx | *.junit | *.xml | *.jsonl) ;;
    *) return 1 ;;
  esac
  printf '%s' "$_base"
}

# tool_evidence_token <payload> -> prints ONE evidence token and returns 0, or
# prints nothing and returns non-zero.
#
# Deriving the token and deciding to promote are ONE computation on purpose. Two
# separate computations can disagree, and the shape of that disagreement is the
# defect this replaces: a marker promoted for an invocation that produced
# nothing, whose denial then cited a run with no result to name. If the evidence
# cannot be named, the run does not get to deny its own retry.
#
# The narrowest observable that separates a real run from an abort is
# `tool_response`: present and non-empty, with no error flag. A FAILING call
# carries no `tool_response` at all — the failure arrives as a top-level `error`
# string — so keying on it there would discard every red suite and suppress only
# green ones, inverting the point: a red suite that printed its failures IS a
# run. On that event the error text therefore counts as output. `is_interrupt`
# is the one failure kept inert: a cancelled call produced no evidence at all.
#
# Ladder, most specific first — the whole reason a token is carried rather than
# a boolean is that a reader of a later denial can tell at a glance how strong
# the cited run's evidence was:
#
#   bundle:<name>   the BASENAME of a results artifact that exists on this host
#   tests:<n>       a count read off the runner's summary line, alongside outcome
#                   vocabulary proving the cases actually ran
#   discovered:<n>  a count with NO outcome vocabulary anywhere — an enumeration,
#                   not an execution. Deliberately a distinct token shape: the
#                   suppression gate must be able to tell it from a result, and a
#                   `tests:` that meant either was indistinguishable to every
#                   reader downstream
#   output:<n>B     a response was present but said nothing interpretable
#   errtext:<n>B    the PostToolUseFailure arm — a red suite that printed
#
# Rung three keeps the honest limit ("a runner that exits 0 having executed 0
# tests still promotes") while making it VISIBLE: `output:812B` in a denial says
# the cited run recorded no count, which is the hour of diagnosis this exists to
# remove.
#
# SECURITY — the token is interpolated into a policy denial that a model reads,
# so it is a channel from tool output into a policy string. Structure was never
# the weak half: the outer filter is one whitespace-free run of
# [A-Za-z0-9._/:+-], bounded at 120 characters (which also keeps the sentinel
# line inside dedupe_lookup's `head -c 200`), it runs before the bound so
# droppable bytes cannot smuggle length past it, and emit_deny escapes through
# `jq --arg`. The weak half was the ALPHABET: that charset is a complete one for
# dot- and slash-separated English, and this rung used to pass a caller-supplied
# path through unchanged, so a response could land a hundred characters of
# chosen prose verbatim in a refusal. Three of the four rungs never could — they
# emit derived numerics and nothing else. This one now emits an existing file's
# basename, so the free text is gone and what remains must first be made real on
# disk. Empty after all of it means no evidence, which means discard: predicate
# and token stay one thing.
tool_evidence_token() {
  local _out _line _tok="" _fallback="" _cand _base _root="" _seen=0
  command -v jq > /dev/null 2>&1 || return 1
  # Candidate bundle paths on `B` lines, the derived-numeric answer on the single
  # `F` line. Two prefixes rather than two jq invocations: the ladder is one
  # decision and splitting it is how the predicate and the token drift apart.
  _out=$(printf '%s' "$1" | jq -r '
    (.tool_response // null) as $r
    | ((.error // "") | if type == "string" then . else "" end) as $errtext
    | (if ($r | type) == "object" then (($r.error? // false) or ($r.is_error? // false))
       else false end) as $rflag
    | (if $r == null then false
       elif ($r | type) as $t | $t == "string" or $t == "array" or $t == "object"
       then ($r | length) > 0
       else true end) as $rhas
    | ((.is_interrupt // false)
       or (if ($r | type) == "object" then ($r.is_interrupt? // false) else false end))
      as $interrupted
    | ((.hook_event_name // "") == "PostToolUseFailure"
       or ($r == null and ($errtext | length) > 0)) as $failed
    | (($interrupted | not)
       and ($rflag | not)
       and ($rhas or ($failed and ($errtext | length) > 0))) as $isrun
    | if ($isrun | not) then empty else
        (if $r == null then ""
         elif ($r | type) == "string" then $r
         else ($r | tojson) end) as $rtext
      | ($rtext + " " + $errtext) as $all
      | [$all | match("[A-Za-z0-9._/-]+[.](xcresult|xcodebuild|trx|junit|xml|jsonl)\\b"; "g")
         | .string] as $bundles
      # A count alone does not say the cases RAN. `Executing 49 tests` is a
      # discovery banner, and a scheme with an empty test plan prints it and
      # exits having executed nothing — which is how one run recorded `tests:49`
      # for zero executed tests and then suppressed every later attempt to run
      # them. Outcome vocabulary is the discriminator: a summary that reports a
      # result says one of these words somewhere. `executed` is in the list and
      # `executing` deliberately is not.
      #
      # Both halves are read off ONE LINE — the line carrying the count. Over the
      # whole text the discriminator is defeated by its own reproducer: the empty
      # test plan that prints `Executing 49 tests` is run by `xcodebuild`, which
      # then prints `** TEST SUCCEEDED **` for the green BUILD, and a vocabulary
      # test spanning both lines reads the verdict of the BUILD as the verdict of
      # the enumeration. A summary line carries its own outcome; a verdict one
      # line away belongs to something else.
      #
      # Lines come from string LEAVES, never the serialised object: an object
      # response carrying an `error` or `errors` key — a shape $rflag above
      # already anticipates — would otherwise satisfy `errors?` by its key name
      # alone and hand a bare enumeration back its `tests:` token.
      | (if ($r | type) == "object" or ($r | type) == "array"
         then [$r | .. | strings] else [$rtext] end) as $leaves
      | (($leaves + [$errtext]) | map(split("\n")) | add) as $lines
      | [$lines[]
          | select(test("([0-9]+)[ \t]+(tests?|examples?|assertions?|passed)\\b"))] as $clines
      # The summary is the count line carrying its own outcome word, wherever it
      # sits: a runner that prints an enumeration banner ABOVE its tally would
      # otherwise bind the count to the banner and demote a real run to
      # `discovered:`. With no such line the first count line stands, so a
      # banner alone still reads as enumeration.
      | (([$clines[]
          | select(test("\\b(executed|passed|failed|failures?|succeeded|errors?|completed?)\\b"; "i"))]
         | first) // ($clines | first)) as $cline
      | (if $cline == null then null
         else ($cline
               | match("([0-9]+)[ \t]+(tests?|examples?|assertions?|passed)\\b")
               | .captures[0].string) end) as $count
      | ($cline != null
         and ($cline
              | test("\\b(executed|passed|failed|failures?|succeeded|errors?|completed?)\\b"; "i")))
        as $ran
      | (if $count != null and $ran then "tests:" + $count
         elif $count != null then "discovered:" + $count
         elif ($rtext | length) > 0 then "output:" + (($rtext | length) | tostring) + "B"
         elif ($errtext | length) > 0 then "errtext:" + (($errtext | length) | tostring) + "B"
         else null end) as $fb
      | [$bundles[] | "B" + .] + (if $fb == null then [] else ["F" + $fb] end)
      | .[]
      end
  ' 2> /dev/null) || return 1

  while IFS= read -r _line; do
    case "$_line" in
      B*)
        [ -n "$_tok" ] && continue
        # A response naming hundreds of paths is a payload, not a result; the
        # first few candidates are where a real bundle appears.
        [ "$_seen" -lt 20 ] || continue
        _seen=$((_seen + 1))
        _cand="${_line#B}"
        if [ -z "$_root" ] && command -v dedupe_root > /dev/null 2>&1; then
          _root="$(dedupe_root "$1")"
        fi
        _base="$(evidence_bundle_basename "$_cand" "$_root")" || continue
        [ -n "$_base" ] && _tok="bundle:$_base"
        ;;
      F*) _fallback="${_line#F}" ;;
    esac
  done <<EOF
$_out
EOF

  [ -n "$_tok" ] || _tok="$_fallback"
  _tok=$(printf '%s' "$_tok" | LC_ALL=C tr -cd 'A-Za-z0-9._/:+-')
  _tok=$(printf '%.120s' "$_tok")
  [ -n "$_tok" ] || return 1
  printf '%s' "$_tok"
}

run_promote() {
  local _payload="$1" _ctx="$2" _tool _ident _class _cmd_head _inv _n _pkey _ev

  [ "${CORPFLOW_TEST_DEDUPE:-}" = "off" ] && return 0
  [ "${CORPFLOW_TEST_GATE:-}" = "off" ] && return 0
  command -v jq > /dev/null 2>&1 || return 0

  _tool=$(printf '%s' "$_payload" | jq -r '.tool_name // empty' 2> /dev/null)
  [ -n "$_tool" ] || return 0

  _ident="$(gate_classify_payload "$_payload" "$_tool")" || return 0
  _class="${_ident%%$'\t'*}"
  _cmd_head="${_ident#*$'\t'}"
  # Only an executing class can have left a marker, so everything else is a
  # cheap exit rather than a filesystem probe.
  case "$_class" in
    full_test_run|scoped_test_run) ;;
    *) return 0 ;;
  esac
  # Resolved only now: the root ladder forks git, and nearly every call exits above.
  [ -n "$_ctx" ] || _ctx=$(corpflow_context_root)
  [ -n "$_ctx" ] || return 0

  # The tree is deliberately NOT consulted here: the run itself may have written
  # un-ignored artifacts, so a fingerprint taken now names a marker the gate
  # never wrote. The gate's pre-run key travels inside the marker instead.
  _n=$(run_index_of "$_ctx")
  [ -n "$_n" ] || return 0
  _inv="$(dedupe_invocation "$_payload" "$_tool" "$_cmd_head")"
  _pkey=$(dedupe_pending_key "$_class" "$_inv" "$_n")
  [ -n "$_pkey" ] || return 0

  # A backgrounded call (`backgroundTaskId`, CONFIRMED) is a handle:
  # its partial stdout may already show a pass count for a run that can still die.
  # Discard, because a wrong suppression strands the stage and a re-run only costs time.
  local _bg
  _bg=$(printf '%s' "$_payload" | jq -c '
    (.tool_response // null) as $r
    | if ($r | type) == "object" and (($r.backgroundTaskId // "") | tostring | length) > 0
      then {auto_moved: ($r.subagentCapApplied == true)} else empty end' 2> /dev/null)
  if [ -n "$_bg" ]; then
    dedupe_discard "$_ctx" "$_pkey"
    command -v write_audit_row > /dev/null 2>&1 \
      && write_audit_row "$_ctx" "test_run_backgrounded" "$_bg"
    return 0
  fi

  # One computation, one branch: `_ev` is both the promotion predicate and the
  # string the later denial will cite.
  if _ev="$(tool_evidence_token "$_payload")"; then
    dedupe_promote "$_ctx" "$_pkey" "$_ev"
  else
    dedupe_discard "$_ctx" "$_pkey"
  fi
  return 0
}

# Sourced by its own bats suite, which calls run_promote directly against a
# fixture ctx; the dispatch below runs only when this file is the entry point.
# shellcheck disable=SC2317 # `return` outside a function fails when executed directly, so the exit IS reached
case "${1:-}" in
  --lib-only) return 0 2>/dev/null || exit 0 ;;
esac

IFS= read -r -d '' PAYLOAD || true
[ -n "${PAYLOAD:-}" ] || exit 0

# An unresolved root (inside run_promote) means nothing was gated there: no marker to promote.
run_promote "$PAYLOAD" ""
exit 0
