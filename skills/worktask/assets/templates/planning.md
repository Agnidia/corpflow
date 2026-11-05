---
handoff:
  stage: PL
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line summary ≤200 chars>"
  rejection_reason: "<gate feedback, revisions only; omit on first draft>"
  key_decisions:
    - { id: pd1, summary: "<decision>", anchor: "planning-N.md#scope" }
  next_stage_focus: "<imperative: what AR must grep/design>"
  open_questions:
    - { id: sw-PL0-1, class: decision, ref: "planning-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    spec: .context/attachments/<spec-file>
    plan: .context/planning-N.md#requirements
title: "<issue title: verb + object, ≤120 chars>"
metadata:
  test_mode: scoped              # build-only | scoped | full
  always_required_tests: []      # explicit override list of test IDs
  ui_visual_check: false         # gate for QA's visual/design comparison
  requires_screenshots: false    # PL judgment: does the diff alter rendered output? detector is advisory; S1 forces true
---

# <Plan title>

## requirements

- REQ-1: <user-facing requirement>

## acceptance-criteria

- AC-1 (REQ-1): Given <state>, when <action>, then <observable result>.
  Verify: `<command>` — recorded for DV and QA to execute; PL does not run it.

## scope

- In: <included surface>

## out-of-scope

- <excluded surface>

## risks

- <known unknown> — mitigation: <mitigation>

## complexity

Score <0–50>: patterns <n>, integration <n>, concerns <n>, risk <n>, docs <n>. Tier <tier>.

## stages

- Created: <PL0 → AR0 → DV0 → …>
- AR0: <included | excluded> — <one decision-shaped reason>
- TL0: <included | excluded> — <one decision-shaped reason>
- Skipped: <stage> — <one decision-shaped reason>

## test-strategy

- Framework: <the repo's own, else the platform default>
- New test files: <paths>, <n> unit scenarios per feature
- Effort: DV <h>, QA <h>
- `requires_screenshots`: <true|false> — <why>; detector signals: [S…]

## summary

<complexity and tier line>. Assumptions you can veto: <…>. Gate questions: <sw-PL0-1 in one line>.

## elicitation-sweep

- id: sw-PL0-1
  class: decision
  summary: "<question the user would rather decide>"
  options:
    - { label: "<option A>", detail: "<consequence>", recommended: true }
    - { label: "<option B>", detail: "<consequence>" }
  rationale: "<one line>"
