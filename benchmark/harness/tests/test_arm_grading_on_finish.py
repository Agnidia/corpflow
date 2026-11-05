"""Each arm is graded as it finishes and a paired run persists it as an arm record.

Dispatch, measurement and the oracle are all faked: no ``claude``, no Swift build.
"""

import json
import os
import shutil
import sys as _sys
import tempfile
import time
import unittest
from unittest import mock

from benchmarkkit import metrics, oracle, pairing, rotation
from benchmarklive import baseline, budget
from benchmarklive.dispatch import DispatchFailure, dispatch
from benchmarklive.records import arm_record_path

_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import (  # noqa: E402
    fake_estimate_runner,
    load_json,
    make_live_sandbox,
    single_object_usage,
    stub_git_sha,
)

_ENV = {"ANTHROPIC_API_KEY": "k"}
DIGEST = "d" * 64
LOC = {"with": 77, "without": 42}
GRADE_PAUSE_S = 0.25


def arm_of(path):
    return os.path.basename(os.path.normpath(path))


class EventLog:
    """One ordered log shared by the dispatcher, the grader and measurement."""

    def __init__(self, script=None):
        self.events = []
        self.script = list(script or [])
        self.dispatches = 0

    def run(self, argv, prompt_text):
        arm = "with" if "--agent" in argv else "without"
        self.events.append(("dispatch", arm))
        self.dispatches += 1
        step = self.script.pop(0) if self.script else single_object_usage()
        if isinstance(step, Exception):
            raise step
        return step

    def grader(self, app_dir, warn=None):
        self.events.append(("grade", arm_of(app_dir)))
        time.sleep(GRADE_PAUSE_S)
        return oracle.OracleResult(built=True, cases_total=2, cases_passed=2, cases_digest=DIGEST)

    def measure(self, app_dir, plugin_root, *args, **kwargs):
        arm = arm_of(app_dir)
        return baseline.AppMeasure(loc_produced=LOC[arm], test_count=3, pass_fail="pass",
                                   app_path=f"arms/{arm}")

    def grades(self):
        return [arm for kind, arm in self.events if kind == "grade"]


class GradeOnFinish(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="grade-on-finish-")
        self.sb = make_live_sandbox(self.tmp)
        self.arm_dir = os.path.join(self.sb.benchmark_dir, "results", "runs", "live-arm")
        self.warnings = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_dispatch(self, log, arm="both", stages=("PL", "AR"), workdir=None, record=None,
                     budget_usd=100.0, est=0.001, arm_record_dir=True, **kw):
        selection = baseline.resolve_arm_selection(
            arm, None, baseline.stages_subset(list(stages), budget.PIPELINE_STAGES))
        with mock.patch.object(baseline, "measure_app", side_effect=log.measure):
            return dispatch(
                workdir=workdir or self.sb.run_id, budget=budget_usd,
                record_path=record or self.sb.record_path,
                benchmark_dir=self.sb.benchmark_dir, workdir_root=self.sb.workdir_root,
                dispatcher=log, env=_ENV, estimate_runner=fake_estimate_runner(est),
                stages=list(stages), git_sha_runner=stub_git_sha, selection=selection,
                grader=log.grader, stderr=self.warnings.append,
                arm_record_dir=self.arm_dir if arm_record_dir else None, **kw)

    def arm_record(self, arm, run_id=None):
        return load_json(arm_record_path(self.arm_dir, run_id or self.sb.run_id, arm))

    def kill_with_arm(self):
        log = EventLog([single_object_usage(), single_object_usage(),
                        DispatchFailure("killed mid-arm")])
        with self.assertRaises(DispatchFailure):
            self.run_dispatch(log)
        return log

    def test_a_kill_during_with_leaves_a_graded_without_arm_record(self):
        log = self.kill_with_arm()
        self.assertEqual(log.grades(), ["without"])
        record = self.arm_record("without")
        self.assertEqual(record["arm"], "without")
        self.assertEqual(list(record["paths"]), ["without"])
        self.assertEqual(record["paths"]["without"]["oracle"]["cases_digest"], DIGEST)
        self.assertEqual(record["paths"]["without"]["loc_produced"], LOC["without"])
        self.assertEqual(record["run_id"], f"{self.sb.run_id}-without")
        self.assertEqual(record["budget_usd"], 50.0)
        self.assertFalse(os.path.exists(arm_record_path(self.arm_dir, self.sb.run_id, "with")))

    def test_each_arm_is_graded_once_and_without_before_the_first_with_dispatch(self):
        log = EventLog()
        self.assertEqual(self.run_dispatch(log), 0)
        self.assertEqual(sorted(log.grades()), ["with", "without"])
        first_with = log.events.index(("dispatch", "with"))
        self.assertLess(log.events.index(("grade", "without")), first_with)
        paired = load_json(self.sb.record_path)
        for arm in ("with", "without"):
            path = paired["paths"][arm]
            self.assertEqual(path["oracle"]["cases_digest"], DIGEST)
            self.assertEqual(path["loc_produced"], LOC[arm])
            self.assertLess(path["wall_clock_s"], GRADE_PAUSE_S)
            self.assertEqual(self.arm_record(arm)["paths"][arm]["oracle"]["cases_digest"], DIGEST)

    def test_a_resumed_with_arm_joins_the_killed_runs_without_arm(self):
        self.kill_with_arm()
        without = self.arm_record("without")
        resumed_id = f"{self.sb.run_id}-resume"
        resumed_path = os.path.join(self.arm_dir, f"{resumed_id}-with.json")
        rc = self.run_dispatch(EventLog(), arm="with", workdir=resumed_id, record=resumed_path,
                               budget_usd=without["budget_usd"])
        self.assertEqual(rc, 0)
        with_rec = load_json(resumed_path)
        self.assertEqual(pairing.comparability_refusals(with_rec, without), [])
        warnings = []
        joined = json.loads(metrics.dumps(
            pairing.join_arm_records(with_rec, without, warn=warnings.append)))
        self.assertEqual(warnings, [])
        self.assertIsNone(joined.get("arm"))
        self.assertEqual(joined["paths"]["without"]["loc_produced"], LOC["without"])
        self.assertEqual(joined["paths"]["with"]["loc_produced"], LOC["with"])

    def test_a_budget_stopped_arm_is_graded_and_stamped_partial(self):
        log = EventLog([single_object_usage(cost=1.8)] * 2)
        rc = self.run_dispatch(log, budget_usd=4.0, est=0.5)
        self.assertEqual(rc, 4)
        record = self.arm_record("without")
        self.assertTrue(record["live_partial"])
        self.assertEqual(record["paths"]["without"]["stage_count"], 1)
        self.assertEqual(record["paths"]["without"]["oracle"]["cases_digest"], DIGEST)

    def test_a_usage_limit_stop_still_grades_and_names_the_arm_record(self):
        limit = "\n".join(json.dumps(e) for e in (
            {"type": "system", "subtype": "init", "plugins": []},
            {"type": "result", "is_error": True, "api_error_status": 429,
             "result": "You've hit your session limit · resets 7pm (Europe/Kiev)"}))
        log = EventLog([single_object_usage(), DispatchFailure("limit", stdout=limit)])
        rc = self.run_dispatch(log, wait_on_limit=False)
        self.assertEqual(rc, 6)
        self.assertEqual(log.grades(), ["without"])
        self.assertTrue(self.arm_record("without")["live_partial"])
        stop = next(w for w in self.warnings if "usage limit" in w)
        self.assertIn(arm_record_path(self.arm_dir, self.sb.run_id, "without"), stop)

    def test_a_plugin_breach_is_never_graded_or_persisted_as_an_arm(self):
        breach = json.dumps({"type": "system", "subtype": "init",
                             "plugins": [{"name": "cc-plugin-privacy", "path": "builtin"}]})
        log = EventLog([breach + "\n" + single_object_usage()])
        rc = self.run_dispatch(log, capture_mode="stream-json")
        self.assertEqual(rc, 5)
        self.assertEqual(log.grades(), [])
        self.assertFalse(os.path.isdir(self.arm_dir))

    def test_no_arm_record_for_a_subset_run_or_without_a_directory(self):
        self.assertEqual(self.run_dispatch(EventLog(), arm=None, stages=("PL",)), 0)
        self.assertFalse(os.path.isdir(self.arm_dir))
        self.assertEqual(self.run_dispatch(EventLog(), arm_record_dir=False), 0)
        self.assertFalse(os.path.isdir(self.arm_dir))

    def test_an_unwritable_arm_directory_only_warns(self):
        with open(os.path.join(self.tmp, "blocker"), "w", encoding="utf-8"):
            pass
        self.arm_dir = os.path.join(self.tmp, "blocker", "live-arm")
        self.assertEqual(self.run_dispatch(EventLog()), 0)
        self.assertTrue(any("arm record not written" in w for w in self.warnings))

    def test_only_the_paired_record_is_history_eligible(self):
        self.assertEqual(self.run_dispatch(EventLog()), 0)
        paired = load_json(self.sb.record_path)
        self.assertNotIn("arm", paired)
        self.assertNotEqual(os.path.dirname(self.sb.record_path), self.arm_dir)
        for arm in ("with", "without"):
            self.assertEqual(self.arm_record(arm)["arm"], arm)
        history = os.path.join(self.tmp, "history.json")
        rotation.rotate(history, paired)
        self.assertEqual([r["run_id"] for r in load_json(history)["live"]], [self.sb.run_id])

    def test_the_default_mechanism_grades_each_arm_once(self):
        log = EventLog()
        self.assertEqual(self.run_dispatch(log, arm_record_dir=False), 0)
        self.assertEqual(sorted(log.grades()), ["with", "without"])


if __name__ == "__main__":
    unittest.main()
