# Company Worktask Plugin

[![OS](https://img.shields.io/badge/OS-macOS%20%7C%20Linux-2f81f7)](#requirements)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-2.1.303%2B-d97757)](#requirements)
[![Codex](https://img.shields.io/badge/Codex-0.156.1%20verified-10a37f)](#requirements)

A staged worktask system for Claude Code and Codex — **9 stages standard, 11 with `--secure`** — with a durable state ledger, worktree-isolated execution behind two human approval gates (plan + finalization), stage transitions, and structured task management.

**Plugin 4.1.3 · Requires Claude Code 2.1.303+ · Verified with Codex CLI 0.156.1**

## Features

- **Worktree-isolated + two approval gates (plan + finalization)**: every worktask runs in a dedicated git worktree and STOPs twice — once after planning to approve the plan (`plan_gate: "checkpoint"`; skipped by `--auto=[plan]` / `--emergency`) and once before finalization to approve commit/push/PR (`fn_gate: "checkpoint"`; skipped by `--auto=[finalization]` / `--emergency`). By default FN STOPs before any commit/push/PR; `--auto=[finalization]` finalizes unattended. The values are orthogonal — `plan` skips only the plan gate, never the FN gate; the third value, `--auto=[decision]`, skips no gate but delegates PL open questions to a Fable-model decision pass instead of the user. Changes are reviewable as PRs. (Batch runs via **`/megatask`** stamp both gates `"bypass"` directly per issue — see the Megatask feature below.)
- **`/megatask` — dependency-DAG batch orchestration**: run many worktasks across a GitHub milestone (`/megatask N`) or an explicit issue array (`/megatask --issues 12,15,18`). Parses `Depends on:` / `Blocks:` + P0–P3 labels into a DAG, executes in topological + priority order (never starting an issue whose blockers are unmerged), isolates each issue in its own worktree, and drives completion via the `megatask-monitor` hook (unblock-dependents + progress). One human checkpoint: the R1 batch confirmation.
- **9-Stage Worktask**: Planning → Architecture → Team Lead → Development → Developer Review → QA → Documentation → Finalization → Stakeholder
- **State Ledger**: `.context/state.json` `tasks{}` — one durable ledger, written only through `state-patch.sh`
- **Native Dependencies**: `blocked_by` arrays for explicit dependency management
- **Durable by construction**: the ledger is a file in the worktask folder, so it survives sessions, compaction, and resume
- **Dynamic Task Creation**: PL0 seeds subsequent stage tasks based on complexity assessment
- **Error Handling**: Retry logic (max 3 per stage) and escalation chains
- **Sub-agent Visibility**: every agent reads the same ledger
- **Agent-Specific Commands**: Specialized commands for each worktask role
- **Ethics Review**: Optional constitutional compliance checkpoint for high-risk features

## State Ledger

Stage state lives in `.context/state.json` under `tasks{}`, keyed by stage id (`PL0`, `DV0`,
`DV1`). All writes go through `skills/worktask/scripts/state-patch.sh`, which owns the merge
lock, the atomic write, and the disk guard.

| Operation | Command |
|-----------|---------|
| Create | `state-patch.sh --task-create <ID> --metadata '<json>'` |
| Set status | `state-patch.sh --task-status <ID> <status>` |
| Add dependency | `state-patch.sh --task-block <ID> --on <ID[,ID...]>` |
| Merge metadata | `state-patch.sh --task-meta <ID> --set '<json>'` |

### Key Benefits

- **Durable**: a file in the worktask folder — survives sessions, compaction, and resume with no configuration
- **Native dependencies**: `blocked_by` arrays, resolved by the orchestrator loop
- **Sub-agent visibility**: every agent reads the same ledger
- **Parallel-track safe**: numbered keys mean `DV0` and `DV1` are distinct entries, not a collision
- **Metadata support**: routing, gates, and dispatch config per task

> corpflow does **not** use Claude Code's `TaskCreate`/`TaskUpdate`/`TaskGet`/`TaskList` tools.
> No current model (Opus 5.5, Sonnet 5.5, Haiku 5.5 or Fable 5.x) is offered them, so the ledger is the one
> mechanism that works on every stage. See `skills/shared/state-ledger.md`.

## Installation

### Requirements

Tools listed below are organized by status (required, optional, platform-specific) with their degradation mode — what capability is lost if the tool is missing. **All tool invocations in the repository are derived from actual call sites, not assumed**.

#### Hard requirements — your worktask will not complete without these

| Tool | Status | Needed for | Degradation | macOS | Linux |
|------|--------|-----------|-------------|-------|-------|
| **bash 3.2+** | Required | Plugin scripts run on bash; 3.2 is the declared floor on macOS | No worktask will start | Installed by default | `apt-get install bash` or `dnf install bash` |
| **Claude Code 2.1.303+ or Codex CLI 0.156.1+** | Required | Host runtime for commands/skills, subagents, hooks, and user decisions | No worktask will start | N/A | N/A |
| **git** | Required | Worktask isolation via git worktree; worktask state from branch tracking | No worktask will start | Installed with Xcode CLT | `apt-get install git` or `dnf install git` |
| **POSIX text toolchain** — `awk`, `sed`, `grep`, `find`, `tr`, `mktemp`, `cut`, `sort`, `comm` | Required | Core shell scripting throughout hooks, skills, tests | No worktask will start | Installed by default (BSD variants) | `apt-get install gawk sed grep findutils coreutils` or `dnf install gawk sed grep findutils coreutils` |
| **Hash tools** — `md5`, `md5sum`, `sha256sum`, `shasum` | Required | File integrity checks; used unguarded in tests and build | No worktask will start | Stock macOS ships `md5` and `shasum` (Perl-shipped). `sha1sum` and `sha256sum` are not available by default; dual-path code handles this (uses `shasum` instead) | `apt-get install coreutils` or `dnf install coreutils` |
| **make** | Required | `make test` (test suite entry point), `make coverage` (coverage gating), `make bootstrap` (dependency resolution) | Cannot run test suite or verify coverage | Installed with Xcode CLT | `apt-get install make` or `dnf install make` |
| **jq** | **Split behavior** — see below | `state-patch.sh` (ledger writer) and `hooks/agent-stop.sh` (hook caller) use it for JSON manipulation | Ledger writers **fail and stop** (e.g., plan approval hangs); hooks **skip gracefully** with a message; the split is documented and intentional | `brew install jq` | `apt-get install jq` or `dnf install jq` |

**The jq split behavior, explained:** `hooks/agent-stop.sh` (line 30) exits 0 when jq is missing — hook skips with "jq not found, skipping" message — so you can still run worktasks. `state-patch.sh` (line 1777, the main patch path at 1833) exits 2 when jq is missing — ledger write fails and blocks the entire stage — so the ledger stays unchanged. Both behaviors are correct for their context: hooks must never block the orchestrator; the ledger writer must never silently skip. If you see "jq required" errors in your logs, you cannot proceed until jq is installed.

#### Strongly recommended — your worktask is slower or incomplete without these

| Tool | Status | Needed for | Degradation | macOS | Linux |
|------|--------|-----------|-------------|-------|-------|
| **`curl`** | Guarded | Anonymous image reachability check in plan issue publishing (`skills/worktask/scripts/publish-pl-issue.sh:469`) | Falls back to authenticated existence check when curl is absent (best effort; only for public repos; private/internal always fail). Non-blocking. | `brew install curl` (or use `/usr/bin/curl` from Xcode CLT if already installed) | `apt-get install curl` or `dnf install curl` |
| **`gitleaks`** (secrets scanner) | Guarded | Security review: scanning for leaked credentials (`skills/security-review-process/scripts/scan-secrets.sh:293`) | Falls back to six built-in regex patterns when gitleaks is absent. Same exit codes (0 = clean, 1 = findings, 2 = error). Less comprehensive but covers the most common patterns. | `brew install gitleaks` | `apt-get install gitleaks` (if available in repos) or download from https://github.com/gitleaks/gitleaks/releases |
| **`gh`** (GitHub CLI, authenticated) | Recommended | Post-PL issue publishing; `/megatask` milestone and issue reads; FN pull requests | Post-PL output prints to the console instead of opening a GitHub issue; `/megatask` cannot read milestones; finalization cannot open PRs | `brew install gh` | `apt-get install gh` or `dnf install gh` (requires 3rd-party repos on some distros; see https://github.com/cli/cli#installation) |
| **yq** | Recommended | Full YAML artifact validation in the handoff gate (uses `yq eval` syntax from mikefarah/yq, the Go implementation) | Frontmatter validation degrades from schema-aware check to grep-only partial check; later stages may proceed with incomplete frontmatter that yq would have caught | `brew install yq` | Distro packages vary: `apt-get install yq` on Debian/Ubuntu installs the wrong tool (Python wrapper). Install via Homebrew (`brew install yq`) or download the Go binary from https://github.com/mikefarah/yq/releases |
| **python3 ≥ 3.10** | Recommended | `/estimate --export csv` (optional performance-analysis export); Python skill tests in QA | CSV export unavailable; Python suite tests skip with "Python 3.10+ not found"; code-coverage assertions skip (per-file assertion-density gate remains in place) | macOS ships 3.9.6 as `/usr/bin/python3` — too old. Use `brew install python@3.12` | Ubuntu 22.04 LTS ships 3.10; Ubuntu 20.04 LTS ships 3.8. Debian 12 ships 3.11. For older LTS versions: `apt-get install python3.12` or `dnf install python3.12` |

#### Platform-specific tools — degrade gracefully on other platforms

| Tool | Status | Needed for | Degradation | Notes |
|------|--------|-----------|-------------|-------|
| **Swift toolchain** | macOS-specific | Apple-platform stages (building Swift packages, DV screenshot capture, code signing) | Swift-dependent phases report as skipped with "swift toolchain absent" message; shell tests and Linux builds unaffected | Install via Xcode CLT: `xcode-select --install`. Or standalone: https://swift.org/install. Linux users with no Swift: this is expected — Swift is an Apple-only platform capability |
| **Xcode command-line tools (CLT)** | macOS-specific | Git integration, code signing, simulator management, compiler access | Xcode-gated phases skip with "Xcode CLT absent" message. Worktask still runs; shell tests and the ledger work on plain bash and git | Install: `xcode-select --install`. Includes: Swift, git, clang, Make |
| **kcov** | Optional, macOS fallback | Code coverage instrumentation for bash (`make coverage`) | **Unusable on macOS** (Error 137, bash 3.2 parser mismatch, mis-parses `BASH_VERSINFO` guards). Falls back to assertion-density proxy (tests/COVERAGE.md documents per-file coverage assertions). On Linux, `make coverage` runs faster with per-target instrumentation. | macOS: documented per-file assertions are the gate (tests/COVERAGE.md). Omit kcov. | Linux: `apt-get install kcov` or `dnf install kcov`. `make bootstrap` tier sequence: checks system binary → attempts `brew install kcov` (if Homebrew available) → falls back to documented per-file assertion-density proxy (tests/COVERAGE.md). |
| **Android toolchain** | Optional, degrades on non-Android hosts | Android-platform stages (Kotlin/Gradle builds, APK signing, device testing) | Android-gated phases skip with "android toolchain absent" message; no effect on general worktask flow | Not needed unless you develop Android apps. Probed by `skills/worktask/scripts/autonomy-preflight.sh` for context; never fatally required |

#### Screenshot capture (on-demand per platform)

Screenshot capture at the DV stage pulls in per-platform tooling on demand (ImageMagick, pngquant, Playwright, a Swift toolchain on macOS). None of it is needed to install or to run a worktask; see `skills/dv-screenshot-capture/SKILL.md` for what each capture path expects.

#### New tools in this release

| Tool | Purpose | Status | Notes |
|------|---------|--------|-------|
| **`portability-lint.sh`** | New CI gate that enforces portable shell (dual-path file-stat/hashing, bash 3.2 floor, no BSD/GNU divergences) | Included, no install needed | Runs in the lint job; exits 0 on this repository. 8 rules (P001–P008) cover `mktemp -t`, `sed -i` without suffix, single-path hash/stat/date tools, unguarded platform binaries, bash 4+ syntax, and `mapfile`/`readarray` |
| **`host-os-lib.sh`** | Shared helper for host operating system detection; centralizes `uname` branching logic | Included, no install needed | Sourced from `skills/worktask/scripts/host-os-lib.sh`. Exported vocab: `macos`, `linux`, `bsd`, `windows`, `unknown`. Three consumers: `autonomy-preflight.sh`, `portability-lint.sh`, `portability-lint-selftest.sh` |

### Install with Claude Code

This repository is both a Claude Code marketplace (`agnidia`) and the plugin it publishes
(`corpflow`). From inside Claude Code:

```
/plugin marketplace add Agnidia/corpflow
/plugin install corpflow@agnidia
```

The plugin activates as soon as it is safe to do so; if the commands do not appear, run
`/reload-plugins`. Hooks — including the `SubagentStop` state-merge safety net — are registered
by `.claude-plugin/plugin.json` on install. There is no manual hook step.

### Install with Codex

```bash
codex plugin marketplace add https://github.com/Agnidia/corpflow.git
codex plugin add corpflow@agnidia
```

Start a new Codex thread after installation, review and trust the bundled hooks, then invoke
workflows as skills: `$request-plan`, `$worktask`, `$arch-review`, and the other command names.
Codex hooks use its native `PLUGIN_ROOT`/`PLUGIN_DATA` environment; Corpflow normalizes those to
`BASE_PLUGIN_ROOT`/`BASE_PLUGIN_DATA` before shared logic runs.

### Upgrade from the `igrsoft` marketplace

The marketplace id is now `agnidia`. If you installed `corpflow@igrsoft`, remove the old marketplace
and install again:

```
/plugin marketplace remove igrsoft
/plugin marketplace add Agnidia/corpflow
/plugin install corpflow@agnidia
```

Then rename the `corpflow@igrsoft` key to `corpflow@agnidia` in every `enabledPlugins` map that
names it. In Codex, remove the old plugin and marketplace, then add the new ones. These steps
were verified on Codex CLI 0.163.0; the two `remove` commands are not checked on 0.156.1:

```bash
codex plugin remove corpflow@igrsoft
codex plugin marketplace remove igrsoft
codex plugin marketplace add https://github.com/Agnidia/corpflow.git
codex plugin add corpflow@agnidia
```

### Verify

Claude Code's `/plugin` or Codex's `codex plugin list` should show **corpflow**. `/worktask`
should autocomplete in Claude Code and `$worktask` should be available in Codex. Then run the
host-native planning entrypoint:

```
/request-plan "add a dark mode toggle to settings"
```

In Codex, use `$request-plan "add a dark mode toggle to settings"` instead.

A plan comes back without touching the repo — the cheapest end-to-end check that agents,
skills, and routing all resolved.

### Optional — platform plugins

The DV stage routes to whichever platform plugin matches the repo, and falls back to project
tooling when none is installed. Each is a separate marketplace under the same org, installed the
same way (`/plugin marketplace add Agnidia/<name>` then `/plugin install <name>@<name>`):

| Plugin | Covers |
|--------|--------|
| `apple-developer` | Swift, SwiftUI, UIKit, AppKit |
| `android-developer` | Kotlin, Jetpack Compose, Gradle |
| `frontend-developer` | TypeScript, React, Vue, Svelte, Angular, CSS |
| `backend-developer` | Node, Go, JVM, Python-web, Ruby, PHP, .NET |
| `system-developer` | C, C++, Python, Bash |
| `ai-engineer` | LLM apps, RAG, fine-tuning, MLOps, evals |

Version floors and the routing contract live in `skills/shared/compatible-plugins.md`.

### Routing overrides

Alias→plugin routing is canonical in `skills/shared/routing-matrix.md` — one row per
platform entry point and functional role (`corpflow:apple-developer →
apple-developer:apple-developer`, `corpflow:web-code-fixer →
frontend-developer:fe-code-fixer`, …). A project can swap any of them: copy
`skills/cross-plugin-handoff/templates/PROJECT-CORPFLOW.md` to the project root as
`CORPFLOW.md`, keep only the rows you override under `## Routing`, and the next worktask
resolves through your targets instead. The same file at
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md` applies to every project; a project-root file
wins per heading (`## Routing`, `## Models`), so a project overrides only what it names:

```markdown
## Routing

| Alias | Target |
|-------|--------|
| `corpflow:apple-developer` | `my-org-apple:apple-developer` |
| `corpflow:apple-code-fixer` | `my-org-apple:code-fixer` |
```

Overrides resolve once at worktask init (persisted as `state.routing`); uninstalled
targets fall back to the default with a `plugin_unavailable` audit row.

### From source

For contributing, or to run the plugin from a working tree:

```bash
git clone https://github.com/Agnidia/corpflow.git
cd corpflow
make bootstrap     # vendor bats, check the swift toolchain, probe kcov
make test          # offline suite — no API calls, no spend
```

Then point Claude Code at the checkout with `/plugin marketplace add /path/to/corpflow`
and install as above.

## Quick Start

### Launching a Worktask

Run the worktask command:

```
/worktask "[task description]"   # The worktask pipeline — PL0 dynamic sizing picks stages
```

`/worktask` is the single-issue entry point. PL0 sizes the pipeline by complexity (dropping AR/TL/DC for small tasks). Use `--auto=[plan]` to skip the plan-approval stop; `--auto=[finalization]` to skip the finalization-approval stop (auto commit/push/PR); `--auto=[decision]` to let a Fable-model delegate answer PL0's open questions; combine as `--auto=[plan, decision, finalization]` for a fully unattended run (escalation-class questions still stop). Use `--emergency` for the incident pipeline (skips both gates). You can also launch via `Skill({skill:"corpflow:worktask"})`. For **multi-issue batches**, use **`/megatask N`** (a milestone) or **`/megatask --issues 12,15,18`** (an array) — it orders by a dependency/blocker DAG and runs each issue unattended.

`/worktask` sets up the worktask context, the state ledger, and stage management.

### Examples

```
/worktask "Add dark mode to settings"
/worktask "/apple-developer:fix-modernize migrate @StateObject to @Environment"
/worktask "/system-developer:fix-modernize . --target cpp23"
```

### Combining with Other Commands

You can embed slash commands within the worktask payload. The orchestrator will:
1. Set up the context and planning
2. Detect the embedded `/command` pattern and store it in `metadata.embedded_commands`
3. Pass the command to the DV stage agent, which invokes it via the `Skill` tool
4. The embedded command's output feeds into the DV stage implementation

Embedded commands are detected by matching `/<name>` or `/<plugin:name>` patterns against available skills. The command arguments are preserved and passed through.

```
/worktask "/apple-developer:fix-refactor src/Views/SettingsView.swift"
/worktask "/code-review PR #123"
```

## Options

### `/worktask`

Gate automation — `--auto=[<values>]` takes an array of any subset of `plan`, `decision`,
`finalization` (brackets optional, e.g. `--auto=plan,decision`). Each value is independent:

| Value | Effect |
|-------|--------|
| `plan` | Stamp `plan_gate: "bypass"` — skip the post-PL plan-approval STOP and proceed straight into the stage loop. FN gate still checkpoints. |
| `decision` | Stamp `decision_gate: "auto"` — PL0's open questions are answered by a Fable-model decision delegate instead of blocking on the user; the amendments land in the plan's existing anchors and the decisions themselves in `state.json facts.decisions[]` marked `(auto-decided)`. Escalation-class questions (irreversible, scope-expanding, security-posture, spend) still stop for a human. Bypasses no gate. |
| `finalization` | Stamp `fn_gate: "bypass"` — skip the pre-FN STOP; auto commit/push/PR. Plan gate still checkpoints. |

Scope and pipeline flags:

| Flag | Effect |
|------|--------|
| `--secure` / `--full` | Force the 11-stage pipeline (adds SR after DR, RE before FN) |
| `--emergency` | Run the incident pipeline (IR→DV→DR→QA→RE→FN); bypasses both gates |
| `--ethics-review` | Add an ET checkpoint after PL |
| `--with-design` | Invoke `designer` during PL (without the flag, Designer is skipped even for UI work) |
| `--sequential` | DC waits for QA instead of running in parallel |
| `--priority High\|Medium\|Low` | Task priority |
| `--platform apple\|android\|web\|systems\|backend\|ai\|all` | Target platform context |
| `--no-gh-issue` | Skip the post-PL GitHub issue auto-publish step |

### `/megatask`

| Form | Effect |
|------|--------|
| `/megatask N` | All open issues in GitHub milestone N |
| `/megatask N --issues 12,15` | Subset of milestone N |
| `/megatask --issues 12,15,18` | Explicit issue array, milestone-agnostic |
| `--secure` | Run each per-issue worktask on the 11-stage path |
| `--platform apple\|android\|web\|systems\|backend\|ai\|all` | Target platform context |
| `--dry-run` | Stop after the DAG is built — no worktrees, no PRs |

## Pipeline Sizing

Single entry point (`/worktask`). PL always runs; PL0 dynamic sizing scores complexity (0–50) and creates only the stages the work needs:

| Score | Tier | Stages created (PL always runs) |
|-------|------|---------------------------------|
| 0–10 | Low | DV → DR → QA |
| 11–20 | Medium | AR (default — PL0 may override per Stage Inclusion Criteria) → DV → DR → QA |
| 21–30 | Moderate | AR (default — PL0 may override per Stage Inclusion Criteria) → DV → DR → QA |
| 31–40 | High | AR (default — PL0 may override per Stage Inclusion Criteria) → DV → DR → QA → DC → FN → ST |
| 41–50 | Critical | AR (default — PL0 may override per Stage Inclusion Criteria) → DV → DR → SR → QA → DC → RE → FN → ST (adds SR + RE) |

\+ TL — only when PL0 splits the work across ≥2 developers (see Stage Inclusion Criteria in `skills/estimation-methodology/SKILL.md`)

`--secure` / `--full` forces the 11-stage path (SR after DR, RE before FN). Security-sensitive features auto-include SR regardless of score.

## 9-Stage Worktask

| Code | Stage | Agent | Purpose |
|------|-------|-------|---------|
| PL | Planning | product-manager | Define requirements |
| AR | Architecture | software-architector | Design solution |
| TL | Team Lead | team-lead | Coordinate approach |
| DV | Development | [language-pro] | Implement solution |
| DR | Developer Review | technical-lead | Code quality review |
| QA | QA | qa-engineer | Test and validate |
| DC | Documentation | technical-writer | Write technical docs |
| FN | Finalization | project-manager | Prepare release |
| ST | Stakeholder | stakeholder | Final approval |

## Ledger Initialization

Only `PL0` is seeded at startup. PL0 seeds subsequent stage tasks after planning:

```bash
# Seed PL0 only — the PL agent seeds remaining stages after planning.
state-patch.sh --task-create PL0 --metadata '{
  "stage":"PL","agent":"corpflow:product-manager",
  "description":"Define requirements, assess complexity, seed stage tasks",
  "worktask_id":"dark-mode","priority":"medium"}'

state-patch.sh --task-status PL0 in_progress

# After planning, PL0 seeds stages based on complexity:
# AR0, DV0, QA0, … — each with metadata.agent for executor resolution.
# Stage agents can split into sub-tasks: DV0 → DV1, DV2
```

## Context Folder Structure

```
.context/
├── planning-0.md            # PL stage (run 0; subsequent PL runs add planning-1.md, planning-2.md, …)
├── architecture-0.md           # AR stage (run 0)
├── coordination-0.md        # TL stage (run 0)
├── development-0.md         # DV stage (run 0)
├── developer-review-0.md    # DR stage (run 0)
├── security-review-0.md     # SR stage (run 0, secure/full variant)
├── testing-0.md             # QA stage (run 0)
├── documentation-0.md       # DC stage (run 0)
├── release-0.md             # RE stage (run 0, secure/full variant)
├── complete-summary-0.md    # FN stage (run 0)
├── retrospective-0.md       # ST stage (run 0)
├── state.json               # Worktask ledger (shared across runs)
├── errors/                  # Per-agent error narratives (if needed)
│   ├── developer.md         # DV retries
│   └── qa-engineer.md       # QA retries
├── designs/                 # Designer-generated .pen mockups
├── images/                  # User-attached visual assets
└── logs/                    # Raw runtime capture (build/test/monitor)
```

All stage artifacts follow the `<basename>-N.md` pattern where N equals `task.metadata.run_index` (stamped by PL0 on every downstream task). First run uses N=0.

## Components

### Agents

| Agent | Description | Worktask Stage |
|-------|-------------|----------------|
| `product-manager` | Product strategy, requirements | PL (Planning) |
| `software-architector` | Architecture, design patterns | AR (Architecture) |
| `team-lead` | Team coordination, sprint planning | TL (Team Lead) |
| `developer` | Dynamic platform developer routing | DV (Development) |
| `technical-lead` | Code quality, technical review | DR (Developer Review) |
| `qa-engineer` | Testing, quality assurance | QA (QA) |
| `technical-writer` | Documentation | DC (Documentation) |
| `project-manager` | Sprint management, releases | FN (Finalization) |
| `stakeholder` | Business approval, ROI | ST (Stakeholder) |
| `security-reviewer` | OWASP compliance, vulnerability review | SR (Security Review, secure/full) |
| `release-engineer` | Versioning, changelog, deployment readiness | RE (Release Engineering, secure/full) |
| `incident-responder` | Production triage, hotfix coordination | IR (Incident Response, emergency) |
| `designer` | UI/UX strategy, design systems | PL (Planning) |
| `ethics-reviewer` | Constitutional compliance, harm assessment | Support |
| `prompt-engineer` | Agent/command optimization | Support |
| `workflow-engineer` | Worktask troubleshooting | Support |

### Commands

28 commands. Orchestration, planning, and publishing commands are unprefixed; the rest carry a stable domain prefix (`design-`, `arch-`, `test-`, `docs-`) naming the surface they act on.

#### Core / Orchestration
| Command | Description |
|---------|-------------|
| `/worktask` | Initialize a single staged worktask (milestone-agnostic) |
| `/megatask` | Orchestrate many worktasks across a milestone or issue array, ordered by a dependency/blocker DAG |
| `/estimate` | Estimate task complexity and effort; `--detailed` runs the platform review inline, `--review` reviews an existing estimate, `--export csv` emits the CSV pack |
| `/improve-yourself` | Retrospective: propose agent/skill/command updates from user edits |
| `/cc-update` | Update plugin agents/commands/skills for new Claude Code features; watches cross-session/cross-plugin comms surfaces and reviews new flags for state-ledger fields |

#### Design (`design-`)
| Command | Description |
|---------|-------------|
| `/design-specs` | Generate design specifications |
| `/design-review` | Review design decisions |
| `/design-accessibility` | Accessibility audit (WCAG) |

#### Planning
| Command | Description |
|---------|-------------|
| `/request-plan` | Turn a free-form request into a lightweight, context-aware plan |
| `/product-requirements` | Generate PRD |
| `/roadmap` | Product roadmap planning |
| `/milestone` | Generate milestone tickets with agent assignments |
| `/sprint` | Sprint planning |

#### Architecture (`arch-`)
| Command | Description |
|---------|-------------|
| `/arch-review` | Architecture review |
| `/arch-decision` | Create ADRs, or TDRs via `--type tdr` |
| `/arch-debt` | Technical debt analysis |

#### Development
| Command | Description |
|---------|-------------|
| `/tech-code-review` | Technical code-review DR gate; `--depth deep` adds full technical-review analysis |

#### QA / Test (`test-`)
| Command | Description |
|---------|-------------|
| `/test-plan` | Generate test plan |
| `/test-coverage` | Coverage analysis |

#### Docs (`docs-`)
| Command | Description |
|---------|-------------|
| `/docs-audit` | Documentation audit |
| `/docs-readme` | README maintenance |
| `/docs-release-notes` | Generate release notes |

#### Ethics
| Command | Description |
|---------|-------------|
| `/ethics-review` | Constitutional compliance review; `--lens harm` runs a full stakeholder harm assessment |

#### Authoring
| Command | Description |
|---------|-------------|
| `/create-agent` | Create new agent definition |
| `/optimize-agent` | Optimize existing agent |
| `/optimize-command` | Optimize command definition |
| `/prompt-audit` | Audit prompt effectiveness |

#### Publishing

| Command | Description |
|---------|-------------|
| `/appstore` | Store publishing front door — listing, screenshots, or IAP; delegates to the platform plugin's release engineer |

The store flows themselves live in the plugin that ships to that store
(`apple-developer:gen-appstore-*`, `android-developer:gen-playstore-*`), because App Store Connect
and Play Console differ field by field. `--apple-platform` selects an Apple device class and is
passed through unchanged — it is deliberately distinct from the plugin-wide `--platform`.

### Skills (24 total)
- `agent-coordination` — Multi-agent coordination, handoffs, parallel execution, error escalation
- `claude-constitution` — Constitutional principles and ethics framework
- `code-comment-standard` — Compact source-comment standard (WHY/contract only); loadable skill wrapping code-documentation.md
- `context-compression` — Context compression between agent handoffs
- `cost-optimization` — Token and cost tracking/optimization
- `cross-plugin-handoff` — Handoff protocol to external plugins; includes the add/replace-a-plugin checklist. Compatible dev plugins are registered in `skills/shared/compatible-plugins.md` (apple-developer, system-developer, android-developer, frontend-developer, backend-developer, ai-engineer)
- `csv-export-templates` — CSV export structure for Google Sheets import
- `dv-screenshot-capture` — DV-stage screenshot capture, attached to the PR as visual evidence
- `estimation-methodology` — Complexity scoring (0–50) and T-shirt sizing
- `gh-issue-dedup` — One GitHub issue per `.context/`; later runs comment instead of duplicating
- `incident-response` — Incident classification, hotfix worktask, rollback, post-mortem (IR)
- `logging-conventions` — Route runtime log capture to `.context/logs/`
- `megatask` — Dependency-DAG orchestration of many worktasks (the `/megatask` command)
- `milestone-helpers` — Helper patterns for milestone/megatask operations (ships from `skills/shared/milestone-helpers/`)
- `pencil-design-worktask` — Design mockup generation via Pencil MCP (Designer)
- `preview-ensurer` — Auto-add `#Preview` to modified SwiftUI views before snapshotting
- `release-engineering` — Semantic versioning, changelog, deployment readiness (RE)
- `request-plan` — Turn a free-form request into a lightweight, context-aware plan
- `security-review-process` — OWASP Top 10 checklist, dependency supply-chain triage, secure-coding patterns (SR)
- `self-improvement` — ST-stage retrospective: propose scoped updates from user edits
- `task-folder-organization` — `.context/` folder structure and artifact naming
- `worktask` — Complete staged worktask system (dynamic sizing, init, stage management)
- `worktask-testing-strategy` — Test-strategy planning for PL/AR stages
- `writing-style` — ASD-STE100-derived prose standard (~80%) for replies, handoffs, reports and docs; loadable skill wrapping writing-style.md

Each name above is the invocable id — prefix with `corpflow:` (e.g. `Skill({skill:"corpflow:worktask"})`). See [skills/README.md](skills/README.md) for the full index with effort levels and shared (non-loadable) utilities.

### Hooks

Registered in `.claude-plugin/plugin.json`. Several are **gates** — they can block a stage from completing, not just observe it.

| Hook | Event | Purpose |
|------|-------|---------|
| `test-execution-gate.sh` | PreToolUse (`Bash`/`Skill`/`Agent`/test MCP) | **Blocks** a test run by a stage that holds no test-execution authority |
| `model-switch-gate.sh` | PreModelSwitch | **Blocks** a mid-worktask re-tier away from the stage's pinned `metadata.model` |
| `model-switch-audit.sh` | PostModelSwitch | Records `model_switched` so cost is attributed to the model that ran |
| `audit-tooluse.sh` | PostToolUse (`Bash`/`Write`/`Edit`) | Appends canonical tool rows to `.context/logs/audit.jsonl`; Bash rows only for ledger patches |
| `anchor-preflight.sh` | PreToolUse + PostToolUse (`Write`/`Edit`) | Denies an Edit adding an off-list H2 to `.context/<stage>-N.md`; after a write, reports anchor and frontmatter findings for an Edit fix |
| `comment-standard-context.sh` | PostToolUse (`Write`/`Edit`) | Injects the comment standard once per session on the first source edit |
| `audit-subagent.sh` | SubagentStop | Writes `subagent_stopped` audit rows |
| `dv-screenshot-gate.sh` | SubagentStop | **Blocks** DV completion on missing or invalid evidence in a task's `screenshots-<TASK_ID>.md`; no captures passes only on backend/systems or `requires_screenshots=false` |
| `dv-comment-density-gate.sh` | SubagentStop | **Blocks** DV completion when a change's comment density breaches the standard |
| `state-merge.sh` | SubagentStop | Merges artifact `handoff:` frontmatter into `.context/state.json` |
| `megatask-monitor.sh` | SubagentStop | Drives the megatask completion loop (unblock dependents, progress) |
| `precompact-checkpoint.sh` | PreCompact | Checkpoints `state.json` before auto-compaction |
| `agent-stop.sh` | SubagentStop (matched to the PL/FN/ST agents) | Stage-boundary audit row |

## Error Handling

### Retry Logic
Retry budget depends on how the failure classifies: `transient` retries up to **3** times (exponential backoff), `logic` up to **2** (corrective context added on the second attempt). `missing_input`, `ambiguous_requirements`, `design_flaw`, and `hard_constraint` do **not** retry — they escalate immediately. Full matrix in `skills/agent-coordination/SKILL.md` § Retry / Escalate Matrix.

Error narrative tracked per-agent in `.context/errors/<agent>.md` (parallel-safe for concurrent stage failures). Raw build/test captures go to `.context/logs/` per `logging-conventions` skill.

```markdown
## Retry 2 — 2026-04-20T14:32:10Z
**Agent**: developer (DV0)
**Classification**: logic
**retry_count**: 2
```

### Escalation Chains
```
9-stage:   ST → FN → DC → QA → DR → DV → TL → AR → PL → USER
11-stage:  ST → FN → RE → DC → QA → SR → DR → DV → TL → AR → PL → USER
Emergency: FN → RE → QA → DR → DV → IR → USER
Ethics:    Any → ethics-reviewer → stakeholder → USER
```

## Command Quick Reference

> Per-command usage (grouped by role/phase) lives in the **Commands** tables above (§ Commands). Every command — planning, development, testing, docs, release, troubleshooting, and `/improve-yourself` retrospective flags — is documented there.

## Development

The deterministic test suite runs offline — bats for shell, stdlib `unittest` for Python, Swift Testing for the benchmark artifact package. No system `bats` or `kcov` needed; `make bootstrap` vendors what it can and probes the rest.

```bash
make bootstrap     # vendor bats, check the swift toolchain, probe kcov
make test          # full offline suite (bats + Python + Swift), via run-tests.sh
make coverage      # + kcov / llvm-cov gating (≥85% target)
make test-ios      # TicTacToeKit on an iOS Simulator (SKIPs without a runtime)
make benchmark     # deterministic A/B plugin-overhead benchmark
make benchmark-live BUDGET=10.00   # live full-pipeline run (credential-gated, opt-in)
make report        # HTML report → benchmark/results/result.html
make clean
```

`make help` lists every target. Details live with the suites they describe:

- [tests/README.md](tests/README.md) — suite organization, fixtures, coverage verdict
- [benchmark/README.md](benchmark/README.md) — the WITH/WITHOUT Tic-Tac-Toe A/B harness
- [skills/README.md](skills/README.md) — full skill index with effort levels
- [CHANGELOG.md](CHANGELOG.md) — release history (`4.0.0`+); earlier majors archived in [CHANGELOG-3.x.md](CHANGELOG-3.x.md), [CHANGELOG-2.x.md](CHANGELOG-2.x.md), and [CHANGELOG-1.x.md](CHANGELOG-1.x.md)

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
