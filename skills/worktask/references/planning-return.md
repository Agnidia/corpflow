# Planning return

Read when executing or checking planning return.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<!-- canonical-body:start -->
## Handoff Protocol

Inputs (anchor-first), completion checklist, run-index resolver, atomic-write rules: `skills/worktask/references/stage-contracts.md` — reference only; this section is self-sufficient, so do not Read it in the steady path. Per-stage frontmatter template: `skills/worktask/assets/templates/template-pl.md#tpl-pl`, already at the top of `skills/worktask/assets/templates/planning.md` (§ PL0 Scaffolding step 1), so it needs no separate read. Prev→this label: `USER→PL`.

### State Patch — REQUIRED before return

Run the one call in § Union this stage's facts in the same call to atomically patch `tasks.PL0` + the `USER→PL` edge into `.context/state.json` from this artifact's `handoff:` frontmatter summary. Put the one-line goal (verb + object, ≤120 chars) in that summary — downstream stages read it as the worktask goal alongside `planning-N.md#requirements`. Exit 3 means your artifact is not on disk: write it and re-run, never continue as if the ledger were patched. If the tool cannot run at all, do not skip: apply the Edit-direct fallback in `skills/worktask/references/contracts/ledger-edges.md#layer-1-fallback`, which writes the `handoffs` edge the hook cannot.

#### Union this stage's facts in the same call

Pass `--facts` in the same call to union this stage's compressed facts into `state.json → facts.*` — the channel `stage-contracts.md` tells every downstream stage to read first, and its only scripted writer. PL owns both `key_decisions` and the `open_questions[]` a `--auto=[decision]` delegate later resolves:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage PL --prev USER --facts '{
  "decisions": [{"id":"pl-1","summary":"≤160 chars","ref":"planning-0.md#stages"}],
  "open_questions": [{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
```

Union by `.id` (last writer wins, newest at the tail): never clobbers an upstream stage's entries, and a re-run is byte-identical. Omitting it loses the facts silently. Canonical rule: `skills/worktask/references/contracts/facts-merge.md#facts-union`.

#### One call, no jq edits to `state.json`

The command is the grant prefix byte for byte, so it matches `agents/product-manager.md`'s
`tools:` grant (`skills/shared/plugin-root-resolution.md § Invocation`); every other
`state-patch.sh --…` step in this file (`--task-create`, `--task-block`, `--ledger-meta`) takes
the same prefix. It writes `tasks.PL0`, the edge and the `facts` arrays. The ledger has no
`stages{}` map to fill (`skills/worktask/references/contracts/ledger-root.md § Ledger root`), and a refused call is fixed by its
flags, never by rewriting the file:

- exit 4, ledger dir "inside the plugin root": cwd is not the project; add
  `--state <project>/.context/state.json`.
- no `state.json` at all: the one case where skipping is correct (`#layer-1-fallback` item 3).
  Never hand-write or re-version a ledger.

Stage-task seeding uses the same `state-patch.sh` grant and shares this fallback ladder; there is
no separate task tool to fall back to.

#### State Patch — `facts.goal` is part of the contract

`facts.goal` is non-empty in `.context/state.json` when PL returns. The orchestrator seeds it from the task description at Step 3a; refine it to the one-line goal above, or add it if the seed lacks it, with one `Edit` of that value: `--facts` has no `goal` key, so it is the one ledger value PL writes by hand. `publish-pl-issue.sh` reads it as the first rank of both the issue title and the `## Summary` chain; without it the issue gets a kebab-slug title and an empty Summary. Also write a `title:` line into the plan's frontmatter — the chain's next rank.
