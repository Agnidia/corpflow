# Script state

Read when executing or checking script state.

Procedure routing: [scripts](scripts.md).

<!-- canonical-body:start -->
# Worktask scripts — CLI reference

CLI, stdout and exit contracts of the helpers the orchestrator loop calls. Read when interpreting a helper's output or exit code. A bare `§ Step …` points into `skills/worktask/references/orchestration.md`; the `blocked_on` arm table stays there (`§ blocked-on-lib.sh — the arm table`).

## state-patch.sh — exit codes

Exits **3** (Layer-1 self-patch signature) when unresolved AND `--prev` given AND `--via` absent,
and on a missing or unknown `handoff.verdict` on any path (`ERROR: verdict refused`); otherwise
exits 0. `--allow-missing-artifact` silences that but writes **nothing**. Contract:
`skills/worktask/references/contracts/ledger-edges.md#layer-1-fallback`.

## state-patch.sh — removing a metadata key

`--task-meta <ID> --unset <key[,key...]>` deletes those keys from `tasks.<ID>.metadata`. It runs
alone or beside `--set`, after the merge and under the same lock and atomic write, so it wins over
a key the same `--set` names.

| Case | Result |
|---|---|
| The key exists | Removed; `has("<key>")` is false afterwards |
| The key is absent | No-op: exit 0, state bytes unchanged |
| A pipeline key: `stage`, `agent`, `model`, `effort`, `plan_gate`, `decision_gate`, `fn_gate`, `workspace_path`, `isolation`, `base_ref`, `requires_screenshots` | Exit 2, the key named on stderr, state unchanged. Correct it with `--set` |
| A malformed name, or `--unset` on another op | Exit 2 |

`--set '{"k":null}'` is not a delete: it stores `k: null`, and `has("k")` stays true.

## state-patch.sh — the description notice

A `description` over 240 chars is cut to 239 plus "…" on `--task-create` and `--task-meta`, and
never refused (`skills/worktask/references/state-ledger.md § description is capped at 240 chars`). After the
write lands, stderr gets one `description_truncated=<id>:<original length>` line per cut. A value
that fits prints nothing.

## permission-park.sh — CLI

```
permission-park.sh classify [--payload <json|text>] [--tool <t>] [--command <c>]   # stdin when --payload absent
permission-park.sh park     --task-id <ID> --detail <json> [--state <state.json>]
permission-park.sh batch    [--tasks <ID,ID...>] [--boundary <ID>] [--workspace-json <path>] [--state <state.json>]
permission-park.sh resume   --task-id <ID> --answer grant|manual [--state <state.json>]
permission-park.sh --self-test
```

Exit `0` success (for classify, the payload is a permission denial); `1` classify found no denial
or no recoverable tool, or park/resume had a ledger write refused or a task not parked; `2` usage
error, missing or unparseable ledger, or broken install. On the text path `--tool`/`--command` are
optional: classify recovers both from the last `Tool(...)` line at or before the classifier-denial
line. It grants nothing, writes no Claude Code configuration, and emits no retry decision.

## permission-park.sh — stdout

| Subcommand | stdout (one JSON line) |
|---|---|
| `classify` | `{"tool","command","classifier_reason","allow_rule"}` |
| `park` | `{"blocked_on":{"kind":"permission","detail":{…4 keys},"resume_with":"decision_ref"},"dedupe_key":"<16 hex>","truncated":true\|false,"audit_row_written":true\|false}` |
| `batch` | `{"mode":"ask","needs":[{"task_id","tool","command","classifier_reason","allow_rule","truncated","cwd"}…],"payloads":[{"questions":[…≤4]}]}`; megatask per-issue run: `{"mode":"megatask_park","needs":[…],"payloads":[],"park":{"boundary","execution","escalated":[{"tool","command_head","truncated"}],"workspace_written","workspace_reason","audit_row_written"}}`, `"park":null` when nothing is parked |
| `resume` | `{"resume_block":{"task_id","tool","command","answer","truncated","do_not_rerun":true,"decision_ref","instruction"},"cleared":true,"audit_row_written":true\|false}` |

## permission-park.sh — the resume audit row

`resume` appends one `permission_resumed` row per successful resume and none on a refusal:
`actor: "orchestrator"`, `subject: <task_id>`, `result: "ok"`,
`metadata.{tool, dedupe_key, command_head, truncated, answer, decision_ref}`. `decision_ref` is
`permission_resumed:<task_id>:<dedupe_key>:<n>`, where `n` is 1 plus the earlier rows with that
subject and key. It is the record `blocked_on.resume_with: decision_ref` points at, and it comes
back as `resume_block.decision_ref` (§ Step 7a). The row never holds the command:
`command_head` is the redacted head every committed row carries (at most 4 tokens, masked,
path-scrubbed, at most 120 characters), `truncated` marks a head showing less than the whole
command, and an unavailable scrub gives `[redacted]` with `redaction: "scrub_unavailable"`. `resume_block.truncated` is a different flag:
the stored command was cut at 512 characters.
