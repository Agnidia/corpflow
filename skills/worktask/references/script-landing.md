# Script landing

Read when executing or checking script landing.

Procedure routing: [scripts](scripts.md).

<!-- canonical-body:start -->
## land-artifacts.sh — CLI

```
land-artifacts.sh --producer <ID> [--consumer <ID>] [--state <p>] [--orch-root <p>] [--dry-run]
land-artifacts.sh --consumer <ID> [--state <p>] [--orch-root <p>] [--dry-run]
land-artifacts.sh --list-landed --tree <path> [--strict] [--state <p>]
land-artifacts.sh --check-path <path>
land-artifacts.sh --self-test | -h | --help
```

Any call with `--producer` is the boundary pass (§ Step 6.5d); `--consumer` alone is the dispatch
gate (§ Step 4.8 — land consumed artifacts). `--dry-run` checks every path and writes nothing.
`--list-landed --tree <path>` prints the landed set scoped to that tree
(`skills/worktask/references/contracts/ledger-streams.md § The landed set`) one path per line; empty output is exit 0, and
no `--tree` is exit 2.

### land-artifacts.sh — the fail-closed modes

`--strict` prints the same set, but exits 1 with empty stdout and one stderr line that never echoes
the entry when any raw `landed_paths` entry scoped to that tree fails the path ladder or the
alphabet. This script never writes such an entry, so one means a hand-edited ledger.
`--check-path <path>` runs the path ladder alone, with no ledger: silent exit 0 when safe, exit 1
printing `reason=<token>` when refused. The orchestrator's grant admits a call only when its first
argument is `--producer`, `--consumer` or `--list-landed`, so every call leads with that argument.
Scripts make the other calls: `fn-stream-merge.sh` and `blocked-on-dispatch.sh` pass `--strict`, and
only the router calls `--check-path`.

## land-artifacts.sh — exits

Exits: 0, 1 or 2 only: an interrupting signal (INT, TERM, HUP) or an unexpected command failure
rolls back what the run wrote and exits 2, so 1 is never a stray status. Exit `0`: landed, same
tree, already present, a gate no-op, nothing selected, or a consumer a boundary pass skips — a
`blocked` one silently, any other non-`pending` one with one `warn` `contract_landed` row
(`consumer_not_pending`). `1`: a consumer failed, and is now `blocked` with
`metadata.landing_error {reason, path, producer}` and one fail `contract_landed` row; the gate
refuses a consumer that is no longer `pending` this way (`consumer_already_dispatched`). Exit 1 is
also a refused `--check-path` or an unsafe entry under `--strict`; neither writes. `2`: usage, a
malformed id, a bad ledger, an invalid tree, a missing tool, a failed ledger write, or that signal
or failure. Refusals and audit rows:
`skills/worktask/references/contracts/artifact-landing.md § Landing consumed artifacts`.
