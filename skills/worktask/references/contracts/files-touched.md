# Files touched

Read when executing or checking files touched. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
<a id="files-touched"></a>
### #files-touched — the changed-file list

Every stage that emits `handoff.files_touched` emits it in one shape, because the field alone can
blow the token budget and ad-hoc truncations diverge.

#### Semantics — post-merge repo-relative

A path is written as it will read after this work merges: relative to the repository root, never to
a worktree, and never absolute. During a run the file lives under the emitting task's
`metadata.workspace_path`, so a consumer that wants to open it resolves `<workspace_path>/<path>`.
The recorded value answers "what did this run change", not "where is this file right now". No
script checks that the paths exist.

#### Cap — `FILES_TOUCHED_MAX = 10`

Emit the first ten repo-relative paths, then, when the full set
is larger, exactly one final entry of the literal form `+ <count> more`:

```yaml
  files_touched:
    - skills/worktask/scripts/state-patch.sh
    - skills/worktask/scripts/handoff-harness.sh
    - "+ 7 more"
```

Ten paths plus the marker cost 33 proxy tokens of the 200-token discretionary budget, and the list
counts inside that budget. The constant lives here and in `handoff-harness.sh`.
`handoff-harness.sh --validate-frontmatter` fails a list longer than the cap without a marker, a
marker that is not last, and more than one marker.

#### The marker obliges the body

Whenever the marker is present, the artifact's own changed-files body section carries the full set
and is marked authoritative in the same edit: the frontmatter is an excerpt, and an excerpt nobody
can complete is an ad-hoc truncation.
