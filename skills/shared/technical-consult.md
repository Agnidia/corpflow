---
name: technical-consult
---

# Technical Consult (TC) Reference

Read on demand by `agents/technical-lead.md` when answering a technical consult (stage TC) on technology choice, tech debt or implementation risk; "you" below is the technical lead. `agents/team-lead.md` branches on the § TC Return Contract block. The DR review never needs this file.

## Technology Evaluation Framework

Prefer, in order: battle-tested (mature, documented, proven, strong community), then serious newcomers (established vendor, clear maintenance commitment). Avoid anonymous, untested, unmaintained, or deprecated technologies.

Score options with the weighted criteria in `commands/arch-decision.md § Evaluation Framework` (team expertise 20%, then community, viability, performance and security at 15% each, integration and cost at 10%). TDR template and the full decision worktask: `commands/arch-decision.md`. Non-markdown documents or document URLs: use pandoc (`skills/shared/pandoc-ingestion.md`).

## Technical Debt Management

Score each debt item 1-5 per PAID dimension: Principal (cost of the shortcut), Accumulated interest (ongoing maintenance burden), Impact on delivery (feature slowdown), Dependency risk (cascade to other systems).

| Type | Interest | Priority Action |
|------|----------|-----------------|
| Security | Critical | Fix now |
| Architecture | High | Schedule (escalate to AR stage) |
| Code | Medium | Fix now or schedule |
| Test | Medium | Schedule |
| Dependency | Variable | Track or schedule |
| Documentation | Low | Track or accept |

The 20% rule: allocate 20% of sprint capacity to debt reduction, high-impact low-effort first, linking items to business metrics (customer issues, maintenance time) to prioritize by actual impact.

## Technical Risk Assessment

| Category | Examples | Mitigation |
|----------|----------|------------|
| Complexity | Tight coupling, deep nesting | Refactor, simplify |
| Performance | O(n²) algorithms, memory leaks | Profile, optimize |
| Security | Injection, auth weaknesses | Review, harden |
| Dependency | Abandoned libraries, CVEs | Update, replace |
| Scalability | Single points of failure | Design for scale |

Assess each by likelihood × impact (High/Medium/Low); document indicators, mitigation steps, contingency plans.

## Callers


| Called From | Trigger → Purpose |
|-------------|-------------------|
| AR | Technology choice → evaluate options, recommend approach |
| TL | Technical risk → implementation risk analysis |
| DV | Complex implementation → deep guidance, pattern advice |
| QA | Quality concern → code quality deep dive |
| Any | Tech debt decision → prioritization, remediation plan |

Only `team-lead` holds the `Agent(corpflow:technical-lead)` grant today. The AR/DV/QA rows (mirrored in `skills/worktask/references/stage-codes.md § Support Agents` and `worktask-stage-context.md § Support Stages`) record intent, not a wired dispatch path.

## TC Return Contract

A TC consult returns advice, not a stage handoff, so it carries its own machine-readable verdict, emitted as the last fenced block of your final message so the caller can branch without reading your prose:

```yaml
tc_review:
  tc_verdict: approve          # approve / reject / conditional
  summary: "<=160 chars — the recommendation itself, not a restatement of the question>"
  anchor: "<artifact.md#section | path:line-range>"   # where the caller reads the decision and its evidence
  conditions: []               # required and non-empty when tc_verdict: conditional
  confidence: high             # high / medium / low
```

Each `conditions[]` entry: `{ id: tc-1, must: "<the single action that flips this to approve>", anchor: "<path:line>" }`.

### Verdict semantics — what the caller does

| `tc_verdict` | Caller action |
|--------------|---------------|
| `approve` | Proceed with the reviewed approach; TC raises no blocker. |
| `reject` | Don't proceed. `summary` + `anchor` carry the reason; the caller picks another option or escalates. |
| `conditional` | Proceed only if every `conditions[].must` is satisfied first — each one discrete and checkable, never "read the prose anyway". |

A `conditional` with empty or absent `conditions[]` is malformed and the caller treats it as `reject`, so emit it only when you can enumerate the conditions. `confidence` is advisory — it never changes the branch, only whether the caller seeks a second opinion.

### TC verdict is not the DR handoff verdict

Distinct key, enum, and lifecycle — keep them separate:

| | DR `handoff.verdict` | TC `tc_review.tc_verdict` |
|---|---|---|
| Key | `verdict`, in the `handoff:` frontmatter of `developer-review-N.md` | `tc_verdict`, in a `tc_review:` block in the consult's return message |
| Enum | `pass` / `fail` (`skills/worktask/assets/templates/template-dr.md#tpl-dr`) | `approve` / `reject` / `conditional` |
| Lifecycle | Patched into `state.json` by `state-patch.sh`; drives the retry/escalate matrix | Advisory, read by the calling agent; never patched into the ledger |

Don't unify the keys or reuse `pass`/`fail` for TC: `state-patch.sh` reads `.handoff.verdict` (awk fallback: a `verdict:` line), so a shared key would make an advisory consult look like a stage gate to the ledger tooling.

State ledger: stage TC (support agent) — a consult produces no `tasks.TC*` entry and no handoff edge (`skills/worktask/references/state-ledger.md`).
