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

- Deny and ask rules hold through an environment-variable prefix with an expanded value (`TZ="$HOME" rm -rf build`), a bare assignment before the command under sandbox auto-allow, and a command or path named by a variable set on `declare`, `typeset`, `export` or `readonly`. These prompt instead of auto-approving: variable names zsh reads differently from bash, read-only commands (`rg`, `git grep`) whose arguments the shell still expands as wildcards, more forms of `ps`, and `pyright`.

### Permission rules — enforcement notes

- Review explicit MCP server wildcards: a tools list does not admit neighboring servers with similar names.
- PreToolUse and PermissionRequest `updatedInput` is validated against the tool schema.
- A hook that permits a write cannot override plan mode.
- A session's exact Bash ask rule is refused, not asked, when a broader deny covers the command. `which` with unusual flags asks.
- `rm -r` of a mount root such as `/Volumes` gets the safety prompt. `sed -i` gets the standard Bash prompt and is not undone by `/rewind`.

### Read denies and protected-file writes

- `Read` deny rules and the outside-directory read block also cover files reached through a symlink by an @-mention or IDE selection, a link swapped in mid-read, pasted or dragged image paths, the file names listed for an @-mentioned folder, and wildcards in option values of read-only Bash commands.
- PreToolUse hook approvals and auto mode still prompt for reads from network (UNC) paths.
- `permissions.blockWritesOutsideWorkingDirectories` makes Write, Edit and NotebookEdit refuse paths outside the working directories in every mode.
- Deny rules and protected-file prompts apply to the file that `cp` or `mv` (including `/bin/cp` and `/bin/mv`) writes into a directory.
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
- Repository `.claude/settings.json` and `.claude/settings.local.json` cannot set `CLAUDE_CODE_DISABLE_ATTACHMENTS` or turn Claude in Chrome on; project settings cannot widen or turn off an admin-required sandbox, replace the proxy behind a managed deny list, extend a strict allowlist, or reopen managed read-denies.
- `CLAUDE_CODE_DISABLE_WEB_FETCH` removes the WebFetch tool.
- A reply sent from `claude agents` to a session waiting on a permission prompt never approves the pending command; a repeated `--channels` reply ID is ignored; a respawned background worker honors `--allow-dangerously-skip-permissions` only after the bypass disclaimer was accepted.

### Settings scope — read-denies, auto mode and trust

- A managed sandbox read-deny path that appears or re-points mid-session drops project grants inside it and ends credential injection from files it covers.
- Keep explicit permission ceilings: print sessions from third-party providers can default to the CLI's default mode.
- Auto mode with telemetry or feature flags off asks or denies the calls the server cannot check; there is no fallback classifier. A project's settings or a plugin cannot turn the server-side check back on after the user turned it off outside the project.
- `--add-dir` registers marketplaces only after that folder's trust dialog.
- A check asks before a shell command that holds the account email and names a User-Agent sends it to the network.

## Sandbox

| Setting | Effect |
|---------|--------|
| `sandbox.network.strictAllowlist` | Denies non-allowlisted hosts for sandboxed commands without prompting. Prefer for unattended batches — a prompt in an unattended run is an indefinite stall |
| `sandbox.filesystem.disabled` | Skips filesystem isolation but keeps network egress control. Narrow escape hatch: requires a documented justification, never set to silence a failing command |
| `--restricted` / `CLAUDE_CODE_RESTRICTED=1` | Removes the built-in tools that run commands or code plus `WebFetch` (unless named in `--tools`), keeps file tools inside the working directory, refuses `bypassPermissions`, ignores user, project and local settings files, and opens no cross-session messaging socket. The strongest posture for untrusted or third-party plugin content; too restrictive for a normal worktask, since no stage could build or test |

Sandbox rules that need no setting:

- Sandboxed commands cannot edit the `--mcp-config` file, and shell startup files run inside the sandbox.
- Sandbox protections apply to a worktree entered by `claude -p --resume` or `--continue`.
- Worktree-isolated sessions refuse locale-prefixed and zsh arithmetic commands, and ignore git replace refs.
- A read-only Bash command does not run outside the sandbox without a prompt.

## Plugin and marketplace paths

A plugin component path (command, agent, skill, hooks, other) that is a symlink, contains a
backslash, or points outside the plugin directory is refused as path traversal; fetched marketplace
entry paths get the same check. This repo is both a marketplace and the plugin it publishes, so every
`commands[]`, `agents[]` and `skills[]` entry in `.claude-plugin/marketplace.json` stays
`./`-relative — no `../`, absolute path, or external URL.
