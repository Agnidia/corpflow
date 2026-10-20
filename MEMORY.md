# corpflow Plugin Memory

Repository-tracked memory (lean rolling format). Narratives live in git history, `CHANGELOG.md`, and the CC band files indexed below. Release tooling reads the `Plugin version:` line; keep its format. Hard cap ~5KB; Release History keeps 12 rows.

## Version Tracking

- Plugin version: **4.1.3** (2026-10-19; orchestration fixes and Claude Code 2.1.303 integration.)
- Claude Code min required: **2.1.303** (hook failure blocking, bounded headless retries, resume messaging, and cross-host subagent defaults)
- Claude Code latest integrated band: **2.1.295→2.1.303**

## CC Feature Band Index

Canonical band files live in the authoritative memory directory (`~/.claude/projects/<slug>/memory/`).

| Band | Canonical file | Plugin release |
|------|----------------|----------------|
| 2.1.295→2.1.303 | cc-features-2.1.295-303.md (draft in .context/; sync pending) | v4.1.3 (dispatch controls, hook failure blocking; min CC → 2.1.303; 297/298 unpublished) |
| 2.1.293→2.1.294 | cc-features-2.1.293-294.md | v4.1.1 develop (Haiku 5.5 rates, DC repin; min CC → 2.1.294) |
| 2.1.285→2.1.292 | cc-features-2.1.285-292.md | v4.1.1 develop (in-process Agent effort, Task→Agent, held reattach; min CC → 2.1.292) |
| 2.1.281→2.1.284 | cc-features-2.1.281-284.md | v4.1.0 develop (Sonnet 5.5 repin, mid-pattern :* preflight; min CC → 2.1.284) |
| 2.1.271→2.1.280 | cc-features-2.1.271-280.md | v4.0.32 develop (Opus 5.5 default, TaskOutput removal; min CC → 2.1.280) |
| 2.1.252→2.1.270 | cc-features-2.1.252-270.md | v4.0.32 develop (queued reattach, SessionEnd timeout; min CC → 2.1.270) |
| 2.1.234→2.1.251 | cc-features-2.1.234-251.md | v4.0.27 (delivery-checked reattach, PreModelSwitch gate) |
| 2.1.221→2.1.233 | cc-features-2.1.221-233.md | v4.0.15 (Todo-tool removal → state ledger) |
| 2.1.216→2.1.220 | cc-features-2.1.216-220.md | v3.37.0 (nesting depth 3; Opus 5 default) |
| 2.1.210→2.1.215 | cc-features-2.1.210-215.md | v3.35.0 (MCP auto-background, spawn cap) |
| 2.1.203→2.1.209 | cc-features-2.1.203-209.md | v3.34.0 (background-agent/worktree stabilization) |
| 2.1.185→2.1.202 | cc-features-2.1.185-202.md | v3.30.0 (background-default dispatch, Sonnet 5) |
| 2.1.176→2.1.183 | cc-features-2.1.176-183.md | v3.24.0 (agent-teams API) |
| 2.1.171→2.1.175 | cc-features-2.1.171-175.md | v3.17.0 (nested sub-agents) |
| 2.1.166→2.1.170 | cc-features-2.1.166-170.md | v3.13.0 (Fable 5) |
| 2.1.157→2.1.165 | cc-features-2.1.157-165.md | v3.12.0 |
| 2.1.151→2.1.156 | cc-features-2.1.151-156.md | v3.10.13 |
| 2.1.143→2.1.150 | cc-features-2.1.143-150.md | v3.10.6 |
| 2.1.141→2.1.142 | cc-features-2.1.141-142.md | v3.9.3 |
| 2.1.129→2.1.140 | cc-features-2.1.129-140.md | v3.9.2 |
| 2.1.122→2.1.128 | cc-features-2.1.122-128.md | v3.8.1 |
| 2.1.115→2.1.121 | cc-features-2.1.115-121.md | v3.6.1 |
| 2.1.102→2.1.114 | cc-features-2.1.102-114.md | v3.6.0 |
| 2.1.92→2.1.101 | cc-features-2.1.92-101.md | v3.5.0 |
| 2.1.87→2.1.91 | cc-features-2.1.87-91.md | v3.4.0 |
| 2.1.77→2.1.86 | cc-features-2.1.77-86.md | v3.3.0 |
| 2.1.51→2.1.76 | cc-features-2.1.51-76.md | v3.1.0/v3.2.0 |

> Band files before 2.1.221 are missing from disk (likely the CC 2.1.228 memory-folder cleanup bug); rows kept as the record.

## Release History (last 12, newest first)

- 2026-10-19: v4.1.3 — Claude Code 2.1.303 update (28 files, dispatch controls, hook enforcement; min CC 2.1.303).
- 2026-10-19: v4.1.3 — worktask orchestration, evidence validation, and sibling contract fixes.
- 2026-10-18: v4.1.2 — suite green (#483, #488), cli-fallback font fix, igrsoft→agnidia marketplace rename.
- 2026-10-08: v4.1.1 (develop) — Claude Code 2.1.294 update (17 files, min CC → 2.1.294, Haiku 5.5 rates, benchmark DC repin).
- 2026-10-06: v4.1.1 (develop) — Claude Code 2.1.292 update (75 files, min CC → 2.1.292, `agent-param` effort, headless opt-in, Task→Agent gate fix).
- 2026-10-06: v4.1.1 (develop) — Claude Code 2.1.291 update (22 files, min CC → 2.1.291, held reattach mode, 2 h background timeout).
- 2026-10-05: v4.1.1 — user-scope CORPFLOW.md fallback (`corpflow_md_locate`); CHANGELOG backfill for consultant-return.v1, screenshot manifests, `## Models`.
- 2026-09-29: v4.1.0 (develop) — Claude Code 2.1.284 update (33 files, min CC → 2.1.284, Opus/Sonnet 5.5-only guidance, preflight mid-pattern :* parity).
- 2026-09-23: v4.0.32 (develop) — Claude Code 2.1.280 update (6 files, min CC → 2.1.280, Opus 5.5 default, workflow-size 15→10, TaskOutput removal, held-message delivery notice).
- 2026-09-13: v4.0.32 (develop) — Claude Code 2.1.270 update (18 files, min CC → 2.1.270, queued reattach row, SessionEnd hook timeout, FORCE preflight).
- 2026-09-09: v4.0.31 — leaderboard V1 fix plan phases A–E: discovered-vs-executed evidence, sweep transport for five agents, AR contract before DV fan-out.
- 2026-09-08: v4.0.30 (cont.) — prompt-audit remediation, 26 findings across agents/commands/skills; tool-grant coverage and template backfill.
