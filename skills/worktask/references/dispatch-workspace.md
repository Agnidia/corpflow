# Dispatch workspace

Read when executing or checking dispatch workspace.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Error Handling](workspace-scheduling.md#error-handling)

<!-- canonical-body:start -->
#### Step 4.8

Two banners, because isolation and assignment are two claims: a stale worktree of a different
clone is isolated, satisfies D0.0, and is still the wrong tree — the case `dv-tree-preflight.sh`
catches. Neither banner is the `WORKSPACE_ROOT=` line:
Step 6's composer emits that as [7]'s first line from the same script, after the re-stamp below.

```typescript
    // 4.8. DV worktree-isolation enforcement — isolation is expected unless
    //      `task.metadata.worktree_waived` is set (or a `worktree_isolation_waived` audit row
    //      exists): every DV stage runs in an isolated worktree before writing files
    //      (agents/developer.md § D0.0), so the agent confirms isolation, creates a worktree,
    //      or flags the deviation and returns instead of silently editing the shared checkout.
    //      DR rejects a DV handoff carrying `worktree:false` absent that waiver.
```

##### Step 4.8 — isolation banner

```typescript
    if (full.metadata.stage === "DV") {
      // /megatask: the tree is init-worktree.sh's linked worktree, outside .claude/worktrees/,
      // where EnterWorktree would wait on a confirmation no one can give.
      const enforce = state.tasks.PL0?.metadata?.megatask_group
        ? `WORKTREE ISOLATION: WORKSPACE_ROOT is already an isolated worktree. Never call ` +
          `EnterWorktree; work it in absolute-path mode (D0.0). Set \`worktree: true\`.`
        : `WORKTREE ISOLATION REQUIRED (always): ` +
          `confirm you are in an isolated worktree before any Edit/Write (D0.0). ` +
          `If not, EnterWorktree and proceed, or flag worktree_isolation_missing and ` +
          `return verdict:blocked. Set handoff frontmatter \`worktree: true\` (false is a hard DR fail).`;
      full.description = full.description + "\n\n" + enforce;
```

##### Step 4.8 — pin the tree

An explicit `WORKSPACE_ROOT` matching the orchestrator root pins the host session; a linked worktree alone does not.
Pin before `Agent()` so the banner and dispatch read one path. Contract: `skills/worktask/references/contracts/artifact-map.md § Pinning a row's tree`.

```typescript
// …continued: step 4.8 body. Concurrent = no transitive blocked_by path either way.
const reaches = (from, to) => {
  const seen = new Set(), stack = [...(state.tasks[from]?.blocked_by ?? [])];
  while (stack.length) {
    const id = stack.pop();
    if (id === to) return true;
    if (!seen.has(id)) { seen.add(id); stack.push(...(state.tasks[id]?.blocked_by ?? [])); }
  }
  return false;
};
```

###### Step 4.8 — detect shared trees and the session pin

```typescript
const sharedWithConcurrent = Object.entries(state.tasks ?? {}).some(([id, t]) =>
  id !== task.id && t.metadata?.stage === "DV" &&
  t.metadata?.workspace_path === full.metadata.workspace_path &&
  !reaches(task.id, id) && !reaches(id, task.id));
const sessionPinned = !!process.env.WORKSPACE_ROOT &&
  fs.realpathSync(process.env.WORKSPACE_ROOT) === fs.realpathSync(_orch_root);
```

###### Step 4.8 — serialize a pinned stream

Block later independent streams on the nearest earlier row; re-read readiness before dispatch.

```typescript
if (sessionPinned && full.metadata.stream) {
  const earlier = Object.entries(state.tasks ?? {})
    .filter(([id, t]) => /^DV[0-9]+$/.test(id) &&
      Number(id.slice(2)) < Number(task.id.slice(2)) &&
      t.metadata?.stage === "DV" && t.metadata?.stream &&
      t.metadata?.workspace_path === full.metadata.workspace_path &&
      !reaches(task.id, id) && !reaches(id, task.id))
    .sort(([a], [b]) => Number(b.slice(2)) - Number(a.slice(2)));
  if (earlier.length > 0) {
    execFileSync("bash", ["skills/worktask/scripts/state-patch.sh", "--task-block",
                          task.id, "--on", earlier[0][0]]);
    state = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
  }
  if ((state.tasks[task.id]?.blocked_by ?? []).some(id =>
        !SETTLED.has(state.tasks[id]?.status))) continue;
}
```

##### Step 4.8 — re-stamp, then read the banner path

```typescript
      // …continued: step 4.8 body. Argv form, never a shell string: a path may contain `'`.
      if (!sessionPinned && full.metadata.stream && sharedWithConcurrent) {
        const tree = ensureStreamWorktree(task);  // this stream's own worktree, off metadata.base_ref
        execFileSync("bash", ["skills/worktask/scripts/state-patch.sh", "--task-meta", task.id,
                              "--set", JSON.stringify({ workspace_path: tree })]);
      }
      // After the re-stamp: the script reads the row's path, falling back to the orchestrator
      // root, never the ledger-level path, which would hand a stream row the orchestrator's tree.
      const assigned = execFileSync("bash", ["skills/worktask/scripts/workspace-root-banner.sh",
                                             "--task", task.id], { encoding: "utf8" })
                         .trim().replace(/^WORKSPACE_ROOT=/, "");
```

##### Step 4.8 — land consumed artifacts

After any re-pin and before Step 5 stamps `in_progress`, a row that declares `consumes` has every
consumed pair landed again into the tree it will run in. A re-pinned stream holds a fresh tree the
boundary pass (§ Step 6.5d) never reached; an unchanged tree is a no-op that writes nothing.

```typescript
      // …continued: step 4.8 body
      const consumes = full.metadata.consumes ?? [];
      if (consumes.length > 0) {
        const land = spawnSync("bash", ["skills/worktask/scripts/land-artifacts.sh",
                                        "--consumer", task.id]);
        if (land.status !== 0 && land.status !== 1) blockOnToolError(task.id);  // 1: already blocked
        if (land.status !== 0) { queueLandingBlock(land, task.id); continue; }  // never Agent()
        full.description += "\n\nLANDED (read-only, never edit or stage): " +
          consumes.flatMap(c => c.paths).join(", ");
      }
```

##### Step 4.8 — a refused landing, and its release

`blockOnToolError` exists because every status other than 0 or 1 records nothing — exit 2, or a
signal or crash that bypassed the script's own mapping to 2 — and a row left `pending` is
re-dispatched every pass. It runs `state-patch.sh --task-meta <ID> --set '{"landing_error":{"reason":"tool_error"}}'`,
then `--task-status <ID> blocked`; if either write fails, stop per § Error Handling. Exit 1 needs
neither, since the script already blocked the row. `queueLandingBlock` reports it as § Step 6.5d does.

Release, once the cause is fixed: `state-patch.sh --task-meta <ID> --set '{"landing_error":null}'`,
then `--task-status <ID> pending`. The next ready pass reaches this gate, which re-lands every pair.

##### Step 4.8 — assigned-tree banner & audit

```typescript
      // …continued: step 4.8 body
      const assertTree =
        `ASSIGNED TREE REQUIRED: before your first Edit/Write run ` +
        `\`bash skills/worktask/scripts/dv-tree-preflight.sh --assigned "$WORKSPACE_ROOT"\` ` +
        `(WORKSPACE_ROOT = ${assigned}). ` +
        `Exit 1 is BLOCKING: do not edit, log workspace_path_mismatch, return verdict:blocked ` +
        `quoting both paths it printed. Warnings are advisory. Isolation (above) is a different ` +
        `claim — a stale worktree passes it and is still the wrong tree.`;
      full.description = full.description + "\n\n" + assertTree;
      appendAudit({ actor: "orchestrator", action: "dv_worktree_enforced", subject: task.id,
                    result: "ok", metadata: { isolation: "worktree", workspace_path: assigned } });
    }
```
