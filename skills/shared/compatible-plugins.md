# Compatible Dev-Plugin Registry

Canonical for plugin-level compatibility metadata: which dev plugins the orchestrator
may route to, their command-set tier, version floors, and handoff defaults. Agent routing
lives elsewhere and is never copied here: alias→agent routing (entry and functional roles,
project override) in `skills/shared/routing-matrix.md`; marker→platform detection and
platform→specialist tables in `skills/shared/platform-detection.md`.

## Registry

### Identity and routing

| Plugin | Role | Platform key | Version floor | Entry alias |
|--------|------|--------------|---------------|-------------|
| `apple-developer` | Apple platforms (Swift, SwiftUI, UIKit, AppKit) | `apple` | >=1.25.0 | `corpflow:apple-developer` |
| `system-developer` | C, C++, Python, Bash systems code | `systems` | >=1.5.0 | `corpflow:system-developer` |
| `android-developer` | Android (Kotlin, Compose, Gradle) | `android` | >=1.4.0 | `corpflow:android-developer` |
| `frontend-developer` | Web UI (React, Vue, Svelte, Angular, TS, CSS) | `web` | >=1.2.0 | `corpflow:frontend-developer` |
| `backend-developer` | Services, APIs, persistence | `backend` | >=1.3.0 | `corpflow:backend-developer` |
| `ai-engineer` | AI/ML, LLM applications, MLOps | `ai` | >=1.2.0 | `corpflow:ai-engineer` |

Entry aliases resolve to qualified `plugin:agent` targets in
`skills/shared/routing-matrix.md § Entry aliases` — the single copy of the target ids.

### Command set

| Plugin | Command set |
|--------|-------------|
| `apple-developer` | core-parity + apple extras + publishing |
| `system-developer` | core-parity + `sanitize-check` |
| `android-developer` | core-parity + publishing |
| `frontend-developer` | core-parity + `gen-component` |
| `backend-developer` | core-parity + `gen-api`, `db-migrate`, `analyze-security` |
| `ai-engineer` | **own set** + `build-test` (documented exception) |

The integration surface is each plugin's root `CORPFLOW.md`
(`skills/cross-plugin-handoff/references/plugin-contract.md § A.4`).

Apple extras: `analyze-issue`, `analyze-localization`, `gen-mock-api`, `fix-security-hardening`,
`review-swiftui`, `review-uikit`, `review-appkit`.

#### Publishing commands

Publishing commands are store-specific and exist only where there is a store — apple
`gen-appstore-listing`, `gen-appstore-screenshots`, `gen-appstore-iap`; android
`gen-playstore-listing`, `gen-playstore-screenshots` (Play Billing IAP is not ported). They are
reached through `/appstore`, which resolves the platform's release engineer via
`skills/shared/routing-matrix.md § Release-engineer aliases`. They are not core-parity,
since a store command is meaningless on a platform with no store.

## Functional-role agents

Used by stage agents consulting a dev plugin outside DV: AR (`software-architector`),
SR (`security-reviewer`), QA (`qa-engineer`), DR remediation. The per-platform
architect/security-auditor/test-generator/code-fixer targets are canonical in
`skills/shared/routing-matrix.md § Functional-role aliases` — this file keeps no copy.
QA's native UI legs (apple and android only) route through the `ui-verifier` aliases in
`skills/shared/routing-matrix.md § UI-verifier aliases`.
QA on web additionally consults `fe-accessibility-auditor` (review-only roster:
`skills/shared/platform-detection.md § Review-only specialists`).

## Core-parity command set

Every registered platform plugin exposes these 15 commands under its own namespace
(`/<plugin>:<command>`):

```
analyze-tech-debt   analyze-accessibility   arch-select    arch-review    review-code
fix-quick           fix-modernize           fix-performance   fix-refactor
gen-tests           gen-docs                deps           debug
build-test          develop-feature
```

Naming grammar: `analyze-*` read-only assessment (never Write/Edit) · `arch-*` architecture
selection and review · `review-*` code review · `fix-*` mutating remediation · `gen-*` artifact
generation · bare verbs for lifecycle (`deps`, `debug`, `build-test`, `develop-feature`).

### ai-engineer exception

Keeps its domain set — `review-code`, `analyze-security`, `data-audit`, `deploy-check`,
`eval-run`, `finetune-plan`, `prompt-optimize`, `rag-audit` — plus `build-test`, the one
core command structurally required for a platform to be routable at all (DV/DR/QA delegate
their build gate to it). Only the two names overlapping the standard were renamed; a wider
core-parity pass is optional.

## Handoff defaults

| Plugin | `requires_screenshots` default | Evidence adapter | `error_file` example |
|--------|-------------------------------|------------------|----------------------|
| `apple-developer` | `true` | `apple-canvas` / simulator | `.context/errors/ios-developer.md` |
| `android-developer` | `true` | `android_adapter` (`adb exec-out screencap`) | `.context/errors/android-phone-developer.md` |
| `frontend-developer` | `true` | `web_adapter` (Playwright / Chrome MCP) + Lighthouse/axe | `.context/errors/react-developer.md` |
| `system-developer` | `false` | `cli_fallback_adapter` (build/test transcripts) | `.context/errors/c-developer.md` |
| `backend-developer` | `false` | `cli_fallback_adapter` (API transcripts, k6, migration logs) | `.context/errors/node-developer.md` |
| `ai-engineer` | `false` | `cli_fallback_adapter` (eval reports, metrics, training logs) | `.context/errors/llm-engineer.md` |

## Support (non-dev) plugins

`corpflow`, `debugging-toolkit`, `security-scanning`, `skill-creator`, `conductor`, `claude-in-chrome`.

The plugin-prefix regexes in `skills/worktask/scripts/publish-pl-issue-lib.sh` must equal this
list united with the Plugin column of § Registry (equivalently: the plugin set of the
default targets in `skills/shared/routing-matrix.md`). Changing one copy alone lets
internal agent identifiers leak into published GitHub issues.

## § Naming — plugin-unique agent prefixes

Functional-role agents carry a plugin-unique prefix: `sys-`, `and-`, `fe-`, `be-`, `ai-`.
The one exception is `apple-developer`, which keeps the bare names `security-auditor`,
`test-generator`, `code-fixer`, `dependency-manager`; any plugin added from here takes a prefix.

Two plugins shipping the same bare name break two things: Claude Code keys installed agents
by frontmatter `name`, so one silently overwrites the other; and `error_file` derives from
the agent basename, so both write to the same `.context/errors/test-generator.md` inside one
worktask.

## Adding or replacing a dev plugin

See `skills/cross-plugin-handoff/references/plugin-contract.md` — the normative contract plus
the ordered touchpoint checklist.

## Claude Code 2.1.303 plugin compatibility

Agent MCP allowlists match one server, including names containing `__`; spell the complete server as `mcp__<whole name>__*`.
SessionStart output from late-loaded plugins no longer leaks across `/clear`, and duplicate plugin names receive a hooks warning (2.1.296).
A plugin name collision still needs operator remediation; do not treat missing hook output as successful sibling initialization.
Plugin hooks under `--worktree` run from 2.1.300; this fix does not cover `--tmux`.
The shared CORPFLOW.md template remains unchanged, so this integration requires no sibling template migration.
