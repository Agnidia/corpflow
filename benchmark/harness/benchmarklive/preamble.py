"""Production-faithful stage-prompt assembly (REQ-1).

assemble_stage_prompt is PURE (inputs → str, no I/O). Marker literals are
byte-identical to cache-lint.sh so a captured live prompt-log lints with the
production prefix_lint. Layout: [1] contract-reminder (byte-stable all stages),
[2] worktask-header (byte-stable all stages), [3] state.json (per stage),
[4] stage-contract (byte-stable within stage), [5] task (dynamic per delegation).
"""

from __future__ import annotations

from typing import Optional

MARK_CONTRACT = "<<<contract-reminder>>>"
MARK_HEADER = "<<<worktask-header>>>"
MARK_STATE = "<<<state-json>>>"
MARK_CONTRACT_STAGE = "<<<stage-contract>>>"
MARK_TASK = "<<<task>>>"

# [1] contract-reminder — byte-identical for EVERY stage of EVERY worktask.
#
# Deliberately silent on how a stage is recorded in state.json. The prompt is shared
# by both arms, so any shape named here reaches the plugin-free WITHOUT arm too, and
# the one it used to name (`stages.<CODE>`) is not the ledger's: the WITH arm's bound
# agent closes its task through state-patch.sh and hand-edited that map instead.
# Nothing in the harness reads stage completion from either arm's state.json.
CONTRACT_REMINDER = (
    "You are a stage agent inside a corpflow staged worktask. Binding contract:\n"
    "1. Read your required inputs from .context/ (paths per the task metadata).\n"
    "2. Produce your stage artifact at the required .context/ path; the first\n"
    "   block MUST be YAML frontmatter (`---` / `handoff:`) per your stage\n"
    "   template, and the body MUST use the mandatory kebab-case H2 anchors.\n"
    "3. On unrecoverable failure: append a classified entry to your\n"
    "   .context/errors/<agent>.md and set verdict blocked/escalate — never\n"
    "   fabricate results.\n"
    "4. Write only files your stage owns. No commit/push unless your contract\n"
    "   says so. Never print or commit secrets.\n"
    "5. Return a concise handoff summary (verdict, key decisions,\n"
    "   next_stage_focus) as your final message."
)

# [4] stage-contract — per-stage-type verbatim excerpt, keyed by stage code.
STAGE_CONTRACT = {
    "PL": ("STAGE PL (Planning). Artifact: .context/planning-0.md. "
           "Anchors: ## requirements, ## acceptance-criteria, ## scope, "
           "## out-of-scope, ## risks, ## complexity, ## stages. "
           "Verdict in frontmatter handoff.verdict."),
    "AR": ("STAGE AR (Architecture). Artifact: .context/architecture-0.md. "
           "Anchors: ## decisions, ## trade-offs, ## patterns, "
           "## integration-points, ## schemas, ## open-questions, ## risks."),
    "TL": ("STAGE TL (Team Lead). Artifact: .context/coordination-0.md. "
           "Anchors: ## fan-out, ## shared-snippets, ## sequence, ## risks."),
    "DV": ("STAGE DV (Development). Artifact: .context/development-0.md. "
           "Anchors: ## files-changed, ## tests-added, ## deviations, "
           "## follow-ups. Produce real code changes + a green build."),
    "DR": ("STAGE DR (Developer Review). Artifact: .context/developer-review-0.md. "
           "Anchors: ## findings, ## verdict, ## blockers, ## follow-ups."),
    "SR": ("STAGE SR (Security Review). Artifact: .context/security-review-0.md. "
           "Anchors: ## findings, ## verdict, ## blockers, ## threat-model."),
    "QA": ("STAGE QA (Testing). Artifact: .context/testing-0.md. "
           "Anchors: ## results, ## coverage, ## regressions, ## verdict."),
    "DC": ("STAGE DC (Documentation). Artifact: .context/documentation-0.md. "
           "Anchors: ## files-changed, ## cross-references, ## follow-ups."),
    "RE": ("STAGE RE (Release). Artifact: .context/release-0.md. "
           "Anchors: ## artifacts, ## version, ## rollback-plan."),
    "FN": ("STAGE FN (Finalization). Artifact: .context/complete-summary-0.md. "
           "Anchors: ## summary, ## artifacts, ## followups, ## metrics."),
    "ST": ("STAGE ST (Stakeholder). Artifact: .context/retrospective-0.md. "
           "Anchors: ## decision, ## learnings, ## followups."),
}


def header(worktask_id: str, plan_file: str) -> str:
    """[2] worktask-header — ONLY the two required literals; byte-identical per worktask."""
    return f"worktask_id: {worktask_id}\nplan_file: {plan_file}"


def _rstrip_newlines(s: str) -> str:
    return s.rstrip("\n")


def assemble_stage_prompt(stage: str, worktask_id: str, plan_file: str,
                          state_json_text: str, task_text: str,
                          stage_contract_override: Optional[str] = None) -> str:
    """Assemble one stage's stdin prompt in the binding [1][2][3][4][5] order (pure)."""
    contract = stage_contract_override if stage_contract_override is not None else STAGE_CONTRACT.get(stage, "")
    state_body = _rstrip_newlines(state_json_text)
    task_body = _rstrip_newlines(task_text)
    return (
        f"{MARK_CONTRACT}\n{CONTRACT_REMINDER}\n"
        f"{MARK_HEADER}\n{header(worktask_id, plan_file)}\n"
        f"{MARK_STATE}\n{state_body}\n"
        f"{MARK_CONTRACT_STAGE}\n{contract}\n"
        f"{MARK_TASK}\n{task_body}\n"
    )


def assemble_canonical_stage_prompt(prompt: str, instruction_set: dict, ledger_digest: str) -> str:
    """Use the production composer's canonical sections only in the WITH arm."""
    header_body = prompt.split(MARK_HEADER + "\n", 1)[1].split(MARK_STATE, 1)[0].rstrip("\n")
    task_body = prompt.split(MARK_TASK + "\n", 1)[1].rstrip("\n")
    return (
        f"{MARK_CONTRACT}\n{instruction_set['contract_reminder']}\n"
        f"{MARK_HEADER}\n{header_body}\n"
        f"{MARK_STATE}\n{ledger_digest.rstrip()}\n"
        f"{MARK_CONTRACT_STAGE}\n{instruction_set['stage_contract'].rstrip()}\n"
        f"{MARK_TASK}\n{task_body}\n"
    )
