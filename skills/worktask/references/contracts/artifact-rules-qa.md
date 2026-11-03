# QA artifact rules

Read before writing or validating the QA stage artifact.

<!-- canonical-body:start -->
#### QA summary lines take the tpl-dv checks (tpl-qa)

Every QA `tests_executed` entry takes the `skills/worktask/references/contracts/test-evidence.md#summary_line-is-the-checked-half-tpl-dv` checks, the strict-runner fail
included. A `gradle*` or `junit*` entry quotes the `junit-tally.sh` line
(`skills/worktask/references/contracts/test-evidence.md#gradle-and-junit-quote-the-junit-tally-line-tpl-dv-tpl-qa`).

#### An unverified security claim in shipped docs is a finding (tpl-qa)

A security or networking claim in payload documentation that QA did not verify is a finding,
recorded in `key_decisions` and reflected in the verdict. "The README says it binds to loopback" is
a claim about the artifact, not about the system, and such claims have passed developer review
while false; only a live probe caught them.

Ask for the claim to carry its own falsifier — for example, the `lsof` command that would disprove
a loopback-binding claim — so it cannot drift from the system and checking it costs one command.
