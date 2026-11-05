# Dispatch routing

Read when executing or checking dispatch routing.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Platform tooling ownership](completion-handoff.md#platform-tooling-ownership)

<!-- canonical-body:start -->
#### Steps 5–5a

```typescript
    // 5. Mark in_progress. hooks/test-execution-gate.sh resolves the acting stage from this one
    //    write (never agent_type or an env var, so nested delegates inherit it).
    sh(`state-patch.sh --task-status ${task.id} in_progress`);

    // 5a. Embedded commands (DV) — APPENDED as suffix [7] when the worktask carries
    //     embedded_commands metadata.
    if (full.metadata.stage === "DV" && worktask_embedded_commands) {
      const skillInvocation = `IMPORTANT: Before implementing, invoke the embedded command via Skill tool: Skill("${embedded_cmd}", args="${embedded_args}")`;
      full.description = full.description + "\n\n" + skillInvocation;
    }
```

#### Step 5b

```typescript
    // Keep command instructions in suffix [7], outside the cacheable prefix.
    if (full.metadata.stage === "DR") {
      const reviewInvocation = `IMPORTANT: Execute developer code review per commands/tech-code-review.md (plugin-root-relative). Save the findings summary to the path on this brief's \`artifact:\` line.`;
      full.description = full.description + "\n\n" + reviewInvocation;
    }
```

#### Step 5c — no platform warm-up

Nothing to warm: corpflow holds no platform build/test grants — DV/DR/QA delegate to `/<plugin>:build-test` and each plugin owns its toolchain lifecycle (§ Platform tooling ownership).

#### Step 5d

```typescript
    // 5d. Conductor-attachments for FN stages — project-manager always creates .context/attachments/
    //     files regardless of PL0's FN-task wording. Mirrors 5b; templates: references/conductor-attachments.md
    if (full.metadata.stage === "FN") {
      const fnInjection = [
        "IMPORTANT — Conductor attachments (FN-stage requirement, non-optional):",
        "Before running `gh pr create`, write both files per",
        "`skills/worktask/references/conductor-attachments.md`:",
        "  • `.context/attachments/PR instructions.md`",
        "  • `.context/attachments/Review request.md`",
        "Run `mkdir -p .context/attachments` first.",
        "Also write the worktask summary + Stage Timings to the path on this brief's `artifact:` line.",
        "Then read `PR instructions.md` and follow it as the PR-creation script.",
      ].join("\n");
      full.description = full.description + "\n\n" + fnInjection;
    }

```

#### Step 5e

```typescript
    // Pinning forbids widening the inherited mode in descendant Agent/Bash calls.
    if (full.metadata.permission_mode === "default") {
      appendAudit({ action: "permission_mode_pinned", subject: task.id, result: "ok",
                    metadata: { stage: full.metadata.stage, mode: "default" } });
    }
```
