"""Seed the WITH arm's ledger the way the production orchestrator leaves it.

``seed_run`` is ``/worktask`` Step 3-3a: it runs the real ``seed-state.sh`` once, before the
arm's first stage. Without it there is no ``state.json`` at all and nothing below can work.

In a real worktask the orchestrator seeds the ledger, PL0 seeds every downstream stage
row (``state-patch.sh --task-create``) and the plan gate stamps the approval carrier
before any stage is dispatched. The harness dispatches bare ``claude -p`` stages, so
none of that happened: DV found no ``DV0`` row (``--claim`` -> "unknown task id"), never
saw an approved plan, and both DV and QA had their test runs denied by
``hooks/test-execution-gate.sh``, which resolves the acting stage from the single
``in_progress`` row. Rows are written through the real ``state-patch.sh`` so the ledger
contract stays the script's, never re-implemented here.

Only stages whose captures showed the failure are seeded (``SEEDED_STAGES``); every other
stage's completion patch creates its own row.
"""

from __future__ import annotations

import json
import os
from typing import Any, Callable, Optional

from benchmarkkit.genlib import Subprocess

from .stage_table import STAGE_TABLE

# stage -> artifact basename (handoff-protocol stage-artifact map).
SEEDED_STAGES = {"DV": "development", "QA": "testing"}

# Values PL0.metadata.approved must hold before DV implements (agents/developer.md).
_APPROVED = ("user", "auto")

# Run-wide defaults when PL stamped none: master is the integration branch the ttt
# workload is cut from; screenshots default on per skills/dv-screenshot-capture.
_DEFAULT_BASE_REF = "master"

# (argv, env, cwd) -> object with .exit_code / .stderr. Injected by tests.
SeedRunner = Callable[[list, dict, str], Any]

# Step 3 of skills/worktask/references/workflow.md.
_CONTEXT_SUBDIRS = ("designs", "images", "errors", "logs")

# seed-state.sh exits: 0 seeded, 3 a ledger is already there (byte-unchanged).
_SEEDED, _EXISTS = 0, 3


class LedgerSeedError(RuntimeError):
    """The WITH arm's ledger could not be seeded; the run must not dispatch."""


def default_runner(argv: list, env: dict, cwd: str) -> Any:
    return Subprocess.run(argv, cwd=cwd, env=env)


def goal_from_prompt(text: str) -> str:
    """The task sentence of a stage prompt, as ``--goal`` wants it: one line.

    Takes the paragraph after ``TASK:`` (whole text when absent), up to the first blank
    line or bullet. ``seed-state.sh`` owns escaping and the 240-char cap.
    """
    marker = text.find("TASK:")
    body = text[marker + len("TASK:"):] if marker >= 0 else text
    lines: list = []
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("- "):
            if lines:
                break
            continue
        lines.append(stripped)
    return " ".join(lines)


def seed_run(arm_cwd: str, plugin_root: str, worktask_id: str, goal: str,
             runner: Optional[SeedRunner] = None) -> str:
    """Seed ``<arm_cwd>/.context/state.json`` with the production ``seed-state.sh``.

    Returns ``"seeded"`` or ``"exists"``. An existing ledger is left byte-unchanged and is
    not reopened the way ``/worktask`` reopens PL0: a second ``in_progress`` row beside
    the claimed stage makes the test-execution gate's acting stage ambiguous. Raises
    ``LedgerSeedError`` on any other outcome. ``/worktask``'s ``--platform`` is not
    passed (the harness has none, so the seed's default applies); the seed takes no
    base_ref or test_mode, which ``seed_stage`` stamps per row.
    """
    context_dir = os.path.join(arm_cwd, ".context")
    for sub in _CONTEXT_SUBDIRS:
        os.makedirs(os.path.join(context_dir, sub), exist_ok=True)
    if not goal:
        raise LedgerSeedError("ledger seed refused: the task prompt yielded no goal")
    script = os.path.join(plugin_root, "skills", "worktask", "scripts", "seed-state.sh")
    argv = ["bash", script, "--worktask-id", worktask_id, "--goal", goal,
            "--context-dir", context_dir, "--workspace-path", os.path.realpath(arm_cwd)]
    # CONTEXT_DIR beside --context-dir: the script's ladder must not reach the enclosing checkout.
    env = dict(os.environ, CONTEXT_DIR=context_dir)
    result = (runner or default_runner)(argv, env, arm_cwd)
    if result.exit_code == _SEEDED:
        return "seeded"
    if result.exit_code == _EXISTS:
        return "exists"
    raise LedgerSeedError(f"ledger seed refused: seed-state.sh rc={result.exit_code} "
                          f"{(result.stderr or '').strip()[:200]}")


def _read_ledger(state_path: str) -> Optional[dict]:
    try:
        with open(state_path, encoding="utf-8") as f:
            ledger = json.load(f)
    except (OSError, ValueError):
        return None
    return ledger if isinstance(ledger, dict) and isinstance(ledger.get("tasks"), dict) else None


def _task_metadata(stage: str, ledger: dict, arm_cwd: str) -> dict:
    """The keys PL0 stamps on a downstream row (pl0-procedure.md § Downstream propagation).

    ``--task-create`` does not fill an absent value and refuses a row missing effort,
    isolation, base_ref, requires_screenshots or workspace_path.
    """
    agent, model, effort = STAGE_TABLE[stage]
    run_wide = ledger.get("metadata") if isinstance(ledger.get("metadata"), dict) else {}
    index = ledger.get("run_index") if isinstance(ledger.get("run_index"), int) else 0
    screenshots = run_wide.get("requires_screenshots")
    metadata = {
        "agent": agent,
        "stage": stage,
        "model": model,
        "effort": effort,
        "isolation": "worktree",
        "base_ref": run_wide.get("base_ref") or _DEFAULT_BASE_REF,
        "requires_screenshots": screenshots if isinstance(screenshots, bool) else True,
        "workspace_path": os.path.realpath(arm_cwd),
        "artifact": f".context/{SEEDED_STAGES[stage]}-{index}.md",
        "plan_file": f"planning-{index}.md",
        "run_index": index,
    }
    if isinstance(run_wide.get("test_mode"), str):
        metadata["test_mode"] = run_wide["test_mode"]
    return metadata


def seed_stage(stage: str, arm_cwd: str, plugin_root: str,
               warn: Callable[[str], None],
               runner: Optional[SeedRunner] = None) -> list:
    """Make the ledger match what the orchestrator would have written before ``stage``.

    Idempotent: a row or approval that already exists is left alone. Returns the
    operations performed. A failed write warns and moves on, because a ledger the
    stage agent then finds wanting is a stage outcome, not a reason to lose the run.
    """
    if stage not in SEEDED_STAGES:
        return []
    state_path = os.path.join(arm_cwd, ".context", "state.json")
    ledger = _read_ledger(state_path)
    if ledger is None:
        warn(f"ledger seed skipped before {stage}: no readable ledger at {state_path}")
        return []

    run = runner or default_runner
    script = os.path.join(plugin_root, "skills", "worktask", "scripts", "state-patch.sh")
    # Explicit --state/--log, plus CONTEXT_DIR: from a nested workdir the script's root
    # ladder otherwise resolves the enclosing checkout's .context/.
    base = ["bash", script, "--state", state_path,
            "--log", os.path.join(arm_cwd, ".context", "logs", "state-merge.log")]
    env = dict(os.environ, CONTEXT_DIR=os.path.join(arm_cwd, ".context"))
    tasks = ledger["tasks"]
    task_id = f"{stage}{ledger.get('run_index') if isinstance(ledger.get('run_index'), int) else 0}"
    done: list = []

    def call(label: str, args: list) -> None:
        result = run(base + args, env, arm_cwd)
        if result.exit_code != 0:
            warn(f"ledger seed failed before {stage}: {label} rc={result.exit_code} "
                 f"{(result.stderr or '').strip()[:200]}")
        else:
            done.append(label)

    pl0 = tasks.get("PL0")
    if isinstance(pl0, dict) and pl0.get("status") == "in_progress":
        # seed-state.sh leaves PL0 open. A run that starts at DV (``--stages``), or a PL
        # agent that never closed its row, would otherwise give the gate two acting stages.
        call("PL0 completed", ["--task-status", "PL0", "completed"])
    if isinstance(pl0, dict):
        meta = pl0.get("metadata") if isinstance(pl0.get("metadata"), dict) else {}
        if meta.get("approved") not in _APPROVED:
            # The unattended plan-gate carrier (skills/worktask/references/workflow.md § Plan gate bypass
            # path): "auto", no audit row. "user" and approval_received are reserved
            # for a human's answer, which no harness run has.
            call("PL0 approved=auto", ["--task-meta", "PL0", "--set", '{"approved":"auto"}'])

    row = tasks.get(task_id)
    if not isinstance(row, dict):
        call(f"{task_id} created", ["--task-create", task_id, "--metadata",
                                    json.dumps(_task_metadata(stage, ledger, arm_cwd))])
    if not isinstance(row, dict) or row.get("status") in ("pending", "blocked"):
        # Loop step 5: the test-execution gate reads the acting stage from this write.
        call(f"{task_id} in_progress", ["--task-status", task_id, "in_progress"])
    return done
