---
name: estimation-methodology
description: Use when estimating task complexity, effort, hours, or budget, or determining worktask tier and PL0 stage set. Complexity scoring (0-50 scale), T-shirt sizing, and mid-run stage escalation for project estimation.
version: 0.4.0
related:
  - ../cost-optimization/SKILL.md
  - ../worktask/SKILL.md
---

# Estimation Methodology

## Calculator Script (canonical math path)

`scripts/estimate-calc.py` does the arithmetic; you supply the judgment inputs (T-shirt size,
factor scores). Use it instead of working the formulas by hand.

### Invocation

```
python3 ${CLAUDE_PLUGIN_ROOT}/skills/estimation-methodology/scripts/estimate-calc.py \
  --size <XS|S|M|L|XL> [--level <junior|mid|senior|expert>] [--multiplier <h>] \
  [--rate <hourly>] \
  [--factors <f1> <f2> <f3> <f4> <f5>] \
  [--tokens <n>] [--input-tokens <n>] [--output-tokens <n>] [--model <haiku|sonnet|opus|fable>] \
  [--retry-complexity <low|medium|high>] [--codebase-type <standard|large|novel>] \
  [--phase-hours <min> <max>]
```

### Output

One JSON line, numbers only — `sp`, `multiplier_h`, `base_hours`, `buffer_pct`, `total_hours`,
`budget` (with `--rate`), `phase`, `ai_cost` (with `--tokens`), `complexity` (the factor score and
its band, with `--factors`).
`--self-test` alone runs the built-in checks.

The sections below are the specification the script implements. Estimation-run procedure, phase
distribution, re-estimation triggers, AI cost factors: `references/estimation-run.md`; the
platform adjustment tables the review step applies: `references/estimate-review.md`; business-case,
status-report and budget-approval skeletons for ad-hoc stakeholder requests: `references/business-case.md`.

## T-Shirt Sizing → Story Points (Range)

| Size | SP Min | SP Max | Hours Min | Hours Max |
|------|--------|--------|-----------|-----------|
| XS | 1 | 1 | 6 | 6 |
| S | 2 | 3 | 12 | 18 |
| M | 4 | 5 | 24 | 30 |
| L | 6 | 10 | 36 | 60 |
| XL | 13 | 21 | 78 | 126 |

## Story Points to Hours

`Hours = SP × multiplier`, applied to SP Min and SP Max independently.

| Level | Multiplier | Use When |
|-------|------------|----------|
| Junior | 10h | New to platform/domain |
| Mid-level | 8h | Familiar with stack |
| Senior | 6h | Default |
| Expert | 4h | Deep specialization |

## 5-Factor Score

Score each factor 1-5. The factor score is their sum (0-25): 0-10 LOW, 11-17 MEDIUM, 18-25 HIGH.
It sizes an estimate; the complexity score PL0 sizes a worktask with is the separate 0–50 score
in § PL0 Stage-Set & Test-Mode by Complexity Score.

| Factor | Description | Score 5 = |
|--------|-------------|-----------|
| Technical Complexity | Algorithm difficulty, new tech | AR/ML/real-time |
| Integration Points | APIs, SDKs, databases | 4+ external SDKs |
| Risk Level | Security, data, user impact | Financial/health data |
| Unknowns | Unclear requirements | R&D heavy |
| Domain Expertise | Specialized knowledge | Niche specialty |

## Phase Constraints

At most 4 weeks (~160 hours) per phase, to keep delivery predictable. Split anything longer into
sub-phases: redistribute features, chain the dependencies.

## Test Integration

Tests belong to each subtask, never a separate phase: `[Task description] + tests` —
"Implement login + tests" (28h), not "Implement login" (20h) plus a separate "Write login tests"
(8h) or a standalone "Unit Tests" phase.

## Buffer Calculation

Add 15% buffer to base hours. Every line below applies to Min and Max independently.

```
Base Hours  = Total SP × multiplier    (6h = senior default)
Buffer      = Base Hours × 0.15
Total Hours = Base Hours + Buffer
Budget      = Total Hours × Rate
```

The buffer covers SDK integration surprises, third-party API changes, client feedback cycles,
bug fixes and polish.

## Worktask Tier Selection

Canonical tier logic. Tier is decided by what the request touches first, and only then by size.

```
# 1. Surface check — beats size, and reads the request
IF the request names credentials, tokens, secrets, PII, payments,
   authn/authz, or untrusted input as part of what it asks for:
  → /worktask --secure     (regardless of size)
ELIF the request describes something broken right now and still failing:
  → /worktask --emergency  (regardless of size)

# 2. Otherwise, size decides
ELIF size == XL:
  → split into ≤ L sub-tasks first
ELSE:
  → /worktask   (PL0 dynamic sizing selects which of the 9 stages run)
```

### What the two escalations are not

`--secure` is not "security-adjacent". Hardening a lint, adding a deny-list guard, or renaming a
branch touches no protected asset — standard tier. The test is whether the request names a secret
or an untrusted input, not whether the word "security" appears nearby. Security-sensitive work
runs the full 11-stage pipeline.

`--emergency` is not "urgent-sounding". A task that has stopped — wedged, abandoned, a batch that
ran away and ended — is standard work. The test is whether something is failing as you write the
plan. A task both stuck and still failing escalates.

#### A surface you discover does not raise the tier

The tier follows the request, never the findings. A search that reaches a secret-handling file
has learned something about the repo, not about what was asked for — almost every file in a
plugin sits near one. Escalating on discovery also makes the tier undecidable at plan time: two
searches of the same repo find different things, so the same request would route differently.

Name what you found in the plan body — a discovered credential path is worth stating and may
well change the work. It does not change the flag.

#### A synthetic asset is not evidence about the asset the request names

The request naming a protected asset is the surface. Learning that the credential is a test
fixture, the key a planted specimen, or the values already fake describes what the repo holds,
not what was asked for. A secret scanner, a rotation runbook and a key-handling path all look
synthetic from inside their own test data; routing them standard puts the work that handles
secrets on the pipeline that does not review them. None of those observations downgrade the
tier.

Name the finding in the plan body — that a specimen is planted is worth stating. It does not
lower the flag.

#### A quiet local tree is not evidence about the failure being reported

The present-tense report in the request is the evidence. A clean worktree, an absent
`.context/`, no live `state.json`, or a green local test run say nothing about the environment the
user is describing — they describe this checkout, which is not the one that is failing.

None of them downgrade a reported live failure, and none of them settle the surface check either
way. If a local observation genuinely changes the tier, name the observation and say what it rules
out; absence of local wreckage rules out nothing.

## PL0 Stage-Set & Test-Mode by Complexity Score

PL0 uses the 0–50 complexity score to pick the stage set and the default `test_mode`
(`skills/worktask/references/pl0-procedure.md § Dynamic Worktask Sizing (PL0 Stage)`, which owns
the `skipped_stages` / `added_stages` stamping, and `§ Required Metadata: Test Selection Gate`).

### Stage set table

| Score | Tier | Stages created |
|-------|------|----------------|
| 0–10 | Low | DV0, DR0, QA0 |
| 11–20 | Medium | AR0*, DV0, DR0, QA0, FN0, ST0 |
| 21–30 | Moderate | AR0*, DV0, DR0, QA0, FN0, ST0 |
| 31–40 | High | AR0*, DV0, DR0, QA0, DC0, FN0, ST0 |
| 41–50 | Critical | AR0*, DV0, DR0, SR0, QA0, DC0, RE0, FN0, ST0 |

\* AR0 is the tier default — PL0 may override it per Stage Inclusion Criteria.

\+ TL0 — only when PL0 splits the work across ≥2 developers (see Stage Inclusion Criteria)

### Stage Inclusion Criteria (PL0 authority)

PL0 makes both decisions during planning, before the plan-approval gate, and surfaces them in
the gate summary. DV0, DR0, QA0 are the floor and are never removable. Record every decision as a
`metadata.skipped_stages` / `metadata.added_stages` entry (`{stage, reason}`); reasons are one
sentence, decision-shaped, not scores.

AR0 — tier default (score ≥11) with PL0 override.
PL0 may exclude it only when all hold: change follows existing patterns; no new interfaces or
schemas; confined to one module; no open design questions.
PL0 includes it at any tier, Low included, when any holds: new module/service/public API/schema
surface; ≥2 viable design approaches needing a recorded decision; cross-cutting integration
(≥3 files across ≥2 subsystems); patterns novel to this codebase; security- or
data-model-relevant structure.

#### TL0 criterion

TL0 — decision-only, never a tier default. Include TL0 only when the work must be split across
≥2 developers/engineers: parallelizable workstreams, multiple DV specialists (mixed-platform DV),
or external-plugin fan-out requiring coordination/merge. Single workstream + single DV agent → no
TL0, at any score.

TL0 without AR0 is allowed (prev edge PL→TL); AR0 at Low tier is allowed (`added_stages`).

### Default test_mode by score

Combine with marker coverage; PL0 stamps `metadata.test_mode`:

| Score | Default `test_mode` | Override |
|-------|---------------------|----------|
| 0–10 (Low) | `build-only` if marker coverage ≥ 50%, else `scoped` | `full` only if stakeholder requests |
| 11–25 (Medium) | `scoped` | `full` if multi-module diff |
| 26–50 (High/Critical) | `full` | — |

### Mid-run re-sizing (one-way ratchet)

Sizing is decided once, at PL0, and the plan gate freezes it. The one sanctioned exception is a
downstream stage discovering a surface PL0 could not have seen: it stops, says so, and returns a
`requests_stage_escalation` object in its artifact `handoff:` frontmatter. It never patches the
ledger — the orchestrator performs the write through the existing `state-patch.sh --task-create` /
`--task-block` operations and records `{stage, reason}` in `metadata.added_stages`.

Nothing downgrades mid-run: no stage is removed, and no complexity score is revised downward to
shed one. Scores freeze at the plan gate, or every High run re-argues its way to Critical.

#### Escalation schema

```yaml
requests_stage_escalation:
  stage: SR                    # a code from skills/shared/stage-codes.md
  falsified: "<verbatim quote from metadata.skipped_stages[].reason>"
  discovered: "<the tree fact PL0 could not have known, with file:line>"
  reason: "<200 chars or fewer>"
```

An artifact field, like `requests_test_evidence` — never a ledger key; `state-patch.sh` gates
`--facts` to a fixed key set and would reject it.

#### The four fire conditions — all four, or it does not fire

1. **Surface, not size.** The work touches a surface whose stage the inclusion criteria mandate:
   credentials, authn, or untrusted input → SR; release artifacts → RE; a protected population or
   an automated user-facing decision → ET. "It feels bigger" is not a surface.
2. **Undiscoverable at PL0.** Found in the tree, not re-derived from the plan's own text. If the
   plan names it, the answer is "do the work", never "add a stage".
3. **A recorded reason is falsified.** Quote the exact `skipped_stages[].reason` being refuted,
   verbatim, so it is greppable against `state.json`. A stage PL0 declined without recording a
   reason cannot be escalated against at all.
4. **No planned stage can absorb it.** A fresh reviewer could reject this work while approving its
   neighbour.

#### Structural caps

- **One per stage task, one accepted per run.** A second distinct surface discovery means the plan
  itself is wrong, so the orchestrator stops at the human gate instead of growing the pipeline.
- **Only stages in the canonical set** — never a second instance of a stage, a re-order, a
  removal, or a re-scored complexity number.
- **Valid at AR, TL, DV\*, DR, and QA only.** At PL, DC, FN, or ST the answer is a follow-up
  issue.
- **Not where a channel already exists**: runtime evidence is `requests_test_evidence`, a second
  opinion is DR's job.
- **Calibration is auditable.** ST0 reads `added_stages` for escalation entries; firing in more
  than one run in five means PL0 sizing is mis-calibrated.

#### What the ratchet is not

It is not a re-plan. Requirements, acceptance criteria, and scope stay unchanged — only the stage
set grows. Work that needs the plan rewritten goes back to the human gate.

## AI Agent Cost Estimation

Token bands by task type. Est. AI Cost is `scripts/estimate-calc.py` at the default split before
retry and complexity multipliers: the low end at the cheaper model of the mix, the high end at the
dearer (mixed = sonnet to opus).

| Task Type | Typical Tokens | Model Mix | Est. AI Cost |
|-----------|----------------|-----------|--------------|
| Trivial | 5,000-10,000 | haiku/sonnet | $0.01-0.04 |
| Simple | 15,000-30,000 | sonnet | $0.05-0.11 |
| Standard | 60,000-120,000 | mixed | $0.22-0.86 |
| Complex | 150,000-300,000 | mixed | $0.54-2.16 |
| Large | 300,000+ | mixed | $1.08+ |

### AI Budget Planning Formula

```
AI Cost = (Input Tokens × Input Rate + Output Tokens × Output Rate)
          × (1 + Retry Factor) × Complexity Multiplier
```

The default input:output split, the factor values and where the rates live:
`skills/cost-optimization/SKILL.md § Cost Estimation Formula`.

Codebase/files/tests/docs/retries/context multipliers, the human-vs-AI scale check, and the
AI-cost-vs-dev-time tradeoff table: `references/estimation-run.md`.
