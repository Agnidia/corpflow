# Hook-Based Stage Monitoring

Claude Code hook events for monitoring agent lifecycle within worktasks.

## Subagent Lifecycle Hooks

| Hook Event | Fires When | Matcher | Payload Fields |
|------------|------------|---------|----------------|
| `SubagentStart` | Stage agent spawned | Agent type name (e.g., `corpflow:developer`) | `agent_id`, `agent_type` |
| `SubagentStop` | Stage agent completes | Agent type name | `agent_id`, `agent_type` |
| `PermissionDenied` | Auto-mode classifier denies a tool call | — | `tool_name`, `tool_input`, `tool_use_id`, `reason` |
| `StopFailure` | API error causes turn end | — | Error details |
| `CwdChanged` | Working directory changes | — | New cwd path |
| `FileChanged` | Monitored file modified | — | File path |
| `WorktreeCreate` | Worktree created | — | Worktree path |
| `DirectoryAdded` | A working directory is registered mid-session (`/add-dir`, or the SDK `register_repo_root` control request) | — | Added directory path |

#### Agent-scoped hooks live in plugin.json

Claude Code ignores `hooks:` (and `mcpServers:`, `permissionMode:`) in the frontmatter of an agent loaded from a plugin, so a hook declared there never runs. To scope a hook to one corpflow agent, register it in `.claude-plugin/plugin.json` under `SubagentStart` or `SubagentStop` with an anchored matcher: the matcher tests the plugin-scoped agent type, and an unanchored `corpflow:stakeholder` would also match any name containing it. `hooks/agent-stop.sh` is wired this way, one group per stage agent:

    { "matcher": "^corpflow:product-manager$",
      "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/agent-stop.sh", "args": ["--stage", "PL"] } ] }

Claude Code's own internal agents (prompt suggestions, `/btw`) also fire `SubagentStop`, with an empty `agent_type`; a named matcher never selects them, a missing one does. `tests/shell/hooks/agent-stop.bats` pins the wiring.

### Later lifecycle events

| Hook Event | Fires When | Matcher | Payload Fields |
|------------|------------|---------|----------------|
| `MessageDisplay` | A message is displayed to the user | — | `message`, `role` (`user`/`assistant`), `display_type` |
| `SessionStart` | Session begins | — | `session_id`, `session_title`, `reloadSkills` (bool), `source` (session origin — a forked session reports `"fork"`, not `"resume"`) |
| `Notification` | Background agent needs input or finishes; also permission prompts (incl. Claude Desktop / VS Code). `idle_prompt` does not fire while background agents still run | — | reason ∈ `agent_needs_input` / `agent_completed` |
| `PreModelSwitch` | A model switch is about to apply | — | Unconfirmed — see § Model-Switch Hooks |
| `PostModelSwitch` | A model switch has applied | — | Unconfirmed — see § Model-Switch Hooks |

#### Later lifecycle events — instruction loading

| Hook Event | Fires When | Matcher | Payload Fields |
|------------|------------|---------|----------------|
| `InstructionsLoaded` | A rule or nested CLAUDE.md loads, including on Write/Edit inside its scope and on a single-file Bash `cat`/`head`/`tail`/`sed -n`/`grep` view (2.1.293) | — | `agent_id`, `agent_type` when a subagent's file access loaded it; effort for rules and nested CLAUDE.md loaded on file access |

### Notification as resume wake-up

`Notification` with `agent_needs_input` / `agent_completed` is the push complement to polling `claude agents --json` during resume: wire it to nudge the orchestrator (or the operator) the moment a stage parks. The `--json` pre-check stays the authoritative reconciliation (`skills/worktask/references/resume.md` step 0). It fires for permission prompts under Claude Desktop / VS Code too, so an unattended run surfaces a parked stage instead of stalling silently.

The Agent tool has no `resume` parameter; use `SendMessage` to reach running agents.

### SessionStart semantics

- `reloadSkills: true` reloads plugin skills mid-session (e.g. after `/reload-skills`) and re-announces only changed skills — listeners re-apply skill-specific initialization idempotently, never assuming every skill re-announces. `sessionTitle` rides alongside it.
- Events stream in headless sessions, so a headless run cannot idle-reap remote workers mid-hook before the handler finishes.

#### SessionStart — resume hooks and rendering

- Resume hooks also receive the session's staleness and an estimated re-cache cost (field names unconfirmed), which lets the resume loop weigh reattach against re-dispatch — policy: `skills/worktask/references/resume.md § Step 0 notes — reattach vs re-dispatch — cost estimation`.
- `--continue`/`--resume` render the conversation without waiting for `SessionStart` hooks, so resume context a hook injects can arrive after the conversation is on screen. Never assume a SessionStart hook has finished before a resumed session is shown.

#### SessionStart — form & grant floor

- Plugin hooks use `${CLAUDE_PLUGIN_ROOT}` exec-form (`type: command` + `args`); shell-form hook commands using `${user_config.*}` are rejected at load, which does not affect them.
- A `PreToolUse` auto-allow inside a background agent task (summaries, compaction, renames) cannot grant tools the agent's own `tools:` list denies — the grant list is the floor.

### Compaction recovery & hook-output guards

- `PreCompact` fires before automatic compaction and blocks it with exit code 2. The managed `hooks/precompact-checkpoint.sh` (in `plugin.json`) snapshots `.context/state.json` to `.context/state.checkpoint-<ts>.json` on every compaction and never blocks (always exit 0).
- `<system-reminder>` tags in hook output are escaped before they reach Claude (2.1.292); corpflow hooks never rely on them.
- Parent agents recover subagent results after compaction; killed or interrupted background agents keep partial results in context. `PostCompact` can re-inject critical state: the managed `skills/context-compression/scripts/post-compact-recovery.sh` writes `.context/logs/post-compact-<ts>.json`. It is registered and recurrence-guarded (`manifest-parity.bats`) but has never been observed firing — a real compaction cannot be simulated in CI — so treat it as registered, not confirmed working.

#### SessionEnd finalization

`SessionEnd` fires on session teardown. The managed `hooks/session-end-finalize.sh` appends one `session_end_finalize` row to `.context/logs/audit.jsonl` naming any tasks still `in_progress`, so a resume can tell "still running" from "died with the session". It only reports and never mutates task status: a teardown hook races the writer it would need the ledger lock from, and a wrong terminal status is worse than an honest unsettled one. It always exits `0`, so a lost row never delays teardown.

Its `plugin.json` entry carries `"timeout": 5`, which bounds the run. Without a per-hook `timeout` a SessionEnd hook gets 1.5 s unless the operator exports `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`; the row is the resume loop's only "died with the session" signal, so its budget must not depend on operator env.

#### Payload, monitor & stall notes

- Hook output over 50K characters is saved to disk and replaced in context by a file path + preview, so a hook or background agent emitting megabytes of error output cannot wedge the session on "Prompt is too long".
- A hook whose stdout is a `{…}` object that is not valid JSON is reported as a hook error naming the parse failure, so a malformed gate verdict fails loudly rather than passing as prose.

##### Payload fields, monitors & stalls

- PreToolUse/PostToolUse hooks receive `file_path` as an absolute path for Write/Edit/Read; `UserPromptSubmit` hooks receive `hookSpecificOutput.sessionTitle`.
- Plugins declare long-running background monitors via the `monitors` manifest key — they stream events into the session without occupying a foreground tool call.
- Stalled subagents fail with a clear error after 10 minutes; surface it and retry or escalate rather than waiting (`skills/agent-coordination/SKILL.md § Stall Timeout`).

### Gate-feedback contract & Stop/SubagentStop additionalContext

Stop and SubagentStop hooks may return `hookSpecificOutput.additionalContext` to feed remediation text back to the model without it being labelled an error. Unlike a bare `{"decision":"block"}`, the `additionalContext` rides into the re-run's context as a fix instruction.

#### Screenshot-gate block payload

`dv-screenshot-gate.sh` reads the stopping task's `screenshots-<TASK_ID>.md` and blocks missing or invalid evidence; no captures passes only on `backend`/`systems`:

```json
{
  "decision": "block",
  "reason": "no_captures — task <TASK_ID> on platform web has no capture rows",
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": "run bash \"$PLUGIN_ROOT/skills/dv-screenshot-capture/scripts/capture.sh\" --task-id <task_id> --context-dir <context_dir> <platform args> --capture <slug>[:<arg>] in one Bash call (agents/developer.md § Screenshot Capture); … headless is not a skip reason; expected manifest .context/images/<worktask_id>/screenshots-<TASK_ID>.md"
  }
}
```

#### Gate-side flag escalation

For a resolved DV task whose flag reads `false`, the gate also invokes `escalate-flag.sh` in its worktree (10 s watchdog, fail open) and re-reads the flag: it may raise it to `true`, never lower it. An escalated block opens with `gate raised the planner's requires_screenshots=false: <n> UI path(s) matched in <ws>`.

The row's `metadata.escalation` holds `invoker` (`gate`), `action` (`escalated|noop|warn|skipped|fault`), `reason` (the helper's token, or `worktree_unresolved`, `helper_missing`, `helper_exit`, `escalation_timeout`, `stdout_unparsable`), `flag_after`, `worktree`, and `rc` / `matched_count` when present. Stops that did not run the helper have no `escalation` key.

#### Gate-feedback contract (one contract, two surfaces)

Every worktask gate — hook-enforced or orchestrator-mediated — returns structured remediation that flows into the next attempt's context:

| Surface | Mechanism | Reference user |
|---------|-----------|----------------|
| Hook gate | `hookSpecificOutput.additionalContext` alongside `decision:block` | `hooks/dv-screenshot-gate.sh` (block path) |
| Orchestrator gate | `blockers[]` / `blocking_defects[]` into the re-dispatched prompt's [6], one flattened line each | `brief-compose.sh`, fed by the `SKILL.md` DR→DV / QA→DV loop-back (`gate_remediation_injected` row) |

The surfaces are symmetric — the hook embeds remediation in the block JSON, the orchestrator embeds the upstream blocker list in the retry prompt — so change them together. The `decision:block` verb, the exit-0 discipline and the `screenshot_gate_block` audit-row schema are unchanged by it; `hookSpecificOutput` is an additive stdout field.

### OTEL Dispatch Tree Parenting

`claude_code.tool` spans carry `agent_id` and `parent_agent_id`, and subagent spans nest under the dispatching `Agent` tool span. With a collector wired via `settings.json` → `otelExporter`, the PL→…→ST dispatch becomes one nested trace tree, and an orphan span identifies a subagent that escaped the chain. A tool execution deferred by a `PreToolUse` hook resumes in the original turn's trace, so a gated call stays attributed to the stage that made it.

#### Hook-stdin forward-compat

`parent_agent_id` is OTEL-side and not confirmed in Stop/SubagentStop hook stdin; `audit-subagent.sh` and `agent-stop.sh` capture it defensively with `(.parent_agent_id // "none")`, so it populates the moment CC surfaces it. Observability only; dedupe keys do not use it.

### Background Tasks & Crons Visibility

Stop/SubagentStop hook stdin includes `background_tasks` and `session_crons` arrays. `hooks/audit-subagent.sh` and `hooks/agent-stop.sh` capture them as additive metadata on existing audit rows, for cross-correlation (which cron/bg task was active when a stage spiked):

- `background_tasks_count: ((.background_tasks // []) | length)`
- `background_task_ids: ((.background_tasks // []) | map(.id // .task_id // "unknown"))`
- `session_crons_count: ((.session_crons // []) | length)`
- `session_cron_ids: ((.session_crons // []) | map(.id // .cron_id // "unknown"))`

Metadata only: the `dedupe_key` shape is unchanged.

### OTEL attributes & log-event correlation

- `tool_decision` events carry `tool_parameters`, so dashboards can tell a `Bash git push` decision from a `Bash ls`.
- `OTEL_RESOURCE_ATTRIBUTES` values surface as metric-datapoint labels, not only span attributes: tag `worktask_id` / `stage` there to slice dashboards per stage without parsing spans.
- `claude_code.lines_of_code.count` carries a `model` attribute — per-model LoC attribution pairs with the tier split in `skills/shared/stage-codes.md`.
- `OTEL_METRICS_INCLUDE_REPOSITORY` tags metrics and events with `vcs.*` repository attributes, so a collector shared across repositories slices per repo.
- Project and local settings ignore the variables that turn on export, set its endpoint or capture content, so a committed `<repo>/.claude/settings.json` cannot start a per-stage dashboard on its own.

#### Log correlation, limits & trace nesting

- Log events carry `message.uuid`, `client_request_id` and `tool_source` for message-level correlation and tool provenance across spans and audit rows.
- `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` sets the 60 KB truncation limit on OTEL content attributes — set it with `OTEL_RESOURCE_ATTRIBUTES` when a collector enforces a payload ceiling.
- Log events emitted outside the turn's async context (background/notification-triggered) carry the interaction span's trace context, so a background-agent completion nests under the originating trace.
- Session transcripts record the reasoning effort per assistant message and `subagentStatusLine` includes it; the `subagentStatusLine` payload also carries `agentType`, so a status script can tell custom subagent types apart (2.1.293) (pairs with § Hook Effort Visibility).

#### BG-Task ID Schema Watch

The ID extraction coalesces `(.id // .task_id // "unknown")` / `(.id // .cron_id // "unknown")` because the canonical key name is not confirmed in CC docs. An `"unknown"` in `background_task_ids` or `session_cron_ids` means CC populates the arrays with an ID field named neither `id` nor `task_id`/`cron_id`; the next `/cc-update` then pins the canonical key (removing the coalesce) in both hook scripts.

Six `subagent_stopped` rows (2026-09-07) resolved real ids and none read `"unknown"`, but the coalesce masks which spelling matched, so the canonical key is still unconfirmed.

### Managed (plugin) vs ad-hoc (user) hooks

Plugin-managed hooks ship in `.claude-plugin/plugin.json` (the current set is there) and survive `allowManagedHooksOnly: true` enforcement, which also runs hooks from force-enabled plugins. The audit trail is a plugin invariant: these fire on every install. Ad-hoc user hooks go in project or `~/.claude/settings.json` for opt-in integrations like dashboard webhooks or SIEM forwarding; the examples below are templates for that case.

### Project-Level Configuration

One `settings.json` block covering every hook shape — `matcher`, the conditional `if`, exec-form `command` + `args`, `http`, and `mcp_tool`:

```json
{
  "hooks": {
    "SubagentStart": [
      {
        "matcher": "corpflow:.*",
        "hooks": [
          { "type": "command", "command": "./tools/log-stage-start.sh", "args": ["--stage", "DV", "--json"] }
        ]
      }
    ],
    "SubagentStop": [
      {
        "if": "agent_type matches 'corpflow:.*'",
        "hooks": [
          { "type": "http", "url": "https://dashboard.example.com/webhook/stage-complete" },
          { "type": "mcp_tool", "server": "audit-mcp", "tool": "log_event", "continueOnBlock": true }
        ]
      }
    ]
  }
}
```

#### Hook entry shapes

- `args: string[]` next to `command` avoids shell-string quoting issues for paths with spaces.
- `type: "mcp_tool"` lets a hook call an MCP server action (elicitations, tool searches) without shelling out. On a blocking event (`PreToolUse` and similar) it waits for a still-connecting server, up to the MCP connect timeout, instead of being skipped.
- `continueOnBlock: true` keeps later hooks in the same matcher group running when an earlier one blocks — use it when independent observers (audit + cost) must both run.

## Conditional Hook Execution

The `if` field uses permission-rule syntax to avoid unnecessary process spawning. It handles compound commands (`ls && git push`) and env-var prefixes (`FOO=bar git push`), and path-conditional matchers on `Read`/`Edit`/`Write` match the target file path. A single-segment `dir/**` matches only `<cwd>/dir`; write `**/dir/**` for any depth.

### Matcher semantics

Hyphenated matchers exact-match rather than substring-match, so a matcher meant to catch an agent however the runtime qualifies its name needs explicit wildcards (`.*corpflow:project-manager.*`, per the `mcp__server__.*` guidance). Comma-separated matchers (`"Bash,PowerShell"`) do not fire — use regex alternation (`Bash|PowerShell`). `Stop` takes no matcher (one set there is ignored) and fires only when the main session ends a turn, so per-agent notifications belong on `SubagentStop`.

### PreToolUse decisions

- Returning `{ "updatedInput": "answer" }` satisfies an `AskUserQuestion`, enabling automated responses in worktask pipelines.
- Returning `"defer"` pauses a headless (`-p`) session at the tool call for later `-p --resume` re-evaluation — the CI/CD approval-gate mechanism.
- JSON on stdout with exit code 2 blocks the call, and the block holds even when that JSON fails schema validation: a malformed payload cannot downgrade an intended block to a pass.
- `permissions.deny` rules override a hook's `permissionDecision: "ask"`; conversely auto mode cannot override an `ask` — a hook `ask` floors the decision at a prompt, even for unsandboxed Bash.
- A `PreToolUse` or `PermissionRequest` hook whose matching fails, or whose tool input cannot be serialized to JSON, blocks the call instead of being skipped. Permission rules and safety checks run again on the input a `PreToolUse` hook rewrote.

### PermissionDenied decision

- The `PermissionDenied` hook fires after an auto-mode classifier denial. Its one decision output is `hookSpecificOutput.retry`, and corpflow never returns `retry: true`: `hooks/permission-denied.sh` leaves the denial standing, appends one redacted `permission_denied` audit row (`tool`, `dedupe_key` and a masked, path-scrubbed `command_head`; never the command, reason or allow rule) and prints nothing.
- The stage returns `verdict: blocked` with a permission `blocked_on`, which holds the full detail; the orchestrator parks the task, asks the user, and resumes only the denied step (`skills/worktask/SKILL.md § Step 6.5a4`). The user grants in Claude Code's own permission UI or runs `! <command>` from the `cwd:` directory the question shows; corpflow writes no allow rule.

### PostToolUse behaviors

- Format-on-save hooks do not cause "File content has changed" errors between consecutive Edit/Write calls — linters and formatters that rewrite files are safe.
- `PostToolUse` and `PostToolUseFailure` inputs include `duration_ms` (tool execution time excluding permission prompts and `PreToolUse` hooks); the managed `hooks/audit-tooluse.sh` records `duration_ms` + `effort.level` on every `tool_invoked` row.
- `hookSpecificOutput.updatedToolOutput` replaces tool output for all tools — `{"hookSpecificOutput": {"updatedToolOutput": "<sanitized output>"}}` — to redact secrets, normalize line endings, or inject structured envelopes before results hit context.
- Async hooks that emit no response payload write no empty transcript entries.
- A hook's `{"continue": false}` halt holds even when the attached tool fails or completes mid-stream.

#### Hook processes & plan visibility

- A synchronous hook finishes shortly after its own process exits, even when a background child it started (`some-daemon &`) keeps the output open. An `asyncRewake` hook whose script is missing is reported once, not on every wake.
- Hooks on `ExitPlanMode` see the plan written in the same response.

### Hook Effort Visibility

Hook payloads include `effort.level` (`low|medium|high|xhigh|max`), so audit/cost hooks can attribute spend to the effort tier without parsing model metadata. corpflow hooks read the payload only and write `"unknown"` when it has no `effort`. `$CLAUDE_EFFORT` is not a substitute: a haiku subagent's payload omits `effort` while the env var still holds the tier the `Agent` call requested (2.1.292). Tier model: `skills/shared/model-selection.md`.

### Error, config & compatibility semantics

- Hook errors include the first line of stderr in the transcript, so `--debug` is not needed; `SessionStart`, `Setup` and `SubagentStart` hooks exiting with code 2 also show their stderr. The debug log keeps a failed hook's stderr even when it also wrote stdout, and records its status code.
- `{"decision":"block"}` from an `Elicitation` or `ElicitationResult` hook declines the MCP elicitation, as exit code 2 does.
- A hook-callback timeout is reported as a timeout and infrastructure errors as such, never as a user rejection: route them as transient failures, not refusals.
- Unrecognized hook event names in `settings.json` do not break the file, so forward-compatible configs survive CC downgrades.

#### OpenTelemetry events

- The `user_prompt` event carries `prompt_text`, a copy of `prompt` — mask or drop it wherever `prompt` is masked. A permission ask left unanswered (in `-p` or on an interrupted turn) emits a `tool_decision` event, and `claude_code.tool.blocked_on_user` spans report their real source and decision.

#### Deleted cwd & broken-hook parks

- After the session's working directory is deleted, hooks run from the project root or home directory. A hook must not assume its cwd still exists — resolve paths from an explicit root, as `hooks/model-switch-lib.sh` and `hooks/state-merge.sh` do.
- A background session parked because a `PermissionRequest`/`PreToolUse` hook printed an invalid answer shows a `claude agents` row naming the hook and the schema error. Read it as an operator-owned park, not a stage to re-dispatch (`skills/worktask/references/resume.md § Live-agent rows — broken hook configuration`).

#### Config-error hints & main-thread agents

- A prompt-type or agent-type hook for `SessionStart`, `Setup` or `SubagentStart` is rejected at load ("use a command-type hook instead"): stage-lifecycle hooks that must react before any session message exists are `type: "command"` (or `type: "mcp_tool"`).
- A `prompt` or `agent` hook written as an instruction ("Block commands that ...") now blocks what it names, and an instruction-style `prompt` hook on `Stop`/`SubagentStop` ends the turn early less often (2.1.294). corpflow ships only command hooks; re-check a sibling or user hook of either type.
- Agent frontmatter `hooks:` and `mcpServers` apply in `--agent <name>` main-thread runs as well as subagent delegations, but only for project and user agents: a plugin agent ignores both in either context (§ Agent-scoped hooks live in plugin.json).

### Hook Terminal Sequences

Hook JSON output accepts `terminalSequence` — `{"hookSpecificOutput": {"terminalSequence": "\u001b]9;Stage QA complete\u0007"}}` — for desktop notifications (OSC 9 / OSC 99), window-title updates (OSC 0/2) and bells (BEL `\x07`) without owning a controlling terminal. Use it on `SubagentStop`, `StopFailure` and `Stop` in headless or background sessions where the parent UI should still notify; pair with the `monitors` manifest key for plugin-level notifications that survive a missing TTY (CI, `claude agents` dispatch).

## Model-Switch Hooks

`PreModelSwitch` can block, confirm, or annotate a model switch; `PostModelSwitch` observes one that already applied. corpflow uses the pair to keep a stage on the tier it was dispatched with: `hooks/model-switch-gate.sh` refuses a mid-worktask re-tier away from `metadata.model`, and `hooks/model-switch-audit.sh` records `model_switched` so cost is attributed to the model that actually ran.

| Registered hook | Event | Decision |
|---|---|---|
| `hooks/model-switch-gate.sh` | `PreModelSwitch` | `block` on an unexplained family change, `confirm` on an explicit user switch, `annotate` on a fallback or an unreadable payload, silent otherwise |
| `hooks/model-switch-audit.sh` | `PostModelSwitch` | none — appends one `model_switched` row, gated on an existing ledger |

### Payload schema — read defensively

The official hooks reference documents `to_model`, `from_model`, and `source` (`command`, `picker`, `sdk`). No installed-build payload was observed. The gate prioritizes these names and retains alternate spellings defensively. Its header distinguishes documented fields from live-unconfirmed and assumed fields; update both after a live probe. Notices use top-level `systemMessage`; ask/deny decisions use `hookSpecificOutput.permissionDecisionReason`. `PreModelSwitch` does not accept `additionalContext` or custom `annotate`/`confirm` decision values. Only interactive `/model` can show an ask prompt; other surfaces refuse it. See [the official hook reference](https://code.claude.com/docs/en/hooks#premodelswitch).

#### Why this gate fails open

The gate's pin is not guessed: it reads `.facts.dispatched_agents[].model_requested` (`skills/worktask/references/handoff-protocol.md § facts — dispatched_agents`). A block is reachable only once the destination coalesce matches a real field, so a wrong guess degrades to annotate-or-silent rather than a spurious block. A gate that failed closed on a malformed payload would wedge every session that switches models.

One closed path sits outside the gate: a plugin hook that fails to load refuses the model switch with the cause named, and each later switch re-checks — so a broken `model-switch-gate.sh` load refuses switches only until the fault is fixed.

## Agent Teams Lifecycle Hooks

With agent teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), two more events support event-driven orchestration in megatask mode, where the lead reacts to teammate progress:

| Hook Event | Fires When | Payload Fields | Use Case |
|------------|------------|----------------|----------|
| `TeammateIdle` | Teammate finishes work and becomes idle; never from the teammate's own subagents or forks | `agent_id`, `agent_type`; the notification carries the teammate's final answer | Read the lane's result directly; assign next task |
| `TaskCompleted` | A task in the shared task list is completed | `agent_id`, `agent_type` | Trigger dependent stages, update orchestrator |

### Stopping teammates programmatically

Either handler can terminate a teammate by returning `{ "continue": false, "stopReason": "Issue completed — PR created" }` — when the issue is done, the megatask budget is exhausted, or a blocking error needs lead intervention.

Background tasks a teammate launches survive the teammate finishing its turn: `TeammateIdle` does not mean its background work has stopped.

## Agent Teams vs Subagents

| Aspect | Subagents (Agent tool) | Agent Teams (`Agent(name: …)`) |
|--------|----------------------|------------------------|
| Context | Own window, results return to caller | Fully independent sessions |
| Communication | Report back to parent only | Direct inter-teammate messaging |
| Coordination | Task dependencies (blockedBy) | Shared task list + messaging |
| Tool restrictions | `tools` frontmatter per agent | Inherits lead's permissions |
| Token cost | Lower (results summarized) | Higher (N context windows) |
| Nesting | Up to 3 levels deep by default (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`), foreground and background sharing one depth budget | Cannot spawn sub-teams |
| Source isolation | None by default; `isolation: worktree` in frontmatter | None by default; worktree mode recommended for megatask |

### When to Use Each

| Worktask Pattern | Subagents | Agent Teams |
|-----------------|-----------|-------------|
| Standard 9/11-stage | Default | Not recommended |
| Cross-plugin handoff (DV→apple-developer) | Default | Not applicable |
| Megatask sequential issues | Default (orchestrator) | Not recommended |
| Megatask parallel independent issues | Agent-based tracks | Optional (experimental) |
| Cross-cutting research / competing hypotheses | Possible | Preferred |
| Code review from multiple perspectives | Possible | Preferred |

### Limitations

- Teammates cannot spawn their own teams (runtime-enforced). Whether the teammate runtime inherits subagent nesting is unverified — treat teammate→subagent spawning as unsupported until observed.
- One implicit team per session — no create/teardown; spawn teammates with `Agent(name: …)` (`team_name` accepted but ignored).
- No session resumption for in-process teammates; token cost is ~Nx for N teammates.
- `/clear` does not kill background agents, so clearing the main session during long runs is safe; background bash processes spawned by subagents are cleaned up on exit.

## MCP Elicitation

MCP servers can request structured input mid-task via interactive forms or browser URLs, which may pause agent execution (Xcode build, Figma, Chrome). Elicitation hooks let worktask agents intercept these.

| Hook Event | Fires When | Use Case |
|------------|------------|----------|
| `Elicitation` | MCP server requests user input | Pre-fill defaults, validate requests, log elicitations |
| `ElicitationResult` | User responds to elicitation | Audit responses, transform data, route to agents |

Use them to log elicitation requests for the audit trail, pre-fill known values from task metadata, and route complex elicitations to the right stage agent.

## Hook reliability through Claude Code 2.1.303

Command and HTTP hooks accept `onFailure: "block"` from 2.1.295. Launch failures, unexpected exits,
timeouts, and invalid JSON/schema output block supported actions. A deliberate exit 0 still follows the hook's own decision.
The plugin pins this behavior on its test-execution and decision-protection PreToolUse hooks and its PreModelSwitch gate.
Advisory artifact checks and observational hooks retain their existing behavior.
`onFailure` has no effect on Stop, SubagentStop, TaskCompleted, TeammateIdle, or asynchronous command hooks.
Keep the stage-boundary harness as the enforcement mechanism when a completion hook cannot run.

Async multiline JSON and SessionStart environment propagation are fixed in 2.1.295. SessionEnd while
background commands run and plugin worktree hooks under `--worktree` are fixed in 2.1.300; `--tmux` remains excluded.
Hook `updatedInput` is validated as tool input from 2.1.300; unknown keys are dropped and invalid input denies the call.
Prompt and agent hooks run at most twelve instances per event concurrently from 2.1.302. Command hooks are unaffected.
These releases do not confirm background notification ID keys, maxTurns partial keys, or model-switch/resume payload field names.
