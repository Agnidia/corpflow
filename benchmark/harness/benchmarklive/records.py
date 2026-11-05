"""BenchmarkRecord assembly: collapse arm measurements into the on-disk record shapes.

Two byte-shapes are frozen here — the paired/skip record and the single-arm record —
and both share the verdict helpers, so a change to one arm's grading cannot drift the
other's.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from benchmarkkit.metrics import (
    BenchmarkRecord,
    PathMetrics,
    StageAttribution,
    Tokens,
    make_arm_record,
    make_record,
    skip_placeholder_without,
)

from . import baseline as baseline_mod
from .arm_exec import _arm_tokens
from .plugin_load import LoadedPlugin
from .stage_table import build_era


@dataclass
class PipelineResult:
    usages: list
    live_partial: bool
    dispatched: int


def _stage_attributions(usages: list, arm: Optional[str]) -> list:
    return [
        StageAttribution(stage=name, fresh_in=u.input_tokens, cache_creation=u.cache_creation,
                         cache_read=u.cache_read, out=u.output_tokens, cost_usd=u.cost_usd,
                         coverage=u.coverage, arm=arm,
                         parent_fresh_in=u.parent_input_tokens,
                         parent_cache_creation=u.parent_cache_creation,
                         parent_cache_read=u.parent_cache_read,
                         parent_out=u.parent_output_tokens,
                         duration_s=u.duration_s if u.diagnostics is not None or u.duration_s > 0 else None,
                         diagnostics=u.diagnostics)
        for name, u in usages
    ]


def _arm_verdict(app: Optional[baseline_mod.AppMeasure], partial: bool) -> tuple:
    """Collapse one arm's measurement into ``(pass_fail, loc, tests, app_path, oracle)``.

    Fail-closed on two counts: an unmeasured or degraded arm is never green, and
    where the held-out oracle ran it — not the arm's self-written suite — decides
    the verdict. The verdict reads the `specified` tier alone, which is the contract
    the arm was actually handed; the `implied` tier is a quality signal reported
    beside it, not something to fail an arm over. Full conformance is required to
    pass; a partial score is a fail that still carries its rate for comparison.
    """
    if app is None:
        return "fail", 0, 0, None, None

    verdict = "fail"
    if not partial:
        if app.oracle is not None:
            verdict = "pass" if _oracle_conforms(app.oracle) else "fail"
        else:
            verdict = app.pass_fail
    return verdict, app.loc_produced, app.test_count, app.app_path, app.oracle


def _oracle_conforms(oracle: dict) -> bool:
    """True when the arm cleared every case it was told about."""
    specified = (oracle.get("tiers") or {}).get("specified")
    if specified is not None:
        return specified.get("pass_rate") == 1.0
    return oracle.get("pass_rate") == 1.0


def build_live_record(run_id: str, timestamp_utc: str, git_sha: str, budget: float,
                      usages: list, stages_dispatched: int, live_partial: bool,
                      with_app: Optional[baseline_mod.AppMeasure] = None,
                      without_app: Optional[baseline_mod.AppMeasure] = None,
                      without_usages: Optional[list] = None,
                      without_dispatched: int = 0,
                      without_partial: bool = False,
                      with_partial: Optional[bool] = None,
                      plugin: Optional[LoadedPlugin] = None,
                      arm_plugins: Optional[dict] = None,
                      config_leaks: Optional[dict] = None) -> BenchmarkRecord:
    """Build the record. Skip mode (``without_usages=None``) keeps the WITHOUT
    placeholder byte-identical; its WITH block reflects whatever measurement and grading
    produced, which since AD-5 runs for every dispatched arm — so that block gains a real
    ``app_path`` and an ``oracle`` key it did not carry before. Paired mode aggregates the
    WITHOUT arm's own 10-stage tokens and tags every stage row with its arm (both
    additive/emit-only). ``plugin`` is the corpflow tree the WITH arm reported loading;
    it is stamped into ``era`` only when observed, as are the ``arm_plugins`` lists and
    the per-arm ``config_leaks``."""
    paired = without_usages is not None
    # Live coverage is never measured; None marks it absent so renderers tell it apart
    # from a real 0.0. Skip mode keeps the byte-stable 0.0 placeholder (asserted by test).
    with_coverage = None if paired else 0.0

    in_total, out_total, tok_total, cost_total, cr_total, cc_total, with_wall = _arm_tokens(usages)

    # Verdicts read per-arm degradation: record-level live_partial ORs both arms,
    # and judging one arm by it would fail a complete arm for the other's breach.
    if with_partial is None:
        with_partial = live_partial
    with_pass, with_loc, with_test, with_app_path, with_oracle = _arm_verdict(with_app, with_partial)

    with_p = PathMetrics(
        tokens=Tokens(input=in_total, output=out_total, total=tok_total,
                      cache_read=cr_total, cache_creation=cc_total),
        cost_usd=cost_total, wall_clock_s=with_wall, loc_produced=with_loc, test_count=with_test,
        coverage_pct=with_coverage, estimate_complexity_score=0, stage_count=stages_dispatched,
        pass_fail=with_pass, app_path=with_app_path, oracle=with_oracle)

    if not paired:
        without_p = skip_placeholder_without()
        return make_record(run_id=run_id, timestamp_utc=timestamp_utc, mode="live",
                           git_sha=git_sha, budget_usd=budget, with_pm=with_p,
                           without_pm=without_p, live_partial=live_partial,
                           stages=_stage_attributions(usages, arm=None),
                           era=build_era(plugin, arm_plugins, config_leaks))

    (o_in, o_out, o_tok, o_cost, o_cr, o_cc, o_wall) = _arm_tokens(without_usages)
    (without_pass, without_loc, without_test,
     without_app_path, without_oracle) = _arm_verdict(without_app, without_partial)

    without_p = PathMetrics(
        tokens=Tokens(input=o_in, output=o_out, total=o_tok, cache_read=o_cr, cache_creation=o_cc),
        cost_usd=o_cost, wall_clock_s=o_wall, loc_produced=without_loc, test_count=without_test,
        coverage_pct=None, estimate_complexity_score=0, stage_count=without_dispatched,
        pass_fail=without_pass, app_path=without_app_path, oracle=without_oracle)

    stages_all = (_stage_attributions(usages, arm="with")
                  + _stage_attributions(without_usages, arm="without"))
    return make_record(run_id=run_id, timestamp_utc=timestamp_utc, mode="live",
                       git_sha=git_sha, budget_usd=budget, with_pm=with_p,
                       without_pm=without_p, live_partial=live_partial, stages=stages_all,
                       era=build_era(plugin, arm_plugins, config_leaks))


def arm_record_path(arm_record_dir: str, run_id: str, arm: str) -> str:
    """Where a paired run persists one arm as a single-arm record.

    The ``<run_id>-<arm>`` stem is the id ``--arm`` runs carry, so ``bench-pair`` reads
    a paired run's arm and a resumed single-arm run as the same kind of input.
    """
    return os.path.join(arm_record_dir, f"{run_id}-{arm}.json")


def build_arm_record(run_id: str, timestamp_utc: str, git_sha: str, budget: float,
                     arm: str, usages: list, stages_dispatched: int, arm_partial: bool,
                     app: Optional[baseline_mod.AppMeasure] = None,
                     plugin: Optional[LoadedPlugin] = None,
                     arm_plugins: Optional[dict] = None,
                     config_leaks: Optional[dict] = None) -> BenchmarkRecord:
    """Build a single-arm record carrying only the arm that ran.

    A sibling of :func:`build_live_record`, which keeps both legacy byte shapes verbatim.
    ``live_partial`` reflects this arm alone, since no other arm was dispatched.
    """
    in_total, out_total, tok_total, cost_total, cr_total, cc_total, wall = _arm_tokens(usages)
    pass_fail, loc, tests, app_path, oracle_payload = _arm_verdict(app, arm_partial)
    pm = PathMetrics(
        tokens=Tokens(input=in_total, output=out_total, total=tok_total,
                      cache_read=cr_total, cache_creation=cc_total),
        cost_usd=cost_total, wall_clock_s=wall, loc_produced=loc, test_count=tests,
        coverage_pct=None, estimate_complexity_score=0, stage_count=stages_dispatched,
        pass_fail=pass_fail, app_path=app_path, oracle=oracle_payload)
    return make_arm_record(
        run_id=run_id, timestamp_utc=timestamp_utc, mode="live", git_sha=git_sha,
        budget_usd=budget, arm=arm, pm=pm, live_partial=arm_partial,
        stages=_stage_attributions(usages, arm=arm), era=build_era(plugin, arm_plugins, config_leaks))
