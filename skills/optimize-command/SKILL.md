---
name: optimize-command
description: Use when the user invokes $optimize-command or asks for the canonical Corpflow optimize-command workflow.
argument-hint: "<command-file> | --all [--focus <area>] [--dry-run] [--report]"
user-invocable: false
---

# optimize-command (Codex adapter)

This skill is the Codex entry point for the canonical Corpflow command.

1. Resolve the plugin root as two directories above this `SKILL.md` and treat it as
   `BASE_PLUGIN_ROOT`.
2. Read `skills/shared/codex-runtime.md` and `commands/optimize-command.md` from that root completely.
3. Apply the command's argument grammar, workflow, write boundaries, and output contract to the
   user's request. Translate Claude-only operations through the Codex runtime adapter.
   Done when the artifact named in the command's § Output Format exists.
4. Use `$optimize-command` for Codex-facing follow-ups. Do not edit the canonical command while running it,
   because the command is shared canon for Claude Code.
