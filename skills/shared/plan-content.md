---
name: plan-content
version: 0.1.0
---

# Plan Content

What a planning artifact carries before any code exists. The stages and skills in § Who applies it
cite the H2 headings below by name and never restate them, so a heading rename is a change to every
pointer.

## Rule — decisions, not a transcript

A plan is the set of decisions the implementer cannot make alone: which files, which names and
signatures, which values from the spec, which tests prove each unit of work.
A plan longer than the code it describes has written the code instead. It is a transcript of the
code, not a plan, and the implementer pays for the code twice.

Write for a capable engineer who has not seen this codebase or this spec. Given the exact interface
and the exact test, they write idiomatic code and make a reasonable choice wherever the plan leaves
one open. Size each step as one action with a checkable result.

### What counts as a step

A step is whatever unit the artifact hands DV to act on: a requirement with its acceptance
criterion, a design decision, a stream's task, a request-plan phase. The spec is what the stage
plans from: the issue or goal for PL, `planning-N.md` for AR and TL, the request for request-plan.

### Why decisions, not code

A planner that writes the bodies does DV's work before anyone has reviewed the design, and the
interface and tests it should have pinned are all an implementer needs to produce the same code.

## Step kinds

Each kind carries what makes it unambiguous, and nothing more.

| Step kind | Carries | Leaves to the implementer |
|---|---|---|
| Test | The test's name and its assertions, with the spec's exact values in them | Setup and fixtures |
| Code | The exact signature (name, parameters, return type), the file it lives in, the values the spec pins | The body, unless the signature and tests leave the algorithm open or the spec fixes exact copy |
| Verification | The command to run and the output that means it passed | Nothing |
| Cross-task reference | A pointer to that task's interface block: a TL stream's interface contract, AR's schemas | That task's code, which the plan does not repeat |

## Placeholders — the opposite failure

A line that decides nothing leaves a gap the implementer fills by guessing, which is not brevity:
`TBD`, "handle edge cases", "add appropriate validation", "write tests for the above", or a type or
function no step defines. Replace each with the decision it stands in for, or delete it.

## Self-review

Run both checks on the finished artifact before the handoff, and fix what they find in place. Done
when every step passes the step scan and the proportion check finds no transcript.

### Step scan

For each step, ask whether the implementer can write exactly one reasonable thing from it. A line
that decides nothing is a gap (§ Placeholders — the opposite failure); a body the signature and
tests already determine is a transcript. Fix both.

### Proportion check

Count the fenced lines that are function or type bodies. Verification commands and byte-exact
expected output are step content, not bodies. A plan whose bodies are most of the document is a
transcript. When the spec is a written document (an issue body, a PRD, `planning-N.md`) rather than
a one-line goal, also compare lengths: a plan several times longer than its spec is a transcript.
Replace the bodies with signatures, test names and assertions, then re-run the step scan to confirm
every step is still unambiguous.

## Who applies it

| Stage or skill | Its artifact names | Pointer site |
|---|---|---|
| PL | Requirements, acceptance criteria with the spec's values, scope | `skills/worktask/references/planning-artifacts.md § Plan content — decisions, not code`; `product-manager.md § What a plan records` |
| AR | Files, signatures, schemas, decisions | `software-architector.md § What a design records` |
| TL | Each stream's interface contract | `team-lead.md § File Ownership Rules` |
| request-plan | Phases, with the files and interfaces each fixes | `request-plan/SKILL.md § Key reuse — do not reinvent these` |

### Who writes the bodies

DV writes every implementation body. This rule does not override `pl0-procedure.md § Exact-output
criteria are byte-exact`: an exact-output rule is a value the spec pins, so its bytes stay in the
plan verbatim.
