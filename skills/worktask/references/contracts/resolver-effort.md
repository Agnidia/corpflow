# Resolver effort

Read when executing or checking resolver effort. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Closing Elicitation Sweep](sweep-boundaries.md#closing-elicitation-sweep)

<!-- canonical-body:start -->
## Resolver Effort Tier

How the Step C.0a resolver's effort tier is chosen, transported and clamped. It sits outside
§ Closing Elicitation Sweep because that section is strict with no rollout tiers, while effort
transport is advisory on one of its two surfaces.

### Why a tier up, and why the same model

The item exists because the stage could not settle it at its own tier; re-asking at the same effort re-runs the reasoning that already declined, and one rung up is the cheapest thing that is actually different. The model is unchanged: the stage's assignment already reflects the work's difficulty, and swapping it would change two variables to explain one outcome.

Ladder, from `skills/shared/model-selection.md § Effort Levels`: `low < medium < high < xhigh < max`, saturating at `max`. The executable copy every consumer reads is `skills/worktask/scripts/effort-ladder.sh`; the bats suite asserts the two agree.

### The tier is a request, not a guarantee

`metadata.effort` is carried in-process by the `Agent` tool's `effort` parameter and on the opt-in headless surface by `claude -p --agent … --effort`. `skills/worktask/scripts/effort-route.sh` picks the surface: in-process by default, headless only when `CORPFLOW_HEADLESS_ROUTE=on`. A request is still not a guarantee: a managed `maxEffortLevel` can cap it, so the hook row decides what ran. The bump is computed and recorded on every path and applied on the surface the route decision picked.

#### Transport audit

Every resolver audit row carries `effort_transport` saying which of the four transports it was (`agent-coordination/references/headless-dispatch.md § Translation table — model & effort`; `skills/worktask/references/workflow.md § Step C.0a`).

#### Recorded vs applied tiers

Under `none` (haiku, no `effort` passed) the `auto_decision_resolved` row records `effort_resolved: "requested, not applied"` and `effort_requested` keeps the computed tier. Under `frontmatter` (no `effort` passed: an unstamped row) `effort_resolved` comes from the hook row like `agent-param`. Under `agent-param` (in-process) and `dispatch-flag` (headless) `effort_resolved` is the tier the subagent's or child's own hook rows observed — `null` with `effort_resolved_reason: no_hook_rows` if none were (a row reading `"unknown"` observed nothing), never copied from the request. Recording the unapplied tier under `none` still gives the ledger the tier the item deserved. Don't reach that tier another way: substituting a different agent believed to run higher trades the domain expertise answering the question for a guess.

### The tier the model can actually carry

`xhigh` runs on Opus 5.5, Sonnet 5.5 and Fable 5.x (the `opus`, `sonnet` and `fable` targets); a pinned id outside those runs it at the highest level it supports at or below, with no error (`model-selection.md § xhigh routing`). A bump above `high` on a model other than the `opus`, `sonnet` and `fable` aliases is clamped to `high` and audited `effort_clamped`, never dispatched as a tier that evaporates in transit. No current stage hits the clamp (the only `haiku` stage sits at `low`), which is why it is enforced in code: nothing in a run would show it if it started happening.

A second silent path cannot be clamped and is read from the audit row instead: a managed or user `maxEffortLevel` below the requested tier runs the session at the cap with no error (`model-selection.md § Effort frontmatter and caps`). Resolvers therefore audit both `effort_requested` and `effort_resolved`, the same reason `dispatched_agents[].model_resolved` exists.
