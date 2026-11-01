---
name: estimate
description: Use when the user invokes $estimate or asks for the canonical Corpflow estimate workflow.
argument-hint: "[\"<task description>\"] [--quick|--detailed] [--stages] [--sequential] [--compare \"<opt1> | <opt2>\"] [--multiplier <hours>] [--ai-rate <amount>] [--dev-rate <amount>] [--no-review] [--review [--focus <areas>] [--update]] [--export csv [--dir <path>] [--delimiter <char>] [--validate]] [--platform <p>]"
user-invocable: false
---

# estimate (Codex adapter)

This skill is the Codex entry point for the canonical Corpflow command.

1. Resolve the plugin root as two directories above this `SKILL.md` and treat it as
   `BASE_PLUGIN_ROOT`.
2. Read `skills/shared/codex-runtime.md` and `commands/estimate.md` from that root completely.
3. Apply the command's argument grammar, workflow, write boundaries, and output contract to the
   user's request. Translate Claude-only operations through the Codex runtime adapter.
   Done when the artifact named in the command's § Output Format exists.
4. Use `$estimate` for Codex-facing follow-ups. Do not edit the canonical command while running it,
   because the command is shared canon for Claude Code.
