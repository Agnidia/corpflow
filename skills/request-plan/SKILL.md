---
name: request-plan
description: Use when the user asks for a plan, an approach, a breakdown, "how would you tackle this", or scoping — even without the word "plan". Turn a free-form request into a context-aware plan (goal, scope, phases, effort, risks) and recommend `/worktask`.
argument-hint: '"<request>" [--save]'
version: 0.5.0
user-invocable: false
---

# Request Plan

> **Codex host:** read `skills/shared/codex-runtime.md` and keep
> `commands/request-plan.md` as the canonical workflow; recommend `$worktask` in the final handoff.
> Claude Code continues to receive `/worktask`.

Produce a lightweight, grounded plan from a free-form request plus current repository context, then
hand off to the worktask system — lighter than a PRD (`/product-requirements`), broader than a
sizing estimate (`/estimate`).

The value is being grounded: the plan reflects this repo (in-flight work, recent commits, project
memory, relevant code), not a generic template. Read context before planning and let it change the
plan.

## Workflow

### 1. Restate the goal

State the goal in one line, in your own words, so the user can correct a misread cheaply.

#### Ask or plan — decide once, and default to planning

Asking is the exception. The first test — *did the search find the surface?* — is applied in § 2,
where the evidence arrives. What is left here, in order:

1. **No surface at all? Ask — and only ask.** Available once § 2's search has run and found
   nothing. Say so plainly and ask which system is meant. Don't produce a full plan for a codebase
   you cannot see: plausible phases for a system nobody can point at read as real work and are not.
2. **Surface found, but two readings of it change the phases? Fold it into the plan.** They
   usually become P0 and P1, or an explicit **Out:** line. Present the plan and name the
   assumption. This branch needs a surface to be ambiguous *about* — a request whose subject the
   repo does not contain belongs to branch 1.
3. **Genuinely incompatible readings, or no subject named? Ask 1–2 focused questions.**

##### Never both

Emit either a question or a full plan for one request, not both. Don't invent scope to fill
silence; a wrong assumption propagates into every later section, but so does a needless question.

### 2. Gather context (lean)

Follow `references/context-gathering.md`. Read only what could change the plan: existing
`.context/` artifacts, project memory, recent git activity, and the code the request touches.

#### Start from what already ships

Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/request-plan/scripts/capability-registry.sh` first, every
time, before any grep — not only for "I want X" requests, because deciding whether a request is
about a capability is itself a guess made before you know the answer. It is the complete inventory
of this plugin's commands, agents, skills, hooks, skill scripts and harness modules, so it is not a
search and has no stop condition. Read it in one pass: the entry you need is the one whose
*description* matches, and a skim finds only the ones whose path does.

The request words a *need*; the registry words a *domain* — "make the app usable one-handed" will
never share a word with the entry that covers it. Read each description for what the capability
*does*, not for words the request happens to repeat.

##### No worked examples here

Deliberately omitted: an example concrete enough to help is a request someone
will later evaluate this skill against, and printing its answer beside it turns the case into a
lookup.

##### The registry precedes the search, never replaces it

A registry hit tells you which surface the work belongs to — you still open that surface and read
it before planning against it, and § "Search by behaviour" below still applies to everything the
registry does not list: a skill's `references/`, the shared canon under `skills/shared/*.md`, and
test or eval infrastructure.

##### A hit changes the plan's content, not its obligations

Finding an adjacent, partial or underlying capability makes the plan about *using, verifying, or
extending* it. It does not license a short answer: the full template still applies, and the plan
still ends with exactly one `/worktask` line (§ 4). "This already ships, run `/x`" with no trigger is
a failure, not a shortcut — the three ways this goes wrong are ending with a question instead of a
plan, recommending another command *in place of* the handoff, and dropping the trigger because
nothing seems left to do. The one exception is § 4's, and it is narrow.

#### Decide which class owns the behaviour

A behaviour in this plugin lives in exactly one of six classes: a **command**, an **agent**, a
**skill**, a **hook**, a skill's **`scripts/`**, or a **harness module**. The registry enumerates all
six, but the classes are the shape of the search even for what it cannot list — a skill's
`references/`, the shared canon, and test or eval infrastructure all sit behind one of the six.

A search that has not decided which class owns the behaviour has not finished. Naming the class is
the cheapest way to notice you only looked in one: three of the six are executable and none of them
are found by grepping prose.

#### Search by behaviour, not by filename

The commonest graded failure: the search stopped at a file whose *name* fit, in the first directory
that hit, while the file owning the behaviour sat in another subtree. "Lean" governs how much you
read, never how hard you look.

- **Use `Explore` for every "where does X live" question.** A grep sweep anchored on a guessed
  filename only reproduces the guess.
- **Search for what the code does, not what it would be called.** Grep the symbols, strings, and
  error text the behaviour must produce. A filename is a hypothesis; a matching symbol is evidence.
- **One hit is not a finding.** Continue until a repo-wide search for the behaviour turns up nothing
  further, or until you hold two candidates — then open both and decide which owns it.

#### When you may stop searching

Stop on evidence, not on satisfaction: when you can name the owning file and say what in it you
read. "More reading wouldn't change the plan" is not a stop condition — a search that has not
reached the right file cannot tell that from the inside, which is how a confident plan ends up about
the wrong module.

§ 1's "no surface at all" branch is available only after this search has actually run. Asking
which system is meant is right when the repo genuinely lacks it, wrong as the exit from a search
that got hard.

#### Confirm ownership before planning against a file

Open the file you found and check that it owns the behaviour, rather than inferring ownership from a
plausible name. A neighbouring file with a similar name is the most common way a plan ends up
specific, confident, and about the wrong thing. If you cannot confirm ownership, name the file you
believe owns it and say you did not verify.

#### Found the surface? Plan it

The registry or the search located the file, command, hook or mechanism the request is about? That
is enough to plan, even if a follow-up question also comes to mind. A question you could have
answered by planning costs a round trip and delivers nothing.

#### Do not assert what you did not check

Every negative claim carries its own scope. "No other path exists", "that mapping is already
complete", or a count of things you did not enumerate are the claims most likely to be wrong and
least likely to be questioned, because they sound like the product of a search.

Name the directories you actually enumerated and scope the sentence to them — "nothing under
`tests/`", never "nothing anywhere". An unscoped negative is a claim about the whole repo and needs
a whole-repo search behind it; a negative scoped to where you looked is true and still useful.
Whatever the scope does not cover is unverified, so say so.

### 3. Synthesize the plan

Fill the template in `references/plan-template.md` exactly (fixed section order).

#### Key reuse — do not reinvent these

- **Phases** use the P0 Required / P1 Nice-to-have / P2 v1.1 model from
  `skills/shared/three-stage-planning.md`, each independently deliverable. All three rows always
  appear: with nothing deferrable, write `P2 — v1.1: none` — dropping the row reads as an
  oversight. Any follow-up you name anywhere in the plan belongs in P1 or P2; folding it into P0
  hides that it is deferrable and collapses a three-phase plan to one.
- **Tests live inside each phase's scope**, never as a separate phase (per the estimation skill).
- **Phase scope names decisions, not code**: the files, interfaces and spec values each phase
  fixes, per `skills/shared/plan-content.md § Rule — decisions, not a transcript`. The worktask's
  DV writes the bodies.

##### Effort

A T-shirt size plus the factor score (0–25, 5 factors) from
`skills/estimation-methodology/SKILL.md`, as a range — a rough cut, not a budget. Both parts are
required for every request type, incidents included: a severity or priority table is not an effort
estimate and does not replace one. Naming the factors behind a surprising score helps, but the size
and the number are what the section owes.

### 4. Recommend the handoff

Follow `references/handoff.md`. Map size + factor score to an invocation with the canonical Worktask
Tier Selection logic in `skills/estimation-methodology/SKILL.md`, and emit one ready-to-paste
command line (e.g. `/worktask "<restated goal>"`). The surface check in that section decides
`--secure` and `--emergency` before size is considered.

Recommend the leanest tier the surface check allows: sizing ratchets one way once the worktask
runs, so a stage that finds a surface this plan could not see adds itself back through
`skills/estimation-methodology/SKILL.md § Mid-run re-sizing`, and nothing downgrades.

#### Exactly one `/worktask` line

Every plan ends with exactly one `/worktask` line. Naming a more specific command (`/estimate`) is
useful context alongside the trigger, never a replacement — recommending one *instead* of the
worktask leaves the user with no handoff.

Disputing the premise does not suspend the line. A plan concluding the reported defect is
misdiagnosed, unreproducible, or absent from the file it was blamed on still emits one — triage is
work, and on a present-tense report `--emergency` is the tier that triages it. Prose naming the tier
("route this to incident response") is not the line; the line is a command the user can paste.

"Absent from the file it was blamed on" bounds this to a file that exists whose defect sits
elsewhere. A request whose *subject system* the repo does not contain is § 1's "no surface at
all" branch instead, and § 1 wins: ask, emit no line.

##### One narrow exception: asked to build what already exists, with nothing left

All three must hold: the request asks to **build, add or fix** something; the search shows it
already exists in the form asked for; and **nothing remains to be done**. Then say so, cite where,
and stop — no plan template, no trigger. Rendering the sections anyway (a Scope for work that
exists, a P0 reading "run the command") is a build plan wearing a refutation's opening line.

##### Two shapes that resemble that exception and are not it

###### Asked to find, reach or use a capability

"How do I…", "I want X", "where does X live" — the surface existing is the *answer to the search*,
not a reason to withhold the plan. Plan the using, verifying or extending of what you found, and end
with the trigger (§ 2). A found surface makes the plan shorter and better grounded; it never makes
the plan optional.

###### A shipped premise with a live remainder

The headline capability shipped, but the search finds something genuinely still missing or broken.
Refute the stale premise *and* plan the remainder — the refutation replaces the wrong plan, not the
plan. Say plainly which part is stale and which is still open.

The test is always whether anything remains to be done. A misdiagnosed bug still needs triage; a
request to *use* a shipped feature still needs a plan; a shipped feature with nothing left does not.

### 5. Output

Print the plan inline; the default is not to write files. Offer to persist it to
`.context/request-plan-0.md` (naming per `skills/task-folder-organization/SKILL.md`) when the user
wants it kept or it will directly seed a worktask run.

## What this skill is not

- Not a PRD generator — formal requirements, user stories, and acceptance criteria at scale route to
  `/product-requirements`.
- Not a budget/CSV estimator — hours, rates, and exportable sizing route to `/estimate`.
- Not a roadmap — multi-quarter planning belongs in `/roadmap`.

Staying lightweight is the point; resist padding the output toward those heavier formats.

## Reference files

| File | Read when |
|------|-----------|
| `references/context-gathering.md` | Step 2 — which sources to read, in priority order |
| `references/plan-template.md` | Step 3 — the exact output structure to fill |
| `references/handoff.md` | Step 4 — mapping effort to a worktask trigger |
