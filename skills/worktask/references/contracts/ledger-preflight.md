# Ledger preflight

Read when executing or checking ledger preflight. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### metadata.preflight

The autonomy preflight's passing result, a registered seam at `version: 1`. Its only writer is
`skills/worktask/scripts/autonomy-preflight.sh --record`, called once after the Step 3a seed of an
unattended run (`skills/worktask/references/launch-seed.md § Step 3a — record the autonomy preflight`), and `--record`
refuses any result that is not a pass. Absent on attended runs, on megatask per-issue runs, and
when the record failed. Consumer: the backend `tool_missing` evidence rule, which excuses a missing
evidence tool only when `tools_absent[]` records it `accepted: true`. Change protocol: bump
`version` on any field change.

##### metadata.preflight — schema

```yaml
# …continued: WorktaskStateLedger.properties.metadata.properties
      preflight:
        type: object
        required: [version, result, ran_at, platforms, checks, tools_absent]
        properties:
          version: { type: integer, const: 1 }
          result: { type: string, enum: [pass, fail] }   # always pass on a ledger
          ran_at: { type: string }                       # date -u +%FT%TZ, or "unknown"
          platforms: { type: array, items: { type: string } }
```

##### metadata.preflight — checks and tools_absent

```yaml
# …continued: metadata.properties.preflight.properties
          checks:
            type: array
            items:
              required: [id, kind, status, detail]
              properties:
                id: { type: string }
                kind: { type: string, enum: [permission, evidence, toolchain] }
                status: { type: string, enum: [pass, fail, skip] }
                detail: { type: string }
          tools_absent:
            type: array
            items:
              required: [tool, platform, accepted]
              properties:
                tool: { type: string, enum: [silicon, magick, convert, playwright, playwright-browser, adb-device, simulator, xcodebuildmcp] }
                platform: { type: string }
                accepted: { type: boolean }              # always true on a ledger
```

##### metadata.preflight — field notes

- `accepted: true` means the tool was named in `/worktask --accept-absent=` at launch; nothing else
  sets it. `--record` runs only after a pass and refuses an unaccepted entry, so every recorded
  `tools_absent[]` entry is `accepted: true`, and an `accepted: false` entry on a ledger is a
  contract violation.
- A tool that was present is never listed in `tools_absent[]`, accepted or not.
- A missing renderer is one entry per binary, as a `tool_missing` row names it (`silicon`,
  `magick`, `convert`); `renderer` accepts all three.
- `checks[].id`: `git-push`, `gh-pr-create`, `gh-pr-merge`, `git-reset-hard`, `renderer`, the other five tools,
  `apple-developer-dir`, `apple-sdk-settings`, `apple-showsdks`, `apple-swift-match`,
  `android-compile-sdk`, and `platform-<p>` (a platform with no checks of its own, recorded `skip`).
- With Playwright itself absent, `playwright-browser` is a `skip` check, not a second absent tool.
