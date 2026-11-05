# Launch planning

Read when executing or checking launch planning.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Plan gate checkpoint path](plan-approval.md#plan-gate-checkpoint-path) · [Banner injection](stage-entry.md#banner-injection)

<!-- canonical-body:start -->
#### Step 3c — which of the two names gets stamped

   ```bash
   # A title (≤60 chars), never the raw task description: the 48-char slug budget
   # drops the overflow silently.
   out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --goal "<concise imperative title>")
   local_branch=$(printf '%s\n' "$out" | sed -n 's/^branch=//p' | tail -n 1)
   target=$(printf '%s\n' "$out" | sed -n 's/^target_branch=//p' | tail -n 1)
   truncated=$(printf '%s\n' "$out" | sed -n 's/^slug_truncated=//p' | tail -n 1)

   # target_branch wins whenever the local name (a host's `<city>-v<n>`, say) is
   # unusable as a PR head.
   stamp="$local_branch"
   if [ -z "$stamp" ] || ! bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --check "$stamp"; then
     [ -n "$target" ] && stamp="$target"
   fi
   ```

#### Step 3c — post-check (non-blocking)

After stamping, assert the stamped value against the predicate. Reuse `$target`; never
re-invoke in rename mode (that writes a second audit row). `BRANCH_NAME_PRINT=1`, `--check`, and
`--print-target` write none:

   ```bash
   stamped=$(jq -r '.facts.branch // ""' .context/state.json)
   if [ -n "$stamped" ] && ! bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --check "$stamped"; then
     jq -cn --arg ts "$(date -u +%FT%TZ)" --arg a "$stamped" --arg d "$target" \
       '{ts:$ts, actor:"orchestrator", action:"branch_convention_check", subject:"PL0",
         result:"warn", metadata:{actual:$a, derived_target:$d}}' \
       >> .context/logs/audit.jsonl
   fi
   ```

#### Step 3c — post-check, the truncation row

`slug_truncated=1` appears only when the budget dropped content. Then append one row naming the input
length and the surviving slug — the evidence a human reads at the plan gate, and the
incumbent-quality signal § Step A.4b reads (`$title` is the `--goal` title; `slug` is the
post-`<type>/` remainder):

   ```bash
   if [ "$truncated" = "1" ]; then
     wid=$(jq -r '.worktask_id // "unknown"' .context/state.json)
     ri=$(jq -r '.run_index // 0' .context/state.json)
     jq -cn --arg ts "$(date -u +%FT%TZ)" --arg s "PL$ri" --arg t "$target" \
       --arg len "${#title}" --arg slug "${target#*/}" --arg dk "$wid:$ri:branch_slug_truncated" \
       '{ts:$ts, actor:"orchestrator", action:"branch_slug_truncated", subject:$s,
         result:"warn", task_id:"PL0",
         metadata:{input_len:$len, slug:$slug, target:$t,
                   origin_stage:"PL", dedupe_key:$dk}}' \
       >> .context/logs/audit.jsonl
   fi
   ```

#### Step 3c — post-check invariants

The post-check only warns; never stop, retry, or rename here. An empty stamp is valid.
An empty derived target means an early guard; a non-empty target beside an invalid stamp indicates a defect.


### Step 4 — attach PL0 metadata

After Step 3a seeds PL0, the orchestrator merges metadata with `--task-meta`; `--task-create` would discard the payload.

`bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta PL0 --set '{"stage":"PL","agent":"corpflow:product-manager","model":"<model>","effort":"<effort>","worktask_id":"<slug>","priority":"<priority>","plan_gate":"checkpoint","decision_gate":"user","fn_gate":"checkpoint","isolation":"worktree","workspace_path":"<resolved root>","description":"<task description>"}'`

Use a fully qualified `plugin:agent`. Stop on a ledger write failure.
`description` is a label capped at 240 characters (239 plus `…`); truncation prints `description_truncated=PL0:<length>`.
Step 6 carries the uncapped input.

<a id="step-4--decision_gate-readers"></a>
<a id="step-4--gate-stamping"></a>
<a id="step-4--option-flag-stamping"></a>
<a id="step-4--workspace_path-stamping"></a>
#### Step 4 — metadata sources

Merge the fields below in that same payload. Missing option flags stay absent; readers treat them as off.

| Field | Source / default | Override |
|---|---|---|
| `model`, `effort` | `model-matrix.sh --resolve product-manager` | `state.models` → `CORPFLOW.md` → matrix; no PL secure override |
| `workspace_path`, `isolation` | Step 3a root, `worktree` | Per-issue stamp |
| `priority`, `worktask_id` | Resolved invocation | Per-issue stamp |
| `description` | Task label, capped | Full input goes to Step 6 |
| `plan_gate` | `checkpoint` | `--auto=[plan]` / emergency: `bypass` |
| `fn_gate` | `checkpoint` | `--auto=[finalization]` / emergency: `bypass` |
| `decision_gate` | `user` | `--auto=[decision]`: `auto` |
| `with_design`, `no_gh_issue` | Absent | `--with-design` / `--no-gh-issue`: `true` |
| `embedded_commands` | Absent | Step 2's commands |

#### Step 4 — the /megatask stamp

The prompt's `PL0.metadata` stamp wins on every shared key in the same `--task-meta PL0` call.
It carries the absolute worktree path and `bypass`/`auto`/`bypass` gates, matching `--auto=[plan,decision,finalization]`.
The stamp exists only in the prompt until Step 3a seeds the ledger.
PM propagates `workspace_path` and `isolation` to every stage task; assignment and isolation remain separate claims.
`--auto=[plan]` never bypasses FN. Emergency leaves `decision_gate: "user"` inert without PL.

#### Step 4 — PL0's model and effort

Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve product-manager`.
Paste its tab-separated model and effort into the payload; never type an alias instead.
`with_design` drives Designer Invocation; `no_gh_issue` drives issue publishing and mailbox opt-out.
PM returns questions according to `decision_gate`; Step A.4 consumes them.

### Steps 5–8 — Dispatch PL, then present the plan

1. Run `state-patch.sh --task-status PL0 in_progress`.
2. Dispatch `Agent({subagent_type:"corpflow:product-manager", model:<PL0 model>, effort:<PL0 effort>, prompt:<planning prompt>})`.
3. After successful completion, run `state-patch.sh --task-status PL0 completed`.
4. Present the [plan summary](plan-approval.md#plan-gate-checkpoint-path) and enter Phase 2.

On dispatch or stage failure, use the existing retry/escalation path; never fabricate completion.

<a id="step-6--record-dropped-and-added-stages"></a>
<a id="step-6--what-pm-computes"></a>
#### Step 6 — the planning prompt

The orchestrator supplies, in order:

1. The user's task description verbatim and uncapped, or the issue body under `/megatask`; never the capped metadata label.
2. The resolved `--auto` array, tier flags, priority, platform, `--accept-absent`, gates, and Step 4 option fields.
3. `WORKSPACE_ROOT=<path>` from `workspace-root-banner.sh --task PL0`.

PM computes the next free `planning-N.md`, assesses complexity, and seeds tasks with `metadata.agent` and `metadata.plan_file`.
Seeded indexes are provisional; a plan revision instead keeps the index frozen.
PM records omitted nine-stage stages in `skipped_stages` and additions beyond tier defaults in `added_stages`.
Both lists contain `{stage, reason}` entries; [planning-artifacts](planning-artifacts.md#dynamic-worktask-sizing-pl0-stage) owns sizing.
