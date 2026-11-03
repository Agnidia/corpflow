#!/usr/bin/env bats
# Cross-surface contracts for the request-plan rule set.
#
# The request-plan rules live across five files, and three of the four graded
# contradictions in the 0.0.1 capture were two of those files answering the same
# question differently. Most of that cross-read needs a human. These are the parts
# that reduce to a predicate, so the contradiction cannot silently come back.
#
# Contracts:
#   No rule surface names a slash command without a command, skill, or built-in entry.
#   commands/request-plan.md makes no "no exception" claim and cites the handoff anchor
#     as the authority for the trigger rule.
#   references/plan-template.md carries the required Surface-check line inside its
#     Recommended-next-step block.
#   Only SKILL.md states a search-termination condition; context-gathering.md points
#     at it, and the refuted 0.2.0 phrasing appears nowhere under skills/request-plan/.
#   The --secure asset enumeration exists exactly ONCE under skills/request-plan/
#     (handoff.md's --secure row) and is a SUBSET of the canonical list in
#     skills/estimation-methodology/SKILL.md § Worktask Tier Selection. Both sides
#     are EXTRACTED, never restated here: a hardcoded copy in the test is the same
#     defect the test exists to catch. A deny-list of the topic-flavour terms canon
#     rejects by name backs it up, for prose that states a tier rule without
#     enumerating one.
#
# Every candidate set gets a non-vacuity guard: these files genuinely contain slash
# commands and headings, so an empty match means the collector regressed rather than
# that the repo is clean.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

COMMAND_FILE="commands/request-plan.md"
TEMPLATE="skills/request-plan/references/plan-template.md"
SKILL="skills/request-plan/SKILL.md"
CONTEXT_GATHERING="skills/request-plan/references/context-gathering.md"
HANDOFF="skills/request-plan/references/handoff.md"
CANON="skills/estimation-methodology/SKILL.md"

# Topic-flavour terms canon explicitly rules OUT as triggers (§ What the two
# escalations are not: "the test is whether the request names a secret or an
# untrusted input, not whether the word security appears nearby"). Any of these
# stating a tier rule in a request-plan surface is a term outside the canon set.
NON_CANON_TIER_TERMS=(
  "security review" "security audit" "threat model" "security-sensitive"
  "penetration test" "vulnerability scan" "hardening"
)

# Claude Code ships these; they resolve to no file in commands/ and never will.
BUILTIN_COMMANDS="/clear /compact /config /context /cost /help /init /model /plugins /agents"

# Every rule surface that states request-plan policy. evals.json is deliberately out:
# it holds eval PROMPTS, so a stale command named there is a corpus fact, not a rule.
rule_surfaces() {
  printf '%s\n' \
    "${PLUGIN_ROOT}/${COMMAND_FILE}" \
    "${PLUGIN_ROOT}/skills/estimation-methodology/SKILL.md"
  find "${PLUGIN_ROOT}/skills/request-plan" -type f -name '*.md' | sort
}

# A `/name` token: at least 3 chars (so the `/x` placeholder in SKILL.md § 2 is not
# read as a command), not preceded by anything that makes it a path segment.
slash_tokens() {
  local f
  while IFS= read -r f; do
    grep -hoE '(^|[^A-Za-z0-9/._*!}-])/[a-z][a-z0-9-]{2,}' "$f" 2>/dev/null || true
  done < <(rule_surfaces) | grep -oE '/[a-z][a-z0-9-]{2,}' | sort -u
}

# --- no surface names a command that does not exist --------------------------

# The worktask skill retains its public slash shorthand without a command file.
unresolved_commands() {
  local t
  while read -r t; do
    [ -n "$t" ] || continue
    case " $BUILTIN_COMMANDS " in *" $t "*) continue ;; esac
    [ "$t" = "/worktask" ] && [ -f "${PLUGIN_ROOT}/skills/worktask/SKILL.md" ] && continue
    [ -f "${PLUGIN_ROOT}/commands/${t#/}.md" ] || printf '%s\n' "$t"
  done
}

@test "commands named in the rule surfaces all resolve" {
  # This is the check that would have caught /pm-prioritize surviving in SKILL.md § 4
  # and /pm-requirements in three files after they were renamed. Until now only a
  # manual grep found those.
  local tokens; tokens="$(slash_tokens)"
  local n; n="$(printf '%s' "$tokens" | grep -c . || true)"
  [ "$n" -ge 3 ] || fail "only $n /command token(s) collected; the collector regressed"

  local bad; bad="$(printf '%s\n' "$tokens" | unresolved_commands)"
  [ -z "$bad" ] || fail "named in a rule surface but no such command:
$bad"
}

@test "the command-existence check can actually fail" {
  # Non-vacuity for the PREDICATE, not just the candidate set: a resolver that accepts
  # everything would pass the test above no matter what the surfaces say.
  local bad
  bad="$(printf '%s\n' /worktask /pm-prioritize | unresolved_commands)"
  [ "$bad" = "/pm-prioritize" ] \
    || fail "resolver did not single out the absent command; got: ${bad:-<nothing>}"
}

# --- the command file does not restate the trigger rule's exception count -----

@test "the command file makes no 'no exception' claim of its own" {
  # § 1b: the file claimed "always exactly one, with no exception" while SKILL.md § 4
  # had acquired exactly one. Two surfaces, opposite answers, no trace to catch it
  # because the wording predated the exception.
  run grep -niE 'no exception|without exception|never an exception' \
    "${PLUGIN_ROOT}/${COMMAND_FILE}"
  assert_failure
}

@test "the command file cites the canonical handoff anchor as the trigger-rule authority" {
  run grep -cF 'skills/request-plan/SKILL.md#4-recommend-the-handoff' "${PLUGIN_ROOT}/${COMMAND_FILE}"
  assert_success
  [ "$output" -ge 1 ] || fail "commands/request-plan.md never points at the canonical handoff anchor"
  grep -q '^### 4\. Recommend the handoff$' "${PLUGIN_ROOT}/${SKILL}"
}

# --- the template carries the surface-check line ------------------------------

@test "the plan template requires a Surface check line before the trigger" {
  # § 3's whole mechanism is that the tier check produces visible output. If the line
  # can be dropped from the template without a test going red, it is advisory again.
  run grep -c '\*\*Surface check:\*\*' "${PLUGIN_ROOT}/${TEMPLATE}"
  assert_success
  [ "$output" -ge 1 ] || fail "plan-template.md carries no **Surface check:** line"
}

@test "the Surface check line sits inside the Recommended next step block" {
  # Placement is the contract: before the trigger, not in a note further down where a
  # plan renderer copying the template block would never see it.
  local block
  block="$(awk '/^## Recommended next step/ {inside=1} inside {print} inside && /^```$/ {exit}' \
             "${PLUGIN_ROOT}/${TEMPLATE}")"
  [ -n "$block" ] || fail "no '## Recommended next step' block in the template — collector regressed"
  printf '%s\n' "$block" | grep -q '\*\*Surface check:\*\*' \
    || fail "the **Surface check:** line is outside the Recommended-next-step block"
}

# --- only SKILL.md states a stop condition ------------------------------------

# The 0.2.0 rule SKILL.md § "When you may stop searching" rejects, in the words the
# drifted copy used. Matched loosely enough that a re-worded revival still trips it.
REFUTED_STOP_RE="wouldn.t change (the )?(scope|plan)|change scope, phases, or effort|stop (when|once) the next read"

# Every request-plan rule surface EXCEPT SKILL.md, which is the single source and
# quotes the refuted phrasing in order to reject it. evals/ is out for the reason the
# header gives: it holds eval prompts, so a phrase there is a corpus fact, not a rule.
non_canonical_stop_surfaces() {
  find "${PLUGIN_ROOT}/skills/request-plan" -type f \( -name '*.md' -o -name '*.sh' \) \
    -not -path '*/evals/*' -not -name 'SKILL.md' | sort
  printf '%s\n' "${PLUGIN_ROOT}/${COMMAND_FILE}"
}

@test "no surface but SKILL.md carries the refuted stop condition" {
  # Class B of the 0.3.0 capture: context-gathering.md carried "stop when the next
  # read wouldn't change scope, phases, or effort" verbatim for a whole version while
  # SKILL.md rejected it in as many words. Eight graded answers stopped at a plausible
  # neighbour, each one following the copy the grader did not.
  local files; files="$(non_canonical_stop_surfaces)"
  [ "$(printf '%s\n' "$files" | grep -c .)" -ge 3 ] \
    || fail "fewer than 3 surfaces collected; the collector regressed"
  local bad
  bad="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -niE "$REFUTED_STOP_RE" || true)"
  [ -z "$bad" ] || fail "a second surface states a search-termination condition:
$bad"
}

@test "the stop-condition check can actually fail" {
  # Non-vacuity for the PREDICATE: the pattern must match the sentence that was
  # actually there, not merely find nothing everywhere.
  run grep -qiE "$REFUTED_STOP_RE" <<< \
    "Stop when the next read wouldn't change scope, phases, or effort."
  assert_success
}

@test "context-gathering.md points at SKILL.md's stop rule instead of restating one" {
  # A pointer, never a restated list — the same shape routing-matrix.bats and
  # test-authority-matrix.bats enforce. SKILL.md § "When you may stop searching" is
  # the only surface allowed to answer this question.
  local body
  body="$(awk '/^## When to stop$/ {inside=1; next} inside && /^## / {exit} inside {print}' \
            "${PLUGIN_ROOT}/${CONTEXT_GATHERING}")"
  [ -n "$body" ] || fail "no '## When to stop' section in ${CONTEXT_GATHERING} — collector regressed"
  printf '%s\n' "$body" | grep -q 'SKILL\.md § When you may stop searching' \
    || fail "${CONTEXT_GATHERING} § When to stop does not point at SKILL.md's rule"
  # And SKILL.md must still carry the heading being pointed at.
  grep -q '^#### When you may stop searching$' "${PLUGIN_ROOT}/${SKILL}" \
    || fail "SKILL.md no longer has the § the pointer names"
}

# --- tier triggers are a subset of the canon asset list -----------------------

canon_tier_section() {
  awk '/^## Worktask Tier Selection$/ {inside=1} inside {print} inside && /^## PL0 / {exit}' \
    "${PLUGIN_ROOT}/${CANON}"
}

# Normalize an English enumeration ("a, b, c, or d") into one lowercase term per
# line: split on commas, drop a leading "or", strip markup and trailing punctuation.
split_enumeration() {
  tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
          -e 's/^or[[:space:]]\{1,\}//' \
          -e 's/[`*]//g' \
          -e 's/[.:;]*$//' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^$' \
    | sort -u
}

# Canon's asset enumeration, read out of the surface-check pseudocode rather than
# hardcoded here — a hardcoded copy is the same defect this file tests for.
canon_secure_assets() {
  canon_tier_section \
    | tr '\n' ' ' \
    | sed -e 's/.*IF the request names[[:space:]]*//' -e 's/[[:space:]]*as part of.*//' \
    | split_enumeration
}

# The ONE enumeration handoff.md is allowed to carry: the `For` cell of the --secure
# row. Everything else in the request-plan surfaces must point at it or at canon.
handoff_secure_assets() {
  grep -m1 '^| `--secure` |' "${PLUGIN_ROOT}/${HANDOFF}" \
    | sed -e 's/.*| the request names[[:space:]]*//' -e 's/[[:space:]]*—.*//' \
    | split_enumeration
}

# Prints every NON_CANON_TIER_TERMS hit in the files named on stdin (one path each).
non_canon_tier_terms() {
  local f term
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for term in "${NON_CANON_TIER_TERMS[@]}"; do
      grep -niF -- "$term" "$f" 2>/dev/null | sed "s|^|${f#${PLUGIN_ROOT}/}:|" || true
    done
  done
}

@test "the canon asset list is where the request-plan surfaces say it is" {
  # Non-vacuity for the canon half: if § Worktask Tier Selection moves, is renamed, or
  # rewords its IF line, the subset test below would compare against an empty set and
  # pass silently — the exact way a parity test rots into a no-op.
  local section; section="$(canon_tier_section)"
  [ -n "$section" ] || fail "no § Worktask Tier Selection in ${CANON}"
  local n; n="$(canon_secure_assets | grep -c .)"
  [ "$n" -ge 5 ] || fail "only $n asset(s) parsed out of canon's surface check; the parser regressed"
}

@test "handoff.md's --secure assets are a subset of canon's" {
  # The real subset check, both sides EXTRACTED — neither list is restated in this
  # file, because a hardcoded copy here is the same defect the test exists to catch.
  # A novel non-canon term added to the row fails on membership, not on a deny-list.
  local extra
  extra="$(comm -23 <(handoff_secure_assets) <(canon_secure_assets))"
  [ -z "$extra" ] || fail "${HANDOFF}'s --secure row names assets canon does not:
$extra"
  local n; n="$(handoff_secure_assets | grep -c .)"
  [ "$n" -ge 5 ] || fail "only $n asset(s) parsed out of the --secure row; the parser regressed"
}

@test "the subset check can actually fail" {
  # Non-vacuity for the PREDICATE at the :71 pattern: an extractor that returned
  # nothing, or a comparison that accepted anything, would pass the test above.
  local extra
  extra="$(comm -23 <(printf '%s\n' compliance credentials tokens | sort -u) \
                    <(canon_secure_assets))"
  [ "$extra" = "compliance" ] \
    || fail "subset check did not single out the non-canon term; got: ${extra:-<nothing>}"
}

@test "no request-plan surface carries a SECOND copy of the asset enumeration" {
  # One enumeration, in handoff.md's --secure row. A second copy is what drifted at
  # 0.3.0: two lists in one file, and only one of them got the 0.3.0 correction.
  local hits
  hits="$(grep -rn 'payments, authn/authz' "${PLUGIN_ROOT}/skills/request-plan" \
            --include='*.md' | grep -v '/evals/' | grep -c . || true)"
  [ "$hits" -eq 1 ] \
    || fail "expected exactly 1 asset enumeration under skills/request-plan/, found $hits"
}

@test "no request-plan surface names a --secure trigger term outside the canon set" {
  # The complement of the subset test above, which only sees an ENUMERATION. Class C
  # of the 0.3.0 capture drifted in as prose: handoff.md's read-back bullet listed
  # "security review, threat modelling" — topic-flavour terms canon rejects by name —
  # and case 80 executed the bullet as written. The only guard was the prose sentence
  # at the top of § Tier selection telling the reader not to keep a parallel ruleset,
  # and a sentence is not a check.
  local bad
  bad="$(printf '%s\n' "${PLUGIN_ROOT}/${HANDOFF}" "${PLUGIN_ROOT}/${TEMPLATE}" \
           | non_canon_tier_terms)"
  [ -z "$bad" ] || fail "tier-trigger term outside the canon asset list:
$bad"
}

@test "the canon-subset check can actually fail" {
  # Non-vacuity for the PREDICATE at the :71 pattern: plant the exact phrasing that
  # drifted in and confirm the collector singles it out.
  local wd; wd="$(mk_tmpworkdir)"
  printf '%s\n' 'body argues the request asked for security review → carry --secure' \
                 'body argues the thing is broken right now → carry --emergency' > "$wd/drifted.md"
  local bad; bad="$(printf '%s\n' "$wd/drifted.md" | non_canon_tier_terms)"
  printf '%s\n' "$bad" | grep -q 'security review' \
    || fail "collector did not flag the planted term; got: ${bad:-<nothing>}"
}
