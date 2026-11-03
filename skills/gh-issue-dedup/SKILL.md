---
name: gh-issue-dedup
description: Use when the PL stage publishes a plan, a repeat `/worktask` runs in an existing `.context/`, or before any `gh issue create` / `publish-pl-issue.sh` call. Keeps one GitHub issue per `.context/`; later runs comment on it instead of duplicating.
version: 0.3.0
related:
  - ../worktask/scripts/publish-pl-issue.sh
  - ../worktask/scripts/preflight-issue-scan.sh
  - ../worktask/SKILL.md
  - ../worktask/references/state-ledger.md
  - ../task-folder-organization/SKILL.md
---

# GitHub issue dedup (one `.context/` ↔ one issue)

Each `.context/` is tracked by one GitHub issue for its whole life. The first worktask run opens
it; every later run in the same `.context/` comments on it with a plan summary, so a feature's
planning history stays on one thread.

`state.json:metadata.github_issue_url` can't carry this binding: `skills/worktask/references/workflow.md` re-seeds
`state.json` without `metadata` on every fresh `/worktask`, so the URL only survives a resume of
the same run.

## The anchor: `.context/gh-issue.json`

Written next to `state.json`, in the artifacts shared across runs (never re-seeded):

```json
{
  "version": 1,
  "url": "https://github.com/<owner>/<repo>/issues/<n>",
  "number": 42,
  "created_run_index": 0,
  "created_worktask_id": "<worktask_id>",
  "created_at": "<ISO-8601>",
  "last_commented_run_index": 0
}
```

`created_run_index` is the run that opened the issue; `last_commented_run_index` advances with
each later run's follow-up comment.

## Two tiers: advisory preflight, then authoritative anchor

The anchor exists only once a `.context/` does, so it protects re-runs, not the first run of work
already filed under different wording. `/worktask` covers that at entry with
`skills/worktask/scripts/preflight-issue-scan.sh` (`skills/worktask/references/workflow.md § Step 2a`): before
`.context/` is created it scores keyword overlap against open-issue titles and offers candidates
to the user, who may bind the new context to one.

The preflight is advisory, human-confirmed, and writes nothing itself; no fuzzy match ever
auto-binds. Reusing an issue writes an anchor with `created_run_index: -1` (the same "predates
this context" value a recovered search hit gets), so the publish step comments instead of creating.

## Resolution order

`publish-pl-issue.sh` resolves the canonical issue in this order, stopping at the first hit:

1. **`.context/gh-issue.json` anchor** — authoritative, local, run-independent.
2. **`state.json:metadata.github_issue_url`** — present only within the same run (resume).
3. **GitHub search** — `gh issue list --state open --search "<title> in:title"`, accepted only on
   an exact normalized-title match with a single result; multi-hit results are refused so an
   unrelated same-worded issue never captures a fresh context. A hit backfills the anchor.
   Disable with `GH_ISSUE_SEARCH=0`.

## The decision

- **Nothing resolves** → create the issue, then write the anchor and the `state.json` URL.
- **Created in this run** (`created_run_index >= run_index`, or a same-run state URL) → defer
  `already_published`; no create, no comment.
- **Created in an earlier run** (`created_run_index < run_index`, or a search hit) → post one
  follow-up comment carrying the sanitized plan summary, marked
  `<!-- worktask-plan:<worktask_id>:<run_index> -->`, then advance `last_commented_run_index`.
  If that marker is already on the issue, defer `comment_already_present` instead.

## Precedence with other guards

Order in `publish-pl-issue.sh`: `--no-gh-issue` opt-out → this dedup → milestone-mode skip →
`gh` present / auth / remote. Under `/megatask` the parent milestone issue is canonical, so
per-issue runs neither create nor comment.

## Enforcement

`skills/worktask/scripts/publish-pl-issue.sh` is the single choke point; the resolve, anchor and
marker functions live in `publish-pl-issue-lib.sh`. Tests: `tests/shell/worktask/gh-issue-dedup.bats`,
and `preflight-issue-scan.bats` for the advisory tier. Route every worktask issue creation through
this helper rather than adding a second `gh issue create` path.
