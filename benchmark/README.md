# Plugin Benchmark — Dual-Path Tic-Tac-Toe A/B Test (Python harness)

Measures plugin overhead via a real, runnable **SwiftUI multiplatform Tic-Tac-Toe
app** (macOS 15+ / iOS 18+) built two ways: **WITH the plugin's staged worktask
pipeline** (staged scaffold driven by the real `estimate-calc.py`) vs **WITHOUT
it** (single-shot baseline). Each generated app ships its own passing **Swift
Testing** suite; the harness runs the tests, captures all metrics, and stores the
latest 3 results per mode as a rolling history.

The harness itself is Python (stdlib-only package `benchmark/harness/` —
`benchmarkkit` + `benchmarklive` + `bin/` entrypoints + `tests/`, zero external
dependencies, no build step). It still subprocesses `swift build` / `swift test`
against the generated apps and the `ttt-template` — that Swift toolchain call IS
the measurement instrument, so swift stays a hard host prerequisite alongside
python3, jq, and make. The plugin's skill scripts (`skills/**/scripts/*.py`) stay
Python and are exercised in-process by the Python skill-script test suite.

## Quick Start

```bash
# Deterministic default (offline, CI-safe, process-overhead comparison)
make benchmark

# Live full-pipeline (opt-in, credential-gated, measures real tokens/cost)
make benchmark-live
make benchmark-live BUDGET=10.00 STAGES=PL,AR,DV   # subset probe

# Render an HTML report (auto-run after a benchmark)
make report        # -> benchmark/results/result.html

# Render an evidence-backed markdown analysis of the latest live run
./benchmark/harness/bin/bench-analyze   # -> benchmark/results/analysis.md

# Or explicitly:
./benchmark/run-benchmark.sh                        # deterministic
./benchmark/run-benchmark.sh --live                 # live, --budget 50.00 default
./benchmark/run-benchmark.sh --live --budget 2.50
./benchmark/run-benchmark.sh --live --stages PL,AR,DV   # targeted stage subset
./benchmark/run-benchmark.sh --live --without-arm skip  # force-skip the WITHOUT baseline
./benchmark/run-benchmark.sh --live --provider codex --arm both --budget 50.00

# One arm at a time (live), then join the two records offline
./benchmark/run-benchmark.sh --live --arm with --budget 50.00
./benchmark/run-benchmark.sh --live --arm without --budget 50.00
./benchmark/harness/bin/bench-pair \
  --a benchmark/results/runs/live-arm/<with-run>.json \
  --b benchmark/results/runs/live-arm/<without-run>.json \
  --out benchmark/results/runs/live/joined.json
```

`--provider claude|codex` defaults to Claude. Make accepts `PROVIDER=codex` for the benchmark targets.
The providers share the workload, stage efforts, scoring, budget gates, records, and reports.
Codex uses `codex exec --json` with stdin prompts and the existing ChatGPT login.
Its isolated configuration loads a verified skills snapshot and canonical stage roles for WITH.
WITHOUT loads no Corpflow skills or roles. Both arms disable nested agents and external services.
Codex applies workspace restrictions and denies reads of credentials, the source checkout, and the opposite arm.

The pinned Codex tiers are Opus → `gpt-6.1-sol`, Sonnet → `gpt-6.1-terra`,
Haiku → `gpt-6-luna`, and Fable → `gpt-6-astra`.
The official standard API-equivalent rates are pinned in `harness/benchmarklive/providers/codex/pricing.json`.
The $50 paired allowance reserves $25 per arm, including failed attempts and retries.
Missing usage or pricing stops the run and saves partial results. Stage admission permits a running-stage overshoot.
Each live JSON record has adjacent HTML and Markdown reports, including partial runs.
Codex coding stages defer native UI, Xcode, and simulator operations to host validation.
Run `make benchmark-native APP=<generated-app>` from the host to test the app's shared iOS scheme.
The command uses a dedicated simulator and writes a separate result bundle; it makes no model calls.
Unavailable runtimes produce an explicit skip. Service errors and failed tests produce failures.

## What It Does

1. **Builds a REAL SwiftUI Tic-Tac-Toe app** two ways:
   - **WITH plugin**: staged scaffold — one stage per `Sources/TicTacToeKit/<module>`
     + executable + tests, complexity score from the real `estimate-calc.py`
   - **WITHOUT plugin**: single-shot copy baseline (1 stage, score 0)

2. **Each generated app includes** (from `benchmark/ttt-template/`):
   - SwiftUI views: main menu, animated 3x3 game board with winning-line
     highlight, leaderboard, settings — plus a `--cli` text loop
   - Engine: move validation, win/draw detection, AI opponent (easy random /
     hard minimax); Codable leaderboard + settings persistence; protocol-based
     sound (headless-safe)
   - A passing Swift Testing suite (48 tests) the harness actually runs

3. **Captures ALL metrics** (real, never fabricated):
   - `loc_produced` — non-blank, non-comment `*.swift` lines (excl. `.build`)
   - `test_count` — parsed from the Swift Testing summary (`Test run with N tests`)
   - `pass_fail` — from the `swift test` exit code ONLY
   - `wall_clock_s` — monotonic, per arm (see wall-clock note below)
   - `estimate_complexity_score` / `stage_count` — process-overhead signals
   - `tokens` (in/out/total/cache_read/cache_creation) / `cost_usd` — null in
     deterministic, real in live
   - per-stage `stages[]` attribution + NEW per-stage `coverage` manifest (live)

4. **Computes deltas**: WITH-vs-WITHOUT `comparison` block (`with`/`without`/
   `delta` per metric; live adds `tokens_total` + `cost_usd`).

5. **Stores history**: `benchmark/results/history.json`, newest last, atomic
   tmp→fsync→rename; the other mode's bucket stays byte-identical. Retention is
   per mode (`rotation.RETENTION`): **deterministic keeps 3** (free to reproduce),
   **live keeps everything** — a live record costs real spend and is the only
   evidence of the run that produced it, so rotating it away would destroy the
   samples a variance envelope needs. Live per-run detail files under
   `results/runs/live/` are tracked in git for the same reason; deterministic ones
   stay ignored. Existing records still decode — back-compat is pinned by
   `HistoryBackCompatTests` against a vendored copy of the real file.

## Wall-clock semantics (Swift migration boundary)

The harness release build and one `ttt-template` warm-up build run **before any
timing**; the per-arm app **builds + test runs stay inside the Timer**. SwiftPM
builds cost far more than the old Python file-copy, so **cross-boundary
wall-clock comparisons (Python-era records vs Swift-era records) are invalid** —
compare wall-clock only within records produced by the same harness generation.
Token/cost fields are unaffected by the boundary.

## Modes

### Deterministic (Default)

```bash
make benchmark
```

- Fully offline (zero network; AC-8 is **link-level**: `bench-deterministic`
  cannot even link the live module — asserted by a Package.swift graph test)
- CI-safe (no credential, no randomness)
- `tokens` / `cost_usd` = `null`; all other metrics real
- Exit codes: 0 success, 1 a generated app's tests failed, 64 bad argv

### Live (Opt-In)

```bash
make benchmark-live
./benchmark/run-benchmark.sh --live --budget 3.00
./benchmark/run-benchmark.sh --live --stages DV,QA   # rc=4 tail re-probe
```

- **NEVER CI** — credential-gated, real spend
- Full pipeline PL→AR→TL→DV→DR→SR→QA→DC→FN→ST (10 stages — SR is in the
  benchmark's live pipeline even when a given worktask drops it as a stage),
  one headless `claude -p` dispatch per stage, frozen argv (BOTH arms identical except `--agent`):
  `claude -p --model <m> --effort <e> --permission-mode bypassPermissions
  --settings benchmark/live/settings/benchmark-settings.json
  --output-format <json|stream-json> --agent <agent>`; prompt fed on stdin as
  the assembled `[1][2][3][4][5]` cache-prefix layout
- `--stages CODE[,CODE…]` (or `make benchmark-live STAGES=…`) dispatches a
  validated subset in canonical order — unknown code exits 64
- Default capture is `stream-json`, which additionally yields the per-stage
  **coverage manifest**; `--capture json` (bench-live flag) keeps the
  single-object capture

**Credentials — machine `claude` login is the PREFERRED source;
`ANTHROPIC_API_KEY` is an optional override.** The credential gate accepts
EITHER: (1) an active `claude` login on the machine (checked via
`claude auth status --json` under the eval `CLAUDE_CONFIG_DIR`, cheap and
non-interactive — no key export needed),
or (2) `ANTHROPIC_API_KEY` in the environment, checked FIRST when present.
**Pitfall:** an `ANTHROPIC_API_KEY` that is actually an OAuth-token-shaped value
(not a real `sk-ant-api…` key) will 401 when used as an API key AND overrides a
working machine login if exported — do NOT `export`/source such a value. If you
rely on the machine login, leave `ANTHROPIC_API_KEY` unset in the invoking
shell. The key VALUE and any CLI-login identity (email/org) are never logged,
echoed, or persisted — presence is the only thing probed. Missing both →
frozen stderr message, rc=3, no dispatch, no record.

**Budget enforcement** — `--budget` bounds what dispatch will START, not what a
run realizes. Both gates decide *before* a stage; a dispatch already in flight
has no cost ceiling, so realized spend can exceed the cap by one stage. Treat
`--budget` as a ceiling on commitments with a one-stage tolerance, and read the
realized figure off the record.

- Pre-flight projection via the real `estimate-calc.py` — rc=2, dispatches
  NOTHING when the projection exceeds `--budget`. Projected per stage from
  `budget.STAGE_EXPECTED_TOKENS`: DV runs an order of magnitude heavier than
  the rest, so one flat figure across the pipeline halves the projection and
  admits budgets that cannot finish. A full paired run projects **~$39**
- Running-tally gate before EACH stage — aborts BEFORE the breaching stage,
  reserving the larger of the next stage's projection and the heaviest stage
  that arm has actually run. Once a stage beats its projection the gate
  reserves the observed figure instead, so only a stage heavier than every
  predecessor can still overshoot.
  **This is what truncates a paired run that is comfortably inside its budget.**
  DV is an order of magnitude heavier than the six stages after it, so once it
  lands the gate demands DV-sized headroom to start a $0.20 stage.
  `live-20260910T160618Z` died on exactly this at `--budget 50`: the WITH arm had
  spent $16.32 of its $25 share, DR projected $2.70, and the reserve carried DV's
  $12.35 — $16.32 + $12.35 > $25, so the arm stopped needing ~$7 more. It realized
  $32.48 of $50. **Budget a paired run at ~$80, not the ~$44 it costs**; the
  headroom is for the reserve rule, not for spend
- **Per-arm shares**: `--budget` is divided by the number of arms actually
  dispatched, each with its own tally — halved on a paired run, and given
  **whole** to a single `--arm` run (see below). One shared purse let the arm
  dispatched first spend the run and leave the second truncated, which compares
  an agent against a budget
- Partial record (`live_partial=true`, `pass_fail="fail"`, partial
  `stage_count`) is **written to disk BEFORE rc=4 returns** — read rc=4
  granularity from `results/runs/live/*.json`, not from the shell exit
  (run-benchmark.sh collapses any non-zero adapter rc to exit 1 cosmetically)

**Usage limit.** A stage that dies on the account's rolling limit ("You've hit your session limit
· resets 7pm (Europe/Kiev)", or `api_error_status` 429) is classified from its full stdout. With
`--wait-on-limit` (the default; `--no-wait-on-limit` turns it off) the harness sleeps until the
reset plus 2 minutes (polling every 15 min when no time is printed; 6h cap, cumulative) and
re-dispatches that stage only. Spend and tokens the interrupted attempt reported are added to
that stage in the record and charged to the budget: the re-dispatch builds on its files, so
leaving it out understates the stage (`KNOWN-BAD-RECORDS.md`, `live-20261001T085738Z`). Its wall
time stays out. Before waiting or retrying, the interrupted attempt must pass the same plugin
and config-isolation checks as a successful attempt (violations exit **5**), and the updated
tally must still afford another attempt (otherwise a budget-limited partial exits **4**).
Off, or over the wait cap, the run writes its partial record and exits **6**, naming the
reset. Interrupted spend and tokens remain in the partial record even without a successful
retry; its stage attribution does not increment the completed `stage_count`.
Any failed stage's full stdout is kept as
`workdirs/<run_id>/captures/<arm>-<STAGE>.failed.jsonl`.

**bench-live exit codes:** 0 success · 1 WITH ledger seed refused · 2 pre-flight decline ·
3 no credential · 4 running-tally breach/degraded (partial record on disk) · 5 plugin contract
broken · 6 usage limit (waiting off or over the cap; partial record on disk) · 64 bad usage.

## Paired ±agent runner (live)

A live run dispatches **both a WITH-agent arm and a WITHOUT-agent arm**, each executing
the full **10-stage prompt sequence** (PL→AR→TL→DV→DR→SR→QA→DC→FN→ST) in parallel:

- **Symmetric arm folders**: each arm runs in its own dir `<workdir root>/<run_id>/{with,without}/`, outside
  the repo and its own `git init`ed repo (`master`, one empty commit), so a stage cannot read the harness or the
  oracle and `git rev-parse --show-toplevel` resolves to the arm. The root is `--workdir-root` /
  `BENCH_WORKDIR_ROOT` / `${TMPDIR:-/tmp}/corpflow-bench`. Captures stay in
  `benchmark/workdirs/<run_id>/captures/`, beside a symlink per arm, so report and analyzer paths hold
- **Shared prompt files**: both arms consume the identical ordered 10-stage prompt files
  (`benchmark/live/prompts/{pl,ar,tl,dv,dr,sr,qa,dc,fn,st}.txt`). Plugin-surface leakage
  (e.g. agent IDs like `apple-developer:ios-developer` or commands like `/swiftui-review`) is
  neutralized from the prompt text so the bare WITHOUT arm sees a fair identical ask
- **Dispatch difference**: WITH adds `--agent`, `--plugin-dir <plugin root>` and enables its
  sibling plugins (apple-developer); WITHOUT adds none and must load **zero** plugins. Both run
  under `CLAUDE_CONFIG_DIR` = `--config-dir` / `BENCH_CONFIG_DIR` / `~/.claude-eval`, with
  `--setting-sources ""` (repo and account-synced plugins would otherwise leak in) and the
  builtin plugins switched off. `system/init` `plugins[]` is checked every stage; a violation
  is rc 5. Stamped as `era.plugins_with` / `era.plugins_without`
- **Config-leak guard**: each stage's tool inputs, in both arms (sub-agents included), are scanned for
  `…/plugins/cache/` or `…/plugins/marketplaces/` paths outside the config dir (tool results do not
  count). The distinct prefixes are stamped per arm as `era.config_leaks` (`{"with": [], "without": []}`
  when clean; arm-scoped); a leak in either arm is rc 5. Stream-json only
- **Ledger seeding**: the harness plays the orchestrator for the WITH arm only. Before its first
  stage it runs the production `seed-state.sh` (`--worktask-id <run_id>`, `--goal` from the PL prompt's
  TASK paragraph, `--context-dir`/`--workspace-path` on the arm); a failure refuses the run (rc 1)
  before any dispatch. Before DV and QA it closes PL0, stamps `PL0.approved="auto"` and creates and
  claims `DV0` / `QA0` through `state-patch.sh`. The WITHOUT arm has no ledger
- **Policy default**: `real` on a full pipeline run, `skip` on a `--stages` subset — `--without-arm real|skip`
  (`run-benchmark.sh --live` or `bench-live`) overrides the default either way
- **Dispatch order**: the WITHOUT arm is dispatched **FIRST** (all 10 stages), followed by the WITH arm;
  the WITHOUT record is flushed to disk immediately — a later WITH-stage budget breach still leaves a
  real WITH-vs-WITHOUT comparison point on disk
- **Budget**: the pre-flight projects the stage list once per arm when `real`; each arm
  then runs under its own running-tally gate holding half of `--budget`
- **Measurement**: wall-clock and `loc_produced`/`test_count`/`pass_fail`/`stage_count`/tokens are
  measured **per arm** from each arm's own generated app and run record, stored in separate
  `paths.with` and `paths.without` objects in the metric schema
- **Failure handling**: a `DispatchFailure` from an arm is tolerated (the other arm still runs);
  a degraded/failed arm sets `live_partial` and that arm's `pass_fail` to `"fail"`
- **Per-call token accounting**: input and output token counts are persisted for every prompt
  execution in both arms, stored in each arm's run record and captured log, enabling per-prompt
  WITH-vs-WITHOUT token comparison in the analysis output
- **`without_arm="skip"` (mechanism default)**: reproduces the deterministic WITHOUT placeholder
  byte-for-byte — WITHOUT tokens/cost `null`, `wall_clock_s: 0.0`, `stage_count: 1`,
  `pass_fail: "pass"`, `app_path: null`. Its WITH block is now measured **and**
  oracle-graded like any dispatched arm, so it carries a real `app_path` and an
  `oracle` key where it previously carried neither
- **Running one arm on its own**: `--arm with|without` — see *Single-arm runs and
  joining* below. Both arms in one dispatch (`--arm both`) remains the default

## Single-arm runs and joining (`--arm`, `bench-pair`)

A paired run welds both arms into one dispatch, so one arm's bad luck destroys the
other arm's completed work — a budget breach in the second arm has thrown away a
finished first arm three times in one day. `--arm` decouples them: each arm can be
run, recorded and re-run on its own, and two arm records are welded back into the
ordinary paired shape afterwards by `bench-pair`.

```bash
./benchmark/run-benchmark.sh --live --arm both      # paired (the default, and the recommendation)
./benchmark/run-benchmark.sh --live --arm with      # WITH arm alone
./benchmark/run-benchmark.sh --live --arm without   # WITHOUT arm alone
make benchmark-live ARM=with BUDGET=50.00
./benchmark/harness/bin/bench-live --arm without …  # same flag on the executable
```

`--arm` requires `--live` (exit 64 otherwise) and accepts only `with`, `without` or
`both`. Left unset it defers to the existing `--without-arm` policy, which is what
keeps the legacy default byte-stable. Contradictory combinations (`--arm both` with
`--without-arm skip`, or `--arm with` with any explicit `--without-arm`) are a usage
error, refused with **exit 64 before the credential probe and before any dispatch**.

**`both` stays the default and stays the recommended mode.** A paired run is the
stronger single measurement because both arms share the same service conditions —
splitting spends that variance control deliberately, and the gate below is the
mitigation, not a replacement. The reason to run a single arm anyway is cost of
failure: a breach or a degraded arm now costs **one** arm's spend instead of two, so
accumulating n over several sessions is cheaper and survives interruption.

### Budget: a single arm gets the WHOLE budget

`--budget` is divided by the number of arms **actually dispatched**, not by a
paired/not-paired flag. So:

| Invocation | Per-arm share |
|---|---|
| `--arm both --budget 100` | $50 WITH + $50 WITHOUT |
| `--arm with --budget 50` | $50 WITH |
| `--arm with --budget 100` | $100 WITH — twice the paired share |

`--arm with --budget 50` and a paired `--budget 100` therefore buy the **same per-arm
spend**. This trips people up: do not halve the budget yourself when running one arm.
The pre-flight projection follows the same rule and projects one arm's stage sequence.
Sizing floor from observed runs: **$50 per arm** (see `results/KNOWN-BAD-RECORDS.md`).

A single-arm record's `live_partial` reflects that one arm only — an arm that was never
dispatched can never raise it. Measurement and oracle grading run for the dispatched
arm unconditionally, so a WITH-only run now carries its own oracle grade.

### Where arm records go — and why they are not in history

An arm record is written to **`benchmark/results/runs/live-arm/`** under an
arm-suffixed run id (`live-<ts>-<sha>-with`, plus a `-2`, `-3` … uniquifier so two
runs of the same arm in the same second on the same commit cannot collide). It stays
**out of `history.json` entirely**.

That is deliberate, not an oversight. `history.json` is what `make report` renders into
`result.html`, and a half-comparison sitting beside full runs is precisely the
misreading this whole feature exists to prevent. Two guards enforce it: the runner
skips rotation for a single-arm run, and the rotation step itself exits 3 (fail-closed)
on any record carrying an `arm` key, so pointing `--record` at an arm record by hand
still cannot get it into history. `bench-analyze` likewise filters arm records out of
both the history path and its newest-file fallback, so an arm record can never be
selected as "the latest live record".

A **joined** record carries no `arm` and rotates through exactly the pre-existing path.

### `bench-pair` — joining two arm records

```bash
./benchmark/harness/bin/bench-pair --a <arm.json> --b <arm.json> --out <record.json>
make benchmark-pair A=<arm.json> B=<arm.json> OUT=<record.json>
```

Pure analysis: no dispatch, no credential, no spend, `benchmarkkit`-only (it cannot
import the live world — the same isolation boundary `bench-analyze` sits behind), so it
is safe to run anywhere, including offline. The output is a record in the **existing
paired shape** — its `comparison` block is built by the same `build_comparison()` a
paired invocation uses — so every downstream consumer (report, analyzer, rotation)
works unchanged. The join is order-insensitive: `--a` and `--b` are keyed by each
record's own `arm`, never by position.

**Exit codes: 0 joined · 64 usage · 65 comparability refusal.** 64 covers bad argv, an
unreadable or malformed input, a paired record passed as an input, an arm record whose
`paths` block does not carry exactly its own arm, and two records of the same arm. 65
means the two runs are not comparable. The split matters: a wrapper must be able to
tell "I called it wrong" from "these two runs cannot be compared".

> **`make benchmark-pair` cannot show you 64 or 65.** GNU make collapses any recipe
> failure into its own **exit 2**. Anything that branches on 64 vs 65 must invoke
> `harness/bin/bench-pair` directly.

### The comparability gate — it refuses, it does not warn

Nothing joins two runs unless they are comparable. The gate evaluates **every** axis and
reports **all** refusals at once (fixing one and rediscovering the next on the retry is
worse than useless), writes **no output file** on refusal, and names the axis and both
values so the message is actionable without opening either record.

| Axis | Refuses when | Policy |
|---|---|---|
| era | the two `era` blocks are not fully equal; either is absent, empty or not a block | **refuse** |
| commit sha | `git_sha` differs; **or** either side is absent, empty or the `"nogit"` fallback | **refuse** |
| oracle case-set digest | `paths.<arm>.oracle.cases_digest` differs, or is absent on **either** side | **refuse** |
| time gap | never | **warn only** — reports the observed gap, no threshold |

Two refusals that surprise people, both intentional: **absent is not a pass.** An
unstamped era or a missing digest means the record cannot vouch for what it was compared
against, so it is refused on the same footing as a mismatch. Likewise two records that
both read `"nogit"` are not two runs at the same commit — they are two runs whose commit
is unknown, and they are refused rather than treated as equal.

Era comparison here is full dict equality, **stricter** than the analyzer's advisory
three-key `era_differences()` caveat: a future era key the analyzer does not inspect
would otherwise pass the gate and then be silently arbitrated away by the join. The two
policies live in two functions on purpose; the analyzer's caveat behaviour is unchanged.

The time gap is the single warn-only axis, and it is reported **without** a threshold.
At n=1 there is no variance envelope from which any number of hours could be derived, so
no number is invented — the observed gap is reported and also stored in the joined
record's `joined_from.observed_gap_s`, so a later reader can judge it without re-running
the join.

The governing principle, worth stating plainly: **a permissive gate is worse than no
gate, because it launders incomparability as a comparison.** Hence refusal everywhere an
honest answer exists, and an unthresholded report where one does not.

### Ingesting a joined record (manual, today)

`bench-pair` writes **only** `--out`. Nothing ingests a joined record automatically yet,
so reading a joined run from `history.json` or `result.html` is a deliberate manual step.
On success `bench-pair` prints the exact rotation command with resolved absolute paths:

```
[pair] wrote <out> (live-<ts>-<sha>-joined-<8 hex>)
[pair] not in history.json — ingest it deliberately with:
  PYTHONPATH="…/benchmark/harness" python3 -c "…rotation snippet…" \
    "<out>" "…/benchmark/results/history.json" "…/benchmark/results/runs"
```

Run that command to rotate the joined record into history exactly as a natively-paired
record rotates. A dedicated `bench-rotate` tool is a planned follow-up and **does not
exist** — do not reach for it.

The joined run id is `live-<later timestamp>-<sha>-joined-<8 hex>`, the tag being a hash
of both source run ids. It is order-insensitive, and it exists so two joins that happen
to share a later-timestamp and a sha cannot collide during ingest.

## Comparability eras

Every record carries an `era` block naming what its numbers can be compared
against — harness generation, prompt-contract version, and the per-stage model
pins read straight from `STAGE_TABLE`:

```json
"era": {"harness": "python-2", "prompt_contract": "scripted-cli-v2",
        "model_pins": {"PL": "claude-opus-5-5", "DC": "claude-haiku-5-5", …}}
```

`bench-analyze` compares the analyzed record's era against the previous live
record **automatically** and emits a `## validity-caveats` entry naming each
differing dimension — no `--reference` flag required. A record with no `era`
block is itself caveated as unverifiable. Bump `PROMPT_CONTRACT` in
`benchmarklive/stage_table.py` whenever the graded task text changes; a workload
change invalidates comparisons just as surely as a model repin.

**Known era boundaries:**

- **v4.1.1** — `DC` repinned from `claude-haiku-4-5` to `claude-haiku-5-5` (Haiku 5.5,
  1/10 the Haiku 4.5 rate). DC token and cost figures from that version on are **not
  comparable** to earlier runs; `bench-analyze` flags the `model_pins` change on its own.
- **v3.37.1** — `STAGE_TABLE` repinned from the prior Opus/Sonnet generation to
  `claude-opus-5` / `claude-sonnet-5`. Runs from that version on are **not
  comparable** to the stored baselines in `results/history.json`,
  `results/analysis.md`, or `results/token-findings-*.md`. `DC` still dispatches
  `claude-haiku-4-5`, unchanged.
- **Python → Swift → Python harness** — see the wall-clock note above.
- **`scripted-cli-v1`** — the graded CLI contract was added to `dv.txt` and
  `without.txt`, changing the workload for both arms.
- **`scripted-cli-v2`** — the contract now states that stdout stays empty on
  exit 1 and 2. The five reject cases had been grading that silently, so a
  reasonable arm that printed the board before erroring lost them without ever
  being told. Stamped as an era because it is a prompt change, though it only
  narrows what was already being graded.
- **`scripted-cli-v3`** — the contract gained three bullets: token whitespace is
  spaces and tabs only, the whole list is parsed before any move is played, and an
  empty token contributes no move. The goldens had been grading all three from the
  reference while the contract said nothing, so arms were losing cases for
  behaviour nobody had described. Stating the rules also **moves that behaviour
  into `specified`** — the five cases added alongside them were filed `implied`
  and stayed there until 2026-09-10, which is how the discriminating tier came to
  read 11 cases while only 5 discriminated.
- **Opus 5.5 pins** — the five Opus stages in `STAGE_TABLE` (PL, AR, DV, DR, SR)
  repinned from `claude-opus-5` to `claude-opus-5-5`, the model the `opus` alias
  resolves to. Runs from this change on are **not comparable** to any earlier
  record. The new pins travel in every record's `era.model_pins`, so the pairing
  gate refuses mixed pairs and `bench-analyze` caveats the first new run against
  the last `claude-opus-5` one on its own; no entry in `results/history.json` is
  edited. The Sonnet and Haiku stages are unchanged.
- **Sonnet 5.5 pins** — the four Sonnet stages in `STAGE_TABLE` (TL, QA, FN, ST)
  repinned from `claude-sonnet-5` to `claude-sonnet-5-5`, the model the `sonnet`
  alias resolves to. Runs from this change on are **not comparable** to any earlier
  record. The new pins travel in every record's `era.model_pins`, so the pairing
  gate refuses mixed pairs and `bench-analyze` caveats the first new run against
  the last `claude-sonnet-5` one on its own; no entry in `results/history.json` is
  edited. The Opus and Haiku stages are unchanged.
- **Plugin-free baseline + isolated config dir** — the WITHOUT arm used to load
  whatever the machine had installed; it now loads zero plugins, and both arms run under
  `~/.claude-eval` with no settings layers. WITH also gains an enabled `apple-developer` and
  seeded `DV0`/`QA0` ledger rows. Records from here on are **not comparable** with earlier
  ones: `era.harness` moves `python-1` → `python-2`, so the pairing gate refuses mixed
  pairs. `era.plugins_with` / `era.plugins_without` are arm-scoped and ignored by it.
- **Out-of-repo workdirs + sub-agent-inclusive tokens (python-3)** — arms now run under
  `--workdir-root` (default `${TMPDIR:-/tmp}/corpflow-bench`), each its own git repo, and a stage's
  `fresh_in`/`out`/`cache_*` sum `result.modelUsage` over every model, sub-agents included; they
  were parent-only `result.usage`. The parent-only figures stay as `parent_fresh_in`, `parent_out`,
  `parent_cache_read`, `parent_cache_creation`. `cost_usd` is unchanged, so cost compares across
  python-2 and python-3 while tokens do not. `era.harness` moves `python-2` → `python-3`, so the
  pairing gate refuses mixed pairs. `era.config_leaks` is arm-scoped and ignored by it.
  The shared stage preamble also stops telling agents to "set `stages.<CODE>` completed" in
  `state.json`: the ledger has no `stages{}` map, and python-2 WITH runs hand-edited one with `jq`
  instead of closing their task through `state-patch.sh`. Both arms get the same shortened
  reminder (five items, not six). `PROMPT_CONTRACT` stays `scripted-cli-v3`: it stamps the graded
  CLI contract, and this change rides the same `python-2` → `python-3` boundary.

- **`scripted-cli-v4`** — `pl.txt` now embeds the same contract, so the WITH arm's PL stage can
  write it into `planning-0.md` as byte-exact acceptance criteria, as a production `/worktask`
  would from the user's goal. The contract text and `CLI_CONTRACT_DIGEST` are unchanged; the
  WITHOUT arm's prompt is unchanged. Bumped because the graded task text one arm sees changed.

The first three predate era stamping, so records from before it must be compared
by hand against this list.

The oracle case set is a **separate** comparability axis, gated on
`oracle.cases_digest` rather than the contract version: adding, retiering or
retiring a case refuses old-vs-new pairings without any contract change. The
2026-09-10 tier audit moved the digest to `sha256:80652591…` while leaving
`scripted-cli-v3` intact, so records either side of it compare on era but refuse
on digest.

### Plugin under test (`era.plugin_path`)

The WITH arm runs `--plugin-dir <plugin root>` and the stream-json `system/init`
event is read back: `era.plugin_path` (realpath) and `era.plugin_version` are what the
CLI **reported loading**, not what was requested. If corpflow resolves anywhere else,
or two copies load because `--plugin-dir` failed to shadow the installed one, the
run stops after that stage with **rc 5**, names both paths plus any `plugin_errors`,
and is never rotated into history. `--capture json` has no init event, so it warns
and stamps no `plugin_path`. The pairing gate ignores `plugin_path`, which only the
WITH arm carries.

## Held-out oracle (quality metric)

Each arm writes its own implementation **and** its own tests, so `swift test`
inside an arm grades nothing an evaluator controls — across every live record
ever stored it has never once returned `fail` for either arm. The oracle
supplies the signal the arm cannot author.

After measurement (outside the arm's Timer, so it never inflates
`wall_clock_s`), the harness release-builds the arm's `tictactoe` product and
drives it through the **scripted CLI contract** — `tictactoe --moves 0,4,1`
prints a board plus a `result:` line, exit 0/1/2. Each of the 42 cases in
`benchmark/oracle/cases.json` is compared on stdout and exit code:

```json
"oracle": {"built": true, "cases_total": 42, "cases_passed": 39, "pass_rate": 0.9286,
           "tiers": {"implied":   {"total": 9,  "passed": 6,  "pass_rate": 0.6667},
                     "specified": {"total": 33, "passed": 33, "pass_rate": 1.0}}}
```

### Two tiers, two questions

The contract is fully written out in the prompt, so restating it in cases asks
only whether the arm can follow a precise spec — which it can. On the first
paired live run both arms swept every case, and the metric separated nothing.
Cases are therefore tiered:

- **`specified`** (33) — behaviour the prompt enumerates. A failure is
  non-conformance with the contract the arm was handed. This is a floor, not a
  discriminator, and **`pass_fail` reads this tier alone** — an arm is never
  failed for behaviour nobody described to it.
- **`implied`** (9) — behaviour the contract's rules determine without spelling
  out, e.g. that a move listed after the game already ended is never played and
  so is never rejected, or that a two-digit index parses and is therefore an
  invalid move rather than malformed argv. Deriving these is the engineering
  judgement the benchmark is trying to detect, so this is the discriminating
  tier — reported beside the verdict, never folded into it.

**A case belongs in `implied` only while a contract-conformant implementation can
still fail it.** Editing `_cli-contract.txt` can therefore silently demote a case:
the three bullets that spell out token whitespace, parse-before-play and empty
tokens converted six `implied` cases into conformance checks, and because their
tier was not moved with them the discriminating tier read 11 cases while only 5
still discriminated — which is why both arms scored `implied` 11/11 on
`live-20260909T152543Z`. Those six are `specified` as of 2026-09-10. When you add
a contract bullet, re-audit the tier of every case it covers.

`test_oracle.py` holds that line with mutants rather than prose. Four
deliberately-wrong reference variants each score `specified` 1.0 — an untiered set
would call them all perfect — and lose only `implied` cases: validating moves
before honouring the early stop (0.67), testing emptiness before trimming (0.89),
a single-digit index parser that still admits negatives (0.67), and stripping
spaces from the whole argument instead of padding each token (0.89). Each of the
four `implied` cases added on 2026-09-10 is named by one of them.

Two retained cases — `malformed-token-outranks-early-stop` and
`invalid-move-outranks-later-win` — have no conformant mutant yet, so the rule
above is asserted for them rather than demonstrated. They are the next tier audit:
either a mutant names them or they are conformance checks in the wrong tier.

- **Goldens are generated, never hand-written** — `oracle.capture_goldens` runs
  each case against `ttt-template`, the reference implementation. A test
  regenerates them and fails on any drift. This is what keeps the `implied` tier
  honest: the goldens record what the reference *does*, not what anyone assumed.
- **Behaviour, not API shape** — an arm may name its types anything; only the
  CLI contract is graded. stderr wording is deliberately not pinned.
- **Fairness** — `live/prompts/_cli-contract.txt` is the SSOT for the contract
  text, and both `dv.txt` (WITH) and `without.txt` (WITHOUT) must embed it
  verbatim; a lint test fails on drift.
- **`pass_fail` follows the oracle** wherever it ran. Records written before the
  oracle existed keep their self-graded verdict and omit the `oracle` key; those
  written against an untiered case set fall back to the overall rate.

Adding the contract to the prompts changed the workload — runs from that point
are not comparable to earlier stored records.

## Coverage manifest (live, per stage)

With `stream-json` capture, each dispatched stage's `stages[]` entry may carry
an additive `coverage` object **after** `cost_usd` (omitted when nothing was
captured — never fabricated). Nested subagents at depth 2+ are visible in the
stream when `--forward-subagent-text` is set, keyed by their spawning Agent
`tool_use` id — Tier-2 specialist work can be attributed to the stage that
spawned it rather than disappearing into the parent's totals:

```json
{
  "stage": "DV", "fresh_in": 37652, "cache_creation": 56772,
  "cache_read": 207310, "out": 4227, "cost_usd": 0.5,
  "coverage": {
    "agents":   ["apple-developer:macos-developer"],
    "skills":   ["swiftui-skills", "swift-testing-entry"],
    "commands": ["/swiftui-review"],
    "tool_calls": 42
  }
}
```

`make report` rolls distinct agents/skills/commands up per record and computes a
plugin-surface coverage ratio (exercised/declared) at report time from
`agents/*.md`, `commands/*.md`, and `skills/*/SKILL.md` counts. Capture is
layered and degrades honestly: stage stdout (stream-json events or single JSON
object) → `.context/logs/audit.jsonl` → nulls + `live_partial`.

Two runtime guarantees back this chain: the stream-json exit drain scales with
queued bytes (no flat 2s cap), so a slow-reading consumer no longer sees
truncated terminal `result` lines; and SIGTERM during a running Bash tool in a
print/SDK dispatch kills the command's process tree and exits 143, so an
interrupted `claude -p` surfaces as a clean rc=143 rather than an orphaned
tree with a false timeout. The defensive line-skip in Coverage parsing stays
as defense-in-depth.

## Layout

```
benchmark/
  run-benchmark.sh              # Orchestrator (deterministic default, --live opt-in)
  harness/                      # Python package "benchmark harness" (stdlib-only)
    benchmarkkit/               #   deterministic world: metrics/rotation/genlib/
                                #   generators/deterministic_run/report/analysis/
                                #   oracle/pairing (comparability gate + join)
    benchmarklive/              #   live world: preamble/dispatch/credentials/
                                #   budget/capture/baseline (6 modules, depends on benchmarkkit)
    bin/
      bench-deterministic       # frozen-argv entrypoint (links benchmarkkit only, AC-8)
      bench-report              # frozen-argv entrypoint (links benchmarkkit only)
      bench-analyze              # frozen-argv entrypoint (links benchmarkkit only)
      bench-pair                # join two arm records (benchmarkkit only; 0/64/65)
      bench-live                # frozen-argv entrypoint (only live-world linker)
    tests/                      # 383 test methods (schema/rotation/generators/report/
                                #   history back-compat/import-isolation + live-gate/
                                #   budget/credentials/prompt-assembly/SSOT/coverage/
                                #   app-measure/without-arm/analysis)
      __init__.py               # makes tests/ a package (importlib discovery)
      _helpers.py               # test fakes: Tripwire/RecordingFake/ThrowAtStage/Sequenced
      fixtures/history.json     # vendored real history (byte-compat oracle)
      test_*.py                 # 30 test modules
  oracle/
    cases.json                  # 42 scripted CLI cases (33 specified / 9 implied)
                                # + goldens captured from ttt-template
                                # (regenerated, never hand-written)
  ttt-template/                 # Canonical SwiftUI TTT fixture (SwiftPM package
                                # "TicTacToe": TicTacToeKit + tictactoe exe,
                                # 48 Swift Testing tests; macOS 15+ / iOS 18+)
  live/prompts/                 # _cli-contract.txt — SSOT for the graded CLI contract,
                                # embedded verbatim by dv.txt and without.txt;
                                # pl.txt … st.txt — section [5] task bodies only
                                # ([1]-[4] prepended by Preamble at dispatch);
                                # without.txt — WITHOUT-arm prompt, sent verbatim
                                # (no preamble, no --agent)
  results/
    history.json                # Rolling history: deterministic latest-3,
                                # live unbounded (tracked in git)
    analysis.md                 # bench-analyze output (evidence-backed markdown)
    runs/{deterministic,live}/  # Per-run detail records: deterministic rotated
                                # latest-3 (gitignored), live kept + tracked
    runs/live-arm/              # Single-arm records (--arm with|without): half a
                                # comparison, NEVER rotated into history.json;
                                # join two of them with bin/bench-pair
  workdirs/<run_id>/{captures/,with,without}   # captures + links to the arm dirs (gitignored);
                                               # the arms live under --workdir-root
```

## Metric Schema (on-disk, key-for-key)

Top-level: `run_id, timestamp_utc, mode, git_sha, budget_usd, paths[, comparison]
[, arm][, live_partial][, stages][, era][, joined_from]` — `comparison` only when
non-empty, `live_partial` only when true, `stages` only when non-empty, `era` only when
stamped, and the two arm-split keys only on the records they describe.
`paths.with` / `paths.without`:

```json
{
  "tokens": {"in": null, "out": null, "total": null,
             "cache_read": null, "cache_creation": null},
  "cost_usd": null,
  "wall_clock_s": 1.9086,
  "loc_produced": 1524,
  "test_count": 48,
  "coverage_pct": 0.0,
  "estimate_complexity_score": 15,
  "stage_count": 9,
  "pass_fail": "pass",
  "app_path": "benchmark/workdirs/<run_id>/with"
}
```

`pass_fail` is **fail-closed**: an arm is `"pass"` only when app measurement
succeeded on a non-degraded run. An arm that dispatched but produced nothing
measurable records `"fail"` with `app_path: null` — it is never green by default.
`coverage_pct` is `null` when unmeasured; a literal `0.0` means measured-zero.
**Nothing in the harness measures coverage today**, so every arm the current code
writes is `null` — the field is plumbed end to end and reserved, never a signal to
read. Measuring it needs `swift test --enable-code-coverage` plus an `llvm-cov`
parse, run outside the arm Timer like the oracle so it cannot inflate
`wall_clock_s`. Historical `0.0` values are the `--without-arm skip` placeholder,
which claimed measured-zero for an arm that never dispatched until 2026-09-10.
Records predating this rule are listed in `results/KNOWN-BAD-RECORDS.md`.

All 5 token keys are ALWAYS emitted (value or null); cache figures are additive
siblings, never summed into `total`. `comparison.<metric>` =
`{"with": …, "without": …, "delta": …}` (`delta` null when either side null).
A present `tokens` block MUST carry all 5 keys; a partial block is rejected. `app_path` stays optional.

### Telling the three record kinds apart

| Record | Root key to look at |
|---|---|
| **arm** (half a comparison) | `arm: "with"` or `"without"`; exactly one `paths` entry; **no** `comparison` block |
| **joined** (two arm runs welded) | `joined_from` present, `arm` absent |
| **natively paired** (one dispatch) | neither `arm` nor `joined_from` |

An arm record populates only its own arm and **omits** the opposite key entirely — it is
never null-filled and never carries the `skip`-mode placeholder, which keeps its
documented meaning of "not run" and must never be read as "this arm ran elsewhere".
`joined_from` records where a joined record came from:

```json
"joined_from": {
  "with":    {"run_id": "live-…-with",    "timestamp_utc": "…"},
  "without": {"run_id": "live-…-without", "timestamp_utc": "…"},
  "observed_gap_s": 12345
}
```

Every newly written record additionally carries `paths.<arm>.oracle.cases_digest`
(`sha256:<64 hex>`) — the identity of the case set the arm was graded against, and the
gate's third refusal axis. Stored records predating it simply omit it, which is why the
join refuses a pair where either side lacks one. The digest is computed over the case
set with cosmetic keys (`description`) excluded, so rewording a case description cannot
manufacture a refusal.

## bench-analyze (evidence-backed markdown)

```bash
./benchmark/harness/bin/bench-analyze                       # latest live record -> results/analysis.md
./benchmark/harness/bin/bench-analyze --run <record.json>    # analyze a specific record
./benchmark/harness/bin/bench-analyze --reference <record.json>  # flag cross-era comparisons
./benchmark/harness/bin/bench-analyze --history <path> --out <md path>
```

Pure, offline, `benchmarkkit`-only (never imports `benchmarklive` — AC-8). Reads
the latest `live`-mode record (from `--history`, default
`benchmark/results/history.json`; falls back to the newest file under
`results/runs/live/` when history has no live entries yet) and renders
`## totals` (tokens/cost with WITH-vs-WITHOUT premium %), `## per-stage` (arm,
cost share, out-token share, cache-hit %), `## cache-economics` (top
`cache_creation` stages, per arm), `## quality-delta` (loc/tests/pass_fail/
tokens-per-LOC per arm, plus coverage % when measured — omitted when absent),
`## validity-caveats` (`live_partial`, placeholder-WITHOUT, cross-era
token payload, n=1), and a closing `## improvement-candidates` checklist built
**only** from mechanical, threshold-based flags (stage cost/out-token >1.5×
median, a failing arm, degraded capture) — never a fabricated recommendation.
No live records yet → prints a message and exits 0.

## Generated Project Surfacing (U2 visible output)

After a live run, the analysis Markdown (`benchmark/results/analysis.md`) and HTML report
(`benchmark/results/result.html`) each contain a **per-arm "Generated project" section**
showing the Swift file tree, per-file LOC counts, and total LOC for each arm:

```markdown
### with arm — `/Users/…/benchmark/workdirs/live-20260722T053500Z/with`
_total LOC: 165_

| file | LOC |
|---|---|
| Sources/TicTacToeKit/AIOpponent.swift | 68 |
| Sources/TicTacToeKit/Board.swift | 42 |
| Sources/TicTacToeKit/GameViewModel.swift | 55 |

### without arm — `/Users/…/benchmark/workdirs/live-20260722T053500Z/without`
_total LOC: 91_

| file | LOC |
|---|---|
| Sources/TicTacToeKit/AIOpponent.swift | 51 |
| Sources/TicTacToeKit/Board.swift | 40 |
```

The arm folder path (`workdirs/<run_id>/{with,without}`, a link into `--workdir-root`) is the
canonical location to inspect the full generated source and test suite post-run, while the
scratch root survives. A zero-spend fixture-driven test sample is
committed to `benchmark/results/samples/analysis-paired-sample.md` demonstrating the rendering.

## Offline utilization experiment

`bench-experiment` prepares baseline WITH versus optimized WITH comparisons without dispatching models.
The ordinary WITH/WITHOUT pairing gate remains unchanged.

### Prepare and verify

```bash
python3 benchmark/harness/bin/bench-experiment prepare \
  --baseline-root <baseline-snapshot> --optimized-root <optimized-snapshot> \
  --common-fixes-root <remediated-app> --output-dir .context/utilization-experiment \
  --pairs 3 --required-finding <finding-id>
python3 benchmark/harness/bin/bench-experiment verify \
  --manifest .context/utilization-experiment/manifest.json
```

Preparation verifies identical workload, model pins, efforts, pricing, effective restrictions, and native acceptance checks.
Both workload directories receive the same fingerprinted remediated app, including the Unicode and native regression suites.
This is a declared remediated starting workload; historical native evidence remains provenance, not trial acceptance.
Source changes and their groups remain explicit in the manifest. Live trials require separate budget authorization.

### Prepare each attempted run

Before each separately authorized live attempt, copy the verified overlay into the exact harness workdir.
Use a fresh run identifier, app directory, and record path for every full-run restart.

```bash
python3 benchmark/harness/bin/bench-experiment prepare-trial \
  --manifest .context/utilization-experiment/manifest.json --variant baseline \
  --run-id <run-id> --app <scratch-root>/<run-id>/with --record <new-record.json>
```

This offline command returns a preparation receipt and a compatible `bench-live` argv template.
Its budget remains a placeholder requiring separate authorization. Preparation launches no model or native command.
The receipt binds the source, workload, initial common fixes, run identifier, app, and expected record.
The analyzer rejects missing receipts and record workload digests that differ from the verified preparation.

### Bind fresh host acceptance

After the attempted run produces its final record, invoke this command on the trusted host:

```bash
python3 benchmark/harness/bin/bench-experiment validate-native \
  --manifest .context/utilization-experiment/manifest.json \
  --preparation-receipt <run-id.prepared.json>
```

This explicit command runs the Unicode regressions and unchanged native acceptance helper.
It fingerprints app inputs before and after validation, plus the record, invocation logs, and native result bundle.
The returned native receipt binds that invocation to the trial. Changed inputs or evidence invalidate acceptance.
Preparation and ordinary analysis never execute this host command.

### Declare trial results

Create an assignments JSON object with `manifest_id` and ordered `trials`.
Each trial has `pair`, `variant`, and an `attempts` list retaining every full-run record.
Each attempt supplies `record`, `preparation_receipt`, and, after successful host validation, `quality`:

```json
{
  "run_id": "the-record-run-id",
  "native_receipt": "the-host-validation-receipt.json",
  "native_record": "the-bound-native-result.json",
  "unicode_record": "the-bound-unicode-result.json",
  "findings": [{"id": "finding-id", "evidence": "review.log"}],
  "blockers": []
}
```

### Preserve all evidence

Use `blockers: []` only when the trial found no blockers.
Each resolved blocker needs `operation`, `status: resolved`, `recovery_condition_changed`, and an `evidence` path.
Pending blockers remain pending and prevent acceptance. The inventory cannot omit blockers found by the baseline trial.
Records already contain their internal stage retry costs; do not duplicate those retries as additional full-run attempts.
Evidence paths resolve against the assignments file directory. Receipt-generated paths are absolute.
Historical native provenance and unbound operator assertions cannot accept a new trial.

### Analyze paired trials

```bash
python3 benchmark/harness/bin/bench-experiment analyze \
  --manifest .context/utilization-experiment/manifest.json \
  --assignments <trial-assignments.json> --output <new-experiment-report.json>
```

Reports retain attempts, partial results, costs, per-pair comparisons, and medians.
`comparison_valid` reports complete, consistent evidence; `observed_savings_accepted` additionally requires a positive median token reduction.
Missing measurements say `unavailable`. Lost findings, concealed blockers, and incomplete acceptance evidence reject observed savings.
The 20–30% reduction remains an experimental target until repeated quality-preserving trials establish it.

## Test suites

- `benchmark/ttt-template` — 48 Swift Testing fixture tests (engine/AI/
  leaderboard/settings/router/view-model), also run on iOS Simulator via
  `make test-ios` (SKIPs cleanly on hosts without an iOS runtime)
- `benchmark/harness` — 383 Python harness self-tests (30 modules), zero real
  LLM calls (all dispatchers injected with fakes/tripwires), incl. schema
  byte-compat (vendored real history.json), rotation, generators (real `swift test`
  on generated apps), deterministic/live pipelines, budget/credential gates,
  prompt assembly, stage attribution, app measurement, the paired ±agent arms,
  per-call token accounting, arm symmetry, and offline analysis

**Total:** 48 Swift TTT artifact tests + 383 Python harness tests + 157 Python
skill-script and skill-eval-engine tests = 588 tests green. The skill-eval share
covers the assertion engine and the eval-set lint only — no skill's output is
dispatched or graded here, so this total says nothing about output quality
(`evals/README.md § Skill eval sets`).

**Reference:** `tests/COVERAGE.md` for the Swift/Python coverage story (Python
opportunistic via coverage.py; Swift jq ≥85% line gate with `Sources/TicTacToeKit/Views/`
excluded from the denominator).

## Known Issues

**P1: Temp directory leaks in live mode** — The harness does not clean up temporary workdirs under `$TMPDIR` when a live run completes. Directories matching `ttt_test_with_*`, `ttt_test_without_*`, and `bats-run-*` accumulate and may consume significant disk space over repeated `make benchmark-live` runs. Workaround: manually clean with `rm -rf $TMPDIR/ttt_test_* $TMPDIR/bats-run-*` after benchmark runs. A fix is pending that will atomically clean all artifacts on normal exit (`harness/benchmarklive/budget.py`).

## References

**Findings & evidence:**
- `benchmark/results/variance-envelope.md` — **read first.** The measured noise floor
  (n=2, 2026-09-10). Only `cost_usd` survives it: the plugin costs ~32-39% more, while
  the token, LOC and test-count deltas are inside run-to-run noise. Every n=1 finding
  below predates this floor and should be re-read against it.
- `benchmark/results/token-findings-1.md` — foundational findings (cache_read dominance, ~74%)
- `benchmark/results/token-findings-2.md` — live A/B measurement (n=1, honesty rule)
- `benchmark/results/token-findings-4.md` — era python-2 per-stage attribution (n=3, 89500e0); AR and PL diagnosis, ranked levers
- `benchmark/results/runs/live/` — raw per-stage live records (token attribution + coverage manifests)
- `benchmark/results/KNOWN-BAD-RECORDS.md` — stored records that must be excluded from comparisons

**Implementation references:**
- `benchmark/harness/benchmarkkit/metrics.py` — BenchmarkRecord schema (ordered JSON)
- `benchmark/harness/benchmarkkit/rotation.py` — per-mode atomic rotation (deterministic 3, live unbounded)
- `benchmark/harness/benchmarklive/preamble.py` — cache-prefix assembly ([1]-[5])
- `benchmark/harness/benchmarklive/dispatch.py` — headless `claude -p` dispatcher + STAGE_TABLE
- `benchmark/harness/benchmarklive/capture.py` — dual-mode stream-json/json capture parser
- `benchmark/harness/benchmarklive/plugin_load.py` — checks the corpflow tree a stage loaded against the tree under test
