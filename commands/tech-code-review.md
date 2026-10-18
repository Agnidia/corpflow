---
name: tech-code-review
description: Perform platform-aware code review using specialized developer expertise; --depth deep adds full technical-review analysis
argument-hint: '[--pr <number> | --path <dir>] [--platform <p>] [--depth surface|deep] [--focus <areas>] [--output summary|detailed] [--severity P2|P1|P0] [--ethics]'
# tools: Write and Edit are scoped to the DR findings artifact `.context/developer-review-N.md`
# (§ Output Format); the review never edits source, because DV applies every fix.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(gh pr diff:*), Bash(gh pr view:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/stream-diff.sh *)
version: 0.3.0
related:
  - agents/developer.md
  - agents/technical-lead.md
  - skills/shared/code-documentation.md
  - commands/arch-review.md
  - commands/arch-debt.md
  - commands/ethics-review.md
  - commands/estimate.md
  - skills/claude-constitution/SKILL.md
  - skills/security-review-process/SKILL.md
  - skills/shared/stage-contracts.md
  - skills/agent-coordination/SKILL.md
---

# Technical Code Review Command

A recall-first, read-only developer code review. This command is the DR (Developer Review) quality gate, run by `agents/technical-lead.md` in the worktask: it statically reviews the change for correctness, security, data-loss, concurrency, and regression risk, records findings to the DR artifact, and routes confirmed bugs back to DV. It never runs code (tests run later in QA) and never applies fixes (DV applies them).

`--depth surface` (default) is the DR review below; `--depth deep` layers a technical-review analysis on top ([Deep Mode](#deep-mode---depth-deep)). Estimation-accuracy reviews: `/estimate --review`. Ad-hoc review outside the worktask pipeline: the built-in `/code-review` or `/simplify`.

## Options

| Option | Values | Effect |
|---|---|---|
| `--platform <p>` | `apple\|android\|web\|systems\|backend\|ai\|all` | Platform context (default: auto-detect per `skills/shared/platform-detection.md`): fills the findings artifact's `**Platform**:` line and sets the idioms `patterns` and `accessibility` are judged against |
| `--path <dir>` | directory | Review that directory; the diff is scoped to it (default: the whole working-tree diff) |
| `--pr <number>` | PR number | Review the changes in that PR, § Reviewing a PR (default: none, the local diff) |
| `--depth <depth>` | `surface\|deep` | Default `surface`; the DR stage passes none, so it always resolves to `surface`. `deep` adds [Deep Mode](#deep-mode---depth-deep) |
| `--focus <areas>` | `security, performance, patterns, tests, safety, honesty, accessibility`; deep adds `quality, debt` | See § Focus Areas (default: every area the depth allows) |

### Output, severity, and ethics options

| Option | Values | Effect |
|---|---|---|
| `--output <format>` | `summary\|detailed` | Verbosity for `--depth deep` (default `detailed`); surface mode always writes the findings artifact below |
| `--severity <level>` | `P2\|P1\|P0` | Minimum severity written to the findings artifact; Phase 1 detection is never filtered by it (default: `P2`, every finding) |
| `--ethics` | — | Add the § Constitutional pass (default: off) |

## Examples

```
/tech-code-review [--pr <number> | --path <dir>] [--platform <p>] [--depth surface|deep] [--focus <areas>] [--output summary|detailed] [--severity P2|P1|P0] [--ethics]
/tech-code-review
/tech-code-review --platform apple --path Sources/
/tech-code-review --pr 42 --focus security,performance
/tech-code-review --pr 42 --severity P1
/tech-code-review --pr 42 --depth deep --focus quality,debt --output summary
/tech-code-review --pr 42 --ethics
```

## Output Format

Findings go to the DR findings artifact `.context/developer-review-N.md § Findings` (N = `task.metadata.run_index`; resolver: metadata → newest glob `developer-review-*.md`), not as inline diff comments — the command has no diff-comment tool.

Each finding carries its severity tag, names the file (and tightest line subrange), states why it is a bug, and names the scenario/inputs/environment needed for it to arise. At most one paragraph each; say so plainly when uncertain and tag `[verify-later]`. Tone matter-of-fact, neither accusatory nor flattering.

### Example findings artifact

```markdown
# Developer Code Review

**Platform**: Apple (Swift/iOS)

## Findings

### #1 [P0] Empty input crashes on load
If the input field is empty when the page loads, `parseInput` force-unwraps nil and crashes.
File: `src/client/ui/Input.tsx:42-44`

### #2 [P1] Caller in PaymentService breaks on changed return type
`fetchUser` now returns `User?`; `PaymentService.charge` does not handle nil and would dereference it.
Triggers when the user lookup misses. Read-confirmed in `PaymentService.ts`.
File: `src/server/PaymentService.ts:88`

### #3 [P2][verify-later] Possible indirect consumer via notification name
The renamed `"userDidUpdate"` notification may still be observed elsewhere; string-literal grep was
inconclusive across generated files. Not blocking.
File: `src/core/Notifications.ts:17`

## Decision

Decision: changes-requested (1 open P0, 1 open P1)
Coverage: 12 files, 34 hunks reviewed
Source: task=- stream=- source=committed reason=-
```

### Decision line (required)

End every review with:

- `Decision: changes-requested` (verdict `fail`) when any open P0 or P1 finding exists.
- `Decision: pass` when the review is P2-only or clean — record the P2 findings for follow-up but do not block.
- `Coverage: N files, M hunks reviewed`.
- One `Source: task=<ID|-> stream=<s|-> source=<label> reason=<token>` line per stream-diff block, copied from that block's header (under `--pr`, the single `source=pr:<N>` line).

These map onto the DR handoff `verdict: pass|fail` in `agents/technical-lead.md`.

## Your Job

Catch real correctness, security, data-loss, concurrency, and regression risks before they reach later review or production. The miss to guard against is a bug you were *somewhat sure* about going unreported, or reported as a throwaway non-blocking note.

| Principle | Rule |
|---|---|
| Don't default to silence | A missed defect becomes an incident; an over-cautious finding costs a reader thirty seconds. An empty findings list is earned through Phase 3 — a clean pass is valid, so never invent a token finding. Coverage (`N files, M hunks reviewed`) is the evidence. |
| Judge objectively | Flag on whether the code is at risk, not on whether the author will agree. |

### Verification stance

| Principle | Rule |
|---|---|
| Read, don't run | Static review only (`Read`, `Glob`, `Grep`, `stream-diff.sh`, read-only `git diff`/`log`/`show`, `gh pr diff`/`view`). Make up for no execution with deeper reading, never by assuming the code works. |
| Adversarial stance | For each non-trivial path, try to construct an input, state, or sequence that breaks it. |
| Absence of evidence ≠ safety | Not finding a concurrent caller or a consumer does not prove there is none. Inability to verify keeps a concern alive (BLOCKED rule). |

Find first (Phase 1), filter second (Phase 2): a concern never written down can never be caught.

## Getting the diff and context

Get the change set from `stream-diff.sh`. It is read-only on git and resolves the base per tree, so no branch name is hardcoded:

```bash
# In a worktask (.context/state.json exists): one labelled block per DV task, task-id order
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/stream-diff.sh --caller DR<N>
# Outside a worktask: this tree only
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/stream-diff.sh --tree "$PWD"
# Scoped by --path: append the pathspec to either form
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/stream-diff.sh --tree "$PWD" -- <path>
```

`--path dir` scopes to that directory; `--pr N` takes its diff from GitHub (§ Reviewing a PR). Never run `git checkout`/`reset`/`stash`, any other tree-mutating command, or anything that runs the product or its tests.

### Reviewing a PR (`--pr`)

`--pr N` reviews that PR instead of the local tree: `gh pr diff N` is the change set, and `gh pr view N --json baseRefName,headRefOid,files` gives its base, head commit and file list. Read context beyond the diff at the PR head with `git show <headRefOid>:<path>`; when that commit is not local, review the diff alone and say so in the findings. Record `Source: task=- stream=- source=pr:<N> reason=-` in place of a stream-diff header.

### Reading a stream-diff block

Each block opens with one header line; `--format names` swaps the body for `<X><TAB><path>` lines plus `?<TAB><path>` per untracked file, `--format tsv` adds each block's `tree`:

```text
stream-diff task=<ID|-> stream=<s|-> source=<committed|staged|worktree|empty> base=<name|-> base_source=<env|task|state|workspace|origin_head|unresolved> files=<n> untracked=<n> staged_also=<n> shared_with=<ID|-> reason=<-|no_changes|base_unresolved|base_unresolvable|tree_unresolved|tree_missing|not_a_work_tree>
```

#### What each header key asks of you

- `source` — `committed` is `<base>...HEAD`; `staged` is the index only; `worktree` is every uncommitted tracked edit, staged or not, against `HEAD`; `empty` is no tracked change, reviewable only through `untracked` when that is above 0. Copy it into the `Source:` line (§ Decision line).
- `reason` — `-` and `no_changes` are clean. Any other token marks a degraded block: name it in `§ Findings`, never as a clean pass.
- `staged_also` — above 0 on a `committed` block, that many uncommitted tracked edits sit outside the body: a coverage gap to record in `§ Findings`, `[verify-later]`.
- `untracked` — new files no body shows: list them with `--format names` and `Read` each under that block's tree.
- `shared_with` — same tree as a lower task, whose block carries the body: review it once.
- `base_source` — `task` is the row's own `metadata.base_ref`; `state` the ledger mirror. A `base` unlike the row's is a finding.

### Read beyond the diff

Most missed bugs live outside the hunk: broken callers, violated contracts, removed guards, renamed-but-still-referenced symbols, regressions to untouched consumers. Before judging any non-trivial change:

- Open the full changed function/type, the definitions it relies on, and any file the diff references but does not modify when behavior depends on it.
- Grep and read the consumers of anything changed — a signature; a default, constant, config literal, threshold, or enum case; or a caller-observable behavior change inside a body (different return for the same input, new early return, changed ordering or side effect). An unchanged signature does not exempt a behavior change.

#### Dynamic references and the intent check

- Name-based grep misses indirect use. For any changed public or serialized symbol, also search its name as a string literal and the indirect-dispatch sites: selectors / `#selector`, `NotificationCenter` names, KVO keypaths, serialized JSON/plist/DB keys, DI or registration tables, reflection, codegen inputs. If indirect use is plausible and you cannot prove it absent, keep a located finding naming the suspected indirection.
- Intent check: where a spec exists (`.context/planning-N.md`, the linked issue/PR body), list every acceptance criterion and stated edge/error/validation requirement and verify the diff satisfies each one. An unmet stated requirement is a P1 correctness finding even if the implemented path is correct.

## Review Methodology

Three decoupled phases: detection finds widely, filtering suppresses, self-verification proves coverage. Collapsing detection into filtering is how the somewhat-sure bug gets dropped before it is written down.

### Phase 1 — Detection

List every plausible concern, with no confidence bar and no "would the author fix it" test — over-inclusion is correct here; Phase 2 filters.

#### Depth gate — scale scrutiny to change size

Small diff (≤10–15 changed lines, single file): one focused sweep against the classes plausibly implicated plus a one-line "other classes: n/a"; skip the per-class "none" list and the riskiest-hunk narrative. Medium / large / architecturally significant diff: the full sweep with per-class accounting and more surrounding-context reading — past ~400 changed lines fatigue rises, so slow down.

For each changed hunk, first reason briefly (scratchpad, not the artifact): what is this code supposed to do; trace the main path plus at least one error / empty / null / boundary / concurrency path; what does it assume about its callers? Then sweep it against the 13 bug classes, one lens each. On a medium/large diff decide every class explicitly — a hit becomes a candidate, a clean class is noted "none".

#### Bug classes 1–4

| # | Bug class | Lens |
|---|---|---|
| 1 | Correctness vs. intent | Logic errors, inverted conditions, wrong operator, copy-paste slips, and any acceptance criterion from the intent check left unimplemented. |
| 2 | Edge cases | Empty/null/zero/negative/very-large inputs, single-element collections, first/last iteration. |
| 3 | Nil / optionals / unwraps | Force-unwraps, non-null assertions, missing nil checks, removed load-bearing guards. |
| 4 | Error handling & failure paths | Swallowed exceptions, generic catches, unchecked error returns, partial failure leaving inconsistent state, missing rollback. |

#### Bug classes 5–8

| # | Bug class | Lens |
|---|---|---|
| 5 | Concurrency / races / ordering | Shared mutable state, check-then-act, missing locks/await, actor isolation, lock ordering, reentrancy, await-point invariants. For any change touching shared / static / instance mutable state, establish the concurrency context: grep call sites for thread/queue/task/actor/async usage. Failing to show it is single-threaded does not disprove a race. |
| 6 | Resource lifecycle / leaks | Unclosed handles/streams/connections, retain cycles, missing dispose/defer, leaked tasks/observers. |
| 7 | Boundary / off-by-one | Indexing, range bounds, slicing, loop terminators, integer overflow/truncation. |
| 8 | Input validation / security | Unsanitized input in file/command/query/HTML, authz/authn checks, secrets in code/logs, injection, unsafe deserialization, missing bounds on external data. |

#### Bug classes 9–12

| # | Bug class | Lens |
|---|---|---|
| 9 | API contract & compatibility | Changed signature/return type/nullability/error semantics; renamed or removed symbol still referenced (statically or via the dynamic-dispatch sites above); broken public/serialized contract. |
| 10 | State / persistence / migration | Schema/migration correctness, default values, data-loss on write, cache/state coherence, idempotency. |
| 11 | Performance cliffs | Accidental O(n²), N+1 queries, work in hot loops, unbounded growth, blocking the main thread. |
| 12 | Regressions to existing behavior | A previously-working path changed, including a latent path this change newly activates. A changed default/constant/threshold that alters an untouched consumer is the classic silent regression — verify those consumers. |

#### Bug class 13 — hallucinated dependencies

| # | Bug class | Lens |
|---|---|---|
| 13 | Hallucinated dependencies | Imports/requires/`use`s resolving to no declared dependency (Package.swift/Podfile/`*.gradle`/package.json/requirements.txt); invented API methods or plausible-but-absent symbols; calls into an API removed in the resolved version. The diff is AI-generated, and a fabricated symbol can type-check locally yet resolve to nothing at build time. |

### Phase 2 — Verification and filtering

The only place you suppress. For each candidate, state the concrete trigger (the input/state/environment under which it bites), then try to confirm it by reading the relevant code (caller, definition, other file, dynamic-dispatch site) — that reading is what promotes a suspicion to a blocker. Drop a candidate only if you can disprove it or it is trivial style with no impact on meaning or behavior. Being unsure lowers the severity; it does not drop the finding.

#### BLOCKED-verification rule

If verification is blocked — caller/consumer/threading model not readable, file generated or outside the workspace, fan-out too large, reference dynamic and unprovable — you have not disproved the concern. Keep it, name what you could not verify, and tag `[verify-later]`. Lack of access never drops a correctness, security, concurrency, or regression concern.

#### Keep / drop bar

Report a candidate when it (a) meaningfully impacts accuracy, performance, security, or maintainability; (b) is discrete and actionable, not "the whole module is messy"; (c) does not demand rigor absent from the rest of the codebase; (d) was introduced or newly activated/exposed by this change; (e) is a real risk to correctness, security, or users, judged objectively; and (f) is clearly not an intentional, documented change by the author.

##### What to keep

- Keep any concern touching correctness, security, data-loss, concurrency, resource leaks, contract breaks, or regressions when it is plausible and you can articulate a trigger, even at moderate confidence. It may rest on a stated, reasonable inference about intent.
- Keep a clearly-reasoned cross-file / integration / ripple risk you cannot prove, provided you name the specific other code you suspect and why. Hedge the wording.

##### Style bar, pre-existing cap, systemic defects

- Raise the bar only for low-severity style / maintainability items: report one only if a competent reviewer would clearly endorse it, and skip trivial style unless it obscures meaning or violates a documented standard. Over-documentation violating `skills/shared/code-documentation.md` (doc-comment essays, design-history narration, audit logs, call-site enumerations, AC-/REQ-/issue-ID tags, commented-out preview/story/fixture blocks) is a P2.
- Pre-existing-weakness cap (class 12): a pre-existing weakness blocks (P0/P1) only if this diff makes the broken path newly reachable and you can name the new entry point. Otherwise record P2 `[verify-later]`, noted "pre-existing, exposed by this change."
- A bug spanning several hunks is in scope — report it as one finding describing the pattern.

#### Severity routing for uncertain findings

- P1 (blocking) when you are somewhat sure or more that it is a real defect and it is of a class a normal test run rarely exercises — concurrency races, rare-edge nil/unwrap crashes, regressions to untouched paths, indirect-dispatch contract breaks. Tests will not rescue these, so a non-blocking note turns a likely-real bug into a guaranteed miss. Requires a read-confirmed trigger or a directly-cited contradiction in the caller/contract you read.
- P2 `[verify-later]` (non-blocking) when a normal test run would exercise it, or it is a located suspicion you could not confirm by reading (blocked or inconclusive). An unproven cross-file suspicion stays P2 until reading the cited code confirms the break.

### Phase 3 — Self-verification

Before writing output (on a small diff, steps 2–3 collapse to one line confirming the implicated classes were considered):

1. Coverage: confirm you examined every changed file and hunk; go back for any you skipped. This backs the coverage statement.
2. What did I miss: re-read the full diff against the 13 classes. Treat your own silence as a warning sign, but do not manufacture a finding to break it.
3. Highest-risk hunks: for the 1–3 riskiest changes (medium/large diffs), answer "what is the most likely way this breaks in production?"
4. Keep a one-line reason, in your reasoning, for anything considered and dismissed.

## Severity scheme (P0/P1/P2 — canonical)

Tag every kept finding with one P-level.

| Canonical | Definition |
|-----------|------------|
| **P0** (blocker) | Crash, data loss/corruption, security vulnerability, broken build/contract, or a regression to core behavior. High confidence. |
| **P1** (high) | Likely-incorrect behavior, unhandled error/edge path, concurrency hazard, resource leak, contract risk, or an unmet stated acceptance requirement, with a read-confirmed or directly-cited trigger (or a hard-to-test class you are somewhat-sure-or-more about, per the routing rule). |
| **P2** (nice-to-have / suspected) | Lower-impact issues, unproven-but-located suspicions, blocked-verification concerns, change-exposed-but-not-newly-reachable pre-existing weaknesses (tagged `[verify-later]`), minor maintainability. |

## Dependency Upgrade Review

When the change touches a manifest (`Package.swift`, `Podfile`, `*.gradle`, `requirements.txt`, `package.json`, …) or its lockfile, review it like feature code: a bump is a behavior change you did not write, and bulk bumps are the riskiest. Supply-chain verdicts belong to the `security-review-process` skill.

| Rule | Why |
|------|-----|
| Read each bumped dependency's changelog (migration notes for a major), not its version number — every bumped package, not just the riskiest-looking | A "patch" can carry behavior change |
| One dependency per change | A bulk bump that breaks the build hides which package did it |
| Check DV's test evidence | Suite green after the bump in DV's report, not "it resolved"; missing evidence or thin coverage is a finding for DV/QA |
| Mind the transitive graph | Review the lockfile / transitive diff, not just the manifest |
| Keep the lockfile honest | Committed, diff reviewed, never hand-edited — it pins what ships |

## Escalation to DV (changes-requested → DV fix → DR re-review)

A read-confirmed P0/P1 (read-confirmed trigger or directly-cited contradiction) makes the verdict `fail` and goes back to DV; DR then re-verifies the fix. A P2 `[verify-later]` suspicion is non-blocking: surfaced in `§ Findings` for QA follow-up, never a DV escalation.

### How to escalate (reuse existing machinery)

1. Set the DR run `verdict: fail` — this is the escalation. On a DR rejection the orchestrator re-dispatches DV with the DR findings verbatim (`run_index` unchanged, `retry_count` up by 1); see `skills/worktask/SKILL.md § Orchestrator Execution Loop` and the `…DR→DV…` chain in `skills/agent-coordination/SKILL.md § Error Handling`.
2. Record the sound findings in `.context/developer-review-N.md § Findings` — the artifact the DV retry prompt reads — one entry per finding naming the file, the trigger, and what must change.

#### Escalation step 3 — optional tracking block

3. If you also append a `## DR[N] Retry — <ts>` block to `.context/errors/developer.md`, give it a `### Resolution Path` with one bullet per sound finding and `**Classification**: missing_input` — besides `exhausted`, the only classification the Retry/Escalate Matrix routes to the previous stage (DV). `logic` re-runs the DR reviewer and `ambiguous_requirements` routes to PL. The block is tracking only; step 1 is the mechanism.

### Re-review after a DV fix

When DR runs again on a DV fix (`retry_count` above 0), read the previous run's `developer-review-N.md § Findings` before you overwrite it:

- Each earlier P0/P1 is fixed in the new diff, or answered in the DV artifact with a reason you accept; otherwise it stays open.
- Changes beyond what the findings asked for get the full review as new code, not a pass as part of the fix.
- A finding you now drop says why in its entry, never disappears silently.

### DR3.5 reconciliation

`agents/technical-lead.md § DR3.5` (test-selection parser warnings: `unknown_symbol`, `missing_marker`, malformed `@depends-on:`) routes to DV by the same two mechanisms, since those warnings concern DV-owned test markers. Either way DV fixes and DR re-reviews the new diff as a fresh run, repeating until no open P0/P1 remains.

## Review Dimension Routing

Suggested `--focus` sets by change type:

| Scenario | Recommended Dimensions |
|----------|----------------------|
| API endpoint changes | security, performance, patterns |
| UI component changes | patterns, tests, accessibility |
| Data model changes | security, performance, patterns |
| Auth/payment flows | security, safety, tests |

## Focus Areas

| Focus | Covers |
|---|---|
| **security** | Authentication, data storage, input validation, secrets, supply chain. Deep mode adds OWASP Top 10, authorization, data protection, secure coding practices. |
| **performance** | Memory, CPU, network, battery. Deep mode adds Big-O complexity, resource management, caching, hot-path optimization. |
| **patterns** | Platform idioms, design patterns, architecture |
| **tests** | Coverage, quality, edge cases |
| **safety** | Harm potential, user protection, error handling for safety-critical paths |
| **honesty** | Truthful comments, accurate error messages, non-deceptive UI patterns |
| **accessibility** | WCAG compliance, VoiceOver/TalkBack support, Dynamic Type |

### Deep-mode focus areas and the safety/honesty format

| Focus | Covers |
|---|---|
| **quality** *(deep)* | Cyclomatic/cognitive complexity, duplication, naming clarity, error-handling completeness, documentation adequacy |
| **debt** *(deep)* | New debt introduced, existing debt affected, interest-rate assessment, remediation. Codebase-wide inventory: `/arch-debt`. |

`--focus safety` and `--focus honesty` findings use the same entry format and P-scale in `§ Findings`, numbered `#S-01` / `#H-01`, and add two lines: the harm or violated property (`Potential harm: SQL injection, data corruption. Affected: all users submitting profile updates.` / `Property violated: truthful, forthright.`) and a concrete recommendation.

### Constitutional pass (`--ethics`)

`--ethics` adds a constitutional pass. `Read` `skills/claude-constitution/SKILL.md` § Honesty Properties and `skills/claude-constitution/references/harm-framework.md` § Hard Constraints (Absolute Limits), then check the change against both: what the product can be used to do, and what its user-facing text, comments and error messages assert. Report hits in the `#S-` / `#H-` format above; a hard-constraint hit is P0.

## Deep Mode (`--depth deep`)

`--depth deep` runs the full surface review and then appends the analysis below, without altering the surface findings, verdict, or DV-escalation loop. Emit these sections with the tables specified (status cells use ✅ / ⚠️):

```markdown
# Technical Review (deep)

## Summary
| Dimension | Score | Status |  — Correctness, Readability, Maintainability, Efficiency, Security, Testability (n/10)
**Overall**: n/10 — one-line merge verdict

## Code Quality Analysis
Complexity:  | File | Cyclomatic | Cognitive | Status |
Duplication: | Pattern | Occurrences | Impact |
Naming:      | Issue | Location | Suggestion |

## Performance Analysis
Hot paths:   | Path | Complexity | Concern |   — e.g. `searchUsers()` | O(n²) | ⚠️ optimize
Resources:   | Check | Status | Notes |        — memory allocation, connection handling, file handles
Caching:     one bullet per candidate with call frequency and why it is cacheable
```

### Deep template — security, debt, coverage

```markdown
## Security Implementation
OWASP:       | Check | Status | Notes |        — input validation, output encoding, authn, authz, data protection, logging
Vulnerabilities: | Risk | Severity | Location | Remediation |

## Technical Debt Identified
New debt:    | Item | Type | Interest | Effort |
Existing:    | Item | Change | Recommendation |

## Test Coverage Impact
| Metric | Before | After | Status |            — line, branch, changed-code coverage
Missing test cases: one bullet each
```

`--output summary` emits the Summary table plus one bullet per section's top finding; `detailed` emits every table.
