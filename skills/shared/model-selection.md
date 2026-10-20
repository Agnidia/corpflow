---
name: model-selection
---

# Model Selection Guidelines

Canonical for tiers, selection criteria, and alias/model behaviour. The stage→model assignment
lives in `skills/shared/stage-codes.md`; how to write a prompt for the chosen model lives in
`skills/shared/model-prompting.md`.

## Cost Tiers

Standard API rates, USD per million tokens, for the model each alias resolves to (§ Aliases).

| Alias | Model | Input $/Mtok | Output $/Mtok | Cache read $/Mtok | Relative cost | Use For |
|-------|-------|--------------|---------------|-------------------|---------------|---------|
| **haiku** | Haiku 5.5 | 0.10 | 0.50 | 0.01 | 1x (baseline) | Formatting, routing, checklists, status checks |
| **sonnet** | Sonnet 5.5 | 2.00 | 10.00 | 0.10 | 20x haiku | Implementation, analysis, test design, coordination |
| **opus** | Opus 5.5 | 4.00 | 20.00 | 0.20 | 40x haiku | Architecture decisions, review gates, complex reasoning, meta-optimization |
| **fable** | Fable 5.1 | 10.00 | 50.00 | 0.25 | 100x haiku | Operator override only, never a stage default |

Relative cost holds at any input:output mix, since every tier prices output at 5x input. Dollars:
`skills/cost-optimization/SKILL.md § Cost Estimation Formula`.

### Haiku prompt-length pricing

Haiku 5.5 alone is priced by prompt length: a prompt over 100,000 tokens bills at 0.50 / 2.50 /
0.05, which narrows the gap to 4x / 8x / 20x. The other three tiers price the full 1M window at the
rates above. The estimator uses the standard row, so a haiku stage whose context grows past 100K
costs up to 5x its estimate.

### Rate ownership

This table owns the rates; everything else points here.
`skills/estimation-methodology/scripts/estimate-calc.py` keeps the one code copy, and
`tests/python/test_estimate_calc.py` fails when the two drift.
Re-check the rates against the `claude-api` skill whenever an alias moves to a new model.

## Aliases

| Alias | Resolves to | Context | Pricing |
|-------|-------------|---------|---------|
| `opus` | Opus 5.5 (`claude-opus-5-5`), the default Opus and Claude Code's default model outside Foundry | 1M by default, no usage-credit gate | § Cost Tiers; fast mode multiplier on top |
| `sonnet` | Sonnet 5.5 (`claude-sonnet-5-5`), the default Sonnet on the Anthropic API | native 1M | § Cost Tiers |
| `fable` | Fable 5.1 (`claude-fable-5-1`), Mythos-class top reasoning. Claude apps gateway sessions still resolve `fable` and `best` to Fable 5 | 1M by default (`[1m]` names normalize to the base id) | § Cost Tiers |
| `haiku` | Haiku 5.5 (`claude-haiku-5-5`), the default Haiku on the Anthropic API | 1M | § Cost Tiers; prompts over 100K bill at the higher Haiku rate |

Opus-tier stages follow the `opus` alias to each new default Opus with no plugin change. `fable` is
a valid operator override, never a plugin default.

### Workflow-only model override

`CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL` selects the model for workflow agents from Claude Code 2.1.296.
It leaves other subagents unchanged. Keep `metadata.model` explicit and reconcile the effective model through existing `model_resolved` evidence.
The classifier-only `CLAUDE_CODE_AUTO_MODE_MODEL` does not change stage model selection.
Fable/best can retry once on the previous Fable model when the newest is unavailable to the organization (2.1.301).
Record observed resolution rather than assuming that the requested alias ran.

### Prefer the alias over a pinned id

Frontmatter and `metadata.model` carry the alias, never a full model id. An alias tracks the
current default; a pinned id strands the stage once that model is superseded and raises a
deprecation warning at load, agent frontmatter `model:` included.

### Fable 5 credit gate

Without 1M usage credits a fable-tier dispatch fails hard with `API Error: Usage credits required
for 1M context`; an interactive 1M session instead auto-compacts back under the standard limit.
Degrade via a session `fallbackModel` (`--fallback-model`) or an `Agent({ model })` /
`metadata.model` override on the stage.

### Fast mode and the lean system prompt

`/fast` applies to Opus: higher token rate and price multiplier, pinned via `/model`. The `opus`
(Opus 5.5) and `fable` targets get Claude Code's lean system prompt by default and `sonnet` and
`haiku` do not, so `opus` and `fable` stages carry a small standing input-token saving.

## Effort Levels

`low` ○, `medium` ◐, `high` ●, `xhigh` ⬣, `max` ⬛. Default effort is `high` on API-key, Bedrock,
Vertex, Foundry, Team and Enterprise plans; Pro keeps `medium` on older models. "ultrathink" still
triggers high effort, and `/effort auto` resets. `/effort` stores its default per model, a saved
level never carries onto a newly released model, and an explicit level set anywhere (`-p`, Agent
SDK, `effortLevel` in project/managed/`--settings`) beats a model's launch default. None of that
is under the pipeline's control, so every stage passes `effort` explicitly.

### xhigh routing

`xhigh` runs on **Opus 5.5, Sonnet 5.5 and Fable 5.x** (the `opus`, `sonnet` and `fable`
targets), so those aliases all carry it, and `max` too. A pinned id outside those runs `xhigh` at
the highest level it supports, with no error: Claude Code falls back to the highest level the
model supports at or below the one set. `haiku` is not on Claude Code's effort list, so
`effort-ladder.sh` caps a resolver bump on it, or on a pinned id, at `high`. `fable` carries the
credit gate above.

### Thinking off above high

Opus 5.5 and the Fable models cannot have thinking turned off: `alwaysThinkingEnabled: false`,
`MAX_THINKING_TOKENS=0` and the session toggle have no effect there, so `opus` and `fable` run
`xhigh`/`max` as asked. When a model Claude Code does not know rejects `xhigh` with thinking
off, the request fails with `Effort 'xhigh' isn't available with thinking turned off`.

### Output headroom at xhigh and max

Thinking counts toward a request's output limit even when its text is not returned, and at
`xhigh`/`max` Opus 5.5 and Fable 5.1 think longer per turn. Claude Code sets that limit, not the
plugin: a `CLAUDE_CODE_MAX_OUTPUT_TOKENS` lowered below the model's default can cut an
`xhigh` stage's reply off. The prompt-side half for Fable is in
`skills/shared/model-prompting.md § fable — the block`.

### Effort visibility and inheritance

Hooks read the active tier from `effort.level` (JSON payload; `"unknown"` when absent), so cost/audit
hooks attribute spend per tier without parsing model metadata
(`skills/agent-coordination/references/hook-monitoring.md § Hook Effort Visibility`). Subagents
and compaction inherit the session's extended-thinking config; pass per-stage `metadata.model` +
`effort` anyway, because explicit beats inherited for stage determinism and cost attribution. An
automatic model switch (after a flagged message, or a retry on a fallback model) keeps the current
effort level instead of taking the new model's default or saved level.

### Effort frontmatter and caps

Every corpflow agent file carries an `effort:` key next to `maxTurns:`, equal to that agent's
Effort cell in `skills/shared/stage-codes.md § Agent Model Matrix` — the matrix stays the sole
place a tier is decided, and `tests/shell/worktask/agent-effort-frontmatter.bats` holds the two
in parity. No `model:` key exists on any agent file (sw-PL1-1); model selection stays a
per-dispatch `Agent()` argument.

#### Effort precedence

corpflow sets a tier only per call: the `Agent` tool's `effort` parameter in-process, `--effort`
on a headless `claude -p --agent` child. Both outrank the agent's own `effort:` frontmatter
(probed at 2.1.292), which beats the session level (`effortLevel`, `/effort`) and a model's
launch default. corpflow reads and sets no effort env var. An operator's
`CLAUDE_CODE_EFFORT_LEVEL` removes the `effort` parameter from the Agent tool and pins every
subagent; the audit row then shows `effort_resolved` ≠ `effort_requested`.

#### Effort caps and observation

A managed or user `maxEffortLevel` (top-level, or per model under `modelSettings`) still clamps
the resolved tier on top of either source, silently and with no error. A tier the target model
does not support falls back downward to the highest one it does (§ xhigh routing above); Haiku
is not on Claude Code's effort list at all, so its frontmatter `effort:` (and any resolver bump)
never applies. `metadata.effort` keeps the requested tier regardless of any of this, so read the
hook-reported `effort.level` — never a stage's own frontmatter or request — before trusting what
tier it actually ran at.

## Managed Allowlists and Org Restrictions

Under management a valid alias may silently resolve to a different model, which is why Pre-Stage
Validation step 6 (`skills/worktask/SKILL.md`) emits an audit row rather than blocking the
dispatch.

### Allowlist mechanics

| Control | Behaviour |
|---------|-----------|
| `availableModels` | Constrains subagent model overrides and the dispatch model picker; `enforceAvailableModels` extends it to the Default model. User/project settings cannot widen a managed list. |
| Alias outside the list | Redirects deterministically to an allowed model rather than leaking the disallowed id. |
| `/fast` | Refused when fast mode resolves to a non-allowlisted model, never a silent switch. |
| `availableModelsMatch: "exact"` | An `availableModels` entry allows only the model version it names, so the model an alias newly resolves to stays blocked until it is listed. |
| `deniedModels` | Blocks the named models even when `availableModels` allows them. |

### Restriction signals and fallbacks

| Control | Behaviour |
|---------|-----------|
| Family step-down | A restricted `model: opus` steps down to the newest org-allowed model in that family, not to the parent's model. |
| Restriction warning | Workflow agents, forked skills, slash commands and resumed background agents warn when the parent runs instead of the requested restricted subagent model; check the step-6 audit row rather than assuming the alias resolved. |
| Org default / restrictions | "Org default"/"Role default" shows in `/model`; restrictions cover the picker, `--model`, `/model` and `ANTHROPIC_MODEL` ("restricted by your organization's settings"). |
| Auto-mode fallback | In auto mode, an org allowlist lacking the current top Opus falls back to the best available Opus rather than failing or down-tiering, so restricted-org `xhigh` still lands on the strongest Opus available. |

#### Restriction signals — model resolution

| Control | Behaviour |
|---------|-----------|
| First-call 404 fallback | A subagent whose model 404s on its first call falls through the session's fallback-model chain; the parent's error names type, HTTP status, request id and model. The stage ran on a model `metadata.model` never asked for, so trust `dispatched_agents[].model_resolved`, not `model_requested`, when attributing cost. |
| Refused alias target | An API refusal of the model an alias resolves to retries once on the previous same-tier model; a fallback retry that cannot run fast runs at standard speed. Attribute cost from `model_resolved`. |
| `modelPicker` / `modelPricing` | Managed settings: `modelPicker` curates the `/model` list; `modelPricing` applies an org's contracted rates to `/cost`, the status line and telemetry, so a cost figure read under it is org-rated, not list-rated. |

## Provider Defaults (Bedrock / Vertex / Foundry)

Auto model/effort selection is on there with no opt-in; disable via `disableAutoMode`. These
providers and Claude-Platform-on-AWS default to the newest Opus they carry, which lags the
first-party default, so confirm what `opus` resolves to via `/model`. Explicit
`--model`/`--effort`/`metadata.model` stay authoritative. Bedrock resolves its region from
`~/.aws` when `AWS_REGION` is unset and prefixes GovCloud inference profiles `us-gov`, so headless
runners need no region env.

### Auto-mode permission classifier

The small model classifying permission decisions in auto mode defaults to a Sonnet-tier model for
external sessions, validated on the first request and then pinned for the session. It is unrelated
to the session model, and an `ANTHROPIC_DEFAULT_SONNET_MODEL` pin to a 5.5 model does not move it.

## Context-Window Accounting

`/context` percentages are computed against the full 1M window on models that have one (Opus 5.5,
Sonnet 5.5, Fable 5.x). The 1M window is the default on Bedrock, Vertex, Foundry, the Claude apps
gateway and a custom `ANTHROPIC_BASE_URL`, with no `[1m]` suffix; `CLAUDE_CODE_DISABLE_1M_CONTEXT=1`
keeps 200K, and `/autocompact 200k` (saved per model) suits a gateway that stops at 200K. How the extended window changes stage handoff budgets, plus the fable
without-credits caveat: `skills/context-compression/SKILL.md`.

## Selection Criteria

A worktask stage never reads this table: its model and effort are its row in
`skills/shared/stage-codes.md`. The table sizes everything else — ad-hoc delegations, support
work, a new agent's default.

| Complexity | Model | Signals |
|------------|-------|---------|
| Simple | haiku | Procedural steps, well-defined output format, little reasoning, high volume / low latency, cost-first: status checks, formatting, platform routing |
| Moderate | sonnet | Moderate reasoning, several considerations to balance, bounded creative output: test design, team coordination |
| Complex | opus | Multi-step or novel reasoning, tradeoff-heavy decisions, high-stakes gates such as code review, meta-level work (agents about agents, prompt optimization), architecture and system analysis |

## Per-Invocation Override

Use the `model` parameter on `Agent()` to override per delegation:

```
Agent({ subagent_type: "corpflow:qa-engineer", model: "sonnet", prompt: "..." })
```

### Task delegation and inheritance

#### Team and Explore agents

- Team agents inherit the leader's model and, for tmux/pane-backed teammates, the leader's
  `--effort`. There is no default-teammate-model setting, so a lane's tier is pinned at
  `Agent(name: …, model: …)` or not at all.
- The built-in `Explore` agent inherits the session model capped at opus, not haiku: budget
  fan-outs at sonnet/opus rates or pass an explicit `model`. A session model id Claude Code does
  not recognize, such as a custom model behind a proxy, is inherited as is rather than switched to
  Opus.

#### Persistence across resume and auto mode

- An explicit per-call override survives resume and follow-up `SendMessage`, so
  `model_requested`/`model_resolved` in `dispatched_agents[]` keep matching for the stage's whole
  lifecycle.
- Command and skill frontmatter `model:` is honoured in interactive sessions (no corpflow command
  or skill sets one). In auto mode, a command or skill naming a model auto mode does not support
  keeps the session model for that turn.

### Worktask stages: explicit, never inherited

A worktask stage is always dispatched with an explicit `model`: the orchestrator reads
`task.metadata.model` from the ledger, resolved from `skills/shared/stage-codes.md § Agent Model
Matrix`, and passes it as a short alias — `Agent({ model: "opus" })`. No corpflow agent carries a
`model:` key, so there is no frontmatter to fall back to.

A dispatch that skips this fails silently: the stage runs on the parent session's model,
`model_requested` and `model_resolved` disagree in `dispatched_agents[]`, and the sized effort
tier is lost (an inherited Haiku, or any pinned id outside the `xhigh` targets, may run `xhigh`
below the tier asked for, § xhigh routing).

## Default Subagent Model (`CLAUDE_CODE_SUBAGENT_MODEL`)

`CLAUDE_CODE_SUBAGENT_MODEL` sets the default subagent model, not an override: an agent's
frontmatter `model:` and an explicit per-spawn `model` both take precedence over it.

Ledger-dispatched stages are safe: `metadata.model` is required there and validated at step 6.
The exposure is any dispatch that bypasses the ledger, such as a stage agent's ad-hoc nested
`Agent()` to a Tier-2 specialist. Omit the model there and the spawn falls through to
`CLAUDE_CODE_SUBAGENT_MODEL`, or the session model if that is unset.

A mid-worktask switch away from a pinned model is gated by `hooks/model-switch-gate.sh`
(`agent-coordination/references/hook-monitoring.md § Model-Switch Hooks`).

### Forced subagent model overrides every pin

`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` inverts that precedence. When set, every subagent runs on
`CLAUDE_CODE_SUBAGENT_MODEL`, or the main session model when that is unset, ignoring both the
per-spawn `model` and the agent's `model:`. Ledger-dispatched stages lose their safety:
`Agent({ model: "opus" })` still passes step 6, then runs on the forced model with no error.

Two controls cover it. PL0 reads the variable before any spend and raises a plan-gate sweep item
(`skills/worktask/references/pl0-procedure.md § Subagent model-force preflight — detection`), and
Step 6.5b backfills `dispatched_agents[].model_resolved` when the runtime surfaces the model that
ran, so cost follows the forced tier rather than the pin. The force applies at spawn, so there is
no mid-stage switch for `hooks/model-switch-gate.sh` to refuse.
