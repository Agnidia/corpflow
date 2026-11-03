# Script routing

Read when executing or checking script routing.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Step 4.8](dispatch-workspace.md#step-48)

<!-- canonical-body:start -->
## Scripts

Invoke via `bash`; never read into context.

| Script | One-line invocation | Purpose |
|--------|---------------------|---------|
| `scripts/state-patch.sh` | `--stage <CODE> --prev <PREV>` | Canonical state.json patch; `hooks/state-merge.sh` delegates here. Self-test: `--self-test`. |
| `scripts/permission-park.sh` | `classify\|park\|batch\|resume` | Parks an auto-mode permission denial without spending a retry, batches the user question, builds the step-only resume (§ Step 6.5a4, § Step 7a). Self-test: `--self-test`. |
| `scripts/land-artifacts.sh` | `--producer <ID>` / `--consumer <ID>` / `--list-landed --tree <path>` | Copies a DV producer's staged `produces` into each consumer's tree, fail closed (§ Step 6.5d, § Step 4.8). Self-test: `--self-test`. |

CLI, stdout and exit contracts for these, the `blocked_on` router and lib, and the mailbox helpers:
`references/scripts.md`.

#### blocked-on-lib.sh — the arm table

| kind | legs | closing_leg | owner_issue | landed |
|---|---|---|---|---|
| user_decision | asked, answered, resumed | resumed | 395 | yes |
| user_action | requested, verified | verified | 394 | yes |
| permission | denied, granted, resumed | resumed | 393 | yes |
| peer_session | sent, delivered, answered, relayed, expired | relayed | 405 | yes |
| artifact | landed | landed | 399 | yes |
| correction | opened, closed | closed | 404 | yes |
| host_environment | probed | probed | 390 | yes |

Every fallback closes on `verified`; an `artifact` need also closes on `landed`. Required and optional keys and `resume_with` are
`skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on, the seven arms at a glance`.

## Related

- `references/fn-gate.md` - FN gate full procedure + post-worktask self-improvement (Read at gate time)
- `references/resume.md` - Resume-after-interruption state table + procedure (Read on reattach)
- `references/workspace-modes.md` - Megatask per-issue/worktree/Conductor workspace rules (Read in workspace modes)
- `references/scripts.md` - Helper CLI, stdout and exit contracts
- `references/pl-issue-publish.md` - PL issue publish semantics and sanitiser rules
- `../../megatask/SKILL.md` - GitHub milestone batch execution
- `../../agent-coordination/SKILL.md` - Multi-agent coordination
- `../../cost-optimization/SKILL.md` - Budget management
- `../../context-compression/SKILL.md` - Context compression
