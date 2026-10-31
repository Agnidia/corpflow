# consultant-return.v1 — sibling consultant return schema

The one shape a sibling plugin's findings-bearing consultation returns to corpflow: the security
auditor an SR stage dispatches, and a sibling findings review handed to DR. `corpflow:security-reviewer`
and `corpflow:technical-lead` validate every such return with
`bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/validate-consultant-return.sh` and merge only what it prints.

A return is never normalized by hand. A mismatched `schema_version` or a missing `severity_counts`
is rejected and goes back to the consultant; it is never merged, edited, or retyped into shape.

Out of scope for v1: code-fixer returns (code, not findings), QA go/no-go, and AR architecture
summaries.

## Object

| Field | Type | Rule |
|---|---|---|
| `schema_version` | string | Exactly `consultant-return.v1`. Absent → accepted with `warn: version_absent` and stamped; any other value, `null` included → `version_mismatch` |
| `verdict` | string | `pass` or `fail`. `needs_changes` → `fail` with `warn: needs_changes_normalized`; absent or any other value → `invalid_verdict` |
| `severity_counts` | object | Exactly the keys `critical`, `high`, `medium`, `low`, plus an optional `info`, each an integer ≥ 0. Absent → `missing_severity_counts`; any other shape → `invalid_severity_counts` |
| `findings` | array | Finding objects. Absent or not an array → `missing_findings`; `[]` is valid |

### Finding

| Key | Type | Rule |
|---|---|---|
| `id` | string | Required, non-empty |
| `severity` | string | Required: `critical`, `high`, `medium`, `low` or `info` |
| `summary` | string | Required, non-empty |
| `location` | string | Optional, `path:line` |

A broken item is `invalid_finding`, located as `findings[<i>].<key>`.

### Severity spelling is strict

Lowercase only. `Critical`, `Info`, `informational`, `P0`–`P3` and every other spelling are
rejected, never mapped: a mapping would move hand-normalization into code and hide which consultant
is non-compliant. DR's P0–P2 scale is a judgment it applies after the merge
(`commands/tech-code-review.md § Severity scheme`), not a translation of these words.

`info` is a level of its own, matching the Info tier of `agents/security-reviewer.md § Severity
Classification`, and is never mapped to `low`. It is advisory: an `info` finding or count is never a
blocker on its own. It is optional, so a return that never uses it stays valid as before.

## What a sibling returns

End the return with exactly one ```` ```json ```` fence, placed last, holding the object.

The validator reads the whole input when it parses as a single JSON object. Otherwise it takes the
last closed fence that opens with up to three spaces, three backticks and `json`. Earlier fences,
tilde fences and an unclosed fence are ignored, and CRLF line endings still match. No closed fence,
or a fence holding anything but one object, is `no_json`; a fence `jq` cannot parse is `unparseable`.

### Transition

A return with no `schema_version` passes, with a warning, while the six sibling plugins adopt v1.
Tightening that to a reject is a planned follow-up, so a sibling stamps the version from the start.

## Output

Exit 0 prints one line of compact JSON with a fixed key order — `schema_version`, `verdict`,
`severity_counts`, `findings` — and each finding keeps only `id`, `severity`, `summary` and
`location`. Unknown keys are dropped, the version is stamped, `needs_changes` becomes `fail`, and a
count written `1.0` prints as `1`. `severity_counts` carries `info`, last after `low`, only when
the input does, so a four-key return prints the same bytes as before.

`severity_counts` are kept as given, never recomputed. When they disagree with the per-severity
tally of `findings[]` the return still passes, with `warn: count_mismatch`, so a consultant that
summarizes rather than listing every finding is not rejected. The comparison covers `info` and
reads an absent `info` count as 0. The detail adds ` info=<n>` to both lists only when the return
uses `info` (the key, or a finding of that severity). Re-validating the output yields identical
bytes, and no warnings unless the counts disagree.

## CLI

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/validate-consultant-return.sh --file <path>
bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/validate-consultant-return.sh -             # stdin
bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/validate-consultant-return.sh --self-test   # "self-test OK"
bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/validate-consultant-return.sh --help        # or -h
```

Consumers run `--file` on a saved return. Stdin is for pipes and tests: a heredoc or `echo` of
consultant output would put agent-generated text on a shell line. The input reaches `jq` as data;
nothing in it is evaluated or built into a command. Needs bash 3.2+ and jq 1.6+.

## Exit codes

| Exit | stdout | stderr |
|---|---|---|
| 0 | the normalized object | zero or more `warn: <code>: <detail>`, in the order `version_absent`, `needs_changes_normalized`, `count_mismatch` |
| 1 | empty | exactly one `reject: <code>: <detail>`; the first failing check wins |
| 2 | empty | exactly one `error: <code>: <detail>` |

Reject codes, in check order: `version_mismatch`, `missing_severity_counts`,
`invalid_severity_counts`, `missing_findings`, `invalid_finding`, `invalid_verdict`. Error codes:
`usage`, `unreadable`, `missing_dependency`, `no_json`, `unparseable`. `--help` and `--self-test`
also exit 0.

### The detail

One line: a locator, a colon, then the offending value as JSON, `absent`, or a type note such as
`not an object (array)`. Control characters are stripped and the echoed value is cut to 80
characters, so a consumer can quote the line verbatim.

```text
reject: version_mismatch: schema_version: "consultant-return.v2"
reject: missing_severity_counts: severity_counts: absent
reject: invalid_severity_counts: severity_counts: keys ["P0","P1","P2","P3"]
reject: invalid_finding: findings[1].severity: "Critical"
warn: needs_changes_normalized: verdict needs_changes normalized to fail
```

## Consumer mapping

| Result | Action |
|---|---|
| Exit 0 | Merge stdout only. Each `warn:` line becomes a note on that consultant's findings |
| Exit 1, or exit 2 with `no_json` / `unparseable` | Rejected return, the consultant's fault: take the reject path with the stderr line verbatim |
| Exit 2 with `usage` / `unreadable` / `missing_dependency` | The consumer's own call failed: fix it and rerun. Never re-dispatch, never merge |

Every attempt is saved verbatim as `.context/logs/consultant-return-<TASK>-<agent>-a<n>.md` before
it is validated. The numbered file is both the audit trail and the attempt count, so no metadata key
carries it.

### The reject path

The first reject re-dispatches the consultant once with the verbatim line; a reject on the `-a2`
return blocks the stage.

- **SR** re-dispatches its own auditor: `agents/security-reviewer.md § Consultant return`.
- **DR** holds no `Agent`, so it returns `verdict: blocked` and the orchestrator re-dispatches:
  `agents/technical-lead.md § Sibling Consultant Returns`.

## Change protocol

Changing a field, a finding key, a flag, an exit code, or a reject, warn or error code updates three
things in the same PR: this file, the validator with its bats contract
(`tests/shell/skills/validate-consultant-return.bats`), and the seam's registry entry. That PR's
description names every consumer: `agents/security-reviewer.md`, `agents/technical-lead.md`,
`skills/cross-plugin-handoff/templates/CORPFLOW.md`, and each sibling `CORPFLOW.md` copied from it.
