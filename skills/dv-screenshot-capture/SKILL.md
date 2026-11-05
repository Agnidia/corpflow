---
name: dv-screenshot-capture
description: Use when DV is about to complete and `metadata.requires_screenshots` is true (the default) — the completion gate blocks otherwise. Captures DV screenshots (or an annotated diff for meta-work) as visual evidence for QA, DR and the PR.
version: 1.1.1
argument-hint: "<worktask_id> <task_id> <platform> <slug> [args-json]"
---

# dv-screenshot-capture

Capture and attach visual evidence during the DV (Development) stage. One screenshot per acceptance criterion with a visual manifestation; one annotated `git diff` for meta-work. Each DV task's completion is gated on its own valid evidence when `metadata.requires_screenshots` is true (default); see § Completion gate. The planner writes the flag; DV may only raise it, via `scripts/escalate-flag.sh`.

## Trigger conditions

Run under any of:

1. **DV completion gate** — DV is about to execute its Completion Verification checklist AND `metadata.requires_screenshots ≠ false`.
2. **Retroactive QA/DR request** — a `screenshot_request` line appended to `.context/errors/developer.md`.
3. **ST retrospective re-run** — ST flagged "missing visual evidence".
4. **Manual user request inside a worktask** — "capture a screenshot of X" while a worktask ledger resolves. Outside one, § Worktask guard stops the run.

## Worktask guard

The first step of every run, before any capture, directory or manifest write. `<task_id>` is the ledger key of the DV task the evidence belongs to (`DV0`, `DV1`, …).

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/resolve-worktask.sh" --task-id <task_id>
```

| Result | Action |
|---|---|
| exit 0, prints `worktask_id=<worktask_id> task_id=<task_id>` | Proceed. |
| exit 0 with `task_id=-`, or a printed `worktask_id` other than the `<worktask_id>` argument | Write nothing and stop: the resolved ledger is not this run's. |
| exit 2 | Relay its stderr line, write nothing and stop. |
| exit 4, nothing printed | Reply with the one line `no worktask resolved — runs only inside a worktask DV stage`, write nothing and stop. |

### Why the guard keys on the ledger

The skill is model-invocable, so this step, not the harness, decides whether a run may write: it tests whether a worktask ledger resolves (§ Root resolution), not who called, and creates nothing. Its exit 4 is unrelated to the gate's `--check` exit 4 (`tool_missing_only`), so never chain the two on a bare exit code.

## Storage layout

```
.context/images/<worktask_id>/
├── dv-<TASK_ID>-NN-<slug>.png   # captures 01–05 per task
├── oversize/                    # .gitignore'd; oversize PNGs, never committed
├── screenshots-<TASK_ID>.md     # REQUIRED manifest, one per DV task
└── screenshots.md               # legacy, read-only (§ Legacy manifest)
```

- `.context` is the context root from § Root resolution, never a cwd-relative path. `<worktask_id>` is `state.json.worktask_id`; `<TASK_ID>` is the DV task's ledger key (`^[A-Z]{2}[0-9]+$`); `<slug>` is kebab-case, ≤40 chars, from the capture's purpose.
- Before the first move to the oversize/ subdirectory, ensure it is git-excluded:
  ```bash
  grep -qxF '.context/images/*/oversize/' .gitignore 2>/dev/null || echo '.context/images/*/oversize/' >> .gitignore
  ```

### Numbering

`NN` is two-digit zero-padded and monotonic per task: `NN = 1 + max` over the `dv-<TASK_ID>-[0-9][0-9]-*` files in the images dir and its oversize/ subdirectory and the `#` column of `screenshots-<TASK_ID>.md` (first = `01`; past `99` the script exits 1). Another task's files never advance it, so parallel streams each start at `01`. Reruns (`run_index > 0`) do not reset it: captures append (`dv-DV0-06-…`), and cleanup happens at FN/ST or via `/worktask archive`.

### Legacy manifest

A shared `screenshots.md` from an earlier run is read only through its `## <TASK_ID>` section (the line exactly `## <TASK_ID>`, up to the next `#` or `##` heading), and only when `screenshots-<TASK_ID>.md` is absent. Nothing writes to it, and a legacy file with no such section counts as absent.

### Root resolution

Every capture script and helper resolves `.context` through `corpflow_context_dir` (`skills/shared/lib/state-read-lib.sh`): `CONTEXT_DIR`, `WORKSPACE_ROOT`, `CLAUDE_PROJECT_DIR`, the git toplevel holding a ledger, then `resolve-root.sh`. It never uses cwd. Nothing is created until a root resolves, and an unresolved root exits 1 with a stderr line (`resolve-worktask.sh`: exit 4, silent).

When `<ctx>/state.json` exists, its `.worktask_id` must equal `--worktask-id` and `.tasks` must hold `--task-id`, else exit 1 (`apple-canvas.sh` exits 5 for an unknown task), so a worktree's capture cannot land in the main checkout. With no ledger, a capture runs only when `CONTEXT_DIR` is set explicitly, which is what a capture outside a worktask (the ad-hoc path) needs. `apple-canvas.sh` takes its SwiftPM root from `git rev-parse --show-toplevel` (else exit 5), and `size-budget.sh --project-root` defaults to the git toplevel of the context dir.

## What to capture

| Scenario | Capture strategy |
|----------|-----------------|
| UI feature (apple/web/android) | Golden-path state after implementation; key edge cases; before+after for bug fixes |
| Meta-work (skill/agent edits) | Annotated `git diff <base>...HEAD` rendered as PNG via `silicon` |
| Backend-only change | CLI output showing key behavior; or `git diff` render |
| Multiple ACs with visual manifestations | One screenshot per AC (up to 5 per task) |
| Bug fix | Before (reproduce) + after (fixed) pair; counts as 2 |

Minimum **1 screenshot** per task when `metadata.requires_screenshots: true`, except that the gate also passes a `backend`/`systems` task with none (§ Completion gate); maximum **5** per task (6th call returns `error: "screenshot_count_exceeded"`).

## Live-drive verification (`ui_visual_check`)

When the plan sets `ui_visual_check: true`, static evidence alone does not satisfy the DV exit gate: a static or host-rendered snapshot verifies structure, not runtime presentation. It never runs the app's real update, layout and navigation path, so same-frame update faults, control overflow and dropped state transitions survive it.

### Live-drive steps

1. Build and run the app on its real runtime surface (booted simulator, emulator, device, browser session).
2. Drive it through each rendered substate the ACs name (default, error, empty, loading, success, every result/review state), tapping through the real transitions rather than jumping to a state in isolation.
3. Confirm each primary control is on-screen and hittable and that transition controls actually present the next state, then capture from that live-driven state.

A `ui_visual_check` row whose only evidence is a static render or a passing unit test is incomplete — recapture from a live-driven run.

### What does not count, per platform

Same rule instantiated per platform; the left column is never sufficient alone.

| Platform | Not sufficient alone | Required |
|----------|---------------------|----------|
| apple | `#Preview` / `ImageRenderer` canvas render (the `apple-canvas` adapter) | app running on a booted simulator or device; a SwiftPM macOS app's root view clicked through in a real window (§ macos-window adapter) |
| web | a Storybook or other static component render | the page driven in a real browser session |
| android | a Compose `@Preview` render | app running on an emulator or device |

Platforms with no rendered UI surface (systems, backend, ai) do not set `ui_visual_check`.

## Adapters

Uniform contract — every adapter returns the same shape:

```
capture(task_id: string, slug: string, platform: string, args: object) → {
  path:  string,     # .context/images/<worktask_id>/dv-<TASK_ID>-NN-<slug>.png
  bytes: integer,    # filesystem size
  ok:    boolean,
  error: string | null   # null on success; values below
}
```

**Error values**: `"no_adapter"` | `"oversize_unquantizable"` | `"tool_missing"` | `"capture_failed"` | `"screenshot_count_exceeded"`

### Adapter selection rule

One table lookup for every platform. A platform whose primary adapter can be unusable registers a degraded-mode predicate, which the dispatcher calls without knowing what it tests.

#### Dispatch table

```python
# Entry = the adapter that normally runs + an optional degraded pair. The
# predicate belongs to the platform adapter, keeping platform-specific
# evidence out of this layer.
ADAPTERS = {
    "apple":   {"primary": apple_adapter,
                "degraded_if": apple_adapter.degraded,
                "degraded":    apple_canvas_adapter},
    "web":     {"primary": web_adapter},
    "android": {"primary": android_adapter},
}

def select_adapter(state, args):
    entry = ADAPTERS.get(state.platform)
    if entry is None:
        return cli_fallback_adapter
    predicate = entry.get("degraded_if")
    if predicate and predicate(state, args):
        return entry["degraded"]
    return entry["primary"]
```

Unknown or `"all"` platform → `cli_fallback_adapter` + audit row `screenshot_platform_fallback`, `reason: "unknown_platform"`.

#### Degraded-mode predicate contract

`degraded_if(state, args) → bool`: total, side-effect free, and safe to call when its platform's tooling is absent — a predicate that cannot decide returns `False`, running the primary and letting the fallback ladder handle a real failure.

### Per-adapter behavior

The `Agent(...)` targets below are platform defaults — a routing override
(`skills/shared/routing-matrix.md` / `state.routing`) swaps the plugin, and the capture
request goes to the override's entry agent instead.

#### apple, web, android adapters

These three delegate the capture to the platform's own agent — corpflow holds no platform tool grants (XcodeBuildMCP and friends), the platform plugin does. Ask that agent to produce a file at the target path, then stat the path yourself to fill the `{path, bytes, ok, error}` contract.

##### Delegation targets

| Adapter | Delegate to | Requested behavior | `reason` |
|---------|-------------|--------------------|----------|
| `apple` | `Agent(apple-developer:ios-developer)` or the matching `macos-`/`tvos-`/`watchos-`/`visionos-developer` | Boot/locate sim (per `args.simulator`), navigate best-effort, screenshot to target path. A SwiftPM macOS app skips this row: § macos-window adapter. | `xcodebuildmcp_unavailable` |
| `web` | `Agent(frontend-developer:frontend-developer)` | Run `scripts/web-capture.sh --task-id <task_id> --url <args.url> --viewport <args.viewport>`. | `playwright_unavailable` |
| `android` | `Agent(android-developer:android-developer)` | Run `scripts/android-capture.sh --task-id <task_id> [--serial <args.serial>]`. | `adb_unavailable` |

##### Delegated-capture result handling

The delegate's prose reply is never the evidence — the file is. After the `Agent` returns, stat the target path:

- Non-empty file → `{path, bytes: <stat>, ok: true, error: null}`; apply the size budget.
- No file, empty file, or an errored `Agent` → fall through to `cli_fallback` exactly as a missing tool did, emitting `screenshot_platform_fallback` with the table's `reason` (or `"delegation_unavailable"` when the agent was unreachable). The enum is unchanged: the capture still surfaces as `"capture_failed"`, or `"tool_missing"` once `cli_fallback` also bottoms out.

#### macos-window adapter

For `apple` when the app is a SwiftPM package with a macOS platform and a library product that exports its root view, run `scripts/macos-window-capture.sh` yourself instead of delegating. It hosts that view in a real `NSWindow`, clicks through the real transitions and renders each `shot`, all in-process, so it needs no simulator, no XcodeBuildMCP grant, and none of the Screen Recording or Accessibility permissions that `screencapture` and a launched binary need. It satisfies `ui_visual_check`; a canvas render does not.

##### macos-window recipe

1. From the package root, write the root file and a one-shot step list, then probe:

```bash
export CONTEXT_DIR=<abs .context>; T="$CONTEXT_DIR/tools"; mkdir -p "$T"
cat > "$T/capture-root.swift" <<'EOF'
import SwiftUI
import <Product>
@MainActor func captureRoot() -> some View { <RootView>() /* + test-store deps */ }
EOF
printf 'shot menu\n' > "$T/steps.txt"
bash "${CLAUDE_SKILL_DIR}/scripts/macos-window-capture.sh" --worktask-id <worktask_id> \
  --task-id <TASK_ID> --product <Product> --root-file "$T/capture-root.swift" --steps "$T/steps.txt" --probe
```

##### macos-window recipe, steps 2–4

One `--probe`, then one capture; re-probe only on a missed click.

2. Read the `probe=` PNG. It is 1x with the title bar included, so a pixel is a click point.
3. Rewrite `steps.txt` — `click <x> <y>`, `wait <s>`, `shot <slug> <caption>`, at most 5 shots, one per AC state — and rerun without `--probe`. That run writes the PNGs, the manifest rows and the `screenshot_captured` rows, and prints `facts_screenshots=<json>` for the `facts.screenshots` merge.
4. `--check` the gate (§ Completion gate). A missed click shows as the wrong screen in its PNG: re-probe with the steps up to that click, fix its coordinates, and rerun the capture.

#### apple-canvas adapter

**Backing tool**: `scripts/apple-canvas.sh`, which runs two host-side SPM executables: `PreviewEnsurer` (`swift run --package-path <plugin>/skills/preview-ensurer/references/reference-impl PreviewEnsurer …`) and `SnapshotHost`. Scaffold tools/SnapshotHost/ in the project from template if missing → PreviewEnsurer auto-adds `#Preview` macros to modified View files → `swift run --package-path tools/SnapshotHost SnapshotHost --view <ModuleType> --output <path> [--size WxH] [--scheme light|dark]`. macOS host first (`metadata.canvas_destination=macos-host`, default); iOS sim opt-in (`ios-sim`). Emits `canvas_render` + `preview_added` audit rows. Full recipe: `references/apple-canvas.md`; heuristics: `references/preview-ensurer.md`.

##### apple degraded-mode predicate

Registered as `ADAPTERS["apple"]["degraded_if"]`, so the xcodebuild log scrape stays out of the generic dispatcher.

```python
def degraded(state, args) -> bool:
    return bool(
        args.get("force_canvas")                              # skill-call opt-in
        or state.metadata.get("requires_canvas_screenshot")    # plan-level opt-in
        or state.facts.get("simulator_blocked") is True        # explicit project marker
        or _grep_recent_log(r"framework not found .* iphonesimulator")
        or state.facts.get("last_sim_boot_failed") is True     # set on a prior boot failure
    )
```

The log scrape reads the most recent xcodebuild log under `.context/logs/` and catches the xcframework-missing-sim-slice case. All clauses false → the sim-booting `apple` adapter runs unchanged.

##### apple-canvas failure → fallback

- Host build fail → `apple` (sim) adapter; audit `screenshot_platform_fallback`, `reason: "canvas_host_build_failed"`.
- Sim unavailable → `cli_fallback`; `reason: "canvas_sim_unavailable"`.
- preview-ensurer error → DV `missing_input`.

#### cli/fallback adapter

Also serves `platform: "all"`, and is implemented by `scripts/cli-fallback.sh`. Chain: 1) `git diff` piped to `silicon --language diff`; 2) silicon absent → an ImageMagick `caption:` text card of the first 60 diff lines; 3) neither produced a usable PNG → no file is written: `ok: false` with `error: "tool_missing"` (exit 2, nothing on PATH) or `"render_failed"` (exit 3, a tool ran and failed).

Nothing sits under this fallback, and its floor is a loud failure rather than an artifact: a placeholder passes an existence check while proving nothing, so consumers treat any non-zero exit as "no capture" and never manifest the path from the contract line. Exact commands, the floor's exit codes, and the redaction recipe: `references/cli-fallback.md`.

##### tool_missing floor row

With `silicon`, `magick` and `convert` all absent, `cli-fallback.sh` writes no image but upserts a tool_missing row into `screenshots-<TASK_ID>.md` (§ tool_missing row) and still exits 2. Exit 2 also means a broken install, so consumers key on stdout `error=tool_missing`, never the bare exit code.

## Scripts (canonical executables)

Nine shipped executables. The five capture scripts (web, android, apple-canvas, macos-window-capture, cli-fallback) take `--worktask-id`, a required `--task-id` and a slug (`--slug`, or a `shot` step in `macos-window-capture.sh`), resolve the next `NN` for that task themselves, and write to `.context/images/<worktask_id>/dv-<TASK_ID>-NN-<slug>.png`, printing its absolute path. `capture.sh` runs them for DV in one call (§ Script usage — one call). `resolve-worktask.sh` is § Worktask guard; `size-budget.sh` and `visual-diff.sh` are helpers.

### Script usage

```bash
bash scripts/resolve-worktask.sh [--task-id <ID>] [--state <state.json>]
bash scripts/web-capture.sh --worktask-id <id> --task-id <ID> --slug <kebab> --url <url> \
  [--viewport WxH] [--browser chromium|firefox|webkit] [--timeout <ms>] \
  [--wait-ms <ms>] [--full-page] [--platform <p>] [--run-index <N>] [--allow-npx-install]
bash scripts/android-capture.sh --worktask-id <id> --task-id <ID> --slug <kebab> \
  [--serial <serial>] [--platform <p>] [--run-index <N>]
bash scripts/apple-canvas.sh --worktask-id <id> --task-id <ID> --modified-files <path> \
  [--view <Module.Type>] [--destination macos-host|ios-sim] [--size WxH] \
  [--scheme light|dark] [--slug <kebab>]
bash scripts/cli-fallback.sh --worktask-id <id> --task-id <ID> --slug <kebab> \
  [--base-ref <ref>] [--platform <p>] [--run-index <N>] [--files <path>]
bash scripts/size-budget.sh --path <file> --worktask-id <id> \
  [--slug <kebab>] [--project-root <dir>]
```

#### Script usage — macOS window

```bash
bash scripts/macos-window-capture.sh --worktask-id <id> --task-id <ID> --product <Product> \
  --root-file <swift> --steps <file> [--package-path <dir>] [--size WxH] \
  [--timeout <s>] [--probe] [--platform <p>] [--run-index <N>]
```

#### Script usage — one call

```bash
bash scripts/capture.sh --task-id <ID> --capture <slug>[:<arg>] ... (1..5) \
  [--platform <p>] [--worktask-id <id>] [--context-dir <dir>] [--base-ref <ref>] \
  [--viewport WxH] [--product <P> --root-file <swift> [--package-path <dir>] [--size WxH]] \
  [--canvas-files <list>]
```

Runs § Worktask guard, the dispatch table, the ladder to the tool_missing floor, the size budget and the manifest rewrite. `<arg>` belongs to the primary adapter: web URL, android serial, macos_window click/wait steps file, apple_canvas `Module.Type`, cli_fallback file list. Apple with neither `--product` nor `--canvas-files` goes to cli_fallback (`delegation_unavailable`). Prints `NN slug adapter bytes|tool_missing|…`, `manifest=` and `facts_screenshots=`; exit 0 written, 1 internal, 2 usage, 3 a capture got no row.

### Per-script behavior

| Script | Does | Failure detail |
|--------|------|----------------|
| `web-capture.sh` | Drives Playwright's `screenshot` CLI | exit 2 `playwright_unavailable`; exit 3 `playwright_navigation_failed` / `playwright_timeout` |
| `android-capture.sh` | Resolves exactly one online device from `adb devices`, then `adb exec-out screencap -p` | exit 2 `adb_unavailable`; exit 3 `no_device_attached`, `multiple_devices` (pass `--serial`), `serial_not_found`, `screencap_failed`, `screencap_corrupt` |
| `apple-canvas.sh` | Scaffolds tools/SnapshotHost/, invokes `preview-ensurer`, renders via `swift run SnapshotHost`, prints the PNG path | 1 = no resolved root or a ledger mismatch, 2 = preview-ensurer errors (`missing_input`) or a broken install, 3 = render failed (escalate to the sim adapter), 4 = scaffold failed, 5 = argument error, incl. a task the ledger lacks or no git toplevel |

#### macos-window-capture.sh

Scaffolds a unique `<ctx>/tools/WindowCaptureHost/<TASK_ID>.<run>/` package per invocation from `templates/window-capture-host.swift` plus `--root-file`, builds it against `--product`, feeds it the steps, then moves the PNGs into the images dir and appends their manifest rows. Host sources, build output, staging/probe artifacts, and logs are isolated across parallel DV tasks and repeated invocations. Exit 1 = bad arguments or step grammar, more than 5 shots, a non-library `--product` (the library products are listed), or a ledger mismatch; 2 `swift_unavailable` (not macOS, or no `swift`); 3 `package_unreadable`, `host_build_failed` (the compiler's first errors go to stderr), `host_run_failed` or `shot_missing`, with nothing moved into the images dir.

#### Helper scripts

| Script | Does | Failure detail |
|--------|------|----------------|
| `cli-fallback.sh` | Runs the silicon→magick chain; emits `path=… bytes=… ok=… error=…` | exit 2 `tool_missing` / exit 3 `render_failed`; neither writes an image. Exit 2 with every tool absent upserts a tool_missing row |
| `size-budget.sh` | Executable form of `§ Size budget`; emits `size_audit: path=… bytes=… verdict=…` | n/a |
| `resolve-worktask.sh` | § Worktask guard; prints `worktask_id=<id> task_id=<ID\|->` | exit 2 bad or unknown task id, malformed `worktask_id`, jq absent, broken install; exit 4 no worktask, nothing printed or created |

#### Tool-resolution notes

Playwright resolves as a `playwright` binary on PATH, else the local package via `npx --no-install`; `--allow-npx-install` opts into `npx --yes` fetching it, and without that flag a missing package degrades down the ladder instead of reaching the network mid-DV.

`adb` offline and unauthorized entries are not counted as devices — counting them would turn "authorize the device" into a spurious ambiguity error — and the captured stream is verified against the 8-byte PNG signature, a mangled one deleted rather than indexed into the manifest.

### Script conventions

All but `apple-canvas.sh` implement `--self-test` — fixture-driven, needing no network, git, browser, or device. Exit codes and the stdout contract live in each script's shdoc header.

The four capture scripts other than `apple-canvas.sh` share one exit-code grammar: 0 success, 1 bad arguments, an unresolved root, a ledger mismatch or a task the ledger lacks, 2 `tool_missing`, 3 `capture_failed` (`render_failed` in `cli-fallback.sh`, which has no lower rung to route to). Exits 2 and 3 still print a well-formed contract line carrying the intended `path` with `bytes=0`, and emit a `screenshot_platform_fallback` audit row — a missing tool degrades down the ladder, it never hard-fails DV.

### Adapter maturity

`apple`'s simulator path is the one prose-only route — driving a simulator needs the XcodeBuildMCP grant this skill does not hold — so its failure falls through to `cli_fallback`. A SwiftPM macOS app takes the scripted § macos-window adapter, and every other adapter ships a self-tested script too.

## Attachment

### screenshots-<TASK_ID>.md manifest (REQUIRED)

One manifest per DV task is that task's authoritative index. The skill rewrites it atomically (a temp file in the same directory, then rename) on every invocation, never piecemeal, and keeps the task's existing rows, tool_missing rows included. Each file has one writer stream, so parallel DV streams never race.

```markdown
# Screenshots — <worktask_id> / <TASK_ID>

> Run index: <N>.

| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |
|---|------|------|-------|----------|---------|---------|----------|------------|
| 01 | <slug> | dv-<TASK_ID>-01-<slug>.png | 187234 | apple | apple_adapter | <one-line caption> | <ISO-8601 UTC> | design-002 |
```

#### Row grammar

`attach-visual-evidence.sh --validate-manifest <path> --task-id <TASK_ID> [--images-dir <dir>]` owns the grammar, and the gate calls it (exit 0 valid, 1 invalid, 2 manifest missing, 3 no rows, 4 `tool_missing_only tools=<a,b>`). Worked example: `references/examples/README.md`.

- All nine columns are mandatory, `#` is two digits, and a task holds at most 5 capture rows.
- Path is a basename `dv-<TASK_ID>-NN-<slug>.<png|jpg|jpeg|webp>` whose `NN` equals `#` and whose `<TASK_ID>` is the manifest's task, so a row citing another task's capture is invalid.
- The file sits beside the manifest as a non-empty regular file, not a symlink, and its leading bytes are a PNG, JPEG or WebP signature that matches the extension. A text file renamed `.png` is invalid.
- Every `dv-<TASK_ID>-*` image on disk has a row.

#### tool_missing row

Written only by `cli-fallback.sh`, on exit 2 with `silicon`, `magick` and `convert` all absent, and upserted by slug:

```markdown
| 02 | <slug> | — | 0 | backend | cli_fallback | tool_missing: silicon(absent), magick(absent), convert(absent) | <ISO-8601 UTC> | — |
```

Path is exactly `—` and Bytes `0`; the Caption lists at least one tool, each suffixed `(absent)`. The row is identified by Adapter `cli_fallback` plus the `tool_missing:` caption prefix, never by the `—` glyph. It is not an image: it passes only under § Completion gate class 4, and the PR attachment renders it as a plain bullet.

#### Design Ref column (QA join key)

The trailing `Design Ref` column is the QA join key: the matching `figma-registry.md` row `ID` when the capture maps to a known design frame, else `—` (see `§ Registry tagging`). The column is optional and append-only — old manifests lacking it parse fine (QA treats a missing value as `—`).

#### Manifest tail sections

```markdown
<!-- …continued: screenshots-<TASK_ID>.md manifest template -->
## Fallbacks invoked

- dv-<TASK_ID>-02: silicon and ImageMagick both absent on PATH; no capture produced (`tool_missing`).

## Out-of-budget files (link-only)

- (none) | <path>: <bytes> after quantize, exceeds 500 KB
```

### Registry tagging (`Design Ref` resolution — advisory)

When `.context/designs/figma-registry.md` exists at capture time, resolve each capture's `Design Ref` so QA can reuse the result image instead of re-capturing:

1. Determine the capture's intended **Screen** and **State** (from the slug / capture purpose / the AC it satisfies).
2. Find the registry row whose `Screen` and `State` both equal the capture's; on a unique match write that row's `ID` (e.g. `design-002`).
3. Skip overview rows (`State: overview`) — they are container-completeness references, not per-state result frames.
4. No registry, no unique match, or an ambiguous (multi-row) match → write `—`.

#### Advisory semantics

This step never fails DV: a failed, missing, or ambiguous match writes `—` and DV proceeds. The registry is PM-owned — DV reads it, never writes or back-patches it. When in doubt write `—`, which routes QA to its live-capture fallback rather than a wrong pairing.

#### Flag escalation (`scripts/escalate-flag.sh`)

Run it from the DV worktree before capture: `escalate-flag.sh --task-id <TASK_ID> --context-dir <ctx>`, then branch on its single stdout line `requires_screenshots=<true|false> action=<escalated|noop|warn> reason=<token>`. With a `false` flag, platform apple/web/android (from the ledger, never an argument) and a change set (`<base>...HEAD`, working-tree and untracked paths, `.context/` excluded) matching `detect-ui-change.sh --path-classes`, it sets the task flag, then the ledger flag, to `true` and appends one `screenshot_flag_escalated` row. It never writes `false`; every operational failure is exit 0 with a `warn` row, and a `warn` after the task flag was raised (`ledger_flag_unwritten`) leaves that write in place. The planner's `false` otherwise stands. The SubagentStop gate runs the same helper (`--invoker gate`) on every DV stop whose flag reads `false`, so a DV that skips it is still covered.

#### Skip manifest (requires_screenshots: false)

When `metadata.requires_screenshots: false` and DV captures nothing:

```markdown
# Screenshots — <worktask_id> / <TASK_ID>

> Skipped: `metadata.requires_screenshots = false`. Rationale: <one line from PL0 or DV>.
```

### PR body attachment

Do not hand-author image refs to `.context/` paths in the PR body — relative `.context/` paths never render in GitHub PR or issue bodies.

FN instead runs `skills/worktask/scripts/attach-visual-evidence.sh --emit pr` and inserts its stdout between `## Test plan` and `## Merge danger`. The helper hosts PNGs via the publish-helper tier order (raw → gist → none-tier note), emitting a `## Visual evidence` block of hosted URLs, and prints nothing when `requires_screenshots == false` or no captures exist. It reads every `screenshots-*.md` in task-id order, then a legacy `screenshots.md`, and the embed cap spans that union. Oversize rows, tool_missing rows and rows past the cap become plain bullets, never image embeds. Insertion contract: `skills/worktask/references/conductor-attachments.md`.

#### Attachment consumers

The orchestrator — not FN — writes to the GitHub issue.

| Consumer | Stage | Action |
|----------|-------|--------|
| **FN** | FN | `--emit pr` → insert block between `## Test plan` and `## Merge danger`. A re-run replays the first emission's hosted URLs from `.context/logs/visual-evidence-pr-<worktask_id>-<run_index>.md` instead of uploading a second asset set (which orphans the first); `--force` re-hosts |
| **Orchestrator** | Post-loop exit | `--post issue` → marker-deduped `gh issue comment` on the PL-published issue (visual-evidence block only) |
| **Orchestrator** | Post-merge (PR closes) | `--post completion` → one marker-deduped comment per issue the PR closes: a `PR: <url>` line, a summary of at most 300 characters, plus the visual-evidence block when captures exist, summary-only otherwise |

## Size budget

Enforced after every `capture()` call:

1. Read `result.bytes`.
2. `bytes ≥ 500_000` → `pngquant --quality=65-80 --force --output <path> <path>`; re-stat.
3. Still `≥ 500_000` → move to `.context/images/<worktask_id>/oversize/` (not committed), record link-only in `screenshots-<TASK_ID>.md § Out-of-budget files`, `ok: false`, `error: "oversize_unquantizable"`. DV proceeds with remaining captures.
4. `200_000 ≤ bytes < 500_000` → audit row `screenshot_size_warn` with `metadata: {path, bytes}`; keep file.
5. `count > 5` for the task → refuse further captures, audit `screenshot_count_exceeded`, DV stops at 5.

Budget constants: warn ≥200 KB, hard fail ≥500 KB, cap 5 files per task.

## Failure modes

### Completion gate

`hooks/dv-screenshot-gate.sh` runs at SubagentStop and classifies only the stopping task's evidence: `screenshots-<TASK_ID>.md`, else the legacy `## <TASK_ID>` section. Another task's rows never satisfy it. `--check <TASK_ID> [--state <state.json>]` runs the same classifier by hand, prints `class=<name> task=<ID> manifest=<path|-> reason=<text>`, and writes nothing.

The live hook always exits 0 and carries a block as `decision: block` JSON with the remediation in `additionalContext`. Any classifier result outside § Gate classes blocks `gate_unresolved`.

#### Gate classes

| `--check` exit | Class | Live SubagentStop outcome |
|---|---|---|
| 0 | `captured`: at least one image row, every row valid | pass |
| 1 | `invalid`: a row breaks § Row grammar, or an image on disk has no row | block `invalid_evidence` |
| 2 | `usage`: bad task id, unresolved ledger or `worktask_id`, jq absent | block `gate_unresolved` |
| 3 | `no_captures`: no rows and no `dv-<TASK_ID>-*` image | pass on `backend`/`systems`, else block `no_captures` |
| 4 | `tool_missing_only`: valid tool_missing rows, no image row | pass on `backend`/`systems`, else block `tool_missing_ui` |

#### Gate scope and inputs

- **Task**: the `task_id` of the `facts.dispatched_agents[]` row for the payload `agent_id`; with no row, the one in_progress DV task whose `metadata.agent` is the payload `agent_type` (`corpflow:developer` matches any in_progress DV task). No DV task in progress, or none naming that agent type, is a no-op. Any other miss blocks `task_unresolved`, unless the ledger flag is `false`.
- **Flag**: `requires_screenshots` from the task's metadata, then the ledger's, else `true`. For a task reading `false` the gate also invokes `escalate-flag.sh --invoker gate` in its worktree (`worktree.path`, else task, else ledger `workspace_path`; 10 s watchdog, fail open), then the gate re-reads; still `false` passes.
- **Platform**: `tasks.<TASK_ID>.metadata.platform`, else the ledger `platform`.
- **No preflight input**: the gate never reads `metadata.preflight`. A `tool_missing` row passes on the platform alone.

### Gate and tool failures

| Failure | Detection | Required Behavior |
|---------|-----------|-------------------|
| `metadata.requires_screenshots: false` AND zero captures | DV completion checklist | Write `screenshots-<TASK_ID>.md` with skip rationale. DV proceeds; no `missing_screenshot_artifact` error. |
| `metadata.requires_screenshots: true` (default) AND zero captures | DV completion checklist; `--check` exit 3 | Outside `backend`/`systems`, DV FAILS with `missing_screenshot_artifact` and the gate blocks `no_captures`. Append `## DV[N] Retry [X/3]` block to `.context/errors/developer.md` (classification: `logic`). Retry: attempt `cli_fallback` once. |
| Platform capture produced no file (delegate unreachable, or its tooling — XcodeBuildMCP / Playwright / adb — missing) | Target path absent or empty after the delegated `Agent`; `error: "tool_missing"` from adapter | Fall back to `cli_fallback`. Audit `screenshot_platform_fallback`. Continue. |

### Fallback-floor, budget, and invocation failures

| Failure | Detection | Required Behavior |
|---------|-----------|-------------------|
| All adapters fail including `cli_fallback` | `ok: false`; stdout `error=tool_missing` (exit 2) or `error=render_failed` (exit 3, a tool ran, no usable PNG) | No image is written: a placeholder passes an existence check while proving nothing. Audit `screenshot_capture_failed`; all tools absent adds a tool_missing row. DV reports a failed capture. |
| Size budget exceeded after pngquant | `oversize_unquantizable` | Move to the oversize/ subdirectory, link-only in `screenshots-<TASK_ID>.md`. Continue. |
| 5-cap reached | `screenshot_count_exceeded` | Stop further captures. Audit row. Continue. |
| `Skill()` invocation fails | DV catches exception | Follow `../worktask/references/workflow.md § Error Handling`. Append to `.context/errors/developer.md` (classification: `transient` for retry; `logic` for escalate to AR). Never treat as success. |

## Redaction

The `cli-fallback.sh` `git diff` pipe can expose env files, tokens, or secrets present in the diff. Redact before piping to `silicon` or `magick`, per `logging-conventions § Bash Pattern`. If a sensitive pattern is detected, capture the file tree (`git diff --name-only`) instead of the diff content.

## Consumers

| Consumer | Stage | What they read | Where they write |
|----------|-------|----------------|-----------------|
| **DV** | DV | Captures; writes its own `screenshots-<TASK_ID>.md` + `state.json → facts.screenshots[]` | `development-N.md § Decisions` + audit.jsonl |
| **DR** | DR | Each DV task's `screenshots-<TASK_ID>.md` (count, first filename, fallbacks, oversize notes) | `developer-review-N.md § Findings` |
| **QA** | QA | Every `screenshots-*.md` (a legacy `screenshots.md` by its `## <TASK_ID>` sections) + each image. `Design Ref` joins each result image to a `figma-registry.md` row `ID`; the manifests are the RMSE result-image source for QA's Registry-Driven Design Comparison (the `--candidate` for `scripts/visual-diff.sh`). Live re-capture is QA's fallback only. | `testing-N.md § Visual Evidence` + `§ Design Comparison` |

### state.json registration schema

`facts.screenshots: [{slug, path, bytes, platform, ok}]` — e.g. `{"slug": "storage-layout", "path": ".context/images/<worktask_id>/dv-DV0-01-storage-layout.png", "bytes": 187234, "platform": "all", "ok": true}`. Max 5 items; cleared on worktask archival (FN/ST), not within a run, following the `facts.files_read` precedent.

### Audit actions emitted by this skill

#### screenshot_* actions

| `action` | When | Required `metadata` keys |
|----------|------|--------------------------|
| `screenshot_captured` | Successful `capture()` | `slug, path, bytes, platform, adapter` |
| `screenshot_skipped` | `metadata.requires_screenshots: false` | `reason` |
| `screenshot_flag_escalated` | `escalate-flag.sh`: `ok` raised, `warn` undecided; `raised` = writes that landed | `platform, base, reason, invoker, raised` (+ `matched_count, matched` when a match was computed) |
| `screenshot_platform_fallback` | Adapter differs from `state.platform` | `requested_platform, used_adapter, reason` |
| `screenshot_size_warn` | 200 KB ≤ bytes < 500 KB | `path, bytes` |
| `screenshot_size_fail` | bytes ≥ 500 KB after pngquant | `path, bytes_before, bytes_after` |
| `screenshot_count_exceeded` | 6th capture attempted | `attempted_slug` |
| `screenshot_capture_failed` | cli/fallback floor: no tool, or a tool that rendered nothing usable | `tools_checked`, `reason` |

#### canvas and visual-diff actions

| `action` | When | Required `metadata` keys |
|----------|------|--------------------------|
| `canvas_render` | Each canvas-adapter invocation (one row per phase) | `phase ∈ {"scaffold","complete","retry"}`, `view`, `destination`, `output_path`, `bytes`, `duration_ms` |
| `preview_added` | `preview-ensurer` added a `#Preview` block to source | `file`, `view_type`, `mock_strategy ∈ {"binding-constant","optional-nil","mock-found","preview-tbd"}`, `lines_added` |
| `visual_diff_run` | QA executes RMSE diff (via `scripts/visual-diff.sh`) | `reference`, `candidate`, `metric: "RMSE"`, `value_percent`, `threshold_percent`, `verdict ∈ {"pass","fail_visual_diff"}` |

##### Adapter-scoped `canvas_render` extras

Those keys are the contract every canvas adapter satisfies; toolchain identifiers are optional adapter-scoped additions. `apple-canvas` also records `swift_version` and `swift_syntax_version` and uses `destination ∈ {"macos-host","ios-sim"}`.
