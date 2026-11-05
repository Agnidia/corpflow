# Planning artifacts

Read when executing or checking planning artifacts.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<a id="section-lookup-1"></a>
Related: [Downstream propagation](planning-sizing.md#downstream-propagation)

<!-- canonical-body:start -->
###### Asset-placeholder grammar (host-and-rewrite contract)

Name each persisted per-frame file with a placeholder token, never a `.context/...` path (sanitiser Pass-1 rule L1 drops any `.context/` line; tokens survive it). The helper greps this exact shape — keep it stable:

```
<figma-source-url-line(s)>

{{asset:figma-<screen>-<state>-<node-id>.png}}
- <description: state, badge/label text, build notes>
<!-- repeat token + bullet pair per frame -->
```

1. `{{asset:<basename>}}` on its own line; PNG basename only, no path part.
2. A `- <description>` line immediately follows each token (one-to-one, in document order).
3. Source URL line(s): kept verbatim above the token block.
4. Hosting belongs to `publish-pl-issue.sh`: post-`sanitise_body` it resolves `.context/designs/<basename>` (the only Figma asset source; `.context/images/` is DV-only) into a hosted `![<basename>](<https-url>)`. The PM never computes or embeds hosted URLs.

### PL0 Scaffolding (when invoked for worktask planning)

Execution order. On a `plan_revision` turn, step 1 reuses the frozen `plan_file` and step 3 patches the existing tasks in place (§ Revision of the run in flight).

1. Compute `<plan_file>`, then Read `skills/worktask/assets/templates/planning.md` and Write it to
   `<plan_file>`: the `#tpl-pl` frontmatter, the § Required Metadata block and every mandatory
   anchor, in order. Nothing else needs looking up to shape the file.
2. Replace every `<…>` placeholder and `N`: requirements, acceptance criteria, success metrics.
   Drop `rejection_reason:` on a first draft; with nothing to ask, the sweep body becomes
   `open_questions: []` plus a one-line nothing-to-elicit statement.
3. Assess complexity (0-50) and seed stage tasks via `state-patch.sh --task-create` with the § Downstream propagation fields

#### Post-publish verification (scaffolding step 4)

4. When `metadata.no_gh_issue` is unset and `publish-pl-issue.sh` ran: published ⇔ `.context/state.json:metadata.github_issue_url` is non-empty (first run — issue created) OR `.context/gh-issue.json` carries a `url` (a later run in this `.context/` commented on the existing context issue). `state.json` is re-seeded per run, so on a follow-up run it does not hold the URL — expected, not a failure.

##### Warn path when neither URL resolves

Append one audit row `action: "pr_issue_link", result: "warn", reason: "github_issue_url_not_set_after_publish"` to `.context/logs/audit.jsonl` and surface it in the plan summary. Re-running `publish-pl-issue.sh` manually is safe — the run-independent `.context/gh-issue.json` anchor makes it resolve the existing issue and comment/skip rather than duplicate (`skills/gh-issue-dedup`). Do not block: the worktask proceeds and the FN validator falls back to rank-2/3/4 (`metadata.github_issue_number` → branch parse → `git log` `#NNN` token).

### Mandatory Plan-File Anchor Schema

`<plan_file>` includes all eight PL H2 anchors from `skills/worktask/references/contracts/artifact-anchors.md#anchors--pl-to-dr` plus the universal `## elicitation-sweep`; `skills/worktask/assets/templates/planning.md` carries them in order. AR/TL/DV/DR read them selectively; a missing anchor forces full-file re-reads (`stage-contracts § Required Inputs` step 3) and breaks the cache-friendly handoff layout.

#### Mandatory Plan-File Anchor Schema — the table

Required anchors (kebab-case, no underscores, no spaces):

| Anchor | Content | Reader stage(s) |
|--------|---------|-----------------|
| `## requirements` | User-facing requirements, with IDs | AR, TL, DV |
| `## acceptance-criteria` | Given/When/Then per requirement | DV, DR, QA |
| `## scope` | What's included | TL, DV |
| `## out-of-scope` | What's explicitly excluded | DV, DR |
| `## risks` | Known unknowns, mitigations | AR, TL |
| `## complexity` | Score 0–50 + factor breakdown | TL (sizing), FN (recap) |
| `## stages` | Per-stage task list | TL, FN |
| `## summary` | Complexity/tier line, vetoable assumptions, gate-question preview | user (plan gate), FN (recap) |
| `## elicitation-sweep` | The plan-gate sweep items, or the explicit empty statement | orchestrator (§ Step C.4) |

#### Exact-output criteria are byte-exact

Every exact-output rule in the goal — CLI flags, output formats, byte-level examples, leading and
trailing spaces — becomes an acceptance criterion whose expected bytes are quoted verbatim in a
fenced block under `## acceptance-criteria`. Never paraphrase, reflow, trim or re-quote them: DV
builds and QA checks against those bytes, and a paraphrase drops exactly the whitespace and
punctuation the rule exists for.

#### Plan content — decisions, not code

`<plan_file>` follows `skills/shared/plan-content.md § Rule — decisions, not a transcript`: its
requirements, acceptance criteria and scope name what DV cannot decide alone, and DV writes every
implementation body. § Exact-output criteria are byte-exact, above, wins on any conflict.

#### Anchor-lint enforcement

At write time `hooks/anchor-preflight.sh` denies an Edit that adds an H2 outside the allow-list; after a Write it reports an off-list H2, a missing anchor or a frontmatter finding for an Edit fix (`handoff-protocol.md § Anchor Pre-Flight`). Without the hook, `handoff-harness.sh --validate-frontmatter` fails the stage boundary on either — same fix, discovered late.

#### Workspace Mode

`task.metadata.workspace_path` is not a mode detector — `/worktask` stamps it on every run
(step 3a/4). Detect workspace mode from the presence of `workspace.json` at the worktree root
(`/megatask` writes it per issue; shape: `skills/shared/milestone-helpers/references/implementations.md
§ workspace.json — canonical shape`), and propagate `workspace_path` verbatim onto every stage
task you create as the assigned tree. Read the issue from `workspace.json` `.issue` and write
artifacts to the workspace `.context/`. See
`skills/megatask/SKILL.md § Orchestrator Pattern`.

### Dynamic Worktask Sizing (PL0 Stage)

1. Assess complexity with the 5-factor table in `skills/worktask/references/lifecycle.md § Complexity Assessment` (patterns, integration, concerns, risk, docs)
2. Sum scores (0-50 total)

#### Stage set by score (step 3)

3. Create stage tasks by score, each with `metadata.agent`:

   **3a — Resolve the tier default** from the tier table in `skills/estimation-methodology/SKILL.md § PL0 Stage-Set & Test-Mode by Complexity Score`.

   **3b — Decide AR0.** A tier default at score ≥11, not a mandate. Apply `§ Stage Inclusion Criteria (PL0 authority)`: exclude only when all exclusion conditions hold; force-include at any tier (including Low) when any inclusion condition holds.

   **3c — Decide TL0.** No tier default; one test — must this work be split across ≥2 developers (parallel workstreams, multiple DV specialists, or external-plugin fan-out needing coordination and merge)? Yes → include TL0 and record it in `added_stages`. No → omit at any score.

#### Recording the decisions (step 3, continued)

Stamp `metadata.skipped_stages` (`{stage, reason}`) for every stage of the full `PL→AR→TL→DV→DR→QA→DC→FN→ST` pipeline not created, and `metadata.added_stages` (same shape) for every stage beyond the tier default. Reasons are one decision-shaped sentence, never a restatement of the score. Record the AR0 and TL0 decisions with reasons in `planning-${N}.md ## stages`; the plan-gate summary surfaces both.

context_refs seeding: AR0 included ⇒ DV0's `metadata.context_refs` names an `architecture-${N}.md` anchor, and DV0/DR0/QA0 dispatches carry `metadata.architecture_ref` once AR completes. AR0 excluded ⇒ no `context_refs` names `architecture-${N}.md` and no `architecture_ref` is stamped.

#### Announce the sizing decision

The first content of `## summary`, above the problem statement, states the complexity score, the
tier, the resulting stage set, and one clause per added or skipped stage, phrased as a decision the
reader may veto ("…and any of them can be overridden at the plan gate"). The returned handoff
`summary` opens with the same sentence. Because `## complexity` and `## stages` are read after the
plan body, an unannounced classification cannot practically be overridden. The gate itself is
unchanged.

#### Stage-task right-sizing

A stage task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's
gate. Fold setup, configuration, scaffolding, and documentation steps into the task whose
deliverable needs them; split only where a reviewer could reject one task while approving its
neighbour. The TL0 and DV-split tests above are the specific cases and win where they disagree;
where they are silent (two DV streams over one file set, a doc step with no deliverable of its
own), this reviewer-gate test decides.
