# Stage guards

Read when executing or checking stage guards.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
## Rule Checks

| Rule | Required Before |
|------|-----------------|
| Test Strategy | PL → AR (when AR runs; else PL owns it) |
| Test Architecture | AR → TL when both run; AR → DV when TL is excluded (the default shape at every tier — see Stage Inclusion Criteria); PL → DV when AR is excluded too |
| Code Format | DV complete |
| Build Pass | DV → DR |
| Unit Tests Written + Pass | DV → DR |
| Developer Review Pass | DR → QA |
| All Tests Pass (Unit + Integration + E2E) | QA → DC |

## Optimization Hooks

### Pre-Stage

| Check | Threshold | Action |
|-------|-----------|--------|
| Context size | > 50% window (standard) or > 30% (1M window) | Compress previous stages |
| Budget usage | > 75% | Alert user |
| Free disk space | < 5 GB before a build stage (AR/DV/QA/SR/RE) | Halt with remediation — see § Pre-Stage Disk Guard |
| Free disk space | < 8 GB before a build stage | Warn; run `swift package clean` hygiene before delegating |

### Pre-Stage Disk Guard (ENOSPC)

Build stages — **AR, DV, QA, SR, RE** — accumulate .build directories and DerivedData across runs, and an
exhausted filesystem kills the build harness mid-stage. Assert free space before delegating any of
the five. Implementation: `scripts/state-patch.sh --disk-check <root>`.

```bash
MIN_GB="${DISK_MIN_GB:-5}"; WARN_GB="${DISK_WARN_GB:-8}"   # hard halt / hygiene warn
AVAIL_GB=$(df -Pg "${WORKSPACE_ROOT:-.}" 2>/dev/null | awk 'NR==2 {print $4+0}')
```

#### Disk guard — semantics

- **Hard halt** (`AVAIL_GB < MIN_GB`): audit `pre_stage_disk_halt result=blocked` with
  `metadata={"stage":"$CODE","avail_gb":…,"min_gb":…}`, print the remediation (`swift package
  clean`; `rm -rf ~/Library/Developer/Xcode/DerivedData/*`), and don't delegate — a halted run is
  recoverable, an ENOSPC-killed harness is not.
- **Warn** (`AVAIL_GB < WARN_GB`): audit `pre_stage_disk_warn result=ok` with the same shape
  (`warn_gb` instead of `min_gb`), proceed, run `swift package clean` as pre-DV hygiene.
- `df -Pg` is POSIX-portable (macOS + Linux); unparseable output degrades to a no-op, so a
  measurement failure never blocks a run.

### Post-Stage

- Compress context for handoff (50-100 tokens)
- Log token usage in task metadata
- Validate artifacts created
- `PostCompact` hook fires after auto-compaction — use to re-inject critical worktask state
