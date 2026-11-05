"""The comparability gate and the join (AC-8 to AC-12).

Pure dicts in, refusals or a joined record out — no sandbox, no dispatch, no spend.
The executable's exit codes are exercised by running it as a subprocess, which is
still entirely offline: bench-pair reads two local files and writes one.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

from benchmarkkit import analysis, metrics, pairing

_HARNESS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_BENCH_PAIR = os.path.join(_HARNESS, "bin", "bench-pair")

_ERA = {
    "harness": "python-1",
    "prompt_contract": "scripted-cli-v3",
    "model_pins": {"PL": "claude-opus-5-5", "DV": "claude-opus-5-5"},
}
_DIGEST = "sha256:" + "1" * 64
_OTHER_DIGEST = "sha256:" + "2" * 64


def _oracle(digest=_DIGEST, passed=2):
    payload = {"built": True, "cases_total": 2, "cases_passed": passed,
               "pass_rate": round(passed / 2, 4)}
    if digest is not None:
        payload["cases_digest"] = digest
    return payload


def _pm(loc=100, tests=4, tokens_total=300, cost=0.5, wall=12.5, digest=_DIGEST):
    return metrics.PathMetrics(
        tokens=metrics.Tokens(input=tokens_total - 50, output=50, total=tokens_total,
                              cache_read=10, cache_creation=20),
        cost_usd=cost, wall_clock_s=wall, loc_produced=loc, test_count=tests,
        coverage_pct=None, estimate_complexity_score=0, stage_count=1,
        pass_fail="pass", app_path="benchmark/workdirs/r/x", oracle=_oracle(digest))


def arm_record(arm, *, sha="abc1234", ts="2026-08-14T10:20:01Z", era=_ERA,
               digest=_DIGEST, partial=False, budget=50.0, loc=100, cost=0.5,
               tokens_total=300, run_id=None, stages=None):
    record = metrics.make_arm_record(
        run_id=run_id or f"live-20260814T102001Z-{sha}-{arm}",
        timestamp_utc=ts, mode="live", git_sha=sha, budget_usd=budget, arm=arm,
        pm=_pm(loc=loc, cost=cost, tokens_total=tokens_total, digest=digest),
        live_partial=partial,
        stages=stages if stages is not None else [
            metrics.StageAttribution(stage="PL", fresh_in=10, cache_creation=1,
                                     cache_read=2, out=3, cost_usd=cost, arm=arm)],
        era=era)
    return record.to_dict()


class GateAxes(unittest.TestCase):
    def test_comparable_pair_yields_no_refusals(self):
        self.assertEqual(
            pairing.comparability_refusals(arm_record("with"), arm_record("without")),
            [])

    def test_era_difference_refuses_and_names_both(self):
        other_era = dict(_ERA, prompt_contract="scripted-cli-v4")
        refusals = pairing.comparability_refusals(
            arm_record("with"), arm_record("without", era=other_era))
        self.assertEqual(len(refusals), 1)
        self.assertIn("era:", refusals[0])
        self.assertIn("scripted-cli-v3", refusals[0])
        self.assertIn("scripted-cli-v4", refusals[0])

    def test_model_repin_refuses(self):
        repinned = dict(_ERA, model_pins={"PL": "claude-opus-6", "DV": "claude-opus-5-5"})
        refusals = pairing.comparability_refusals(
            arm_record("with"), arm_record("without", era=repinned))
        self.assertTrue(any("model_pins" in r for r in refusals))

    def test_unknown_future_era_key_still_refuses(self):
        # Full dict equality on top of the three-key diff: a key era_differences() does
        # not inspect must not slip through and be silently arbitrated by the join.
        future = dict(_ERA, sampling_seed=7)
        refusals = pairing.comparability_refusals(
            arm_record("with"), arm_record("without", era=future))
        self.assertTrue(any("era:" in r and "sampling_seed" in r for r in refusals))

    def test_absent_era_refuses_on_the_same_footing(self):
        refusals = pairing.comparability_refusals(
            arm_record("with", era=None), arm_record("without"))
        self.assertTrue(any(r.startswith("era:") and "absent" in r for r in refusals))

    def test_empty_era_on_both_sides_refuses(self):
        # `{} != {}` is False and era_differences() finds no diffs, so equality alone
        # would certify two unstamped records as same-era.
        refusals = pairing.comparability_refusals(
            arm_record("with", era={}), arm_record("without", era={}))
        self.assertTrue(any(r.startswith("era:") and "absent" in r for r in refusals))

    def test_empty_era_on_one_side_refuses(self):
        refusals = pairing.comparability_refusals(
            arm_record("with", era={}), arm_record("without"))
        self.assertTrue(any(r == "era: absent vs stamped" for r in refusals))

    def test_non_dict_era_refuses_instead_of_crashing(self):
        # Operator-supplied files are the gate's input domain; a hand-edited scalar era
        # must be a refusal, not an AttributeError out of era_differences().
        refusals = pairing.comparability_refusals(
            arm_record("with", era="scripted-cli-v3"), arm_record("without"))
        self.assertTrue(any(r.startswith("era:") for r in refusals))

    def test_sha_mismatch_refuses_and_names_both(self):
        refusals = pairing.comparability_refusals(
            arm_record("with", sha="abc1234"), arm_record("without", sha="def5678"))
        self.assertEqual(len(refusals), 1)
        self.assertIn("commit sha:", refusals[0])
        self.assertIn("abc1234", refusals[0])
        self.assertIn("def5678", refusals[0])

    def test_both_absent_sha_refuses_rather_than_comparing_equal(self):
        # None == None passed the axis before: two records with no commit identity were
        # certified as the same commit.
        a, b = arm_record("with"), arm_record("without")
        del a["git_sha"], b["git_sha"]
        refusals = pairing.comparability_refusals(a, b)
        self.assertEqual(len(refusals), 1)
        self.assertEqual(refusals[0], "commit sha: absent vs absent")

    def test_both_nogit_sha_refuses_rather_than_comparing_equal(self):
        # "nogit" is the fallback for "no commit identity available" — precisely the
        # environment (export, container without git) where two arm runs may sit many
        # commits apart.
        refusals = pairing.comparability_refusals(
            arm_record("with", sha="nogit"), arm_record("without", sha="nogit"))
        self.assertEqual(len(refusals), 1)
        self.assertIn("commit sha:", refusals[0])
        self.assertIn("unknown", refusals[0])
        self.assertIn("nogit", refusals[0])

    def test_one_sided_unknown_sha_refuses_and_names_both(self):
        refusals = pairing.comparability_refusals(
            arm_record("with", sha="abc1234"), arm_record("without", sha="nogit"))
        self.assertEqual(len(refusals), 1)
        self.assertIn("abc1234", refusals[0])
        self.assertIn("nogit", refusals[0])

    def test_empty_string_sha_refuses(self):
        refusals = pairing.comparability_refusals(
            arm_record("with", sha=""), arm_record("without", sha=""))
        self.assertEqual(refusals, ["commit sha: absent vs absent"])

    def test_digest_mismatch_refuses_and_names_both(self):
        refusals = pairing.comparability_refusals(
            arm_record("with"), arm_record("without", digest=_OTHER_DIGEST))
        self.assertEqual(len(refusals), 1)
        self.assertIn("oracle case-set digest:", refusals[0])
        self.assertIn(_DIGEST, refusals[0])
        self.assertIn(_OTHER_DIGEST, refusals[0])

    def test_one_sided_absent_digest_refuses(self):
        refusals = pairing.comparability_refusals(
            arm_record("with"), arm_record("without", digest=None))
        self.assertEqual(len(refusals), 1)
        self.assertIn("oracle case-set digest:", refusals[0])
        self.assertIn(_DIGEST, refusals[0])
        self.assertIn("absent", refusals[0])

    def test_every_axis_is_collected_not_short_circuited(self):
        # A reader who fixes one axis and re-runs must not discover the next only on
        # the following attempt.
        refusals = pairing.comparability_refusals(
            arm_record("with"),
            arm_record("without", sha="def5678", digest=_OTHER_DIGEST, era=None))
        self.assertEqual(len(refusals), 3)
        self.assertTrue(any(r.startswith("era:") for r in refusals))
        self.assertTrue(any(r.startswith("commit sha:") for r in refusals))
        self.assertTrue(any(r.startswith("oracle case-set digest:") for r in refusals))

    def test_time_gap_is_not_a_refusal_axis(self):
        # AC-11: any interval joins; no threshold appears anywhere.
        far = arm_record("without", ts="2027-01-01T00:00:00Z")
        self.assertEqual(pairing.comparability_refusals(arm_record("with"), far), [])


class ObservedGap(unittest.TestCase):
    def test_gap_is_reported_in_whole_seconds_and_is_symmetric(self):
        a = arm_record("with", ts="2026-08-14T10:20:01Z")
        b = arm_record("without", ts="2026-08-14T11:20:01Z")
        self.assertEqual(analysis.observed_gap_s(a, b), 3600)
        self.assertEqual(analysis.observed_gap_s(b, a), 3600)

    def test_unparseable_timestamp_yields_none_not_a_fabricated_zero(self):
        self.assertIsNone(analysis.observed_gap_s(
            arm_record("with", ts="whenever"), arm_record("without")))


class Join(unittest.TestCase):
    def test_join_produces_the_paired_shape(self):
        joined = pairing.join_arm_records(
            arm_record("with"), arm_record("without")).to_dict()
        self.assertEqual(sorted(joined["paths"]), ["with", "without"])
        self.assertNotIn("arm", joined)
        self.assertEqual(joined["mode"], "live")
        self.assertEqual(sorted(joined["comparison"]),
                         sorted(metrics.DETERMINISTIC_COMPARISON_KEYS
                                + ["tokens_total", "cost_usd"]))

    def test_comparison_matches_a_native_paired_invocation(self):
        # AC-8 by construction: the join calls the same build_comparison() the paired
        # record builder does, rather than reimplementing the deltas.
        with_pm = _pm(loc=140, cost=0.8, tokens_total=450)
        without_pm = _pm(loc=100, cost=0.5, tokens_total=300)
        expected = metrics.BenchmarkRecord(
            run_id="x", timestamp_utc="t", mode="live", git_sha="s", budget_usd=None,
            paths=[("with", with_pm), ("without", without_pm)],
            comparison=metrics.build_comparison(with_pm, without_pm, "live"),
        ).to_dict()["comparison"]
        joined = pairing.join_arm_records(
            arm_record("with", loc=140, cost=0.8, tokens_total=450),
            arm_record("without", loc=100, cost=0.5, tokens_total=300)).to_dict()
        self.assertEqual(joined["comparison"], expected)

    def test_join_is_order_insensitive(self):
        a = arm_record("with", ts="2026-08-14T10:20:01Z", loc=140)
        b = arm_record("without", ts="2026-08-14T12:00:00Z", loc=100)
        self.assertEqual(pairing.join_arm_records(a, b).to_dict(),
                         pairing.join_arm_records(b, a).to_dict())

    def test_derived_fields_take_the_later_timestamp_and_shared_sha(self):
        joined = pairing.join_arm_records(
            arm_record("with", ts="2026-08-14T10:20:01Z"),
            arm_record("without", ts="2026-08-14T12:00:00Z")).to_dict()
        self.assertEqual(joined["timestamp_utc"], "2026-08-14T12:00:00Z")
        self.assertEqual(joined["git_sha"], "abc1234")
        self.assertRegex(joined["run_id"],
                         r"^live-20260814T120000Z-abc1234-joined-[0-9a-f]{8}$")
        self.assertEqual(joined["budget_usd"], 100.0)
        self.assertEqual(joined["era"], _ERA)

    def test_joined_run_id_distinguishes_pairs_that_share_timestamp_and_sha(self):
        # Without a source-derived component these two joins collide, and the rotation
        # dedupe then treats the second as a re-ingest and drops it silently.
        first = pairing.join_arm_records(
            arm_record("with", run_id="live-a-with"),
            arm_record("without", run_id="live-a-without")).to_dict()
        second = pairing.join_arm_records(
            arm_record("with", run_id="live-b-with"),
            arm_record("without", run_id="live-b-without")).to_dict()
        self.assertEqual(first["timestamp_utc"], second["timestamp_utc"])
        self.assertEqual(first["git_sha"], second["git_sha"])
        self.assertNotEqual(first["run_id"], second["run_id"])

    def test_joined_run_id_is_stable_and_order_insensitive(self):
        a = arm_record("with", run_id="live-a-with")
        b = arm_record("without", run_id="live-a-without")
        self.assertEqual(pairing.join_arm_records(a, b).run_id,
                         pairing.join_arm_records(b, a).run_id)

    def test_partial_on_either_arm_propagates(self):
        joined = pairing.join_arm_records(
            arm_record("with", partial=True), arm_record("without")).to_dict()
        self.assertTrue(joined["live_partial"])
        clean = pairing.join_arm_records(
            arm_record("with"), arm_record("without")).to_dict()
        self.assertNotIn("live_partial", clean)

    def test_stage_rows_are_concatenated_with_their_own_arm_tags(self):
        joined = pairing.join_arm_records(
            arm_record("with"), arm_record("without")).to_dict()
        self.assertEqual([s["arm"] for s in joined["stages"]], ["with", "without"])

    def test_joined_from_names_both_sources_and_the_observed_gap(self):
        joined = pairing.join_arm_records(
            arm_record("with", ts="2026-08-14T10:20:01Z", run_id="live-a-with"),
            arm_record("without", ts="2026-08-14T11:20:01Z",
                       run_id="live-b-without")).to_dict()
        self.assertEqual(joined["joined_from"]["with"]["run_id"], "live-a-with")
        self.assertEqual(joined["joined_from"]["without"]["run_id"], "live-b-without")
        self.assertEqual(joined["joined_from"]["observed_gap_s"], 3600)
        self.assertEqual(list(joined)[-1], "joined_from")  # last in the optional tail

    def test_per_arm_oracle_payloads_travel_intact(self):
        # The digest is per-arm precisely so the join never has to arbitrate one value
        # and discard the other.
        joined = pairing.join_arm_records(
            arm_record("with"), arm_record("without")).to_dict()
        self.assertEqual(analysis.oracle_cases_digests(joined),
                         {"with": _DIGEST, "without": _DIGEST})

    def test_joined_record_round_trips(self):
        joined = pairing.join_arm_records(arm_record("with"), arm_record("without"))
        text = metrics.dumps(joined)
        self.assertEqual(metrics.dumps(metrics.loads(text)), text)

    def test_natively_paired_record_carries_no_joined_from(self):
        native = metrics.make_record("r", "t", "live", "s", 1.0, _pm(), _pm()).to_dict()
        self.assertNotIn("joined_from", native)


class JoinInputFaults(unittest.TestCase):
    def test_two_same_arm_inputs_are_refused(self):
        with self.assertRaises(pairing.PairingError):
            pairing.join_arm_records(arm_record("with"), arm_record("with"))

    def test_a_paired_record_as_input_is_refused(self):
        paired = metrics.make_record("r", "t", "live", "s", 1.0, _pm(), _pm()).to_dict()
        with self.assertRaises(pairing.PairingError):
            pairing.join_arm_records(paired, arm_record("without"))

    def test_arm_record_carrying_both_paths_is_refused(self):
        # Accepted before: the opposite half was silently discarded by the join rather
        # than reported, so the operator got a comparison built from data they did not
        # supply on that side.
        both = arm_record("with")
        both["paths"]["without"] = arm_record("without")["paths"]["without"]
        with self.assertRaises(pairing.PairingError) as ctx:
            pairing.arm_pair(both, arm_record("without"))
        self.assertIn("declares arm 'with'", str(ctx.exception))

    def test_arm_record_missing_its_own_path_is_refused_by_shape_not_by_digest(self):
        # Previously caught only incidentally, by the digest axis — change that axis and
        # the case became uncaught.
        missing = arm_record("with")
        missing["paths"] = {}
        with self.assertRaises(pairing.PairingError):
            pairing.arm_pair(missing, arm_record("without"))

    def test_arm_record_with_no_path_block_is_refused(self):
        broken = arm_record("with")
        del broken["paths"]
        with self.assertRaises(pairing.PairingError):
            pairing.arm_pair(broken, arm_record("without"))


class MalformedBelowTheShapeCheck(unittest.TestCase):
    """A block of the wrong type is a PairingError, which is what the module promises.

    These shapes pass ``arm_pair`` — the arm and its path key agree — and only crash
    deeper, in the digest accessor. They escaped as an ``AttributeError`` before, so a
    module caller writing ``except PairingError`` got a traceback for input the CLI was
    already classifying correctly.
    """

    def _with_arm_oracle(self, value):
        record = arm_record("with")
        record["paths"]["with"]["oracle"] = value
        return record

    def test_non_dict_oracle_raises_pairing_error_from_the_join(self):
        with self.assertRaises(pairing.PairingError) as ctx:
            pairing.join_arm_records(
                self._with_arm_oracle("graded"), arm_record("without"))
        self.assertIn("paths.with.oracle", str(ctx.exception))
        self.assertIn("str", str(ctx.exception))

    def test_non_dict_oracle_raises_pairing_error_from_the_gate_alone(self):
        # bench-pair calls the gate directly, ahead of the join, so the conversion has
        # to hold on that surface too.
        with self.assertRaises(pairing.PairingError):
            pairing.comparability_refusals(
                self._with_arm_oracle(["graded"]), arm_record("without"))

    def test_non_dict_path_metrics_block_raises_pairing_error(self):
        broken = arm_record("with")
        broken["paths"]["with"] = "fast"
        with self.assertRaises(pairing.PairingError) as ctx:
            pairing.join_arm_records(broken, arm_record("without"))
        self.assertIn("paths.with", str(ctx.exception))

    def test_non_dict_paths_block_raises_pairing_error_from_the_gate(self):
        # The join refuses this earlier, in arm_pair; the gate is the surface where the
        # accessor's `.items()` is reached.
        broken = arm_record("with")
        broken["paths"] = ["with"]
        with self.assertRaises(pairing.PairingError):
            pairing.comparability_refusals(broken, arm_record("without"))

    def test_malformed_on_the_second_argument_is_caught_the_same_way(self):
        broken = arm_record("without")
        broken["paths"]["without"]["oracle"] = "graded"
        with self.assertRaises(pairing.PairingError):
            pairing.join_arm_records(arm_record("with"), broken)

    def test_an_unstamped_digest_still_refuses_rather_than_raising(self):
        # The conversion fires only where the accessor would have crashed. An absent,
        # empty or falsy oracle block is unstamped, not malformed, and must keep
        # producing the refusal that names both sides.
        for value in ({}, None, ""):
            record = self._with_arm_oracle(value)
            refusals = pairing.comparability_refusals(record, arm_record("without"))
            self.assertEqual(len(refusals), 1, value)
            self.assertIn("oracle case-set digest:", refusals[0])
            self.assertIn("absent", refusals[0])


class ModuleLevelGate(unittest.TestCase):
    """The fail-closed property belongs to pairing.py, not only to bin/bench-pair."""

    def test_join_refuses_an_incomparable_pair_without_the_cli(self):
        with self.assertRaises(pairing.PairingError) as ctx:
            pairing.join_arm_records(
                arm_record("with", sha="abc1234"),
                arm_record("without", sha="def5678"))
        self.assertIn("commit sha:", str(ctx.exception))

    def test_join_names_every_refusal_not_just_the_first(self):
        with self.assertRaises(pairing.PairingError) as ctx:
            pairing.join_arm_records(
                arm_record("with"),
                arm_record("without", sha="def5678", digest=_OTHER_DIGEST, era=None))
        message = str(ctx.exception)
        for axis in ("era:", "commit sha:", "oracle case-set digest:"):
            self.assertIn(axis, message)

    def test_join_refuses_the_unknown_sha_pair_the_gate_now_catches(self):
        with self.assertRaises(pairing.PairingError):
            pairing.join_arm_records(
                arm_record("with", sha="nogit"), arm_record("without", sha="nogit"))


class ExecutableExitCodes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bench-pair-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, name, record):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
        return path

    def _run(self, *args):
        return subprocess.run([sys.executable, _BENCH_PAIR, *args],
                              capture_output=True, text=True)

    def test_clean_join_exits_zero_and_writes_the_record(self):
        a = self._write("a.json", arm_record("with"))
        b = self._write("b.json", arm_record("without"))
        out = os.path.join(self.tmp, "nested", "joined.json")
        proc = self._run("--a", a, "--b", b, "--out", out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(out, encoding="utf-8") as f:
            joined = json.load(f)
        self.assertEqual(sorted(joined["paths"]), ["with", "without"])
        self.assertIn("observed gap", proc.stderr)

    def test_success_prints_the_ingest_command(self):
        # The join produces something nothing consumes automatically; the operator is
        # told the one command that ingests it rather than left to infer it.
        a = self._write("a.json", arm_record("with"))
        b = self._write("b.json", arm_record("without"))
        out = os.path.join(self.tmp, "joined.json")
        proc = self._run("--a", a, "--b", b, "--out", out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ingest", proc.stdout)
        self.assertIn("rotation.rotate", proc.stdout)
        self.assertIn("history.json", proc.stdout)
        self.assertIn(out, proc.stdout)

    def test_malformed_record_exits_64_not_a_traceback(self):
        # The docstring promises 0/64/65; an uncaught AttributeError would surface as 1
        # and a wrapper could read a crash as neither usage nor refusal.
        broken = arm_record("with")
        broken["era"] = "scripted-cli-v3"
        broken["paths"]["with"]["oracle"] = "graded"
        a = self._write("a.json", broken)
        b = self._write("b.json", arm_record("without"))
        out = os.path.join(self.tmp, "o.json")
        proc = self._run("--a", a, "--b", b, "--out", out)
        self.assertEqual(proc.returncode, 64, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertFalse(os.path.exists(out))

    def test_unknown_sha_pair_exits_65_and_writes_nothing(self):
        a = self._write("a.json", arm_record("with", sha="nogit"))
        b = self._write("b.json", arm_record("without", sha="nogit"))
        out = os.path.join(self.tmp, "joined.json")
        proc = self._run("--a", a, "--b", b, "--out", out)
        self.assertEqual(proc.returncode, 65)
        self.assertFalse(os.path.exists(out))
        self.assertIn("commit sha:", proc.stderr)

    def test_arm_record_carrying_both_paths_exits_64(self):
        both = arm_record("with")
        both["paths"]["without"] = arm_record("without")["paths"]["without"]
        a = self._write("a.json", both)
        b = self._write("b.json", arm_record("without"))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(proc.returncode, 64)

    def test_refusal_exits_65_and_writes_nothing(self):
        a = self._write("a.json", arm_record("with"))
        b = self._write("b.json", arm_record("without", sha="def5678"))
        out = os.path.join(self.tmp, "joined.json")
        proc = self._run("--a", a, "--b", b, "--out", out)
        self.assertEqual(proc.returncode, 65)
        self.assertFalse(os.path.exists(out))
        self.assertIn("commit sha:", proc.stderr)
        self.assertIn("abc1234", proc.stderr)
        self.assertIn("def5678", proc.stderr)

    def test_all_refusals_appear_in_one_message(self):
        a = self._write("a.json", arm_record("with"))
        b = self._write("b.json", arm_record("without", sha="def5678",
                                             digest=_OTHER_DIGEST, era=None))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(proc.returncode, 65)
        for axis in ("era:", "commit sha:", "oracle case-set digest:"):
            self.assertIn(axis, proc.stderr)

    def test_same_arm_inputs_exit_64_not_65(self):
        a = self._write("a.json", arm_record("with"))
        b = self._write("b.json", arm_record("with", run_id="live-other-with"))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(proc.returncode, 64)

    def test_paired_input_exits_64_not_65(self):
        paired = metrics.make_record("r", "2026-08-14T10:20:01Z", "live", "abc1234",
                                     1.0, _pm(), _pm()).to_dict()
        a = self._write("a.json", paired)
        b = self._write("b.json", arm_record("without"))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(proc.returncode, 64)

    def test_missing_argument_exits_64(self):
        self.assertEqual(self._run("--a", "x.json").returncode, 64)
        self.assertEqual(self._run("--nope", "x").returncode, 64)

    def test_unreadable_input_exits_64(self):
        b = self._write("b.json", arm_record("without"))
        proc = self._run("--a", os.path.join(self.tmp, "gone.json"), "--b", b,
                         "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(proc.returncode, 64)

    def test_help_exits_zero(self):
        self.assertEqual(self._run("--help").returncode, 0)

    def test_no_threshold_number_appears_in_the_gate_source(self):
        # AC-11: the gap is reported, never compared. Nothing may introduce a bound.
        with open(os.path.join(_HARNESS, "benchmarkkit", "pairing.py"),
                  encoding="utf-8") as f:
            source = f.read()
        for token in ("MAX_GAP", "GAP_THRESHOLD", "gap >", "gap <"):
            self.assertNotIn(token, source)


class BudgetMismatchWarning(unittest.TestCase):
    """Unequal arm allowances warn on stderr and still join with exit 0."""

    setUp = ExecutableExitCodes.setUp
    tearDown = ExecutableExitCodes.tearDown
    _write = ExecutableExitCodes._write
    _run = ExecutableExitCodes._run

    def test_unequal_budgets_warn_naming_both_and_still_join(self):
        warnings = []
        joined = pairing.join_arm_records(arm_record("with", budget=50.0),
                                          arm_record("without", budget=25.0),
                                          warn=warnings.append)
        self.assertEqual(joined.budget_usd, 75.0)
        self.assertEqual(len(warnings), 1)
        self.assertIn("with budget_usd 50.0", warnings[0])
        self.assertIn("without budget_usd 25.0", warnings[0])
        a = self._write("a.json", arm_record("with", budget=50.0))
        b = self._write("b.json", arm_record("without", budget=25.0))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "j.json"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("bench-pair: warning: arm budgets differ", proc.stderr)

    def test_equal_budgets_join_silently(self):
        warnings = []
        pairing.join_arm_records(arm_record("with", budget=25.0),
                                 arm_record("without", budget=25.0), warn=warnings.append)
        self.assertEqual(warnings, [])
        a = self._write("a.json", arm_record("with", budget=25.0))
        b = self._write("b.json", arm_record("without", budget=25.0))
        proc = self._run("--a", a, "--b", b, "--out", os.path.join(self.tmp, "j.json"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("budgets differ", proc.stderr)


if __name__ == "__main__":
    unittest.main()
