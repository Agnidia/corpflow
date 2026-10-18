# DV reference — rarely needed sections of `agents/developer.md`

Read a section only when its trigger in `agents/developer.md` fires; the agent body names each one.
Kept out of the agent body because every DV turn pays for the body's tokens.

## Sibling tooling — listed, not granted

Names this route can reach, not tools this agent holds: `tools:` carries no platform build or MCP
tool (`skills/worktask/SKILL.md § Platform tooling ownership`). An XcodeBuildMCP tool is reached
only by delegating to an Apple implementation agent, which inherits the server
(`skills/cross-plugin-handoff/SKILL.md § MCP Dynamic Server Inheritance`).

### XcodeBuildMCP — project and simulator

The `tools:` union of apple-developer 1.30.2's five platform developers; re-check when that plugin updates.

`mcp__XcodeBuildMCP__session_show_defaults`, `mcp__XcodeBuildMCP__session_set_defaults`,
`mcp__XcodeBuildMCP__discover_projs`, `mcp__XcodeBuildMCP__list_schemes`,
`mcp__XcodeBuildMCP__show_build_settings`, `mcp__XcodeBuildMCP__clean`,
`mcp__XcodeBuildMCP__build_sim`, `mcp__XcodeBuildMCP__build_run_sim`, `mcp__XcodeBuildMCP__test_sim`,
`mcp__XcodeBuildMCP__list_sims`, `mcp__XcodeBuildMCP__boot_sim`, `mcp__XcodeBuildMCP__screenshot`,
`mcp__XcodeBuildMCP__snapshot_ui`, `mcp__XcodeBuildMCP__get_app_bundle_id`.

### XcodeBuildMCP — device and macOS

`mcp__XcodeBuildMCP__build_device`, `mcp__XcodeBuildMCP__test_device`,
`mcp__XcodeBuildMCP__install_app_device`, `mcp__XcodeBuildMCP__launch_app_device`,
`mcp__XcodeBuildMCP__list_devices`, `mcp__XcodeBuildMCP__get_device_app_path`,
`mcp__XcodeBuildMCP__build_macos`, `mcp__XcodeBuildMCP__build_run_macos`,
`mcp__XcodeBuildMCP__test_macos`, `mcp__XcodeBuildMCP__launch_mac_app`,
`mcp__XcodeBuildMCP__stop_mac_app`, `mcp__XcodeBuildMCP__get_mac_bundle_id`,
`mcp__XcodeBuildMCP__get_mac_app_path`.

## Absolute-path mode — supported when EnterWorktree is refused (D0.0)

When the host refuses `EnterWorktree` on the assigned path (an out-of-tree confirmation denied, an externally-managed tree already checked out), use absolute-path mode on the assigned tree — a supported mode, not a degradation. Never fall back to the shared checkout and never pick a different tree. A `/megatask` per-issue DV starts here without trying `EnterWorktree`, as its banner says: its tree is a linked worktree outside `.claude/worktrees/` (check with `git -C "$WORKSPACE_ROOT" rev-parse --git-dir`).

- Every Read/Edit/Write path is absolute and under `$WORKSPACE_ROOT`; every git call is `git -C "$WORKSPACE_ROOT"`; build and test runners get the same root explicitly.
- D0.0a still runs, from inside that tree, with `--assigned "$WORKSPACE_ROOT"`.
- `worktree:` stays `true` — the pinned tree is isolated whether or not you entered it through the tool. Record the refusal and the mode in `§ Approach`.

## Worktree Mode

All DV operations run in the isolated worktree (§ D0.0). Use `EnterWorktree`/`ExitWorktree`; git with `git -C {workdir}`. Point build/test at the worktree with the toolchain's own directory flag rather than `cd`-chaining — `--package-path` (SwiftPM), `-p`/`--project-dir` (Gradle), `--prefix` (npm), `-C` (make), `--rootdir` (pytest); `/<plugin>:build-test` takes the path directly. Base-ref resolution, background & shared-checkout rules, the out-of-tree `EnterWorktree` confirmation guard, and background-session lifecycle: `skills/worktask/references/workspace-modes.md § DV Worktree Mechanics`.

A direct build or test run follows `skills/cost-optimization/SKILL.md § 4d. Command Output Hygiene`.

### cwd discipline

Every `Write`/`Edit` targets a path under `task.metadata.workspace_path` while a worktree is active. Reading context from outside it is fine; writing back to those external paths is not. Verify the prefix before each write — a path under `.../conductor/workspaces/<repo>/<workspace>/…` proceeds; one under `.../Projects/…` (plugin source repo / canonical clone) is a stop: rebase onto `workspace_path`. When in doubt prefer `Bash: pwd` plus a relative path over an absolute path inherited from an outside `Read`.

### Produced and landed files

- **Producer**: a row with `produces` runs `git add -- <path>` for each declared path before its completion patch. Landing copies the staged index blob, so an unstaged path blocks the consumer `not_staged` and an edit after staging blocks it `staged_then_modified`; re-stage after any later edit.
- **Consumer**: your row's `landed_paths`, also named on the `LANDED (read-only, never edit or stage)` dispatch line, are read-only: never edit, never stage. The producer's tree ships them, and the DR and FN untracked checks exclude them.

## Eval-Harness Authoring (with-skill / without-skill A-B loops)

When building an eval harness for orchestrator fan-out (`RUN.md` + per-prompt files), `RUN.md` carries an arm-symmetry clause: every run receives only its named prompt file's content; the orchestrator adds no spawn-time instruction/hint/caveat absent from BOTH arms' files. A grading-integrity meta-instruction (e.g. "do not compensate with prior knowledge") goes into every prompt file's shared preamble before the arm-specific directory line, never improvised per-arm.

## Budget-Aware Checkpointing (multi-batch runs)

The gate above fires at return time; if you exhaust context mid-batch the orchestrator inherits partial, undocumented state. So checkpoint as you go.

### Checkpoint steps

1. **After each sub-batch commit**, merge a lightweight progress record into `state.json → tasks.<ID>.progress` (your own row; schema: `handoff-protocol.md#state-json-schema`) — completed batch ids and the next pending batch, nothing heavier (no diffs, no file contents):

   ```bash
   _sf=".context/state.json"; _tmp="${_sf}.tmp.$$"
   jq --arg id "<ID>" --argjson done '["B1","B2"]' --arg next "B3" \
      '.tasks[$id].progress = {completed_batches:$done, next_batch:$next, updated_at:(now|todateiso8601)}' \
      "$_sf" > "$_tmp" && sync "$_tmp" && mv -f "$_tmp" "$_sf"
   ```

### Checkpoint steps 2–3

2. **At the checkpoint turn** your brief's `TURN BUDGET` line names, or when the remaining context cannot finish the next batch, do not push forward: finish and commit the batch in flight, update `tasks.<ID>.progress`, write `<your artifact>` with no `handoff.verdict`, list every unfinished batch in its body, and return. The orchestrator auto-resumes that partial return (`references/return-arms.md § Step 6.5a2`); a re-dispatch resumes from `progress.next_batch`. `## Blockers` (`kind: hard_constraint`, `escalate_to: TL`) is for a real hard constraint only.
3. **Never emit a progress narration as terminal output.** A checkpoint artifact with its unfinished batches listed is a valid partial handoff; a chat-style "here's where I got to" is not.

## Delegation

Route with the Agent tool. The `subagent_type` is the qualified agent ID from `agents/developer.md § Platform Specialization` or, for specialists outside those rows, from the per-platform tables in `skills/shared/platform-detection.md`. The delegate's brief carries its own `TURN BUDGET` line, sized to the delegate's `maxTurns` by the same helper (`references/return-arms.md § Turn budget — the cap`).

### Dispatch Injection (REQUIRED)

Before every `Agent(<plugin>:<agent>)`, resolve the sibling's root; `<plugin>` is the id before `:` and the one stdout line is `<ROOT>`:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/resolve-sibling-root.sh <plugin>
```

Open the prompt with:

```
Your plugin root is <ROOT>. Read <ROOT>/CORPFLOW.md and follow it; resolve every file you need under <ROOT> and never search the filesystem for plugin files.
```

Exit 1 → dispatch nothing to that plugin; take `agents/developer.md § Plugin unavailable` with the stderr line as `reason`.
Pass `effort` = the `effort:` line of your brief on every such call; without it the target runs at its own frontmatter tier (`skills/agent-coordination/SKILL.md § Effort on nested delegation`).
Follow the plugin-root line with section `[4b]`, the model discipline block
(`skills/cross-plugin-handoff/SKILL.md § Model discipline block`).

#### Why the line is required

A sibling plugin's agents carry no corpflow preamble (`skills/cross-plugin-handoff/references/plugin-contract.md`): without the line the specialist returns an artifact with no `handoff:` frontmatter, and without `<ROOT>` it searches the disk and can load another config's install. Without `[4b]` it gets no model discipline, since it cannot tell which model it was dispatched on.

### Context Passing

Pass: the exact-output contract verbatim (`agents/developer.md § Pass the contract verbatim`), task description, detected platform markers, DV stage context (task ID, compressed summaries of `<plan_file>` and — when AR ran — `architecture-N.md`, test strategy), acceptance criteria, platform constraints, architectural decisions, and the code-documentation rule (`skill: corpflow:code-comment-standard`; density ≤40% of added lines, gated by `dv-comment-density-gate.sh`; rationale and answers to DR findings go in `<your artifact>`, never in source). Request implementation code, a summary for `<your artifact>`, and any blockers in the `## Blockers` schema (`agents/developer.md § Artifact Schema`).

### Routing Audit

On every `Agent(specialist)` invocation append one `audit.jsonl` line: `action: "delegation"`, `metadata: {to_agent: "<qualified subagent_type>", platform: "<apple|android|web|systems|backend|ai>", markers: [<matched globs>], reason: "<one-line why>", task_id: "<DV task id>"}`. When the target came from a routing override, add `alias: "<corpflow:* alias>"` and `routing_source` (`"project-override"` or `"user-override"`, from `state.routing_source`) to the metadata. The specialist writes its own retry/error narrative to `.context/errors/<basename>.md` (e.g. `errors/ios-developer.md`) per `stage-contracts § Cross-Plugin Stages`. A `delegation` row pointing at `self`/generic for a back-end (→ `backend-developer:*`) or web-UI (`.tsx`/`.vue`/`.svelte`/component/state/styling → `frontend-developer:*`) DV task is a routing miss.
