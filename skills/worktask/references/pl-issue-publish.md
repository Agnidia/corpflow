# PL Issue Publish — reference

Runtime semantics of `scripts/publish-pl-issue.sh`, which the orchestrator runs between PL0 completion and stage-loop entry (`skills/worktask/references/completion-handoff.md § PL Issue Publish`). Read when interpreting its audit rows or changing what it publishes.

## Outcome & audit vocabulary

**Non-blocking by contract** (default): the orchestrator wraps the call in `; true`, and the helper itself returns `0` for every operational outcome (success, deferred, network error, sanitiser abort) — only catastrophic bugs (`jq` missing, `audit_dir_unwritable`, `state_corrupt`, `plan_unreadable`) raise `1`. Each outcome writes one `github_issue_created` row to `.context/logs/audit.jsonl` with `result ∈ {ok, deferred, failed, error}`, `metadata.reason` from the table below, and dedupe key `<worktask_id>:<run_index>:gh_issue`. On success `metadata.mode ∈ {create, comment}`: the FIRST run in a `.context/` creates the issue, a LATER run comments on it (cross-run dedup — `skills/gh-issue-dedup`; milestone mode skips both).

## Reason enum

| `metadata.reason` | Notes |
|---|---|
| `gh_not_installed`, `auth_missing`, `no_remote` | environment preflight failures |
| `network_error` | genuine transport-failure stderr only (`could not resolve host`, `connection refused`, `timeout`); label/auth/api failures map to their specific reason instead |
| `sanitiser_aborted` | >50% strip-ratio abort (§ Strip-ratio abort) |
| `already_published`, `comment_already_present` | cross-run dedup outcomes |
| `opted_out` | `--no-gh-issue` |
| `milestone_mode` | megatask per-issue skip |
| `helper_not_found` | emitted by the orchestrator, not the helper, when the helper file is unreachable |
| `label_create_failed`, `gh_api_error`, `gh_timeout`, `permission_denied`, `repo_not_found` | `gh`-side failures |

### Reason enum — advisory rows

`title_fallback_worktask_id` is advisory, not an outcome (§ Title and Summary resolution): every prose title source was empty, so the published title is the kebab worktask id. It carries `metadata.title_source`, uses the `<dedupe_key>:title_source` suffix so it never masks the canonical outcome row, and never blocks.

## Strict mode

`--strict`, or `metadata.gh_issue.strict: true` on state.json, flips operational failures from non-blocking `result: "deferred"` to blocking `result: "failed"` with `exit 1`. Use when an unpublished issue is unacceptable (compliance-tracked runs). Default behaviour is unchanged.

## Title and Summary resolution

`facts.goal` is OPTIONAL — it exists only once the PM agent patches state.json, so an orchestrator-inline seed, a hand-authored `.context/`, or a regenerated state leaves it unset. Title and Summary therefore resolve independently, first non-empty wins:

| | Chain |
|---|---|
| **Title** | `facts.goal` → plan frontmatter `title:` → plan first `# ` H1 → first sentence of `## summary`/`## problem` → `worktask_id` |
| **Summary** | `facts.goal` → `## summary` → `## problem` |

### Title and Summary resolution — invariants

`worktask_id` is deliberately absent from the Summary chain — an empty section is honest, a slug posing as prose is not. Reaching the `worktask_id` title rank emits the advisory `title_fallback_worktask_id` row, so the degradation is visible rather than silent; it never blocks. At every rank the title is reduced to its first line, sanitised, then capped at 100 characters on the last word boundary with `…` counted inside the budget, so a multi-line frontmatter value cannot break the title. `resolve_context_issue_search()` recovers a lost `.context` ↔ issue binding by exact-title search against the current title, and also probes the legacy fixed-100 title when it differs, so an issue published under the older scheme is still recovered rather than duplicated.

## External-ticket extraction

The helper extracts a `^[A-Z][A-Z0-9]+-[0-9]+` prefix from `facts.goal`, then the winning title source, then the plan frontmatter's `issue:`, then upper-cased `worktask_id`. On match it (a) ensures the issue title starts with the prefix without double-prefixing, (b) appends a `ticket:<PREFIX>` label (auto-provisioned via the same `ensure_labels()` path as the canonical set), (c) persists the prefix to `state.json:metadata.external_ticket`, (d) includes `external_ticket` in the success audit row. A canonical or ticket label `ensure_labels()` cannot create is dropped from the `--label` argument and recorded in `metadata.labels_dropped` (array).

## Sanitiser pass 1 — line drops (L1–L9)

Drops entire lines matching any of nine rules: `.context/` paths; absolute paths (`/Users/`, `/home/`, `/tmp/`, `/var/`, `/opt/`, `/etc/`, `/root/`); `~/`-prefixed paths; `conductor/workspaces/<id>` directories; the literal tokens `workspace_path`/`plan_file`/`run_index`/`artifact_path`; every numbered artifact filename (`planning-N.md`, `architecture-N.md`, `coordination-N.md`, `development-N.md`, `developer-review-N.md`, `testing-N.md`, `documentation-N.md`, `release-N.md`, `complete-summary-N.md`, `retrospective-N.md`, `incident-N.md`, `ethics-review-N.md`); `./` and `../` relative paths.

## Sanitiser pass 2 — filename tokens (A1–A5)

Strips filename-shaped tokens (`MyClass.swift`) UNLESS an allow-list rule fires — A1: inside a fenced code block; A2: inside inline-code backticks; A3: follows a `symbol:` prefix; A4: on a narrative-bullet line labelled `class`/`type`/`protocol`/`struct`/`enum`/`function`/`fn`/`func`/`method`; A5: extension outside the deny-list `.md/.json/.jsonl/.swift/.ts/.py/.yml/.yaml/.sh/.bash/.go/.rs/.kt/.java/.rb/.cpp/.c/.h/.hpp/.m/.mm`.

## Strip-ratio abort

If the sanitiser removes more than 50% of the body length, the helper refuses to publish, persists the (still partially-sanitised) body to `.context/logs/issue-body-<run_index>.aborted.tmp` for operator inspection, and audits `result: "deferred"`, `reason: "sanitiser_aborted"`, `metadata.strip_ratio: <int>`. Operators amend the plan's `## requirements`/`## acceptance-criteria`/`## scope`/`## complexity` anchors to reduce path-like noise.

## Skip paths: opt-out and megatask

- **`--no-gh-issue`**: `/worktask` Step 4 stamps `metadata.no_gh_issue: true` on PL0 and PM propagates it. The helper exits `0` immediately with `result: "deferred"`, `reason: "opted_out"` — no `gh` API call. Stage-loop entry proceeds unchanged.
- **Megatask per-issue**: exits `0` immediately with `result: "deferred"`, `reason: "milestone_mode"` — **no `gh issue create`, no `gh issue comment`, no API call of any kind**, because the parent milestone issue is the canonical record and auto-posted plan comments fragment the review surface; PR linkage ties the implementation back. Detection (highest priority first): `MILESTONE_MODE=1` env override (tests), non-empty `state.json:metadata.milestone`, `workspace.json` present at `$PWD` or `$WORKSPACE_ROOT`.

## Cross-run dedup (one `.context/` ↔ one issue)

`state.json` is re-seeded on every fresh `/worktask` (its `metadata` is wiped), so the canonical issue reference lives in the run-independent `.context/gh-issue.json` anchor. Guard order: opt-out → **cross-run resolve** → milestone skip → `gh`/auth/remote. The helper resolves the anchor, or — anchor lost — an exact-title **single-hit** `gh issue list --state open --search` (`GH_ISSUE_SEARCH=0` disables; ambiguous multi-hit results are refused): created **this** run → `already_published`; created in an **earlier** run → one marker-deduped follow-up comment (`result: "ok"`, `metadata.mode: "comment"`, `metadata.resolved_via ∈ {anchor, search}`) instead of a duplicate; re-posting in the same run defers `comment_already_present`. Full protocol: `skills/gh-issue-dedup`.

## Hard guarantee

**HARD GUARANTEE** — no local-file paths, no `.context/` references, no `planning-N.md` or any other artifact filename, no absolute or relative source paths, no Conductor workspace IDs, and no `workspace_path`/`plan_file`/`run_index`/`artifact_path` literals are EVER written to the published GitHub issue body, under any circumstances. Defence-in-depth: PL0 authoring hygiene is primary (`references/pl0-procedure.md § Anchor-content hygiene`), the two-pass sanitiser is the runtime safety net, the >50% strip-ratio abort is the final brake.

## Non-blocking guarantee

Helper exit 1 (catastrophic), exit 0 with `result: "deferred"` (any reason), a `gh` hang past `GH_TIMEOUT` (default 30s), or a `state.json` write failure after a successful `gh` call — none cause the orchestrator to halt, retry the publish step, or branch. Its only post-helper action is to read one optional `published_url=<url>` line from stdout (terminal UX) and continue unconditionally to stage-loop entry.
