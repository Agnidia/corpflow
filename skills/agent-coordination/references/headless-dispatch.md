# Headless Dispatch — `claude agents` Flag Bridge

The contract mapping `task.metadata` to `claude -p --agent` CLI flags, for external orchestrators (CI runners, batch schedulers, the user's shell, and the corpflow orchestrator's own headless route) invoking a worktask stage outside the in-process `Agent()` path.

The corpflow orchestrator dispatches every stage in-process via `Agent({ subagent_type, model, effort, prompt })` by default; the other flags below are honoured only by a CLI dispatch. PL0 populates the fields anyway, so every dispatcher — in-process or CLI — reads one source of truth.

## Translation Table

| `task.metadata` key | CLI flag | Type | Honoured in-process? | Stage examples |
|---|---|---|---|---|
| `agent` | `--agent <name>` | string | N/A (in-process uses `Agent({subagent_type})`) | overrides the session's `settings.json` `agent` default; e.g. force `corpflow:developer` for a one-shot run |
| `--all` (listing flag, not a `metadata` key) | `claude agents --all` | bool | N/A (listing only) | includes **completed** sessions in `claude agents [--json]` output; pair with `state` to tell `done` apart from `running`/`blocked` |

### Translation table — model & effort

#### Model assignment

| `task.metadata` key | CLI flag | Type | Honoured in-process? | Stage examples |
|---|---|---|---|---|
| `model` | `--model <alias>` | string | **Yes** (passed to `Agent()`) | DV→`opus`; QA/FN→`sonnet` |

A managed `availableModels` allowlist also constrains subagent overrides, and `enforceAvailableModels` the Default model, so a requested id may silently resolve to another. Benchmark-parity snapshots use pinned ids (§ Alias note); audit rather than assume.

#### Effort tier assignment

| `task.metadata` key | CLI flag | Type | Honoured in-process? | Stage examples |
|---|---|---|---|---|
| `effort` | `--effort <tier>` | `low\|medium\|high\|xhigh\|max` | **Yes** (`Agent` `effort`, 2.1.292) | DV complex→`xhigh`; DR→`high`; FN→`medium`; RE→`low` |

`claude agents --effort` also accepts `ultracode`, which is not a plugin `metadata.effort` tier; the plugin enum stays `low/medium/high/xhigh/max`. In `/effort`, Ultracode is its own toggle (Tab, or `/effort ultracode [on|off]`) that no longer forces `xhigh` and stays on at any level, so an operator who has it on still runs the tier the stage passes. A managed or user `maxEffortLevel` caps effort on every provider — a tier pinned above the cap runs at the cap with no error.

#### Effort route and transport

The route decision lives in `skills/worktask/scripts/effort-route.sh` (architecture-1.md ADR-3). Since 2.1.292 the default is in-process, with the tier on the `Agent` tool's `effort` parameter. This CLI surface is the opt-in: `CORPFLOW_HEADLESS_ROUTE=on` sends every non-haiku stage headless. `--effort` outranks the agent's own `effort:` frontmatter here too (probed at 2.1.292). `effort_transport` names the surface that applied the tier: `agent-param` (in-process, including the fallback after a headless `warn`), `dispatch-flag` (this CLI surface), `frontmatter` (no `effort` passed: an unstamped row) or `none` (haiku). `commands/worktask.md § Step C.0a` is the one canonical table.

### Translation table — permission, workspace & MCP

| `task.metadata` key | CLI flag | Type | Honoured in-process? | Stage examples |
|---|---|---|---|---|
| `permission_mode` | `--permission-mode <mode>` | `default\|acceptEdits\|plan\|bypassPermissions` | **Yes — audited** (§ Permission-Mode Pinning) | SR/FN→`default`; DV under `--auto=[plan]`→`bypassPermissions`. The CLI's choices are `acceptEdits\|auto\|bypassPermissions\|manual\|dontAsk\|plan`, with no `default`: pass plugin `default` as `manual`. `auto` and `dontAsk` are CLI-only values, not plugin `metadata.permission_mode` tiers |
| `workspace_path` | `--cwd <path>` | string | N/A (in-process inherits parent cwd) | megatask tracks → per-issue worktree |
| `add_dirs` (array) | repeated `--add-dir <path>` | string[] | N/A | cross-repo work, monorepo siblings |
| `mcp_config_path` | `--mcp-config <path>` | string | N/A | scoped MCP set per dispatch |

### Translation table — plugins, skip-permissions & settings

| `task.metadata` key | CLI flag | Type | Honoured in-process? | Stage examples |
|---|---|---|---|---|
| `plugin_dir_overrides` (array) | repeated `--plugin-dir <path>` | string[] | N/A | local plugin development; a path may name a folder of plugins, and each child folder with a manifest loads |
| `dangerously_skip_permissions` | `--dangerously-skip-permissions` | bool | Advisory; orchestrator may refuse | CI batch only, with a deny-list in `settings.json` |
| `settings_path` | `--settings <path>` | string | N/A | provider / org config swap |

### Translation table — compaction and retry

The optional fields in `skills/shared/state-ledger.md § Compaction and retry controls` are enforced headless controls, not advisory hints.
`headless-dispatch.sh` accepts matching hyphenated arguments, such as `--auto-compact-window 200000` and `--retry-watchdog true`.
Explicit arguments override ledger values; otherwise the child inherits runtime defaults and its existing environment.
A configured compaction window also pins the child environment, so an inherited window cannot defeat the task setting.
Environment overrides apply only to the child, including a resumed child. No parent or sibling environment changes.

Pass the complete metadata object to `effort-route.sh --dispatch-controls`. Configured controls require `CORPFLOW_HEADLESS_ROUTE=on`, including haiku stages.
The headless dispatcher refuses an in-process fallback when any control is configured. Codex routes without an equivalent transport must refuse before spawning.

`autoCompactWindow` in agent frontmatter or `--agents` definitions accepts integer token counts from 100000 to 1000000 (2.1.296).
An inherited positive `CLAUDE_CODE_AUTO_COMPACT_WINDOW` overrides that frontmatter field. Fork agents ignore that field; do not substitute a fork for a configured stage.

### Advisory vs audited legend

"Advisory" = recorded on the task and read by external dispatchers, but the in-process `Agent()` tool has no equivalent parameter. `effort` left this class in 2.1.292. "Audited" = the orchestrator writes an `audit.jsonl` line when the field is set, though it cannot enforce the mode on an `Agent()` child.

## Per-Stage Recommended Flag Sets

One canonical invocation; substitute the per-stage row plus concrete IDs from `task.metadata` at call time. `claude agents run` is not a subcommand and there is no top-level `--cwd` (§ Dispatch surface drift), so the real recipe `cd`s into the worktree first and dispatches through the top-level print-mode surface — re-derived and implemented in `skills/worktask/scripts/headless-dispatch.sh`, which validates every field against a closed allowlist before building this argv array. The tier is carried by `--effort` alone, and `WORKSPACE_ROOT` names the orchestrator's ledger root, never the worktree the child's cwd points at:

### Print-mode invocation

```bash
cd "$WORKTREE" && WORKSPACE_ROOT="$LEDGER_ROOT" \
  claude -p --agent "$AGENT" --model "$MODEL" --effort "$EFFORT" \
  --permission-mode "$MODE" --permission-prompts none \
  --output-format stream-json --verbose < "$PROMPT"
```

`--permission-prompts none` denies instead of hanging on anything that would otherwise prompt. Never `--bg` (it auto-commits and opens a draft PR, racing the FN gate) and never `--dangerously-skip-permissions`/`--allow-dangerously-skip-permissions` — `headless-dispatch.sh` has no code path that can add either.

### Permission cap and ledger inputs

`$MODE` is never applied verbatim: `headless-dispatch.sh --parent-mode <mode>` caps it at the orchestrator's own session mode (narrower of the two on a fixed order — a headless child can never run wider than the same stage would in-process), and PL/SR/FN/RE additionally never exceed `manual` regardless of that cap. An omitted `--parent-mode` defaults to `manual`, never "no cap"; an unrecognized one is refused (exit 2, nothing spawned) — failing closed, not silently defaulting. `--effort`/`--permission-mode`/`--workspace`/`--artifact` are all optional on the CLI: when left out, the script reads them itself from `<ledger-root>/.context/state.json`, so a caller dispatching through a shell string (the orchestrator's own `Bash` tool call, for one) need not carry those ledger values through it at all.

### Stage permission defaults

| Stage | `$AGENT` | `$MODE` |
|---|---|---|
| **DV** | `corpflow:developer` | `bypassPermissions` |
| **DR** | `corpflow:technical-lead` | `acceptEdits` |
| **SR** | `corpflow:security-reviewer` | `default` |
| **QA** | `corpflow:qa-engineer` | `acceptEdits` |
| **FN** | `corpflow:project-manager` | `default` |
| **RE** | `corpflow:release-engineer` | `default` |
| **ST** | `corpflow:stakeholder` | `acceptEdits` |

A DV child gets bypass only from `--permission-mode`, never from saved consent. `claude agents` now asks for bypass consent when the only saved consent is in `.claude/settings.local.json` or a `--settings` file, and a background session that ignores bypass shows a notice that stays (2.1.293). Before that, such a session silently ran without bypass.

### Model & effort defaults

`$MODEL` and `$EFFORT` come from `skills/shared/stage-codes.md § Agent Model Matrix` (a two-hop join: § Primary Stages resolves the stage to its agent, the matrix resolves that agent to its pair; § Secure overrides under `--secure` or `--full` replaces the resolved pair outright, so it can also lower a pair `CORPFLOW.md` raised). Pass the model as the alias; the pinned ids in § Alias note are for benchmark-parity runs only. Override per task when `metadata.model` / `metadata.effort` are set. `benchmark/harness/benchmarklive/stage_table.py` mirrors those rows as the machine-checked SSOT; model rules (aliases, cost tiers, the effort ladder) stay in `skills/shared/model-selection.md`.

### Alias note

Benchmark-parity pins: `opus` → `claude-opus-5-5`, `sonnet` → `claude-sonnet-5-5`, the models the aliases resolve to today (`skills/shared/model-selection.md § Aliases`). They are ids rather than aliases because they match `STAGE_TABLE` in `benchmark/harness/benchmarklive/stage_table.py`, whose per-stage pins stamp every record's comparability era: an alias that moved under a run would change the model without changing the stamp. Moving them opens a new era that is not comparable to the stored baselines (`benchmark/README.md § Comparability eras`), so they move only with a benchmark re-baseline, never as a docs refresh. Everywhere else, including a production headless dispatch, pass the alias.

### Runner-side reliability

- The `stream-json` init event carries `mcp_server_errors` — the `--mcp-config` entries the validator skipped. A runner depending on a scoped MCP set (`metadata.mcp_config_path`) reads it at init rather than discovering the gap at the first `mcp__<server>__*` call. `claude mcp list` / `/mcp` report HTTP status and error text on failed connections.
- The same `system/init` event's `plugin_errors` entries carry `path` for a `--plugin-dir` that failed to load, so a runner passing several plugin dirs can name the one that is missing.
- With `--forward-subagent-text`, depth-2+ subagents appear in the stream keyed by their spawning Agent `tool_use` id, so per-stage token attribution sees nested Tier-2 work instead of folding it into the parent stage.

#### Runner-side reliability — partial responses & signals

- A turn dying on a mid-stream API error keeps the text `claude -p` already produced — salvage the partial work instead of treating the dispatch as empty. Since 2.1.288 a mid-response API timeout no longer fails the turn: `-p` sessions and subagents continue from the partial response, and a thinking-only response is retried.
- `-p` and SDK sessions honor SIGTERM even when a supervisor (`timeout`, systemd) sends SIGCONT with it (2.1.288).

#### Background-worker & env reliability

Background sessions do not inherit another session's `ANTHROPIC_*` env; they preserve a shell-exported `ANTHROPIC_BASE_URL`, inherit the dispatching shell's `PATH`, honor `effortLevel` when forked through the daemon, and follow `CLAUDE_CODE_EXTRA_BODY`. `--setting-sources` (SDK `settingSources`) is forwarded to spawned sessions — teammates, `/bg`, `claude agents` sessions and `--worktree --tmux` — so a runner's restriction holds one level down. `claude --bg` in a directory that has not passed the workspace trust prompt asks for trust first and exits when not run interactively, so an unattended runner trusts the worktree before dispatching into it.

#### Fork subagents & auto-mode hand-back

With `CLAUDE_CODE_FORK_SUBAGENT=1`, a fork runs under its parent's permission mode (it cannot leave plan mode), and its own Agent call runs in the foreground, so the fork gets the child's result (2.1.285). An auto-mode subagent ends as soon as it hands its report back (2.1.285). A login-expiry warning fires before interruption, so a runner can re-auth ahead of the cut-off; gateway-auth jobs (`ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL`) survive daemon respawns.

#### Unattended-runner resilience

`CLAUDE_CODE_MAX_RETRIES` is capped at 15; for unattended batches set `CLAUDE_CODE_RETRY_WATCHDOG` instead — it raises the default retry count for non-capacity transient errors to 300 and lifts the cap. The streaming idle watchdog is on by default for all providers: a stream silent for 5 minutes aborts and retries (`CLAUDE_ENABLE_STREAM_WATCHDOG=0` disables). Transient 429s unrelated to the usage limit retry automatically with backoff for subscribers. One retry limit covers a whole model call, so with default settings a failing call sends at most 14 requests (2.1.286). Under `CLAUDE_CODE_RETRY_WATCHDOG`, a very long stream that keeps failing streams again and gives up after three timeouts (2.1.288).

#### Structured output & MCP auth

`--json-schema` structured output suits dispatch pipelines (schema-validation failures abort after 5 attempts). Since 2.1.290 a connection drop after the structured output arrived no longer exits non-zero with `is_error: true` on a `success` result. Authenticate MCP servers up front with `claude mcp login <name>` / `claude mcp logout <name>` (`--no-browser` completes over SSH). `claude agents --dangerously-skip-permissions` shows the bypass disclaimer and applies bypass mode to spawned agents.

#### Print-mode (`claude -p`) runners

`--permission-prompts none` makes an unattended runner deny anything that would prompt instead of hanging, while the active permission mode decides the rest. It is a print-mode flag, not a `claude agents` flag and not a ledger field. `claude -p` waits for a Monitor the model armed to fire or time out before exiting. A `cd` persists across turns in non-interactive sessions. With `-p`, `--agents` takes the path to a JSON file as well as inline JSON, and allows an empty `prompt`. `--system-prompt` and `--append-system-prompt` accept their text and `-file` forms together, the file's text first. The first non-interactive turn waits up to 2s for connecting MCP servers named by `--allowedTools` or an `mcp_tool` hook, even with `CLAUDE_CODE_MCP_STARTUP_WAIT_MS=0`.

#### Print-mode runners — background time limit, `--bare` and the prompt tool

In unattended sessions (`-p`, Agent SDK, CI, cloud) a background Bash or PowerShell command stops at its `timeout` (default 30 min, max 2 h) and Claude is notified (2.1.285; interactive sessions have no limit since 2.1.288). A long background job in a `-p` run therefore sets `timeout` explicitly, and a runner still stops any command that outlives its stage. `--bare` connects only the MCP servers named on the command line, sends no system reminders, starts no background tasks and skips hooks (2.1.286); never dispatch a stage with it, because the audit rows come from the child's hooks. `--permission-prompt-tool` receives a background subagent's permission request instead of auto-denying it (2.1.285).

#### Print-mode runners — exit waits, MCP start-up and overload backoff

A one-shot `claude -p` or Agent SDK run now waits for a background command and a scheduled wakeup after the final result, instead of stopping the command 5 s later and dropping the wakeup (2.1.292). A runner's exit therefore waits for those too, so bound them with `timeout`. The first turn no longer waits for HTTP and SSE MCP servers to answer `resources/list`. A runner that keeps hitting 529 overloads can lengthen the retry backoff with `CLAUDE_CODE_OVERLOADED_RETRY_BASE_DELAY_MS`.

## Live Session Discovery

`claude agents --json` returns a JSON array of currently live Claude sessions — poll it to discover what is already running, complementing the dispatch table above, which covers how to start something. Canonical orchestrator shell-out, scoped to one worktask track:

```bash
claude agents --json | jq -r --arg track "$TRACK_ID" '
  .[] | select(.metadata.worktask_track == $track) | .agent_id'
```

### Usage patterns

- **Resume pre-check** — before respawning a subagent during resume, query live sessions; if any `agent_id` from `.context/state.json.facts.dispatched_agents[]` still appears, reattach via `SendMessage` instead of re-delegating (`skills/worktask/references/resume.md § Resume Procedure` step 0).
- **Parallel track health** — `claude agents --json | jq '[.[] | select(.tag=="corpflow-track")] | length'` should equal the orchestrator-derived `parallel_tracks`. Less = stalled track.
- **Status-line integration** — drives tmux / status-bar widgets showing the active stage without polluting `.context/`.

The JSON schema is not formally versioned — guard every read with defensive jq (`.parent_agent_id // "none"`); see § Schema Versioning Watch.

### Schema Versioning Watch

#### Recorded baseline (CC 2.1.169)

Array of objects with these observed top-level fields:

- Required: `session_id` (string), `agent_type` (string), `agent_id` (string), `started_at` (ISO-8601 string)
- Optional: `parent_agent_id` (string), `cwd` (string), `tag` (string), `metadata` (object), `waitingFor` (string — what a live session is blocked on, e.g. `approval`/`input`; empty/null = busy mid-work), `id` (string — stable session identifier), `state` (string — lifecycle phase, e.g. `running`/`blocked`/`done`)

Rows also render a `done/total` progress count in the human-readable (non-`--json`) listing.

#### `--all` semantics

`claude agents [--json] --all` includes completed sessions (otherwise filtered out); blocked and just-dispatched sessions are always listed. With `state`, a resume scan can tell a `blocked` agent (reattach via `SendMessage`) from a genuinely absent one (re-delegate) (`skills/worktask/references/resume.md § Resume Procedure` step 0).

#### "Needs input" status axis

Sessions parked on a sandbox approval, an MCP elicitation/input request, or a managed-settings prompt report as "Needs input" rather than busy/"Working". The exact JSON field/value is unconfirmed (possibly a new `waitingFor` value, possibly a separate flag); until a watch run pins it, treat any such session as parked on us (same bucket as `waitingFor: approval/input`), never as busy. These parks are operator-owned (`skills/worktask/references/resume.md § Live-agent rows`). The watch run that pins the field updates this entry.

#### Defensive-read rule for optional fields

`waitingFor`, `id` and `state` are read defensively (`.waitingFor // empty`, `.id // ""`, `.state // ""`); additive optional fields do not bump min CC (§ If the baseline shifts covers only required, renamed or type-changed fields). The resume loop branches directly on `{agent_id, state, waitingFor}`.

#### Watch protocol for future /cc-update runs

In any cc-update whose CC version delta touches the `claude agents` CLI surface, the prompt-engineer runs `claude agents --json | jq 'first | keys'`, diffs the key list against the recorded baseline and the observed drift below, and surfaces any drift as a Q for the operator.

#### Observed drift — interactive rows

Interactive rows diverge from the baseline (unannounced, first seen on CC 2.1.175). As last probed (CC 2.1.294, unchanged since 2.1.270) they carry exactly `{pid, cwd, kind: "interactive", startedAt, sessionId, name, status}`: camelCase `sessionId`, `startedAt` as an epoch-millis number, a `kind` discriminator, `name` (the readable session name — also the `SendMessage`/`/rename` address, and the key a session's own name reuses), `status` (e.g. `"busy"`), and no `agent_id`, `id`, `state` or `waitingFor`. The resume identity chain `agent_id // id // sessionId` tolerates the missing ids.

#### Open: dispatched-agent and teammate rows

Unconfirmed whether rows with `kind` ≠ `interactive` keep the snake_case baseline, and what `kind` a teammate row carries: no such row was live at any probe. Release notes (2.1.234→2.1.251) say live teammates appear in `ListAgents`/`claude agents --json` and the pre-warmed idle worker stays hidden until a task claims it. Until pinned: (a) coalesce both spellings in every read (§ Defensive jq pattern); (b) filter by `kind` before matching resume rows; (c) expect the resume pre-check to degrade safely to "absent → re-delegate" when fields read null.

#### Dispatch surface drift

`claude agents run` is not a subcommand — `claude agents run --help` prints `claude agents` usage (through 2.1.294). Top-level `claude` accepts `--bg`, `--model`, `--effort`, `--permission-mode`, `--add-dir`, `--plugin-dir`, `--settings` and `--mcp-config` but no `--cwd`, so an external dispatcher must `cd` into the worktree first. Re-derived: `claude -p --agent <plugin:agent> --model <m> --effort <tier> --permission-mode <mode> --permission-prompts none` (§ Per-Stage Recommended Flag Sets; `skills/worktask/scripts/headless-dispatch.sh`).

#### Defensive jq pattern

Canonical for any plugin code reading this output:

```jq
.[] | {
  session:    (.session_id // .sessionId // "unknown"),   # camelCase observed on 2.1.175
  kind:       (.kind // "agent"),                          # "interactive" rows are NOT dispatched agents — filter before matching
  parent:     (.parent_agent_id // .parentAgentId // "none"),
  tag:        (.tag // "untagged"),
  waiting_for: (.waitingFor // ""),  # "" = busy mid-work; "approval"/"input" = parked on us
  state:       (.state // "")        # "running"/"blocked"/"done"
}
```

#### If the baseline shifts

On a baseline shift (new required field, renamed field, type change), the next cc-update bumps the min CC version and adds a migration note to the relevant `cc-features-<from>-<to>.md` band file.

#### Child tool grants: `--tools`, MCP denials & WebSearch

`--tools` listing `Grep`/`Glob` wires up dedicated native search tools rather than shelling out — relevant only to a runner hand-building the `--tools` set; the in-process `Agent()` path inherits agent-frontmatter `tools:` unchanged. A subagent's `disallowedTools` honors MCP server-level specs (`mcp__server`, `mcp__*`), so a cross-plugin dispatch can deny a whole server to a child. `WebSearch` works inside subagents (~200 calls/session, `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` tunes it). Auth-capable MCP servers hide auth-stub tools from headless / SDK runs. A subagent or `--agent` run whose own tool list leaves out a built-in tool is no longer told the tool is off for the whole session, so the child sees its narrowed grant as its own (2.1.293).

## Session Lifecycle CLI (attach / logs / stop / respawn / rm)

`claude attach <id|name>` attaches a terminal to a running background session; part of the session name works in place of the id for `attach` and `logs` (2.1.290). Since 2.1.285 `/resume` and `claude --resume <id>` open a session that is running in the background instead of refusing, and `claude --resume <id> "prompt"` sends the prompt as its next turn. `logs`, `stop` (alias `kill`), `respawn` and `rm` complete the surface (`claude --help`); options placed before the subcommand no longer start a new session (2.1.285). `logs`, `stop`, `kill` and `rm` no longer sign the operator out when the login has expired or is about to (2.1.293).

### Operator tools vs orchestrator reattach

These are operator tools for human debugging. The orchestrator's reattach path stays `SendMessage` (`skills/worktask/references/resume.md`).

### Resume and cleanup behavior

`claude --resume <session-id> --bg` continues that session under its own ID when nothing is running it, so a recorded `dispatched_agents[]` id stays valid; when a copy starts instead, the CLI announces it. A background session whose machine was off shows as stopped at its real end and asks before resuming. `claude agents`/`claude rm` delete a session whose worktree branch was merged locally but not pushed.

## Permission-Mode Pinning (in-process)

When the orchestrator reads `task.metadata.permission_mode === "default"` for a stage, it does not propagate `--dangerously-skip-permissions` or any equivalent shorthand into descendant `Agent()` calls or nested `Bash` invocations for that stage, and it appends one `audit.jsonl` line:

```json
{
  "ts": "<ISO-8601 UTC>",
  "actor": "orchestrator",
  "action": "permission_mode_pinned",
  "subject": "<task_id>",
  "result": "ok",
  "metadata": { "stage": "<code>", "mode": "default" }
}
```

Subagents inherit the parent session's permission mode (the Agent tool's deprecated `mode` parameter is ignored), so pinning is about not widening the inherited mode — the audit line records that the boundary held. Apart from `model` and `effort`, every other flag above is advisory in-process and takes effect only on a CLI dispatch.

### Subagent `permissionMode: auto`

A subagent definition with `permissionMode: auto` no longer enters auto mode when auto is unavailable — off in settings, tripped by the circuit breaker, or not supported by the model (2.1.292). It runs in the inherited mode instead.

## External-Dispatch Audit Hook

A headless runner invoking a stage from the CLI appends one line to the same worktask's `.context/logs/audit.jsonl`:

```json
{
  "ts": "<ISO-8601 UTC>",
  "actor": "external:<runner-name>",
  "action": "external_dispatch",
  "subject": "<task_id>",
  "result": "ok",
  "task_id": "<task_id>",
  "metadata": {
    "invoker": "<ci|cron|user-shell>",
    "agent": "<plugin:agent>",
    "flags": ["--model=…", "--effort=…", "--permission-mode=…", "--cwd=…"]
  }
}
```

Without it the post-worktask audit cannot tell in-process delegation from CLI dispatch, which matters for cost attribution, security review and reproducibility.

## Anti-Patterns

- Passing `--dangerously-skip-permissions` from an interactive session — it is for headless CI runs that already carry a deny-list (`permissions.deny`, `autoMode.hard_deny`) in `settings.json`; interactively, let the permission UI handle prompts.
- Pointing `--cwd` and `task.metadata.workspace_path` at different paths — resolve one canonical worktree directory and pass it consistently.
- Setting `dangerously_skip_permissions: true` on PL/SR/FN tasks: human review is the point of a gated stage. PL0 should reject such metadata at validation time.
- Treating CLI flags as a replacement for agent-frontmatter `tools:` restrictions — flags configure the session, frontmatter restricts the agent; both apply.

### FN-gate race

Background agents launched from `claude agents` auto commit, push and open a draft PR when they finish code work in a worktree, instead of stopping to ask. For gated worktasks, scope headless DV dispatches to implementation only (no push-capable permission mode or credentials) so commit/push/PR stays with the FN stage behind `fn_gate`. Megatask lanes stamp per-issue `fn_gate: "bypass"`, so lane auto-PR is by design there.

## Background Shell Dispatch

Two ways to spawn background shell work without occupying a foreground agent turn, besides a CLI agent dispatch. Choose by whether you need agent reasoning (an agent dispatch) or just a shell side-effect.

- **`! <command>`** — inside a running session, prefixing a shell command with `!` (e.g. `! swift build 2>&1 | tail -20`) runs it in a background shell and delivers stdout/stderr into session context on completion. Unlike a `Bash` tool call it does not block the turn.
- **`claude --bg --exec '<command>'`** — from outside a session, a one-shot background command that exits on completion, e.g. `claude --bg --exec 'cd "$WORKTREE" && swift build > .context/build.log 2>&1'`. For CI/cron jobs needing Claude's tool environment but no interactive agent; combine with `--model` or `--permission-mode`, and `cd` inside the command since there is no `--cwd`.

## Claude Code 2.1.295–2.1.303 observations

- Print and SDK sessions without an explicit permission mode have provider-dependent defaults (2.1.302). Always pass the ledger's capped mode.
- Fork mode is enabled by default in print/SDK/IDE sessions from 2.1.302; `CLAUDE_CODE_FORK_SUBAGENT=0` disables it.
- Main-conversation subagents run in the background; their own Agent calls default to the foreground. Keep waiting for completion evidence.
- `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL` affects workflow agents only. It refines existing `model`/`model_resolved` auditing; it needs no new ledger field.
- CLI 2.1.303 returned `[]` during the integration probe. This does not confirm, rename, or remove any baseline row key.
- A stopped `claude agents` service can end running sessions after about one minute (macOS and Linux without an installed service, 2.1.295).
- New watchdog limits bound retry waits; overload backoff uses `CLAUDE_CODE_OVERLOADED_RETRY_MAX_DELAY_MS`. Do not increase pipeline retry counts implicitly.
- `CLAUDE_CODE_AUTO_MODE_MODEL` selects the client-side classifier model only. It does not select the stage or server-side classifier model.
- Advisor flags and plugin-eval tool restrictions remain operator-only controls; they introduce no task metadata.
