#!/usr/bin/env bats
# Contract tests for the DV fan-out model (handoff-protocol.md § DV fan-out — ledger tasks).
# Pins the prose contract (AC1, AC2, AC5) and the S3 iteration seam against a fixture
# ledger (AC6): per-stream DV rows resolve downstream through the ledger, never through a
# composed development-N.md name.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

STATE_PATCH="skills/worktask/scripts/state-patch.sh"
HARNESS="skills/worktask/scripts/handoff-harness.sh"
DV_FIX="tests/fixtures/worktask/dv-fanout"

# S3, verbatim from handoff-protocol.md § Iterating the DV tasks. The "S3 idiom" test
# below fails if the prose drifts from these programs, so the seam has one spelling.
S3_PATHS='.tasks | to_entries
  | map(select(.value.metadata.stage == "DV" and (.key | test("^DV[0-9]+$"))))
  | sort_by(.key | ltrimstr("DV") | tonumber)
  | .[] | (.value.artifact // .value.metadata.artifact // empty)'
S3_REFS='.tasks | to_entries
  | map(select(.value.metadata.stage == "DV" and (.key | test("^DV[0-9]+$"))))
  | sort_by(.key | ltrimstr("DV") | tonumber)
  | .[] | ((.value.artifact // .value.metadata.artifact // empty) | split("/") | last) + "#files-changed"'

# The pin rule of handoff-protocol.md § Pinning a row's tree, as data: prints every DV row id
# that carries metadata.stream and shares its workspace_path with another DV row when neither
# reaches the other through blocked_by, transitively. Ledgers are acyclic, so recurse ends.
PIN_RULE='.tasks as $t
  | def deps($id): ($t[$id].blocked_by // [])[];
    def reach($a; $b): any(deps($a) | recurse(deps(.)); . == $b);
    [$t | to_entries[] | select(.value.metadata.stage == "DV")] as $dv
  | $dv[] | select(.value.metadata.stream) | .key as $k | .value.metadata.workspace_path as $p
  | select(any($dv[]; .key != $k and .value.metadata.workspace_path == $p
      and (reach($k; .key) | not) and (reach(.key; $k) | not)))
  | $k'

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  # BATS_TMPDIR is not a git repo: without a declared root state-patch's ladder misses.
  export WORKSPACE_ROOT="$WD"
}

# write_dr <refs-list> — a DR artifact whose refs.dev is exactly the given S3 output.
write_dr() {
  {
    printf -- '---\nhandoff:\n  stage: DR\n  verdict: pass\n'
    printf '  summary: "fixture review. 0 findings"\n  key_decisions: []\n  open_questions: []\n'
    printf '  refs:\n    dev:\n'
    printf '%s\n' "$1" | sed 's/^/      - /'
    printf '    findings: developer-review-0.md#findings\n---\n\n# Developer Review\n'
    printf '\n## %s\n\nNone.\n' verdict findings blockers follow-ups elicitation-sweep
  } > "$WD/.context/developer-review-0.md"
}

@test "AC1: the old fan-out headings and merge wording are gone; one DV fan-out heading remains" {
  cd "$PLUGIN_ROOT"
  run grep -rnE '^#{2,4} (TL fan-out|Stream Slugs|Multi-Run Within a Stage|Per-stream DV artifacts)' agents skills commands
  assert_failure 1
  run grep -rnE 'merged canonical|merges? them into the canonical|alone merges|merge inputs' agents skills commands hooks
  assert_failure 1
  run bash -c "grep -rnE '^#{2,4} DV fan-out' agents skills commands | wc -l | tr -d ' '"
  assert_output "1"
}

@test "AC2: no downstream contract template or I/O row names a bare development-N.md" {
  cd "$PLUGIN_ROOT"
  run bash -c "awk '/^### #tpl-(dr|sr|qa|dc|re) /{f=1} /^### #tpl-(fn|st|ir|et|pl|ar|tl|dv) /{f=0} f' skills/shared/stage-contracts.md"
  assert_success
  [[ "$output" == *"#tpl-re"* ]] || fail "template slice is empty; the heading shape moved"
  run bash -c "printf '%s\n' \"\$1\" | grep -nE '\\bdevelopment-(N|[0-9]+)\\.md\\b'" _ "$output"
  assert_failure 1
  run grep -nE '^\| \*\*(DR|SR|QA|DC|RE)\*\* \|.*development-N\.md' skills/shared/stage-contracts.md
  assert_failure 1
}

@test "AC2: no downstream agent names a bare development-N.md" {
  cd "$PLUGIN_ROOT"
  run grep -nE '\bdevelopment-(N|\$\{?N\}?|[0-9]+)\.md\b' agents/technical-lead.md agents/qa-engineer.md \
    agents/security-reviewer.md agents/release-engineer.md agents/technical-writer.md
  assert_failure 1
}

@test "AC5: the CHANGELOG re-entry check lives in RE, not in the DR checklist" {
  cd "$PLUGIN_ROOT"
  grep -q '^#### Scope-addition re-entry checklist' agents/technical-lead.md \
    || fail "technical-lead.md lost its re-entry checklist heading"
  run bash -c "awk '/^#### Scope-addition re-entry checklist/{f=1;next} /^#### /{f=0} f' agents/technical-lead.md | grep -c CHANGELOG"
  assert_output "0"
  run grep -c 'CHANGELOG names the new scope' agents/release-engineer.md
  assert_success
  [ "$output" -ge 1 ]
}

@test "S3: handoff-protocol.md spells the iteration idiom this suite executes" {
  local doc="$PLUGIN_ROOT/skills/worktask/references/handoff-protocol.md" line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    grep -qF -- "$line" "$doc" || fail "S3 drifted: handoff-protocol.md no longer carries: $line"
  done <<< "$S3_PATHS"$'\n''| .[] | ((.value.artifact // .value.metadata.artifact // empty) | split("/") | last) + "#files-changed"'
}

@test "AC6: fixture row descriptions carry no development- path" {
  run jq -r '.tasks[].metadata.description // empty' \
    "$PLUGIN_ROOT/$DV_FIX/state.two-stream.json" "$PLUGIN_ROOT/$DV_FIX/state.single-dv.json"
  assert_success
  refute_output --partial "development-"
}

@test "AC6: two DV streams claim, self-patch by id, and flow into DR through S3" {
  cp "$PLUGIN_ROOT/$DV_FIX/state.two-stream.json" "$WD/.context/state.json"
  cd "$WD"
  local k s refs ref
  for k in 0 1; do
    run bash "$PLUGIN_ROOT/$STATE_PATCH" --claim "DV$k"
    assert_success
  done
  for s in "0 service" "1 web"; do
    cp "$PLUGIN_ROOT/$DV_FIX/development-0-${s#* }.md" .context/
    run bash "$PLUGIN_ROOT/$STATE_PATCH" --stage DV --task-id "DV${s%% *}" \
      --artifact ".context/development-0-${s#* }.md" --prev PL
    assert_success
    refute_output --partial "is not the canonical name"
  done

  run jq -r "$S3_PATHS" .context/state.json
  assert_success
  assert_output "$(printf '.context/development-0-service.md\n.context/development-0-web.md')"

  run jq -r "$S3_REFS" .context/state.json
  assert_success
  assert_output "$(printf 'development-0-service.md#files-changed\ndevelopment-0-web.md#files-changed')"
  refs="$output"

  write_dr "$refs"
  run bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter .context/developer-review-0.md --state .context/state.json
  assert_success
  run bash "$PLUGIN_ROOT/$STATE_PATCH" --stage DR --prev DV
  assert_success
  run jq -r '.tasks.DR0.status' .context/state.json
  assert_output "completed"

  while IFS= read -r ref; do
    [ -f ".context/${ref%%#*}" ] || fail "refs.dev element does not resolve: $ref"
    grep -q '^## files-changed$' ".context/${ref%%#*}" || fail "no ## files-changed in ${ref%%#*}"
  done <<< "$refs"
}

@test "S3: task ids sort numerically, and non-DV or non-numeric rows are skipped" {
  jq '.tasks.DV10 = (.tasks.DV1 | .metadata.artifact = ".context/development-0-docs.md")
      | .tasks.DV2 = (.tasks.DV1 | .metadata.artifact = ".context/development-0-cli.md" | .artifact = ".context/development-0-cli-recorded.md")
      | .tasks.DVx = .tasks.DV1' \
    "$PLUGIN_ROOT/$DV_FIX/state.two-stream.json" > "$WD/.context/state.json"
  run jq -r "$S3_REFS" "$WD/.context/state.json"
  assert_success
  assert_output "$(printf '%s\n' development-0-service.md development-0-web.md \
    development-0-cli-recorded.md development-0-docs.md | sed 's/$/#files-changed/')"
}

@test "AC6: a single-DV ledger yields a one-element refs.dev naming development-N.md" {
  run jq -r "$S3_REFS" "$PLUGIN_ROOT/$DV_FIX/state.single-dv.json"
  assert_success
  assert_output "development-0.md#files-changed"
  [ -f "$PLUGIN_ROOT/$DV_FIX/development-0.md" ] || fail "single-DV fixture artifact missing"
}

# team-lead.md Steps 4-5, verbatim. The pin test fails when the prose drops the subject
# override, and the fan-out tests replay STEP5_OVERRIDE, so the recipe and the replay agree.
STEP4_SET='"subject":"{primary stream subject}","stream":"{primary-slug}",'
STEP5_ARGS='--arg desc "$STREAM_SCOPE" --arg subj "$STREAM_SUBJECT" \'
STEP5_OVERRIDE='($m | del(.produces, .consumes)) + {description:$desc, subject:$subj, stream:$slug,
       artifact:".context/development-\($m.run_index)-\($slug).md"}'

# seed_pl0_ledger — DV0 as PL0 seeds it (a subject, plan and AR context_refs, the dispatch
# keys) and a completed AR0 whose decisions are on disk, so every brief ref resolves.
seed_pl0_ledger() {
  printf '## requirements\n\nR.\n\n## acceptance-criteria\n\nA.\n' > "$WD/.context/planning-0.md"
  printf '## decisions\n\nD.\n' > "$WD/.context/architecture-0.md"
  jq -n --arg wd "$WD" '{version: 2, worktask_id: "subject-fixture", plan_file: ".context/planning-0.md",
    run_index: 0, facts: {}, handoffs: {},
    tasks: {
      PL0: {status: "completed", metadata: {stage: "PL"}},
      AR0: {status: "completed", metadata: {stage: "AR", run_index: 0}},
      DV0: {status: "pending", blocked_by: ["AR0"], metadata: {stage: "DV", agent: "corpflow:developer",
        model: "opus", effort: "high", isolation: "worktree", base_ref: "develop",
        requires_screenshots: false, workspace_path: $wd, run_index: 0,
        artifact: ".context/development-0.md", subject: "Fix the whole issue",
        context_refs: ["planning-0.md#requirements", "planning-0.md#acceptance-criteria",
          "architecture-0.md#decisions"]}}}}' > "$WD/.context/state.json"
}

# step4_narrow — Step 4's --task-meta call with the primary stream filled in.
step4_narrow() {
  bash "$PLUGIN_ROOT/$STATE_PATCH" --task-meta DV0 --set '{"description":"Own the core stream",
    "subject":"Build the core stream","stream":"core","artifact":".context/development-0-core.md"}'
}

# step5_meta <slug> <subject> — Step 5's --metadata value for one stream, via STEP5_OVERRIDE.
step5_meta() {
  jq -n --argjson m "$(jq -c '.tasks.DV0.metadata' "$WD/.context/state.json")" \
    --arg slug "$1" --arg desc "Own the $1 stream" --arg subj "$2" "$STEP5_OVERRIDE"
}

@test "subject: team-lead.md Steps 4-5 spell the per-stream subject override" {
  local slice line
  slice=$(awk '/^4\. Narrow DV0/ { f = 1 } /^##### Step 5 field notes/ { f = 0 } f' "$PLUGIN_ROOT/agents/team-lead.md")
  [ -n "$slice" ] || fail "Steps 4-5 slice is empty; the Step 4 or field-notes heading moved"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    grep -qF -- "$line" <<< "$slice" || fail "Steps 4-5 drifted: team-lead.md no longer carries: $line"
  done <<< "$STEP4_SET"$'\n'"$STEP5_ARGS"$'\n'"$STEP5_OVERRIDE"
}

@test "subject: a 4-stream fan-out yields four distinct subjects and no duplicate refs" {
  seed_pl0_ledger
  cd "$WD"
  run step4_narrow
  assert_success
  local s k subjects="" brief
  for s in "1 api" "2 web" "3 cli"; do
    run bash "$PLUGIN_ROOT/$STATE_PATCH" --task-create "DV${s%% *}" \
      --metadata "$(step5_meta "${s#* }" "Build the ${s#* } stream")"
    assert_success
  done
  for k in 0 1 2 3; do
    brief=$(bash "$PLUGIN_ROOT/skills/worktask/scripts/brief-compose.sh" "DV$k" \
      --state .context/state.json --orch-root "$WD") || fail "DV$k brief did not compose"
    [ -z "$(grep '^ref: ' <<< "$brief" | sort | uniq -d)" ] || fail "DV$k brief repeats a ref: line"
    grep -q '^ref: architecture-0.md#decisions$' <<< "$brief" || fail "DV$k brief lost the AR ref"
    subjects+="$(grep '^subject: ' <<< "$brief")"$'\n'
  done
  [ "$(printf '%s' "$subjects" | sort -u | grep -c '^subject: ')" -eq 4 ] \
    || fail "subjects are not four distinct lines: $subjects"
}

@test "subject: a stream clone keeping DV0's subject exits 2, ledger byte-identical" {
  seed_pl0_ledger
  cd "$WD"
  run step4_narrow
  assert_success
  cp .context/state.json .context/state.json.before
  # A clone with no subject override inherits DV0's subject.
  run --separate-stderr bash "$PLUGIN_ROOT/$STATE_PATCH" --task-create DV1 --metadata "$(jq -n \
    --argjson m "$(jq -c '.tasks.DV0.metadata' .context/state.json)" \
    '$m + {description:"Own the api stream", stream:"api", artifact:".context/development-0-api.md"}')"
  assert_failure 2
  [[ "$stderr" == *"invalid --task-create DV1: metadata.subject repeats tasks.DV0 (each DV stream needs its own subject); state.json unchanged"* ]] \
    || fail "unexpected stderr: $stderr"
  cmp .context/state.json .context/state.json.before
}

@test "subject: batched siblings sharing a subject refuse the whole batch" {
  seed_pl0_ledger
  cd "$WD"
  run step4_narrow
  assert_success
  cp .context/state.json .context/state.json.before
  run --separate-stderr bash "$PLUGIN_ROOT/$STATE_PATCH" \
    --task-create DV1 --metadata "$(step5_meta api "Build the client")" \
    --task-create DV2 --metadata "$(step5_meta web "Build the client")"
  assert_failure 2
  [[ "$stderr" == *"invalid --task-create DV2: metadata.subject repeats tasks.DV1 in this batch (each DV stream needs its own subject); batch refused, state.json unchanged"* ]] \
    || fail "unexpected stderr: $stderr"
  cmp .context/state.json .context/state.json.before
}

# bare_dev_literals <file>... — every bare development-N.md literal as <file>:<line text>.
# Line numbers are dropped so the allow-list matches content, not positions that drift.
bare_dev_literals() {
  grep -HnE '\bdevelopment-(N|\$\{?N\}?|[0-9]+)\.md\b' "$@" | sed -E 's/^([^:]+):[0-9]+:/\1:/'
}

# step_48_slice <SKILL.md> — the body of #### Step 4.8, through its ##### subsections.
step_48_slice() {
  awk '/^#### Step 4\.8$/ { f = 1; next } f && /^#+ / && !/^##### / { f = 0 } f' "$1"
}

# A test on the row's own path being empty is dead: --task-create refuses a DV row without one,
# so a pin gated on it never fires.
DEAD_PIN_RE='![[:space:]]*full\.metadata\??\.workspace_path|workspace_path[[:space:]]*={2,3}[[:space:]]*("|undefined|null)'

@test "AC2: reader-facing prose names no bare development-N.md beyond the producer-side allow-list" {
  cd "$PLUGIN_ROOT"
  local allow files
  # Producer-side only: the DV agent naming its own single-DV artifact, and the stage-artifact
  # map row that defines the name. Every other bare literal would send a reader to a file a
  # stream run never writes.
  allow="$(mk_tmpworkdir)/allow"
  cat > "$allow" << 'EOF'
agents/developer.md:- "Implement the DV0 task described in `development-0.md`"
agents/developer.md:  "decisions": [{"id":"dv-1","summary":"≤160 chars","ref":"development-0.md#deviations"}],
agents/developer.md:  "open_questions": [{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}' \
skills/worktask/references/handoff-protocol.md:| DV | `development-N.md` (per DV ledger task: `development-N-<stream>.md`) | yes |
EOF
  files=(agents/developer.md skills/task-folder-organization/SKILL.md
    skills/cross-plugin-handoff/templates/CORPFLOW.md skills/worktask/references/handoff-protocol.md)
  run bare_dev_literals "${files[@]}"
  [[ "$output" == *"agents/developer.md:"* ]] || fail "allow-listed literals vanished; shrink the allow-list"
  run bash -c 'printf "%s\n" "$1" | grep -vxF -f "$2"' _ "$output" "$allow"
  assert_failure 1
}

@test "B1: the pin rule is stated once, under handoff-protocol.md #### Pinning a row's tree" {
  cd "$PLUGIN_ROOT"
  run grep -rhE "^#{2,6} Pinning a row's tree$" agents skills commands
  assert_output "#### Pinning a row's tree"
  run grep -rlE "^#{2,6} Pinning a row's tree$" agents skills commands
  assert_output "skills/worktask/references/handoff-protocol.md"
  run grep -rlF 'neither row reaches the other through `blocked_by`' agents skills commands
  assert_output "skills/worktask/references/handoff-protocol.md"
}

@test "B1: SKILL.md Step 4.8 cites the canonical pin rule and has no dead empty-path condition" {
  cd "$PLUGIN_ROOT"
  run step_48_slice skills/worktask/SKILL.md
  assert_success
  [[ "$output" == *"pin the tree"* ]] || fail "Step 4.8 slice is empty or lost its pin subsection"
  [[ "$output" == *"handoff-protocol.md § Pinning a row's tree"* ]] || fail "Step 4.8 no longer cites the pin rule"
  run bash -c 'printf "%s\n" "$1" | grep -nE "$2"' _ "$output" "$DEAD_PIN_RE"
  assert_failure 1
}

@test "B1: concurrent streams sharing a tree need a pin; a blocked_by-serialized chain does not" {
  run jq -r "$PIN_RULE" "$PLUGIN_ROOT/$DV_FIX/state.pin.json"
  assert_success
  assert_output "$(printf 'DV0\nDV1')"
  run jq -r "$PIN_RULE" "$PLUGIN_ROOT/$DV_FIX/state.two-stream.json"
  assert_success
  assert_output ""
}

dispatch_step48() {
  env -u WORKSPACE_ROOT -u MILESTONE_MODE -u CONTEXT_DIR -u CLAUDE_PROJECT_DIR \
    node "$PLUGIN_ROOT/$DV_FIX/dispatch-step48.js" \
    "$PLUGIN_ROOT/skills/worktask/SKILL.md" "$1" "$2" "$3"
}

@test "pinned session serializes a later stream on its assigned tree" {
  run dispatch_step48 "$PLUGIN_ROOT/$DV_FIX/state.pin.json" DV1 pinned
  assert_success
  printf '%s\n' "$output" | jq -e '
    .state.tasks.DV1.blocked_by == ["PL0", "DV0"] and
    .state.tasks.DV1.metadata.workspace_path == "/wt/shared" and
    .skipped == true and
    ([.calls[][0]] | index("skills/worktask/scripts/state-patch.sh")) != null and
    ([.calls[] | select(.[1] == "--task-meta" or (.[0] | endswith("workspace-root-banner.sh")))] | length) == 0
  ' >/dev/null
}

@test "three pinned streams chain by numeric row id" {
  jq '.tasks.DV2.metadata.workspace_path = "/wt/shared" |
      .tasks.DV2.blocked_by = ["PL0"]' "$PLUGIN_ROOT/$DV_FIX/state.pin.json" \
    > "$WD/three.json"
  run dispatch_step48 "$WD/three.json" DV2 pinned
  assert_success
  printf '%s\n' "$output" | jq -e '
    .state.tasks.DV2.blocked_by == ["PL0", "DV1"] and
    .state.tasks.DV2.metadata.workspace_path == "/wt/shared" and
    .skipped == true
  ' >/dev/null
}

@test "unpinned session gives an independent stream its own tree" {
  run dispatch_step48 "$PLUGIN_ROOT/$DV_FIX/state.pin.json" DV1 unpinned
  assert_success
  printf '%s\n' "$output" | jq -e '
    .state.tasks.DV1.blocked_by == ["PL0"] and
    .state.tasks.DV1.metadata.workspace_path == "/wt/stream-DV1" and
    .skipped == false and
    ([.calls[] | select(.[1] == "--task-block")] | length) == 0
  ' >/dev/null
}

@test "existing transitive order remains unchanged on repeat pinned dispatch" {
  run dispatch_step48 "$PLUGIN_ROOT/$DV_FIX/state.pin.json" DV4 pinned
  assert_success
  printf '%s\n' "$output" | jq -e '
    .state.tasks.DV4.blocked_by == ["DV3"] and
    .state.tasks.DV4.metadata.workspace_path == "/wt/serial" and
    ([.calls[] | select(.[1] == "--task-block" or .[1] == "--task-meta")] | length) == 0
  ' >/dev/null

  jq '.tasks.DV1.blocked_by += ["DV0"]' "$PLUGIN_ROOT/$DV_FIX/state.pin.json" \
    > "$WD/ordered.json"
  run dispatch_step48 "$WD/ordered.json" DV1 pinned
  assert_success
  printf '%s\n' "$output" | jq -e '
    .state.tasks.DV1.blocked_by == ["PL0", "DV0"] and
    ([.calls[] | select(.[1] == "--task-block" or .[1] == "--task-meta")] | length) == 0
  ' >/dev/null
}
