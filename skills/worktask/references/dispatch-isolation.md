# Dispatch isolation

Read when executing or checking dispatch isolation.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
#### Step 4.8a

```typescript
    // 4.8a. DV test-scope enforcement — DV-only, never QA (QA's full-suite run IS the sanctioned
    //       regression gate, agents/qa-engineer.md § Q1 Three-Mode Dispatcher).
    if (full.metadata.stage === "DV") {
      let mode = full.metadata.test_mode ?? state.metadata?.test_mode;
      if (mode == null) {  // PL0 stamps test_mode; a silent default would hide the missing stamp
        appendAudit({ actor: "orchestrator", action: "dv_test_scope_enforced", subject: task.id,
                      result: "warn", metadata: { test_mode: "scoped", reason: "test_mode_unstamped" } });
        mode = "scoped";
      }
```

##### Step 4.8a — scope banner

```typescript
      // …continued: step 4.8a body
      const scope =
        `TEST SCOPE (mode: ${mode}): run ONLY \`Executed Tests (DV)\` per ` +
        `agents/developer.md D2. DO NOT re-run the full suite to reverify a fix between ` +
        `iterations — full-suite regression is QA's gate, not DV's. Apple test identifiers ` +
        `are suite-terminal (\`-only-testing:<Target>/<Suite>\`); per-function identifiers ` +
        `are forbidden — they select nothing and degrade to a full run. Record the resolved ` +
        `mode in your artifact's \`§ Decisions\` (your row's \`metadata.artifact\`).`;
```

##### Step 4.8a — inject & audit

```typescript
      // …continued: step 4.8a body
      full.description = full.description + "\n\n" + scope;
      appendAudit({ actor: "orchestrator", action: "dv_test_scope_enforced", subject: task.id,
                    result: "ok", metadata: { test_mode: mode } });
    }
```

#### Step 4.8b

```typescript
    // 4.8b. Stage test-execution ban — every stage NOT in {DV, QA}, which are exempt because
    //       they hold execution authority (scoped/full). Canon:
    //       skills/worktask/references/testing-strategy.md § Test-Execution Authority. This banner teaches
    //       (a blocked agent sees the rule instead of retrying); hooks/test-execution-gate.sh
    //       is the mechanical backstop and the ONLY layer covering a nested delegate's leaf
    //       Bash call and the orchestrator's own shell.
```

##### Step 4.8b — ban banner & audit

```typescript
    if (full.metadata.stage !== "DV" && full.metadata.stage !== "QA") {
      const ban =
        `NO TEST EXECUTION at this stage (${full.metadata.stage}): authority is stage-scoped, ` +
        `see \`skills/worktask/references/testing-strategy.md § Test-Execution Authority\`. Build-only ` +
        `verification (\`/<plugin>:build-test --no-test\`) stays permitted. Need runtime ` +
        `evidence → record \`requests_test_evidence: <what and why>\` in this stage's artifact ` +
        `(non-blocking) or return \`verdict: blocked\` + \`error_escalated_to: "DV"\` (blocking, ` +
        `existing error-handling loop — no new machinery).`;
      full.description = full.description + "\n\n" + ban;
      appendAudit({ actor: "orchestrator", action: "stage_test_ban_enforced",
                    subject: full.metadata.stage, result: "ok",
                    metadata: { stage: full.metadata.stage } });
    }
```
