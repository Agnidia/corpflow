---
name: plugin-root-resolution
---

# Plugin-Root Resolution (provider-agnostic)

**Definition**: the directory containing the Corpflow portable `plugin.json`,
`.codex-plugin/plugin.json`, or `.claude-plugin/plugin.json` manifest. Known layouts include the
Claude Code cache
`~/.claude/plugins/cache/agnidia/corpflow/<version>/` (version-keyed, so never hardcode
it); a plain git clone, where it is the repository root; or wherever another harness
installed the plugin directory.

## Canonical names

Shared Corpflow code uses `BASE_PLUGIN_ROOT` and `BASE_PLUGIN_DATA`. The mirrored
`corpflow-base.sh` utility initializes them from host inputs. Codex hooks provide `PLUGIN_ROOT` and
`PLUGIN_DATA`; Claude Code provides `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`. Do not invent a
`CODEX_PLUGIN_ROOT` variable.

## Why a host variable alone is not enough

`CLAUDE_PLUGIN_ROOT` is Claude Code-only, with two behaviors:

1. Claude Code textually substitutes the exact bare token (dollar-brace form) when it loads
   skill, command or agent content and when it parses hook `command:` strings in
   `plugin.json` / agent frontmatter.
2. It is exported as an environment variable to hook (and MCP/LSP server) subprocesses
   only, not to the model's Bash tool environment.

So the token is literal and dead whenever a subagent `Read`s a plugin file from disk, a
snippet is pasted into another prompt, or a non-Claude-Code harness consumes these skills.
Every convention below works in all three states: substituted, expanded-to-empty, and
literal prose.

## Resolution ladder

1. **`$BASE_PLUGIN_ROOT` when already initialized** — explicit host-neutral override.
2. **`$PLUGIN_ROOT` in Codex hooks**, then **`$CLAUDE_PLUGIN_ROOT` in Claude hooks**.
3. **Skill base directory, minus `/skills/<name>`** — agent-skills harnesses expose the loaded
   "Base directory for this skill: `<path>`" on load; for a corpflow skill the root is two
   levels up.
4. **Read-path derivation** — from the absolute path of a file you read, walk up to the nearest
   ancestor containing any supported manifest marker.
5. **Claude Code cache, last resort** (CC installs only):
   `ls -d ~/.claude/plugins/cache/agnidia/corpflow/*/ 2>/dev/null | sort -V | tail -1`
   — may be stale if an older version is pinned.

Validate every candidate with `corpflow_is_plugin_root`.

## Canonical executable-snippet shape (markdown)

Fenced snippets that call ungranted bundled helpers use this preamble, keeping their
existing `-f` guard and audit-deferral bodies. A script the file's frontmatter grants takes
§ Granted-script invocation shape instead:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"  # Claude Code substitutes this token when loading this file
# Empty? Substitute <plugin-root>: the dir containing .claude-plugin/plugin.json —
# two levels above this skill's base directory (see skills/shared/plugin-root-resolution.md).
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="<plugin-root>"
HELPER="$PLUGIN_ROOT/skills/<skill>/scripts/<helper>.sh"
```

## Host-boundary behavior

The snippet above is intentionally a Claude boundary because its permission matcher performs
textual substitution. Codex skill adapters instead resolve `BASE_PLUGIN_ROOT` from their own base
directory and follow `skills/shared/codex-runtime.md`.

Under Claude Code the first line is substituted and the fallback is dead code. Elsewhere
the variable expands to empty, the `-d` test fails, and the executor substitutes
`<plugin-root>` via the ladder. A placeholder pasted verbatim fails the `-f` guard: graceful
deferral, not a hard error.

## Granted-script invocation shape

### Grant

A frontmatter grant for a bundled script names the interpreter, the unquoted token and the
script path, and ends in space-star. A `.py` script takes `python3` in place of `bash`:

```
Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *)
```

#### Matching and scoped grants

- A quoted token never matches: rules match the command text, and the invocation is unquoted.
- A `$PLUGIN_ROOT` rule never matches: the variable is not in the Bash tool environment.
- Substitution in agent `tools:` is not explicitly documented (skill content, agent content
  and skill `allowed-tools` are). A grant that does not match denies the call, and the stage
  takes the permission-denied park path (`skills/worktask/SKILL.md § Step 6.5a4`).
- A fixed literal argument prefix may sit before the space-star to scope the grant to one
  subcommand, e.g. `Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --consumer *)`.
  The prefix is literal (letters, digits, `_ . , = / -` and single spaces; no `*`, `$`,
  quotes or other shell metacharacters). Never collapse it to the bare script form, which
  would widen the grant.

### Invocation

In a file whose frontmatter grants a script, every runnable mention of it (a fenced or
backticked command, or a `Run …` / `invoke …` instruction) is the grant prefix, byte for
byte, followed by the arguments:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage DR --prev DV
```

#### Forbidden, legal and exempt mentions

- Forbidden, because none can match the grant: a relative `bash skills/…` path; a bare
  `state-patch.sh --…`; `bash "$PLUGIN_ROOT/…"`; indirection through `$HELPER` or `$SCAN`; a
  quoted token; an env-prefixed command (`X=1 bash …`); an interpreter-less `skills/…/x.sh`.
- Legal: a capture such as
  `out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage DR --prev DV)`.
  Allow matching inside `$(…)` is not documented, so a capture may still prompt.
- A descriptive mention that is not an instruction to run
  ("`handoff-harness.sh check_sweep_ledger` fails when …") stays as written.
- A snippet keeps its control flow but drops the `-f` guard: `bash` exits 127 when the
  script is absent, and that exit is the deferral signal.

### On-disk references

A file read from disk is never substituted, so it carries the same literal text. The reader
replaces the token with the absolute plugin root its own loaded body shows. It does not
shell-expand the token (absent from the Bash tool environment) or fall back to a relative
path (which resolves against the working repo, not the installed plugin).

## Author rules

### Markdown token form

Markdown may contain the token only in its exact bare dollar-brace form, not the shell
default-value (colon-dash) form inside the braces: that form forfeits load-time
substitution and risks mangled output from partial matchers.

### Composed paths

A composed path (the token, a slash, then segments) breaks when the token is not
substituted, so it is legal only where arm H or arm S holds. Each occurrence is judged on
its own; every other composition, such as a `references/` doc path, is illegal.

- **Arm H — hook commands.** The path is `hooks/<name>.sh` in Claude Code-native config: the `hooks` block of `.claude-plugin/plugin.json`, `hooks:` entries in skill frontmatter, and verbatim documentation of those entries (`skills/worktask/references/handoff-protocol.md`).
- **Arm S — granted scripts.** The path is `skills/<skill>/scripts/<name>.sh` or `.py` with no `..`, and the token either follows `Bash(bash ` / `Bash(python3 ` with ` *)` right after the path, or follows `bash ` / `python3 ` at line start or after a backtick, a space, `(` or `$(` (not after `"`). The interpreter fits the extension: `bash` with `.sh`, `python3` with `.py`.

### Enforcement

`tests/shell/skills/plugin-root-refs.bats` enforces both arms and zero colon-dash forms in
`*.md`. It sources `skills/shared/scripts/grant-lint.sh` for the arm S path rule, so that
rule is defined once. `grant-lint.sh` also checks frontmatter grants and, with
`--invocations`, runnable body mentions of granted scripts.

### Prose, scripts, tests

- **Prose instructions** write helper paths plugin-root-relative (e.g.
  `hooks/megatask-monitor.sh`) followed by: "(plugin root: `${CLAUDE_PLUGIN_ROOT}` if
  available, else resolve per `skills/shared/plugin-root-resolution.md`)".
- **Shell scripts** (executed, never load-substituted) source
  `skills/shared/lib/corpflow-base.sh`, call `corpflow_init_base_paths`, and construct bundled
  paths with `corpflow_plugin_path`. The resolver uses `BASE_PLUGIN_ROOT`, `PLUGIN_ROOT`, then
  `CLAUDE_PLUGIN_ROOT`, followed by a self-location walk over all supported markers.
  `hooks/lib/corpflow-base.sh` is a byte-identical mirror, checked by
  `tests/shell/skills/corpflow-base.bats`.
- **Tests** may set or unset the env var to exercise the override and fallback contracts
  (`tests/shell/worktask/hook-install.bats`, `tests/shell/dv-screenshot/apple-canvas.bats`,
  `tests/shell/hooks/anchor-preflight.bats`).
