# DR artifact rules

Read before writing or validating the DR stage artifact.

<!-- canonical-body:start -->
#### refs.dev is a list, one element per DV row (tpl-dr … tpl-re)

`refs.dev` is always a YAML list: a single-DV run yields a one-element list, never a scalar.
Each element is `<artifact basename>#files-changed`, one per DV ledger row, in ascending numeric
task-id order. Resolve them from the ledger rather than composing a filename — the idiom and the
naming grammar are `skills/worktask/references/contracts/artifact-map.md § Iterating the DV tasks` (seam S3). The same field, shape
and rule apply to `skills/worktask/assets/templates/template-sr.md#tpl-sr`, `skills/worktask/assets/templates/template-qa.md#tpl-qa`, `skills/worktask/assets/templates/template-dc.md#tpl-dc` and `skills/worktask/assets/templates/template-re.md#tpl-re`.
