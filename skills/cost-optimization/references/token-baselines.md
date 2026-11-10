# Token Baselines & Context Efficiency

## Per-Stage Token Baselines

Per-stage typical token ranges are the **Typical tokens** column of `skills/context-compression/SKILL.md § Stage Budget Table`; price a row with `skills/cost-optimization/SKILL.md § Cost Estimation Formula`.

**Total Worktask Range**: 58,000-123,000 tokens (~$0.21-0.44 for sonnet at the default split, before retry and complexity multipliers).

## Context Window Efficiency Improvements

Most of Claude Code's context savings are automatic. Listed here is only what carries a decision: a knob to set, a cap to plan against, or a surface to read.

### Knobs

Prompt-cache TTL knobs: `skills/cost-optimization/SKILL.md § Finer-grained TTL controls`.

| Setting | Effect |
| --- | --- |
| `showThinkingSummaries: true` | Restores thinking summaries, off by default because they cost tokens |
| `MCP_TOOL_TIMEOUT` | Honoured by remote HTTP/SSE servers |
| `CLAUDE_CODE_ENABLE_AUTO_MODE=1` | Auto model/effort on Bedrock/Vertex/Foundry; explicit `--model`/`--effort` still win |
| `--forward-subagent-text` | stream-json forwards depth-2+ spawns, so attribution does not fold Tier-2 into the parent |
| `BASH_MAX_OUTPUT_LENGTH` | Environment variable capping how much Bash output is kept in context; the rest is truncated |

#### Session commands

| Setting | Effect |
| --- | --- |
| `/recap`, `--recap` | Session recap, reusable as handoff context |
| `/autocompact <N>` | Sets the auto-compaction threshold, saved per model so each model keeps its own; `200k` is a safety net on 1M models |
| `/mcp` | Disables MCP servers the session does not use, dropping their tool definitions from context |
| `/rewind` vs `/compact` | `/rewind` drops the most recent turns and keeps the rest verbatim; `/compact` rewrites the whole conversation into a summary |

### Caps to plan against

| Limit | Value |
| --- | --- |
| Tool results / hook output | >50K chars go to disk, not context  |
| Opus-tier max output | 64k default, 128k upper bound |
| MCP tool descriptions + server instructions | 2KB each |
| Skill `description:` | 250 characters |
| Stalled subagent | Clear error after 10 min instead of silently burning budget |
| Compaction loop guard | Stops after 3 failed compactions or 3 immediate refills, with an actionable error |

#### Caps to plan against — retries, search and resume

| Limit | Value |
| --- | --- |
| Failed model call | One retry limit covers the whole call: at most 14 requests with default settings |
| Interactive WebSearch | Budget refills at 100 calls/hour instead of ending after 200 (`CLAUDE_CODE_WEB_SEARCH_REFILLS_PER_HOUR`; 0 turns refill off) |
| Mid-run message to a subagent | The resumed subagent or teammate keeps its earlier thinking and prompt cache, so a nudge does not pay a full re-cache |
| 1M window | Autocompact respects the 1M threshold, but a 1M session without usage credits compacts back under the standard limit — budget handoffs against the standard window unless credits are confirmed |

### Cost-visibility surfaces

| Surface | Shows |
| --- | --- |
| `/cost` | Per-model and cache-hit breakdown, plus the prompt-cache line (`skills/cost-optimization/SKILL.md § Verifying the hit rate`) |
| `/stats` | Includes subagent usage |
| `/context all` | Per-skill token estimates via the active model's tokenizer |
| `/context` in a fresh session | The baseline every turn pays before any work: system prompt, tools, MCP servers, memory, skills |
| `/skills` (press `t`) | Sorts the skill list by token cost |
| `claude plugin details <name>` | Inventory + token cost before install/enable |
| `/skill-doctor` | Loaded skills that go unused and what each costs in context — use it to prune |

### Telemetry counters

- OpenTelemetry `api_request` events split cache writes into `cache_creation_5m_tokens` and `cache_creation_1h_tokens`. Use them to tell cache lifetimes apart rather than treating every write as five minutes.
- Tool decisions carry `classifier_verdict`, `permission_mode`, and an optional `classifier_category` (requires `OTEL_LOG_TOOL_DETAILS=1`).
- Idle compaction can compact conversations above 200K tokens after about 54 minutes. `idleCompaction: false` disables it, and `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` changes the threshold. These operator controls do not change stage token budgets.

### Behaviors worth exploiting

| Behavior | Why it matters |
| --- | --- |
| Failed read-only tool does not cancel parallel siblings | Read/Glob/WebFetch first, read-only Bash later — one failure does not waste the batch |
| Subagents discover project + user + plugin skills | Stop inlining skill instructions into a delegation prompt; the child loads them itself |
| `claude -p` keeps text produced before a mid-stream API error | A failed headless stage yields salvageable partial work instead of a full re-run |

### Canonical elsewhere

Model defaults and aliases, per-model effort defaults, 1M credit gates, fast mode and the lean system prompt, and managed `availableModels`/`enforceAvailableModels` allowlists: `skills/shared/model-selection.md`. Spawn ceilings (depth 3, 20 concurrent, no per-session total-spawn cap: `skills/agent-coordination/SKILL.md § No total cap; concurrency is the one that bites`), `--max-budget-usd` halting *running* subagents, and `workflowSizeGuideline` fan-out sizing: `skills/agent-coordination/SKILL.md`.

## Calendar Month Billing

Billing runs per calendar month and a partial month bills in full — the rate and rule live in `skills/shared/three-stage-planning.md § Calendar Month Billing (AI Agents)`. Consequences: track month boundaries in ledger metadata, plan a large worktask to finish inside one month, front-load complex stages early in the cycle, and defer non-urgent work when the month is nearly over and budget is tight.

## Constitutional Considerations

### Safety and Ethics Override Cost

Constitutional compliance outranks cost optimization. Don't optimize in these cases, nor when the ethics-reviewer asked for comprehensive analysis or the stakeholder flagged the task for ethics review:

| Scenario | Action |
| --- | --- |
| Ethics review needed | Accept the extra stage cost, run the review |
| Hard constraint check | Use opus reasoning if the analysis needs it |
| Safety-critical code | Prioritize thoroughness over review time |
| User harm potential | Escalate to the stakeholder regardless of cost |

### Ethics Review Cost Budgeting

Ethics work runs on opus. Costs are the opus rate at the default split of `SKILL.md § Cost Estimation Formula`, before retry and complexity multipliers.

| Ethics Activity | Typical Tokens | Est. Cost |
| --- | --- | --- |
| Quick ethics check | 2,000-5,000 | $0.014-0.036 |
| Standard ethics review | 5,000-10,000 | $0.036-0.072 |
| Comprehensive ethics audit | 15,000-30,000 | $0.108-0.216 |
| Hard constraint analysis | 5,000-10,000 | $0.036-0.072 |

### Constitutional Budget Allocation

Share of worktask budget to reserve for ethics: standard 10% (ad-hoc consultation) · high-risk features 20% (mandatory review) · user data handling 15% (privacy and consent) · AI/ML features 25% (fairness and bias).
