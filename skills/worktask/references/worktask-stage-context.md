---
name: worktask-stage-context
---

# Worktask Stage Context

Canonical source for the pipeline shape and each stage's role. Agents carry only their own
one-line `**Stage**:` marker and read this file on demand, not on every stage run. Stage codes,
agents, and model assignments: `skills/worktask/references/stage-codes.md`.

## Pipelines

```
9-stage:   PL → AR → TL → DV → DR → QA → DC → FN → ST
11-stage:  PL → AR → TL → DV → DR → SR → QA → DC → RE → FN → ST
Emergency: IR → DV → DR → QA → RE → FN
```

The 11-stage (full/secure) set adds SR after DR and RE before FN. PL0 sizes which stages run by
complexity score: AR is a tier default at score ≥11 that PL0 may override either way, TL runs only
when PL0 splits the work across ≥2 developers, DC stays tier-driven. Criteria:
`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria (PL0 authority)`.

## Stage Roles

| # (11) | Code | Stage | Role |
|--------|------|-------|------|
| 1 | PL | Planning | Turn the request into a requirements + acceptance-criteria plan and size the stage set. |
| 2 | AR | Architecture | Design the technical solution, ADRs, and test architecture from the plan. |
| 3 | TL | Team Lead | Coordinate the implementation approach and decide any intra-issue DV split. |
| 4 | DV | Development | Implement the planned changes (developer routes to the platform specialist). |
| 5 | DR | Developer Review | Gate code quality with a read-only developer review before QA. |
| 6 | SR | Security Review | Assess security/OWASP exposure of the change (11-stage / secure only). |

### Stages 7–11

| # (11) | Code | Stage | Role |
|--------|------|-------|------|
| 7 | QA | QA Testing | Select and run tests, add edge-case coverage, verify acceptance. |
| 8 | DC | Documentation | Update code docs, README, and project docs for the change. |
| 9 | RE | Release Engineering | Prepare versioning, changelog, and release artifacts (11-stage only). |
| 10 | FN | Finalization | Aggregate stage artifacts, verify QA's recorded test evidence is green (executes nothing), summarize, and open the PR. |
| 11 | ST | Stakeholder | Final business acceptance — approve for release or request changes. |

## Support Stages (on demand)

| Code | Stage | Role |
|------|-------|------|
| IR | Incident Response | Own the `/worktask --emergency` flow: triage, root cause, hotfix coordination. |
| DS | Design | UX/UI design input across PL/AR/DV/QA when `--with-design`. |
| TC | Technical Review | On-demand deep technical-lead review (AR/TL/DV/QA). |
| ET | Ethics Review | On-demand constitutional/harm review (any stage). |
| PE | Prompt Engineering | Agent/prompt optimization (meta-tooling). |
| WE | Workflow Engineering | Worktask state-machine and state-ledger troubleshooting. |
