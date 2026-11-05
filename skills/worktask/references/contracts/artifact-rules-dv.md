# DV artifact rules

Read before writing or validating the DV stage artifact.

<!-- canonical-body:start -->
#### Your artifact and row id come from the ledger (tpl-dv)

You write one artifact, the one your ledger row names (`tasks.<ID>.metadata.artifact`), not a
canonical file assembled from other DV rows. Naming grammar, the per-row `stream`/`artifact` keys
and the single-DV case: `skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks`. Patch that row by id and
path, since the orchestrator's basename guess cannot see a stream suffix:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage DV --task-id <ID> --prev <PREV> --artifact <your row's artifact path>
```

#### UI evidence comes from the running app (tpl-dv)

A screenshot offered as DV evidence is captured from the app built and run on its real runtime
surface this run, with each control confirmed on-screen and driven. The full rule is
`skills/dv-screenshot-capture/SKILL.md § Live-drive verification (ui_visual_check)`, with the
per-platform adapter table in its § Adapters.

The contract consequence: a `ui_visual_check` whose only evidence is a static render — `#Preview`,
`ImageRenderer`, an IDE canvas — is incomplete, not merely weaker. Canvas capture is the registered
degraded adapter on Apple and emits `screenshot_platform_fallback`; a DV artifact resting on it
without that row, or with it and no statement of why the live surface was unavailable, has not
shown the change working. Recapture from a live-driven run, because a static render differs from the
live app exactly where UI defects live: real data, real layout, real state transitions.
