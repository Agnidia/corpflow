# PL artifact rules

Read before writing or validating the PL stage artifact.

<!-- canonical-body:start -->
#### rejection_reason — after a plan-gate rejection

After a plan-gate rejection, the revised `planning-N.md` sets `rejection_reason:` to the user's gate feedback (verbatim or condensed) — distinct from the plan's `## summary` narrative — so downstream stages and ST retrospectives can cite it without reconstructing it from `audit.jsonl`. Omit the field on a first, un-rejected draft.
