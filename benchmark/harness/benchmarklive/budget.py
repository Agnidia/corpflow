"""Budget enforcement for live dispatch.

Two gates: (a) PRE-FLIGHT projection > budget → decline before any dispatch (rc=2);
(b) RUNNING-TALLY abort before each stage → partial record written before rc=4 (D6).
Neither fabricates spend — the tally only accumulates REAL per-stage costs (None adds
nothing). SR stays in PIPELINE_STAGES (AR delta D3).

`--budget` bounds what dispatch will START, not what a run realizes: gate (b) can
refuse the next stage but a dispatch already in flight has no cost ceiling, so
realized spend can exceed the cap by one stage. `RunningTally` holds back a reserve
sized from observed spend to keep that excess to the first stage that surprises the
projection; nothing here makes the cap absolute.
"""

from __future__ import annotations

import json
from typing import Callable, Optional

from benchmarkkit.genlib import Subprocess

PER_STAGE_EXPECTED_TOKENS = 40_000

PIPELINE_STAGES = ["PL", "AR", "TL", "DV", "DR", "SR", "QA", "DC", "FN", "ST"]

# Per-stage token expectations. DV runs an order of magnitude heavier than any
# other stage, so one flat figure across the pipeline projects a full run at
# roughly half its real cost and admits budgets that cannot finish it. Derived
# from the WITHOUT arm of live-20260807T114444Z-a0cdb43, the only complete
# 10-stage record — n=1, so recalibrate once a variance envelope exists.
STAGE_EXPECTED_TOKENS = {
    "PL": 45_000, "AR": 90_000, "TL": 30_000, "DV": 400_000, "DR": 120_000,
    "SR": 75_000, "QA": 50_000, "DC": 10_000, "FN": 35_000, "ST": 20_000,
}


def expected_tokens(stage: Optional[str] = None) -> int:
    """Tokens to project for ``stage``; the flat figure covers unlisted names."""
    return STAGE_EXPECTED_TOKENS.get(stage or "", PER_STAGE_EXPECTED_TOKENS)


class BudgetExceeded(Exception):
    pass


def estimate_stage_cost(estimate_calc_path: str, tokens: Optional[int] = None,
                        model: str = "opus", retry_complexity: str = "high",
                        runner: Optional[Callable[[list], str]] = None,
                        stage: Optional[str] = None) -> float:
    """Project one stage's USD cost via the REAL estimate-calc.py ai_cost chain.

    ``tokens`` wins when given; otherwise ``stage`` selects its calibrated figure.
    Any parse/exec failure returns 0.0 defensively — a failed estimate must never
    block a run on its own.
    """
    tokens = tokens if tokens is not None else expected_tokens(stage)
    argv = ["python3", estimate_calc_path, "--tokens", str(tokens),
            "--model", model, "--retry-complexity", retry_complexity]
    if runner is not None:
        try:
            stdout = runner(argv)
        except Exception:
            return 0.0
    else:
        r = Subprocess.run(argv)
        if r.exit_code != 0:
            return 0.0
        stdout = r.stdout
    try:
        usd = (json.loads(stdout).get("ai_cost") or {}).get("usd")
    except (ValueError, TypeError, AttributeError):
        return 0.0
    return usd if isinstance(usd, (int, float)) else 0.0


def preflight_projection(stages: list, estimate_calc_path: str, arms: int = 1,
                         runner: Optional[Callable[[list], str]] = None) -> float:
    """Project ``stages`` once per arm — both arms run the identical sequence."""
    per_arm = sum(estimate_stage_cost(estimate_calc_path, stage=s, runner=runner)
                  for s in stages)
    return per_arm * arms


def assert_preflight_within_budget(budget: float, stages: list, estimate_calc_path: str,
                                   arms: int = 1,
                                   runner: Optional[Callable[[list], str]] = None) -> float:
    """Gate (a). Raise BudgetExceeded if the projection exceeds budget; else return it."""
    projection = preflight_projection(stages, estimate_calc_path, arms=arms, runner=runner)
    if projection > budget:
        raise BudgetExceeded(
            f"pre-flight projection ${projection:.4f} exceeds budget ${budget:.4f} "
            f"for {len(stages)} stages x {arms} arm(s); dispatching nothing"
        )
    return projection


class RunningTally:
    """Gate (b). Accumulates REAL per-stage spend; decides if the next stage fits.

    The gate can only refuse to START a stage, so what it holds back decides how
    far a run can overshoot. It reserves the larger of the next stage's projection
    and the heaviest stage this arm has actually run: once one stage has beaten
    its projection, every later decision reserves the observed figure instead, and
    only a stage heavier than every predecessor can still breach the cap.
    """

    def __init__(self, budget: float, strict: bool = False) -> None:
        self.budget = budget
        self.spent_usd = 0.0
        self.max_stage_usd = 0.0
        self.strict = strict
        self.reliable = True

    def reserve(self, next_stage_estimate: float) -> float:
        return max(next_stage_estimate, self.max_stage_usd)

    def can_afford(self, next_stage_estimate: float) -> bool:
        return self.reliable and self.spent_usd + self.reserve(next_stage_estimate) <= self.budget

    def add(self, real_cost: Optional[float]) -> None:
        if real_cost is None:
            if self.strict:
                self.reliable = False
            return
        self.spent_usd += real_cost
        self.max_stage_usd = max(self.max_stage_usd, real_cost)
