# DC artifact rules

Read before writing or validating the DC stage artifact.

<!-- canonical-body:start -->
#### Security and networking claims cite their evidence (tpl-dc)

Any security or networking claim in payload documentation names the stage and the evidence that
verified it — a probe, a config line, a test — or it does not ship. "Binds to loopback", "requires
auth", "no credentials at rest" are all claims of this class.

Prefer a claim that carries its own falsifier: documentation that ships the command proving it
cannot drift from the system silently. A claim with no cited evidence is DC asserting something no
stage established, and it will be believed.

#### Under fan-out, DC reads a tree that does not exist yet (tpl-dc)

In fan-out mode each DV row lands in its own tree, so a cross-stream claim — a path, a command,
an integration — describes an assembled tree DC cannot see, and may be right even though DC's tree
lacks it.

Mark every cross-stream claim `consistency-checked, not executed`, naming what was compared and why
execution was impossible. An unmarked claim reads as verified, so DC's verdict would carry a
confidence its evidence does not support.

#### DC runs the option-existence gate before handoff (tpl-dc)

Before handoff DC runs `doc-option-check.sh` (`skills/worktask/scripts/`) over every documentation
file it wrote or edited, with one `--tree` per assigned tree: `metadata.workspace_path`, plus each
worktree the dispatch names. The script checks two things. Every documented env var and long flag
must appear in a tracked or untracked, not-ignored file of some tree, the docs under check and
`.context/` excluded. Every link target and backticked relative path must resolve inside a tree and
exist. It prints one JSON line per finding and exits 0 clean, 1 on a finding, 2 on bad usage, 3 when
a tree or doc cannot be read.

Exit 1 is a gate failure, not a warning, and neither 2 nor 3 is a pass. `--allow` suppresses a name
the host sets, and each use names that host in `documentation-N.md`. The steady-path steps live in
`agents/technical-writer.md § Option-existence gate (DC2)`.

#### DC exempts a runtime path with --allow-path (tpl-dc)

`--allow-path <path>` suppresses a `missing` path finding at that tree-relative path or below it, for a path the code creates at run
time. The value must not be empty, `.`, absolute, or hold `..`. Each use records the creating
`file:line` or the `.gitignore` line in `documentation-N.md`. DC uses it after one failed fix
attempt, never deletes a correct claim to quiet the check, and runs the gate at most 3 times per doc
set.

#### DC scopes CHANGELOG.md and skips vendored docs (tpl-dc)

The gate reads a `CHANGELOG.md` only from its `## [Unreleased]` heading to the next `## ` heading.
With no `[Unreleased]` heading it gives no finding. `--exclude <path>` skips a vendored doc at that
tree-relative path or below it, with the same value rules as `--allow-path`. Each use records the
path and the reason in `documentation-N.md`.
