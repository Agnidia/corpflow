---
name: cost-optimization
description: Use for budget management, model selection, and cost tracking and optimization of AI agent worktasks. Model and effort right-sizing, prompt-cache TTL, search batching, cost estimation formula, efficiency analysis.
version: 0.3.0
related:
  - skills/worktask/SKILL.md
  - skills/agent-coordination/SKILL.md
  - skills/claude-constitution/SKILL.md
---

# Cost Optimization

Model right-sizing, token discipline, per-stage tracking, budget gates. Per-stage budgets and typical token ranges: `${CLAUDE_SKILL_DIR}/../context-compression/SKILL.md § Stage Budget Table`. CC context-efficiency knobs, caps and cost-visibility surfaces, and ethics cost budgeting: `${CLAUDE_SKILL_DIR}/references/token-baselines.md`.

## Per-Effort Thinking-Budget Ceilings

Effort (`low` ○, `medium` ◐, `high` ●, `xhigh` ⬣, `max` ⬛) maps to a thinking-token ceiling. Claude Code does not enforce these; they justify the effort tiers in `../worktask/references/stage-codes.md` and let reviewers calibrate complexity against cost.

| Effort | Thinking Budget | Use For |
|--------|-----------------|---------|
| `low` | ≤ 4K | Formatting, routing, status updates |
| `medium` | ≤ 16K | Implementation, code review, coordination |
| `high` | ≤ 32K | Multi-step reasoning; sonnet/opus default on API/Team plans |
| `xhigh` | ≤ 50K | Hard tradeoffs, meta-optimization, ethics/security review |
| `max` | ≤ 64K | Novel-domain research only; unassigned by default |

**Tuning**: +1 tier when a stage repeatedly retries with `classification: logic`; −1 tier when it passes first try three runs running.

## Cost Reduction Strategies

### 1. Model Right-Sizing

Use the cheapest model that can do the task: tiers and mapping in `../shared/model-selection.md` (§ Cost Tiers, § Selection Criteria); a worktask stage's model and effort are its row in `../worktask/references/stage-codes.md`. Moving procedural work (status checks, formatting, simple validation) off sonnet cuts the rate for those stages to 1/20 (1/4 on Haiku prompts over 100K); opus costs ~40x haiku, so reserve it for architecture-grade reasoning. Outside the matrix, pass `effort: medium` for cost-sensitive work, since non-Pro plans default to `high`.

### 2. Context Compression

| Technique | Token Reduction | When to Apply |
|-----------|-----------------|---------------|
| Artifact references | 60-80% | Always — reference paths, not content |
| Decision summaries | 40-60% | Stage handoffs |
| Code path notation | 70-90% | When discussing code structure |
| Bullet vs prose | 30-50% | All documentation |

Compress before retrying, not after. Worked examples and per-content-type techniques: `skills/context-compression/`.

### 3. Context Window Efficiency

Mostly automatic in CC; the knobs, caps, and visibility surfaces (including `/skill-doctor` for pruning unused skills) are in `${CLAUDE_SKILL_DIR}/references/token-baselines.md`.

### 4. Batch Operations

Group file reads before analysis, combine related searches, cache repeated lookups. One batched request instead of five sequential ones drops ~80% of per-call overhead.

### 4a. Git Search Strategy

One combined command per question, not `git log` → `git show --stat` → `git show` → `git diff` (4 commands, 1 answer):

```bash
git log --oneline -10 --all -p -S '<term>' -- '*.swift'   # symbol history + diffs
git log --oneline -5 -p -- <file>                         # one file's history + diffs
git log --oneline --stat <base>..HEAD                     # everything on the branch
```

### 4b. Grep Batching

Combine related patterns with `|` alternation — `Grep("dismissCompleted|completedScan|stopScanning")`, not three calls.

**Zero-result protocol**: after 2 consecutive zero-result searches on one topic, stop searching. Ask for the correct symbol/path, or Glob for candidate files first and grep within those.

### 4c. Targeted Reads

Read the ledger digest and current stage brief first. Read upstream handoff frontmatter next.
Resolve the referenced sections required by the stage, then inspect relevant source files and tests.
Expand exploration when unresolved requirements or findings justify it; record the reason.
A missing reference blocks its dependent check until resolved; never treat missing content as an empty requirement.
Above 200 lines, use a known location with `offset`/`limit` instead of reading the whole file.

#### Source inventories and review coverage

Use `skills/worktask/scripts/source-inventory.sh [root]` for ordinary source inventories.
It excludes build products, generated capture tools, images, and archived logs.
Pass `--include-artifacts` when investigating artifacts or ignored dependencies; it bypasses ignore rules while excluding Git metadata.
Read an explicit source or evidence path whenever the inventory excludes an artifact required by the task.
Code and security reviewers inspect the relevant implementation, dependencies, tests, and changed paths.
Handoff summaries guide navigation; they cannot substitute for reviewing the code or finding defects outside the summary.

### 4d. Command Output Hygiene

Command output stays in context for the rest of the session, like an appended file, and is re-billed on every later turn. Run noisy commands with their quiet flag (`-quiet`, `--silent`, `-q`) or trim them (`| tail -n 50`). Send builds and tests to the platform's `/<plugin>:build-test` or its builder subagent, which returns a verdict instead of the raw log. The session-wide output cap: `${CLAUDE_SKILL_DIR}/references/token-baselines.md § Knobs`. Background command notices and TaskStop results over 1,000 characters show only the start and end, so tee a long command to `.context/logs/` when its middle matters.

### 5. Early Termination

| Scenario | Action |
|----------|--------|
| Simple bug fix | Skip AR stage, minimal TL stage |
| Documentation-only | Skip DV stage, minimal QA stage |
| Hotfix / trivial change | `/worktask` — PL0 dynamic sizing drops AR/TL/DC for low complexity |

Cost by size (PL0-sized): trivial ~1-4 stages · standard 9 stages · complex 9 + iterations; dollar ranges per size are the token bands in `skills/estimation-methodology/SKILL.md § AI Agent Cost Estimation`.

## Prompt Caching (1h TTL) & Handoff Protocol

The handoff protocol's preamble layout, expected cache-read ratios and `cache-lint.sh` are in `skills/worktask/references/contracts/prompt-layout.md#cache-prefix`. Its `state-merge.sh` SubagentStop hook ships default-on in `.claude-plugin/plugin.json`.

### Recommended `settings.json` stanza

```json
{
  "env": {
    "ENABLE_PROMPT_CACHING_1H": "1"
  }
}
```

The 5-min default TTL is shorter than many stages (DV/QA on complex features), so the preamble cache goes cold mid-pipeline: retries inside a stage still save, cross-stage hits are lost.

### Finer-grained TTL controls

Reach for the narrowest knob that solves the problem:

| Knob | Scope | Use when |
|---|---|---|
| `experimental.cacheTtl` (`"5m"`/`"1h"`) | One agent, via its frontmatter | A single long-running stage needs the longer TTL and the rest do not. Applies only when no subagent TTL setting is configured |
| `promptCacheTtl` / `subagentPromptCacheTtl` | Settings, main conversation vs subagents separately | The orchestrator's own context is worth holding for an hour while stage agents stay at 5 minutes |
| `ENABLE_PROMPT_CACHING_1H` | Session-wide | The whole pipeline is long enough that everything benefits |

### Verifying the hit rate

`/cost` shows a per-session prompt-cache line (hit ratio, misses, tokens re-cached, warm/cold) and a matching `prompt_cache` object for status-line scripts, each naming a likely cause per miss (tool definitions or system prompt changed, idle past the TTL). Check it against the handoff protocol's ≈60% cross-stage target rather than assuming the rate; preamble drift shows up as changed-prompt misses, a too-short TTL as idle misses.

### Sibling fan-out staggering

CC staggers same-prefix siblings on a fan-out so later ones read the cached prefix instead of each re-paying to write it — the runtime complement to `cache-lint.sh`, which keeps the prefix byte-identical. Widest fan-out: TL-split DVN tracks, `/megatask`. `CLAUDE_CODE_WORKFLOW_PREFIX_STAGGER_MS=0` disables it when a run is latency-bound, not token-bound.

## Budget Tracking

### Cost Estimation Formula

```
Estimated Cost = (Input Tokens × Input Rate + Output Tokens × Output Rate)
                 × (1 + Retry Factor) × Complexity Multiplier
```

- **Base Tokens**: per-stage baselines (`${CLAUDE_SKILL_DIR}/references/token-baselines.md`); Base Tokens = Input Tokens + Output Tokens
- **Default split**: 80:20 input:output, applied when only Base Tokens is known, or when one side is known and the other is not. At that split one million tokens costs 1.8 × the tier's input rate
- **Input Rate / Output Rate**: per tier in `skills/shared/model-selection.md § Cost Tiers`. The formula prices all input as uncached, so cache reads bring the real figure down
- **Retry Factor**: 0.1 low · 0.2 medium · 0.5 high complexity
- **Complexity Multiplier**: 1.0 standard · 1.5 large codebase · 2.0 novel domain

`skills/estimation-methodology/scripts/estimate-calc.py` implements this formula (`--tokens`, or `--input-tokens`/`--output-tokens`).

## Optimization Checklist

- **Before**: confirm PL0 sizing dropped unneeded stages · set a budget limit if applicable · verify per-stage model assignments
- **During**: watch token use at stage transitions · compress at handoffs · push sub-tasks to haiku where possible · keep command output quiet or trimmed (§ 4d)
- **After**: review the per-stage cost breakdown · record optimization opportunities · update baselines if they drifted
