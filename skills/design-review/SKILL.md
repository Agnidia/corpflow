---
name: design-review
description: Use when the user invokes $design-review or asks for the canonical Corpflow design-review workflow.
argument-hint: "<screen, component, or feature> [--focus ui|ux|a11y|system] [--depth quick|standard|comprehensive]"
user-invocable: false
---

# design-review (Codex adapter)

This skill is the Codex entry point for the canonical Corpflow command.

1. Resolve the plugin root as two directories above this `SKILL.md` and treat it as
   `BASE_PLUGIN_ROOT`.
2. Read `skills/shared/codex-runtime.md` and `commands/design-review.md` from that root completely.
3. Apply the command's argument grammar, workflow, write boundaries, and output contract to the
   user's request. Translate Claude-only operations through the Codex runtime adapter.
   Done when the artifact named in the command's § Output Format exists.
4. Use `$design-review` for Codex-facing follow-ups. Do not edit the canonical command while running it,
   because the command is shared canon for Claude Code.
