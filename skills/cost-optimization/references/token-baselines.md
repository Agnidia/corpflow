# Token Baselines & Context Efficiency

## Per-Stage Token Baselines

Per-stage typical token ranges are the **Typical tokens** column of `skills/context-compression/SKILL.md § Stage Budget Table`; price a row with `skills/cost-optimization/SKILL.md § Cost Estimation Formula`.

**Total Worktask Range**: 58,000-123,000 tokens (~$0.21-0.44 for sonnet at the default split, before retry and complexity multipliers).

## Context Window Efficiency Improvements

Most of Claude Code's context savings are automatic. Listed here is only what carries a decision: a knob to set, a cap to plan against, a surface to read, or a correction that changes how older cost numbers compare. Versions let a report be dated.

### Knobs

Prompt-cache TTL knobs: `skills/cost-optimization/SKILL.md § Finer-grained TTL controls`.

| Setting | Since | Effect |
|---|---|---|
| `showThinkingSummaries: true` | 2.1.89 | Restores thinking summaries, off by default because they cost tokens |
| `MCP_TOOL_TIMEOUT` | 2.1.142 | Honoured by remote HTTP/SSE servers — lifts the silent 60s cap that drove retry churn |
| `CLAUDE_CODE_ENABLE_AUTO_MODE=1` | 2.1.158 | Auto model/effort on Bedrock/Vertex/Foundry; explicit `--model`/`--effort` still win |
| `--forward-subagent-text` | 2.1.219 | stream-json forwards depth-2+ spawns, so attribution stops folding Tier-2 into the parent |
| `BASH_MAX_OUTPUT_LENGTH` | — | Environment variable capping how much Bash output is kept in context; the rest is truncated |

#### Session commands

| Setting | Since | Effect |
|---|---|---|
| `/recap`, `--recap` | 2.1.108 | Session recap, reusable as handoff context |
| `/autocompact <N>` | 2.1.221, 2.1.288 | Sets the auto-compaction threshold, saved per model so each model keeps its own; `200k` is a safety net on 1M models |
| `/mcp` | — | Disables MCP servers the session does not use, dropping their tool definitions from context |
| `/rewind` vs `/compact` | — | `/rewind` drops the most recent turns and keeps the rest verbatim; `/compact` rewrites the whole conversation into a summary |

### Caps to plan against

| Limit | Since | Value |
|---|---|---|
| Tool results / hook output | 2.1.51, 2.1.89 | >50K chars go to disk, not context (tool results were 100K before) |
| Opus-tier max output | 2.1.77 | 64k default, 128k upper bound |
| MCP tool descriptions + server instructions | 2.1.84 | 2KB each |
| Skill `description:` | 2.1.86 | 250 characters |
| Stalled subagent | 2.1.113 | Clear error after 10 min instead of silently burning budget |
| Compaction loop guard | 2.1.76, 2.1.89 | Stops after 3 failed compactions or 3 immediate refills, with an actionable error |

#### Caps to plan against — retries, search and resume

| Limit | Since | Value |
|---|---|---|
| Failed model call | 2.1.286 | One retry limit covers the whole call: at most 14 requests with default settings |
| Interactive WebSearch | 2.1.290 | Budget refills at 100 calls/hour instead of ending after 200 (`CLAUDE_CODE_WEB_SEARCH_REFILLS_PER_HOUR`; 0 turns refill off) |
| Mid-run message to a subagent | 2.1.290 | The resumed subagent or teammate keeps its earlier thinking and prompt cache, so a nudge no longer pays a full re-cache |
| 1M window | 2.1.128, 2.1.172 | Autocompact respects the 1M threshold, but a 1M session without usage credits compacts back under the standard limit — budget handoffs against the standard window unless credits are confirmed |

### Cost-visibility surfaces

| Surface | Since | Shows |
|---|---|---|
| `/cost` | 2.1.92 | Per-model and cache-hit breakdown, plus the prompt-cache line (`skills/cost-optimization/SKILL.md § Verifying the hit rate`) |
| `/stats` | 2.1.89 | Includes subagent usage |
| `/context all` | 2.1.139 | Per-skill token estimates via the active model's tokenizer |
| `/context` in a fresh session | — | The baseline every turn pays before any work: system prompt, tools, MCP servers, memory, skills |
| `/skills` (press `t`) | 2.1.111 | Sorts the skill list by token cost |
| `claude plugin details <name>` | 2.1.139 | Inventory + token cost before install/enable |
| `/skill-doctor` | 2.1.261 | Loaded skills that go unused and what each costs in context — use it to prune |

### Telemetry corrections

These change how pre-fix numbers compare to current ones.

| Fix | Since | Consequence |
|---|---|---|
| `cache_creation_input_tokens` nested breakdown | 2.1.152 | Nested calls attribute to the sub-call layer; previously double-counted in the parent |
| Bedrock/Vertex/Mantle/Foundry cache regression | 2.1.211 | Trailing system block was billed as fresh input — reconcile pre-fix dashboards against provider billing |
| Streaming cost/token double-count | 2.1.214 | `/cost` is trustworthy on streaming turns only from here on |
| Mid-conversation cache block behind gateways | 2.1.212 | Bedrock/Vertex/1P and custom base URLs get direct-API cache economics |

#### Telemetry corrections (continued)

| Fix | Since | Consequence |
|---|---|---|
| Tool-definition re-render after OAuth refresh | 2.1.248 | Cost a full prompt-cache miss roughly hourly in long sessions, and lost extended-thinking context with it |
| `ScheduleWakeup` definition drift across `--resume` | 2.1.248 | Under usage overage the tool definition changed between a session and its resume, missing the cache on the resumed first turn |

### Behaviors worth exploiting

| Behavior | Since | Why it matters |
|---|---|---|
| Failed read-only tool no longer cancels parallel siblings | 2.1.72, 2.1.128 | Read/Glob/WebFetch first, read-only Bash later — one failure no longer wastes the batch |
| Subagents discover project + user + plugin skills | 2.1.133 | Stop inlining skill instructions into a delegation prompt; the child loads them itself |
| `claude -p` keeps text produced before a mid-stream API error | 2.1.219 | A failed headless stage yields salvageable partial work instead of a full re-run |

### Canonical elsewhere

Model defaults and aliases, per-model effort defaults, 1M credit gates, fast mode and the lean system prompt, and managed `availableModels`/`enforceAvailableModels` allowlists: `skills/shared/model-selection.md`. Spawn ceilings (depth 3, 20 concurrent, no per-session total-spawn cap: `skills/agent-coordination/SKILL.md § No total cap; concurrency is the one that bites`), `--max-budget-usd` halting *running* subagents, and `workflowSizeGuideline` fan-out sizing: `skills/agent-coordination/SKILL.md`.

## Calendar Month Billing

Billing runs per calendar month and a partial month bills in full — the rate and rule live in `skills/shared/three-stage-planning.md § Calendar Month Billing (AI Agents)`. Consequences: track month boundaries in ledger metadata, plan a large worktask to finish inside one month, front-load complex stages early in the cycle, and defer non-urgent work when the month is nearly over and budget is tight.

## Constitutional Considerations

### Safety and Ethics Override Cost

Constitutional compliance outranks cost optimization. Don't optimize in these cases, nor when the ethics-reviewer asked for comprehensive analysis or the stakeholder flagged the task for ethics review:

| Scenario | Action |
|----------|--------|
| Ethics review needed | Accept the extra stage cost, run the review |
| Hard constraint check | Use opus reasoning if the analysis needs it |
| Safety-critical code | Prioritize thoroughness over review time |
| User harm potential | Escalate to the stakeholder regardless of cost |

### Ethics Review Cost Budgeting

Ethics work runs on opus. Costs are the opus rate at the default split of `SKILL.md § Cost Estimation Formula`, before retry and complexity multipliers.

| Ethics Activity | Typical Tokens | Est. Cost |
|-----------------|----------------|-----------|
| Quick ethics check | 2,000-5,000 | $0.014-0.036 |
| Standard ethics review | 5,000-10,000 | $0.036-0.072 |
| Comprehensive ethics audit | 15,000-30,000 | $0.108-0.216 |
| Hard constraint analysis | 5,000-10,000 | $0.036-0.072 |

### Constitutional Budget Allocation

Share of worktask budget to reserve for ethics: standard 10% (ad-hoc consultation) · high-risk features 20% (mandatory review) · user data handling 15% (privacy and consent) · AI/ML features 25% (fairness and bias).

## Claude Code 2.1.303 cost observations

Sonnet 5.5 cache reads cost $0.10 per million tokens in CLI accounting from 2.1.296; the canonical model-selection table already matches.
OpenTelemetry `api_request` events split cache writes into `cache_creation_5m_tokens` and `cache_creation_1h_tokens` from 2.1.300.
Use those counters to distinguish cache lifetimes rather than treating every write as five minutes.
Tool decisions add `classifier_verdict`, `permission_mode`, and optional `classifier_category` from 2.1.301.
The category requires `OTEL_LOG_TOOL_DETAILS=1`; 2.1.302 fixes missing category values and preserves tool identity under low attribute limits.
Idle compaction can compact conversations above 200K tokens after about 54 minutes (2.1.299).
`idleCompaction: false` disables it; `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` changes the threshold.
The 2.1.302 config UI exposes the toggle. These operator controls do not change stage token budgets.
