# Claude Code Hardening

Read when the diff touches Claude Code configuration — permission rules, `settings*.json`, hooks,
sandbox settings, plugin or marketplace manifests, agent `tools` grants — or when the worktask runs
unattended (`/megatask`, `--auto=[finalization]`) or on a shared runner.

## Permission rules

Flag: bash bypass patterns, compound-command injection (`&&`/`||`), env-var prefix bypasses
(`FOO=bar cmd`), `/dev/tcp` redirects, unscoped wildcard allow rules (`Bash(*)`, `Read(*)`),
deny-rule precedence, subagent permission scope, LSP `which` fallback injection. Scoped wildcards
match correctly and are legitimate — don't flag `WebFetch(domain:*.example.com)` subdomain rules or
mid-pattern file rules like `Read(secrets-*/config.json)`.

### Rule syntax

- Single-segment `dir/**` allow rules and hook `if:` conditions are cwd-anchored — they match only `<cwd>/dir`; any-depth needs `**/dir/**`. `deny`/`ask` rules keep any-depth matching.
- `Write(path)`/`NotebookEdit(path)`/`Glob(path)` rules trigger a startup warning — those tools take no path predicate the way Edit/Read do; recommend `Edit(path)`/`Read(path)`.
- A `!`-prefixed deny or ask rule applies only within the settings source that wrote it; a bare `!` negation is ignored.
- A permission rule containing a NUL byte matches nothing.

### Bash matching

- A Bash rule with a mid-pattern `:*` (`Bash(git -C:* push)`) is honored from every source, settings files included, with a startup warning on how it matches; `autonomy-preflight.sh` reads it as a bare `*`, so a deny or ask rule of that form fails the check it could match.
- The file a Bash `tee` writes is checked against `Edit()` deny rules and the write-path check; a `Bash(tee:*)` allow rule does not cover destinations outside the working directories.
- Deny and ask rules on symlinked directories (`/etc`, `/tmp`, `/var` on macOS; `/bin` on Linux) apply by real path, and Bash honors deny rules written on the symlinked spelling.
- Bash analysis fail-closes on FD redirects, commands over 10k characters, zsh subscripts in `[[ ]]`, unsafe `help`/`man` forms, and arithmetic assignment to an integer variable (`OPTIND=1`, `RANDOM=2+2`). Extra ask prompts there are the detection working, not a regression.

### Bash matching — prefixes and new prompts

- Deny and ask rules hold through an environment-variable prefix with an expanded value (`TZ="$HOME" rm -rf build`), a bare assignment before the command under sandbox auto-allow, and a command or path named by a variable set on `declare`, `typeset`, `export` or `readonly`. These now prompt instead of auto-approving: variable names zsh reads differently from bash, read-only commands (`rg`, `git grep`) whose arguments the shell still expands as wildcards, more forms of `ps`, and `pyright`.

### Read denies and protected-file writes

- `Read` deny rules and the outside-directory read block also cover files reached through a symlink by an @-mention or IDE selection, a link swapped in mid-read, pasted or dragged image paths, the file names listed for an @-mentioned folder, and wildcards in option values of read-only Bash commands.
- PreToolUse hook approvals and auto mode no longer skip the prompt for reads from network (UNC) paths, and a notebook or PDF read can no longer return an unapproved file through a link swapped mid-read (2.1.292).
- A whole-tool `Bash` allow rule or an allowing hook prompts for, and does not run, a shell write to a file the file tools refuse outright (the Anthropic profile store, the host credentials file).

## Settings scope

- Project `.claude/settings.json` and `.claude/settings.local.json` cannot start a session in bypass (`defaultMode: "bypassPermissions"` is ignored there; only user or managed settings or `--permission-mode` can), enable detailed beta tracing or raw API body logging, bypass an OTLP collector pinned by managed settings, or set `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_TMPDIR`, or `TMPDIR`/`TMP`/`TEMP` through `env`.
### Settings scope — telemetry, permission mode and managed rules

- Project and local settings also ignore OpenTelemetry variables that turn on export, set its endpoint, or capture content (`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOG_*`); a startup notice, `/status` and `claude doctor` list the ones ignored.
- An interactive terminal or VS Code session with no permission mode configured starts in auto mode; `permissions.defaultMode` still overrides it.
- Under managed `allowManagedPermissionRulesOnly`, `allowed-tools` pre-approval is dropped for repository, user and `--add-dir` skills and commands, skills-directory plugin manifests, and plugins from marketplaces, claude.ai and npm. Only plugins from an official Anthropic source, or a source managed settings vouch for, keep it; every other skill's tool calls go through the managed rules.
### Settings scope — MCP allowlists and read boundaries

- A managed MCP allowlist `${VAR}` resolves from the startup environment and managed-settings env, not the settings-file env; a settings-file variable does not expand there.
- `permissions.blockReadsOutsideWorkingDirectories` blocks file reads outside the working directories (auto mode asks once before the first); sandboxed git still sees the user's git config and a worktree-isolated subagent still sees its own checkout. A project `CLAUDE.md`, rule or `AGENTS.md` symlinked outside the working directories does not load under it or under a matching `Read` deny rule.

### Settings scope — managed policy and repo-settable keys

- Managed `allowedProviders` limits the API providers a machine may use. A managed settings file that links outside the managed folder triggers a warning, and `/status` and doctor warn when managed settings ignore user sandbox `allowRead` paths or allowed domains.
- Repository `.claude/settings.json` and `.claude/settings.local.json` can no longer set `CLAUDE_CODE_DISABLE_ATTACHMENTS` or turn Claude in Chrome on; project settings cannot widen or turn off an admin-required sandbox, replace the proxy behind a managed deny list, extend a strict allowlist, or reopen managed read-denies.
- `CLAUDE_CODE_DISABLE_WEB_FETCH` removes the WebFetch tool.
- A reply sent from `claude agents` to a session waiting on a permission prompt never approves the pending command; a repeated `--channels` reply ID is ignored; a respawned background worker honors `--allow-dangerously-skip-permissions` only after the bypass disclaimer was accepted.

### Settings scope — policy cache and mode exits

- A tampered on-disk cache of server-managed settings can no longer switch off or unseat the built-in policy plugin while the settings fetch fails (2.1.292).
- A skill's or slash command's `allowed-tools` rule no longer comes back in a later turn after the session leaves auto or plan mode partway through that turn (2.1.292).
- A managed sandbox read-deny path that appears or re-points mid-session now drops project grants inside it and ends credential injection from files it covers (2.1.292).

## Sandbox

| Setting | Effect |
|---------|--------|
| `sandbox.network.strictAllowlist` | Denies non-allowlisted hosts for sandboxed commands without prompting. Prefer for unattended batches — a prompt in an unattended run is an indefinite stall |
| `sandbox.filesystem.disabled` | Skips filesystem isolation but keeps network egress control. Narrow escape hatch: requires a documented justification, never set to silence a failing command |
| `--restricted` / `CLAUDE_CODE_RESTRICTED=1` | Removes the built-in tools that run commands or code plus `WebFetch` (unless named in `--tools`), keeps file tools inside the working directory, refuses `bypassPermissions`, ignores user, project and local settings files, and opens no cross-session messaging socket. The strongest posture for untrusted or third-party plugin content; too restrictive for a normal worktask, since no stage could build or test |

## Plugin and marketplace paths

A plugin component path (command, agent, skill, hooks, other) that is a symlink, contains a
backslash, or points outside the plugin directory is refused as path traversal; fetched marketplace
entry paths get the same check. This repo is both a marketplace and the plugin it publishes, so every
`commands[]`, `agents[]` and `skills[]` entry in `.claude-plugin/marketplace.json` stays
`./`-relative — no `../`, absolute path, or external URL.

## Claude Code 2.1.295–2.1.303 hardening

The 2.1.303 floor includes late-registered tool restriction enforcement (2.1.295), protection against sandbox writes
to reloadable `--plugin-dir` code (2.1.299), safe-mode persistence on restart, and managed hook/MCP policy enforcement.
Review explicit MCP server wildcards: tools lists no longer admit neighboring servers with similar names.
PreToolUse and PermissionRequest `updatedInput` undergo tool-schema validation from 2.1.300.
A hook that permits a write cannot override plan mode (fixed in 2.1.299).
The Read tool refuses image sources above 128 MB and avoids reading image-named pipes/devices wholesale (2.1.302).
Keep explicit permission ceilings; third-party print sessions can default to the CLI's default mode from 2.1.302.
