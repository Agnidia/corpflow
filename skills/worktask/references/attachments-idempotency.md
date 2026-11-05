# Attachments idempotency

Read when executing or checking attachments idempotency.

<!-- canonical-body:start -->
## Idempotency

Both files are overwritten on every FN run; the header comment (`worktask_id` + `ts`) carries traceability. Stages after FN do not modify them.
