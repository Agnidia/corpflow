# Planning design

Read when executing or checking planning design.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<a id="section-lookup-1"></a>
Related: [Propagation fields — DV rows](planning-sizing.md#propagation-fields--dv-rows) · [Propagation fields — dispatch pair](planning-sizing.md#propagation-fields--dispatch-pair)

<!-- canonical-body:start -->
#### Mid-run escalation channel

Sizing can only ratchet up mid-run: a downstream stage that finds a surface PL0 could not have seen
returns `requests_stage_escalation`, and the orchestrator adds the stage. Conditions, caps, and
validity: `skills/estimation-methodology/SKILL.md § Mid-run re-sizing`.

Two consequences for PL0. `skipped_stages[].reason` is the sentence an escalation must quote and
falsify, so write it as a decision about the surface ("no credentials, tokens, PII, payments,
authn, or untrusted input is read, written, or exposed"), never as a restatement of the score. And
every declined stage gets a `skipped_stages` entry — fire condition 3 has nothing to quote without
one.

#### Dependency chain & run-index stamping (steps 4–5)

4. Set the dependency chain between seeded tasks with `state-patch.sh --task-block <ID> --on <ID[,ID…]>`
5. Mark PL0 completed after creating all stage tasks

Stage artifact paths in task descriptions use `<basename>-${N}.md` (e.g., `architecture-${N}.md`). DV is the exception: each DV row writes the path its own `metadata.artifact` carries (§ Propagation fields — DV rows).

#### Agent mapping for `metadata.agent`

Always emit the fully-qualified `plugin:agent` form; bare names are not accepted. The prefix follows the owning plugin: `corpflow:` for orchestration/process agents, the detected platform's dev-plugin prefix for platform work. Resolve platform agents from the routing matrix, never memory: entry and functional-role aliases (architect, security auditor, test generator, code fixer) in `skills/shared/routing-matrix.md` — a `CORPFLOW.md § Routing` override (project root, else user scope) wins, and the resolved map persists as `state.routing`; DV specialists in `skills/shared/platform-detection.md`. Code pattern: `skills/worktask/references/initialization-tasks.md § PL Creates Subsequent Tasks`.

##### Stage → agent table

Platform variant = the same role from the detected platform's plugin, per the registries above.

Default stage agents: `skills/worktask/references/stage-codes.md#primary-stages-11-stage`.
AR and SR may use the detected platform's architect and security auditor; DV uses its entry agent or specialist.
DR invokes `/tech-code-review`; QA may delegate to the platform's test generator. Other stage roles retain their stage-code owners.

##### DV0 routing override — plugin worktask-infrastructure

Read `skills/worktask/references/stage-codes.md#dv-infrastructure-routing` for the conditional agent, model, and Markdown ownership rules.

### PL Stage: Automatic Design Detection

#### Design Detection Criteria

Weighted-score the task description for design indicators:

| Category | Weight | Keywords |
|----------|--------|----------|
| UI Components | 2 | button, form, screen, layout, modal, dialog, menu, navigation, tab, card, list, table, grid |
| User Experience | 3 | user flow, accessibility, a11y, usability, interaction, gesture, wireframe, prototype |
| Visual Design | 2 | color, theme, dark mode, typography, font, icon, animation, responsive |
| Platform UI | 2 | view, widget, swiftui, uikit, navigationstack, tabview, compose, @composable, jetpack, material3, react, vue, svelte, angular, jsx, tsx, dom |
| High-Confidence | 5 | "redesign", "new ui", "ui/ux", "design system", "user interface", "visual refresh" |

**Negative Indicators** (-3 each): backend, api only, database, migration, infrastructure, no ui

**Threshold**: Score >= 5 triggers Designer invocation

#### Designer Invocation

Flag gate: invoke `corpflow:designer` only under `--with-design` (`PL0.metadata.with_design == true`, stamped by `/worktask` Step 4); the keyword score is advisory. Without the flag, skip Designer even for UI apps and note the skip in `## summary`.

Threshold met AND flag set ⇒ `Agent(subagent_type: "corpflow:designer")` requesting:
1. UX Assessment, Design Scope, Technical Design, Pencil Mockups, Effort Estimate
2. Mockups saved to `.context/designs/` as `mockup-[feature]-[screen]-[variant].pen`
3. Critical states: default, error, empty, loading

##### Combined Output

Designer writes `.context/designs/ux-assessment-N.md` and returns its path; PM merges it. `<plan_file>` gets a Design Requirements section: Figma Design References (URLs + node descriptions → `.context/designs/figma-*.png`), Visual Mockups (`.context/designs/mockup-*.pen`), UX, UI Components, Accessibility.

##### Placement guard (non-negotiable)

Persist Figma frames only to `.context/designs/` with a `figma-registry.md` — the artifact QA's design-comparison gate reads. Never write them to `.context/images/` (DV screenshots + user attachments only): a Figma PNG there disables the QA design gate (no `.context/designs/`) and masks an absent DV `screenshots-<TASK_ID>.md`.

### Figma Design Capture

A Figma URL in the task description or user input triggers capture regardless of the design-detection score. Trigger regex:

```
figma\.com/(?:file|design|proto)/([a-zA-Z0-9]+)/([^?]+)(\?node-id=([0-9-]+))?
```

#### Trigger path forms & capture doc

`(?:file|design|proto)` is non-capturing (Group 1 `fileKey`, Group 4 `nodeId`) and must match both the `§ design-preview` trigger and `skills/shared/figma-capture.md § Figma URL Detection` — do not add `/board/` or `/slides/` (`get_metadata` is design-file-only). On trigger, Read `skills/shared/figma-capture.md` for the capture mechanics (URL detection, auth probe, capture workflow, `figma-registry.md` schema, post-capture plan update, Pencil coexistence). A no-Figma PL run skips that Read.

### PL Stage: Automatic Ethics Gate Detection

PL0 scans the task for high-risk domain signals and inserts ET0 between PL0 and AR0 on threshold (same weighted scoring as design detection; negative indicators hold false positives down).

#### Ethics Risk Keyword Table

| Category | Weight | Keywords |
|----------|--------|----------|
| User Tracking | 4 | analytics, tracking, telemetry, user behavior, location, device fingerprint, cross-site, session recording |
| Financial | 4 | payment, billing, subscription, charge, refund, price discrimination, dynamic pricing, fee |
| Content Moderation | 3 | moderation, filter, ban, block user, content policy, takedown, flag content, shadowban |
| AI-Driven Decisions | 5 | automated decision, ai recommendation, algorithmic, ranking, personalization, model output |
| Vulnerable Populations | 5 | minor, child, elderly, disability, accessibility-critical, mental health, medical, protected class |
| Data Collection | 3 | PII, personal data, consent, GDPR, CCPA, HIPAA, biometric, sensitive data |
| High-Confidence Terms | 6 | "dark pattern", "addictive", "surveillance", "bias audit", "adversarial", "deepfake" |

##### Ethics thresholds & override

**Negative Indicators** (-3 each): internal-only, admin dashboard, test harness, dev-only, no user impact, synthetic data

**Threshold**: Score >= 5 triggers ET0 insertion AND `error_escalated_to: "ET"` reservation.

**Manual override**: `/worktask --ethics-review "..."` always creates ET0 regardless of score.

#### ET0 Insertion Pattern

When threshold met, PL0: (1) seeds an `ET0` ethics-review task before AR0 with `metadata` `{stage: ET, agent: "corpflow:ethics-reviewer", model: "<model>", effort: "<effort>", error_file: ".context/errors/ethics-reviewer.md", plan_file, run_index: N, worktask_id}`, with the pair from `model-matrix.sh --resolve ethics-reviewer` like every other seed (§ Propagation fields — dispatch pair); its description asks for `.context/ethics-review-${N}.md` with `Decision ∈ {pass, block, conditional}`. (2) runs `state-patch.sh --task-block AR0 --on ET0` so AR0 also blocks on ET0 (PL0 completes first, so ET0 is the effective gate).

Decision cascade:
- `Decision: pass` → AR0 unblocks, worktask continues
- `Decision: conditional` → AR0 unblocks with ethics constraints injected into prompt
- `Decision: block` → AR0 remains blocked, worktask halts, user notified

### Output Budget (PL)

The plan is written to `planning-N.md` (≤350 lines, tiered detail), never emitted in the final chat text. Final return ≤250 tok.
Figures: `skills/context-compression/SKILL.md § Stage Budget Table`, PL row.
