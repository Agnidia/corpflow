---
name: logging-conventions
description: Use when an agent pipes build, test, simulator, Monitor, or incident output via background Bash or `tee`. Route runtime log capture to `.context/logs/`; covers filename grammar, `errors/<agent>.md` vs `logs/` split, and cleanup.
---

# Logging Conventions

Runtime log capture routing for the corpflow worktask. Pairs with `task-folder-organization`.

## The Split

| Artifact | Location | Author | Purpose |
|----------|----------|--------|---------|
| `errors/<agent>.md` | `.context/errors/<agent>.md` | Owning agent, narrative | Escalation story per agent: what went wrong, retry count, handoff context. One file per agent, so parallel stages never collide. |
| `*.log` | `.context/logs/` | Machine-written stdout/stderr | Raw runtime capture for post-hoc inspection |

## Filename Grammar

```
<kind>-<scope>-<YYYYMMDD-HHMMSS>.log
```

### Kind Taxonomy

The kind names what the log is, not which tool made it.

| Kind | Source | Example |
|------|--------|---------|
| `build` | Any compile/package run — xcodebuild/SwiftPM, Gradle, cargo, `go build`, bundlers, CI | `build-ios-sim-20260420-141522.log` |
| `test` | Any test-runner run — XCTest, JUnit, pytest, `go test`, jest, bats | `test-qa-20260420-143008.log` |
| `monitor` | `Monitor`-tool streams | `monitor-developer-20260420-142250.log` |
| `sim` | Simulator/emulator device-log streams (Apple `launch_app_logs_sim`, Android `adb logcat`). No device surface ⇒ no `sim` logs | `sim-iphone15-20260420-143201.log` |
| `incident` | IR background tails | `incident-20260420-090512.log` |
| `hotfix` | Emergency DV stream | `hotfix-auth-20260420-103344.log` |
| `cost` | `SubagentStop` hook JSONL | `cost-dv-20260420-141522.jsonl` |
| `audit` | Orchestrator/agent audit trail (append-only, no timestamp) | `audit.jsonl` |

### Scope and timestamp

**Scope**: free-form short tag for the owner or target — agent name (`developer`, `qa-engineer`), simulator id (`iphone15`), stage code (`qa`, `dv`), or feature slug (`auth`, `checkout`). ≤ 24 chars, kebab-case.

**Timestamp**: `YYYYMMDD-HHMMSS` in UTC (host local if the agent is human-facing), from `date -u +%Y%m%d-%H%M%S`.

## Bash Pattern

Save complete build, test, and diagnostic evidence before returning an excerpt.
Use the controlled helper when a direct project command produces routine output:

```bash
LOG=".context/logs/build-<scope>-$(date -u +%Y%m%d-%H%M%S).log"
python3 "$PLUGIN_ROOT/skills/worktask/scripts/bounded-output.py" --log "$LOG" -- <build-command>
```

The helper retains the command exit status and writes the complete merged stream to an exclusive evidence file.
Its response contains at most 8,000 Unicode characters, including the status, evidence path, and truncation marker.
A truncated response includes the beginning and end, keeping late failures visible.
Use a unique timestamp for each attempt; existing evidence files are never overwritten.

### Targeted excerpts

Bound ordinary search output through the same helper, or use supported tool output arguments.
Retrieve further evidence with `--read --log <path> --start <character-offset>`.
Larger source excerpts remain permitted when implementation or review needs them.
This helper controls its own commands; it does not intercept arbitrary shell or MCP output.

For a background stream, use `tee` with the existing log path and bound the result shown to the agent.

## Monitor-Tool Pattern

1. Start background Bash writing to `.context/logs/monitor-<agent>-<ts>.log` (via `tee`).
2. Attach `Monitor` to the running background id for live events.
3. On detach the file stays readable via `Read`; reference its path in downstream stage docs (`testing-N.md`, `incident-N.md`, `release-N.md`).

MCP auto-background: the tee pattern covers Bash-invoked builds/tests only. An MCP tool call (`build_sim`, `test_sim`, …) past ~2 min is auto-backgrounded, and no tee'd log exists until the agent reads the completion result — treat the completion notification, never a `.context/logs/*.log` file's mere presence, as the readiness signal (`agent-coordination § MCP Auto-Background`).

## Cleanup & Retention

- **Per-task hygiene**: `.context/logs/` clears with the rest of `.context/` when the task archives (worktask FN stage or `/worktask` completion).
- **Size guard**: retain complete evidence on disk; bound displayed excerpts and retrieve specific sections when needed.
- **Secrets**: never log secrets, tokens, or keychain data. If a tool prints them, redact before `tee` (e.g. `sed -E 's/(authorization|api[_-]?key|password|token|secret|bearer)[=:]\s*\S+/\1=REDACTED/'`) — a starter pattern, so review the output for leaks.
- **Git**: `.context/` follows the project's existing ignore policy — no special handling.

## Cross References

- `skills/task-folder-organization/SKILL.md` — canonical `.context/` folder rules.
- `skills/agent-coordination/SKILL.md` §Monitor Tool for Background Events — tool mechanics.
- `skills/incident-response/SKILL.md` — DV hotfix log stream (`hotfix` kind).
- `agents/workflow-engineer.md` §Handle Error — per-agent `errors/<agent>.md` escalation (narrative counterpart).

## Common Mistakes

1. **Runtime output in `errors/<agent>.md`** — those are narrative escalation; raw captures belong in `logs/`.
2. **Missing timestamp** — re-runs then clobber prior evidence. Always `$(date -u +%Y%m%d-%H%M%S)`.
3. **Scattering to `/tmp`** — invisible to downstream stages, lost on workspace reset.
4. **Logging secrets** — redact before `tee`; never commit logs that may hold credentials.
5. **A sibling `log/` folder** — canonical name is `logs/` (plural), one per project.
