# Ledger streams

Read when executing or checking ledger streams. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### Fan-out fields (DV rows)

Set on DV rows only. Canonical model, naming grammar and the single-DV case:
`skills/worktask/references/handoff-protocol.md § DV fan-out — ledger tasks`.

| Field | Purpose |
| --- | --- |
| `stream` | Kebab slug naming this row's artifact, unique among the run's DV rows. Assigned by the row's creator (PL0, or TL when TL runs) — DV never invents one. Mandatory once a run carries ≥2 DV rows; omittable for a lone DV row |
| `artifact` | The path this row writes, `.context/development-<N>-<stream>.md` (`.context/development-<N>.md` for a lone row). Planned value only: `tasks.<ID>.artifact`, stamped by `state-patch.sh --artifact` at completion, outranks it |

### Landing fields (DV rows)

Written on DV rows and read by `skills/worktask/scripts/land-artifacts.sh`. Declarations, passes and
refusal reasons: `skills/worktask/references/handoff-protocol.md § Landing consumed artifacts`.

| Field | Purpose |
| --- | --- |
| `produces` | Producer rows: repo-relative, post-merge paths this row `git add`s for its consumers before its completion patch. Written by PL0 or TL only |
| `consumes` | Consumer rows: `[{from: "DV<n>", paths: [path]}]`, each path one the producer lists in `produces`. The row is also `blocked_by` every `from`. Written by PL0 or TL only |

#### Landing results

| Field | Purpose |
| --- | --- |
| `landed_paths` | Consumer rows: sorted unique paths landed untracked into this row's tree. Written only by `land-artifacts.sh`; absent or `[]` is normal (§ The landed set) |
| `landed_roots` | Consumer rows: every spelling of each tree those paths landed into — the banner path, `git rev-parse --show-toplevel`, the physical root. Written only by `land-artifacts.sh`, in the same write as `landed_paths` |
| `landing_error` | `{reason, path, producer}` while a refused landing holds this row `blocked`; `null` once released |

#### The landed set

The paths landed into one tree: `landed_paths` from every row whose `landed_roots` holds that
tree, so no reader has to decide which row is the consumer. Every reader computes it with this
expression, byte for byte, always passing the tree as `--arg root`:

```jq
[(.tasks // {})[] | .metadata | select(any(.landed_roots // [] | arrays | .[]; . == $root)) | .landed_paths // [] | arrays | .[] | strings | select(test("\\A[A-Za-z0-9._@+/-]+\\z"))] | unique | .[]
```

The key is the tree that received the landing, not a row's assigned `workspace_path`: a re-pin
rewrites that path, and a copy left in the old tree must stay excluded there. An entry outside the
`[A-Za-z0-9._@+/-]` alphabet is dropped, so it never becomes a match pattern; the match is
whole-string, so an entry with a trailing newline is dropped too.

##### The landed set — each reader's root

| Reader | `$root` |
| --- | --- |
| Script transports (fn-preflight base-sanity, `skills/worktask/references/orchestration.md` Step 4.7a) | `land-artifacts.sh --list-landed --tree "$(git rev-parse --show-toplevel)"`. `--tree` is required (exit 2 without it); the script matches the tree's physical path |
| `fn-stream-merge.sh` | `--list-landed --tree <tree> --strict`, each stream's `<tree>` from `plan`, never a union |
| `blocked-on-dispatch.sh` (`artifact` arm) | `--list-landed --tree <workspace_path> --strict`, the parked task's `metadata.workspace_path` |
| `hooks/dv-comment-density-gate.sh` | Its physical `_root`, resolved with `cd -P` and `pwd -P` |

`--strict` fails closed on an entry the path ladder refuses instead of dropping it; the FN arm and
the artifact arm use it.

##### The landed set — each agent's root

| Reader | `$root` |
| --- | --- |
| `agents/project-manager.md` (FN scope check) | Single tree: `git rev-parse --show-toplevel`. Multi-stream arm: the stream's `<tree>` from `fn-stream-merge.sh plan` |
| `agents/technical-lead.md` (DR untracked check) | The DV row's `metadata.workspace_path` as the ledger holds it, else the orchestrator's `git rev-parse --show-toplevel` |
| Any reader with no tree to hand | `--arg root ""`, which matches no row: the set is empty, never the union over every tree |

##### The landed set — subtracting it

A reader subtracts the set from untracked entries only, enumerated file-level
(`git status --porcelain --untracked-files=all` or `git ls-files --others --exclude-standard`),
since default porcelain collapses a new directory to `?? dir/`. It never subtracts from `M`, `A` or
`D` lines: a staged landed path is a consumer violation and stays visible. An empty set is normal;
only `land-artifacts.sh` writes it, and the producer's tree ships every landed file.

### Dispatch metadata (optional)

Optional, additive fields — `permission_mode`, `add_dirs`, `mcp_config_path`,
`plugin_dir_overrides`, `dangerously_skip_permissions`, `settings_path` — each mapping 1:1 to a
`claude -p --agent` recipe flag; canonical per-field table (flag, type, in-process honouring, usage):
`skills/agent-coordination/references/headless-dispatch.md § Translation Table`. In-process the
orchestrator honours `model` (always) and `permission_mode` (audited per
`skills/agent-coordination/references/headless-dispatch.md § Permission-Mode Pinning (in-process)`);
the rest are advisory, read only by external CLI dispatchers, and the orchestrator may refuse
`dangerously_skip_permissions`.

#### Compaction and retry controls

The five optional fields below require the headless route. They remain unset by default under schema version 2.

| Field | Type | Child transport |
| --- | --- | --- |
| `auto_compact_window` | Integer, 100000–1000000 tokens | `--autocompact` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; a subagent's `autoCompactWindow` can lower it, never raise it (2.1.312) |
| `retry_watchdog` | Boolean | `CLAUDE_CODE_RETRY_WATCHDOG` (`1` or `0`) |
| `retry_watchdog_max_wait_ms` | Positive integer milliseconds | `CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS` |
| `retry_watchdog_max_usage_limit_wait_ms` | Positive integer milliseconds | `CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS` |
| `overloaded_retry_max_delay_ms` | Positive integer milliseconds | `CLAUDE_CODE_OVERLOADED_RETRY_MAX_DELAY_MS` |

##### Control validation before writes

Millisecond values cannot exceed 2147483647. Watchdog wait limits require `retry_watchdog: true` on the resulting row.
Explicit nulls and numeric strings are invalid. Validate the merged row for metadata updates, before writing anything.
These controls do not change `model`, permission ceilings, or dispatched-agent records.

#### Dispatch writer rules

PL0 should set `permission_mode: default` on SR/FN tasks under `--secure`/`--full` and never sets
`dangerously_skip_permissions` (CI batch only) on PL/SR/FN tasks; full rules:
`skills/worktask/references/pl0-procedure.md § Optional dispatch metadata`. `workspace_path` (always
stamped, not dispatch-optional) names the worktree a headless dispatcher `cd`s into before running
`claude -p --agent` — there is no top-level `--cwd` flag to carry it instead.

#### effort is mandatory, and the Agent call carries it

The ledger requires `effort`; the C.0a resolver reads it and bumps one rung.
See `skills/worktask/references/contracts/sweep-boundaries.md § Blocking items are resolved, not asked`.
Static agent `effort:` mirrors the matrix; `agent-effort-frontmatter.bats` enforces parity.
Claude applies it only when the call omits effort.
Since 2.1.292, `Agent()` passes the stamped tier (`effort_transport: "agent-param"`), above frontmatter.
Raises, resolver bumps, and `CORPFLOW.md § Models` overrides therefore apply in-process.
Only `CORPFLOW_HEADLESS_ROUTE=on` chooses headless transport.
`state-patch.sh` validates `EFFORT_ENUM` on `--task-create` and `--task-meta`.
`CLAUDE_CODE_SUBAGENT_EFFORT` (2.1.316) supplies defaults only; explicit effort wins, requiring no new field.
Admin ceilings are cached in `facts.capabilities.effort_cap`.
