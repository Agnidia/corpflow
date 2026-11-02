---
name: arch-review
description: Use when the user invokes $arch-review or asks for the canonical Corpflow arch-review workflow.
argument-hint: "[--pr <number> | --path <dir>] [--scope full|focused] [--checklist]"
user-invocable: false
---

# arch-review (Codex adapter)

This skill is the Codex entry point for the canonical Corpflow command.

1. Resolve the plugin root as two directories above this `SKILL.md` and treat it as
   `BASE_PLUGIN_ROOT`.
2. Read `skills/shared/codex-runtime.md` and `commands/arch-review.md` from that root completely.
3. Apply the command's argument grammar, workflow, write boundaries, and output contract to the
   user's request. Translate Claude-only operations through the Codex runtime adapter.
   Done when the artifact named in the command's § Output Format exists.
4. Use `$arch-review` for Codex-facing follow-ups. Do not edit the canonical command while running it,
   because the command is shared canon for Claude Code.
