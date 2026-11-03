# Test evidence

Read when executing or checking test evidence. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### Verification Command carries the runner's verbatim summary line (tpl-dv)

`## verification-command` carries the command and the summary line the runner printed, copied
byte-for-byte into the artifact or into a `.context/logs/` capture the artifact names — not a
paraphrase, a count retyped from memory, or "all tests pass".

DV and QA hold test-execution authority and no stage between them does, so once the stage closes
nobody downstream can re-derive the number; the artifact is the only record that a count was
observed. DR treats a green suite reported without the line as an unverifiable claim.

Where a runner writes its tally only to a terminal, capture through a pty or a log and copy the line
out of the capture. Where a stage's scoped authority refuses the full-suite entrypoint, record the
refusal and quote the summary line of the scoped run that was permitted.

##### summary_line is the checked half (tpl-dv)

The same line goes in the frontmatter as the `summary_line` of that runner's `tests_executed` entry;
DV and QA carry it on every entry whose `count` is non-zero. `handoff-harness.sh
--validate-frontmatter` fails an entry whose line is absent, empty, digitless, or found neither in
the artifact body nor in a `.context/logs/` capture the artifact names, one `fail:` per bad entry in
a single run. It also fails an entry from a strict runner when the line does not carry that
entry's `count` as a whole-number token (§ Strict runners fail a count-less line).

##### An xcresult summary corroborates an xcodebuild line (tpl-dv, tpl-qa)

An `xcodebuild` line composed from `xcrun xcresulttool get test-results summary` JSON is printed
by no runner, so it has a third home: a `.context/logs/*.json` capture of that JSON, named in the
artifact body, whose `totalTestCount` equals the entry's `count`, with `count` a whole-number token
of the line. A missing capture, a file that is not that JSON, or an unequal total stays a fail. The
validator reads the capture only and never runs `xcresulttool`. Suggested name:
`.context/logs/qa0-xcresult-summary.json`.

##### Strict runners fail a count-less line (tpl-dv, tpl-qa)

The strict runners are listed once, in `skills/shared/testing-strategy.md § Strict-count runners`,
with the one exception for a failing pytest run. The list covers every name that starts with
`gradle` or `junit`, in any case. For every other runner the missing token only warns, with one
`count_corroboration` audit row. A `bash-*` live script then names a `.context/logs/` capture
whose result line carries the count. `xcodebuild` stays at warn: a mixed XCTest + Swift
Testing scheme prints one tally per framework and no total.

##### Gradle and JUnit quote the junit-tally line (tpl-dv, tpl-qa)

Gradle prints no count (`BUILD SUCCESSFUL in 4s`). For a `gradle*` or `junit*` runner, run
`skills/worktask/scripts/junit-tally.sh <results-dir>` on the JUnit XML directory (Gradle:
`build/test-results/test`). Capture its line to `.context/logs/`, name that capture in the
artifact, and quote the line as the `summary_line`:
`JUnit XML tally: 58 tests executed, 0 failures, 0 errors, 0 skipped`. The executed count is
`tests` minus `skipped`, summed over the leaf `<testsuite>` elements.

##### tests_executed carries one entry per runner (tpl-dv)

A multi-runner suite (bats + swift + pytest, say) records one entry per runner invocation, each
with its own `count` and the summary line that runner printed — never a sum across runners, and
never one runner standing in for the rest: `{runner: bats, count: 1949, summary_line: "1..1949"}`
and `{runner: pytest, count: 589, summary_line: "589 passed in 41.2s"}`. The same runner run at two
scopes is two entries. A rework round writes only its own entries: the ledger keeps earlier rounds
under `tasks.<ID>.rework_runs` (`skills/worktask/references/contracts/ledger-field-notes.md § Field notes — tests_executed, rework_runs`),
so no artifact copies one forward.

#### Acceptance commands are replayed, not trusted (tpl-dv, tpl-qa)

DV lists one self-checking command per exact-output rule (CLI flags, output format, byte-level
example) under `## acceptance-commands`: a fenced `bash` block, one command per line, each
comparing real output to the expected bytes with `cmp` or `diff`. QA executes every line verbatim
and records it as `- exit=<n> <command>` under its own `## acceptance-commands`;
`skills/worktask/scripts/acceptance-check.sh --qa <testing-N.md> --dv <development-N.md>` then
decides — a listed command that was not executed, or exited non-zero, is `verdict: no-go`. A green
unit suite does not stand in for it: the contract is exactly what a paraphrase between agents
loses.

##### Each acceptance command fails closed (tpl-dv, tpl-qa)

Each command must fail closed: a missing match, a tool error or a wrong count exits non-zero. A
top-level `|| true`, `|| :`, `|| echo …` or `|| printf …` tail exits 0 whatever it found, so
`acceptance-check.sh --dv` reports it as `fail-open:` in both modes and exits 1.

Each pattern is anchored to the whole token it checks (`^T-subject:`, not `^T-subject`). An
unanchored prefix also matches a sibling added later, such as `T-subject-shape`, so the command
goes stale without failing.

##### DV runs its acceptance commands green first (tpl-dv)

DV runs every line green before it hands off. It records each run under its own heading, outside
the fence, as `- exit=<n> <command>`, and `acceptance-check.sh --dv <development-N.md>`, with no
`--qa`, checks those rows. `handoff-harness.sh --validate-frontmatter` runs the same check on every
DV artifact and fails it with one `fail: stage=DV acceptance …` line per finding. Every DV round,
rework included, re-runs and re-records the full list. QA's replay stays the trust boundary: DV's
rows are self-attested.

#### Zero executed tests must say whether the suite compiles (tpl-dv)

Each `tests_executed` entry's `count` is cases that actually ran — the number in that runner's
summary line, never the number a runner enumerated before exiting. Zero is legal; being unable to
tell zero from "never built" is not.

So when the `tests_executed` list is empty or every `count` is `0`, `test_suite_compiles` is
required: `true`, `false`, or `unknown` with the reason in the body. Compilation is checkable
without test-execution authority, which is why it is asked of the stage that was denied.

##### Why not build_status (tpl-dv)

`build_status` reports the app build, and a test target can fail to compile while the app builds
clean. `handoff-harness.sh --validate-frontmatter` fails a DV artifact whose `tests_executed` list
is empty or all-zero and carries no `test_suite_compiles`.
