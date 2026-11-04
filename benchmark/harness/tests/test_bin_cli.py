"""Subprocess tests for the four CLIs in benchmark/harness/bin/.

bench-live and bench-deterministic are covered by ARGV VALIDATION ONLY: every
subprocess case here must exit on a usage error before any dispatch, build or
spend can occur. The assertions therefore pin both the exit code and the absence
of any output artifact — a guard that fires after the record has been written is
not a guard. The single exception is TestBenchLiveArmWiring, which runs in-process
against a stubbed dispatch(); it cannot spend either. bench-report and
bench-analyze are exercised end to end against throwaway fixtures because neither
reaches the live world.

stdlib unittest only (no pytest), matching the rest of this suite.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

BIN_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin")


def run_cli(name, args, cwd):
    """Invoke bin/<name> as a subprocess; never inherits this process's stdin."""
    return subprocess.run(
        [sys.executable, os.path.join(BIN_DIR, name), *args],
        cwd=cwd, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=120,
    )


class CLITestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def write_json(self, relpath, payload):
        path = os.path.join(self.tmp, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        return path

    def assertNoRunArtifacts(self):
        """No CLI under test may leave a record, history or workdir behind."""
        leaked = []
        for root, _dirs, files in os.walk(self.tmp):
            leaked.extend(os.path.join(root, f) for f in files)
        self.assertEqual([], leaked, "a usage-error path wrote an artifact")


# ---------------------------------------------------------------------------
# bench-report
# ---------------------------------------------------------------------------

MINIMAL_HISTORY = {
    "deterministic": [{
        "run_id": "deterministic-20200101T000000Z-abc1234",
        "timestamp_utc": "2020-01-01T00:00:00Z",
        "mode": "deterministic",
        "git_sha": "abc1234",
        "paths": {
            "with": {"loc_produced": 120, "test_count": 8, "pass_fail": "pass"},
            "without": {"loc_produced": 90, "test_count": 4, "pass_fail": "pass"},
        },
        "comparison": {},
        "stages": [],
    }],
    "live": [],
}


class TestBenchReport(CLITestCase):
    def test_renders_html_from_a_minimal_history_fixture(self):
        history = self.write_json("benchmark/results/history.json", MINIMAL_HISTORY)
        out = os.path.join(self.tmp, "out", "result.html")

        proc = run_cli("bench-report", ["--history", history, "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("[report] wrote", proc.stdout)
        self.assertTrue(os.path.isfile(out))
        with open(out, encoding="utf-8") as f:
            html = f.read()
        self.assertIn("<html", html.lower())
        # The fixture's run must actually reach the page — an empty shell would
        # pass a mere "file exists" check.
        self.assertIn("deterministic-20200101T000000Z-abc1234", html)

    def test_history_flag_without_a_value_is_a_usage_error(self):
        proc = run_cli("bench-report", ["--history"], self.tmp)

        self.assertEqual(64, proc.returncode)
        self.assertIn("--history needs a value", proc.stderr)
        self.assertEqual("", proc.stdout)
        self.assertNoRunArtifacts()

    def test_unknown_argument_is_a_usage_error(self):
        proc = run_cli("bench-report", ["--histry", "x"], self.tmp)

        self.assertEqual(64, proc.returncode)
        self.assertIn("unknown arg '--histry'", proc.stderr)
        self.assertNoRunArtifacts()

    def test_help_exits_zero_and_writes_nothing(self):
        proc = run_cli("bench-report", ["--help"], self.tmp)

        self.assertEqual(0, proc.returncode)
        self.assertIn("bench-report [--history", proc.stdout)
        self.assertNoRunArtifacts()

    def test_absent_history_file_still_renders_an_empty_report(self):
        # build_report is deliberately tolerant: a first run with no history
        # must produce a page rather than a traceback.
        out = os.path.join(self.tmp, "result.html")
        proc = run_cli(
            "bench-report",
            ["--history", os.path.join(self.tmp, "nope.json"), "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertTrue(os.path.isfile(out))


# ---------------------------------------------------------------------------
# bench-analyze
# ---------------------------------------------------------------------------

LIVE_RECORD = {
    "run_id": "live-20200101T000000Z-abc1234",
    "timestamp_utc": "2020-01-01T00:00:00Z",
    "mode": "live",
    "git_sha": "abc1234",
    "budget_usd": 50.0,
    "paths": {
        "with": {"loc_produced": 120, "test_count": 8, "pass_fail": "pass",
                 "cost_usd": 1.25, "coverage_pct": 82.0},
        "without": {"loc_produced": 90, "test_count": 4, "pass_fail": "fail",
                    "cost_usd": 0.40, "coverage_pct": None},
    },
    "comparison": {},
    "stages": [],
}


class TestBenchAnalyze(CLITestCase):
    def test_writes_markdown_analysis_for_an_explicit_record(self):
        record = self.write_json("record.json", LIVE_RECORD)
        out = os.path.join(self.tmp, "analysis", "analysis.md")

        proc = run_cli("bench-analyze", ["--run", record, "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("[analyze] wrote", proc.stdout)
        self.assertTrue(os.path.isfile(out))
        with open(out, encoding="utf-8") as f:
            markdown = f.read()
        self.assertIn("live-20200101T000000Z-abc1234", markdown)

    def test_picks_the_newest_live_record_out_of_history(self):
        older = dict(LIVE_RECORD, run_id="live-older", timestamp_utc="2019-01-01T00:00:00Z")
        history = self.write_json(
            "benchmark/results/history.json", {"live": [older, LIVE_RECORD]})
        out = os.path.join(self.tmp, "analysis.md")

        proc = run_cli("bench-analyze", ["--history", history, "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode, proc.stderr)
        with open(out, encoding="utf-8") as f:
            markdown = f.read()
        # The newest record is the SUBJECT; the older one may only be named as the
        # era-comparability baseline in the caveats.
        self.assertIn("# Benchmark Analysis — live-20200101T000000Z-abc1234", markdown)
        body, _, caveats = markdown.partition("## validity-caveats")
        self.assertNotIn("live-older", body)

    def test_previous_history_record_is_era_compared_without_a_reference_flag(self):
        older = dict(LIVE_RECORD, run_id="live-older", timestamp_utc="2019-01-01T00:00:00Z")
        history = self.write_json(
            "benchmark/results/history.json", {"live": [older, LIVE_RECORD]})
        out = os.path.join(self.tmp, "analysis.md")

        proc = run_cli("bench-analyze", ["--history", history, "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode, proc.stderr)
        with open(out, encoding="utf-8") as f:
            caveats = f.read().partition("## validity-caveats")[2]
        self.assertIn("cross-era vs previous run live-older", caveats)

    def test_empty_history_reports_no_records_instead_of_writing_a_stub(self):
        # PREMISE CORRECTION: the plan called for "empty history -> error". The
        # CLI documents "0 success (incl. 'no live records yet')" and behaves
        # that way; asserting an error here would pin a shape it never emits.
        history = self.write_json("benchmark/results/history.json", {"live": []})
        out = os.path.join(self.tmp, "analysis.md")

        proc = run_cli("bench-analyze", ["--history", history, "--out", out], self.tmp)

        self.assertEqual(0, proc.returncode)
        self.assertIn("no live records yet", proc.stdout)
        self.assertFalse(os.path.exists(out))

    def test_an_unreadable_record_is_a_hard_error_not_a_silent_pass(self):
        bad = os.path.join(self.tmp, "bad.json")
        with open(bad, "w", encoding="utf-8") as f:
            f.write("NOT JSON {{{")

        proc = run_cli("bench-analyze", ["--run", bad], self.tmp)

        self.assertEqual(1, proc.returncode)
        self.assertIn("[analyze] error:", proc.stderr)

    def test_flag_without_a_value_and_unknown_flag_are_usage_errors(self):
        proc = run_cli("bench-analyze", ["--run"], self.tmp)
        self.assertEqual(64, proc.returncode)
        self.assertIn("--run needs a value", proc.stderr)

        proc = run_cli("bench-analyze", ["--runn", "x"], self.tmp)
        self.assertEqual(64, proc.returncode)
        self.assertIn("unknown arg '--runn'", proc.stderr)
        self.assertNoRunArtifacts()


# ---------------------------------------------------------------------------
# bench-live — ARGV VALIDATION ONLY. No case here may reach dispatch.
# ---------------------------------------------------------------------------

class TestBenchLiveArgv(CLITestCase):
    def _assert_usage_error(self, args, needle):
        proc = run_cli("bench-live", args, self.tmp)
        self.assertEqual(64, proc.returncode, f"{args!r} -> {proc.stderr!r}")
        self.assertIn(needle, proc.stderr)
        self.assertEqual("", proc.stdout, "a refused run must print nothing on stdout")
        self.assertNoRunArtifacts()

    def test_the_three_required_flags_are_required(self):
        self._assert_usage_error([], "--workdir, --budget and --record are required")
        self._assert_usage_error(
            ["--workdir", "w"], "--workdir, --budget and --record are required")
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1"],
            "--workdir, --budget and --record are required")

    def test_a_non_numeric_budget_is_refused_before_dispatch(self):
        # The budget cap is the only spend ceiling; an unparsed value must never
        # be allowed to reach the dispatcher as a default.
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "fifty", "--record", "r.json"],
            "--budget must be a number, got 'fifty'")

    def test_an_unknown_stage_code_is_refused(self):
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1", "--record", "r.json", "--stages", "ZZ"],
            "unknown stage code 'ZZ'")

    def test_an_empty_stage_list_is_refused(self):
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1", "--record", "r.json", "--stages", ", ,"],
            "--stages needs at least one stage code")

    def test_an_invalid_capture_mode_is_refused(self):
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1", "--record", "r.json", "--capture", "yaml"],
            "--capture must be json or stream-json")

    def test_an_invalid_without_arm_is_refused(self):
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1", "--record", "r.json",
             "--without-arm", "maybe"],
            "--without-arm must be real or skip")

    def test_a_trailing_flag_without_a_value_is_refused(self):
        self._assert_usage_error(
            ["--workdir", "w", "--budget", "1", "--record"], "--record needs a value")

    def test_unknown_flags_are_refused_rather_than_ignored(self):
        self._assert_usage_error(["--dry-run"], "unknown arg '--dry-run'")

    def test_help_exits_zero_without_touching_the_world(self):
        proc = run_cli("bench-live", ["--help"], self.tmp)
        self.assertEqual(0, proc.returncode)
        self.assertIn("bench-live --workdir", proc.stdout)
        self.assertNoRunArtifacts()


# ---------------------------------------------------------------------------
# bench-live — arm-selection wiring. In-process with dispatch STUBBED OUT: the
# argv-only rule above exists to prevent spend, and a stub cannot spend. This is
# the only way to see which selection the CLI hands to dispatch().
# ---------------------------------------------------------------------------

class TestBenchLiveArmWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import importlib.util
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader("bench_live_cli", os.path.join(BIN_DIR, "bench-live"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.cli)
        cls.full = list(cls.cli.budget_mod.PIPELINE_STAGES)

    def setUp(self):
        self.calls = []
        real = self.cli.dispatch_mod.dispatch
        self.addCleanup(setattr, self.cli.dispatch_mod, "dispatch", real)
        self.cli.dispatch_mod.dispatch = lambda **kw: self.calls.append(kw) or 0

    def _run(self, *args):
        with self.assertRaises(SystemExit) as exit_ctx:
            self.cli.main(["--workdir", "w", "--budget", "1", "--record", "r.json", *args])
        self.assertEqual(0, exit_ctx.exception.code)
        return self.calls[-1]

    def test_no_stages_flag_pairs_both_arms(self):
        self.assertEqual(self._run()["selection"].dispatch, ("without", "with"))

    def test_arm_records_go_beside_the_record_directory_under_live_arm(self):
        kwargs = self._run("--record", "/bench/results/runs/live/live-1.json")
        self.assertEqual(kwargs["arm_record_dir"], "/bench/results/runs/live-arm")

    def test_stages_listing_the_whole_pipeline_pairs_both_arms(self):
        kwargs = self._run("--stages", ",".join(self.full))
        self.assertEqual(kwargs["selection"].dispatch, ("without", "with"))
        self.assertEqual(kwargs["stages"], self.full)

    def test_a_reordered_duplicated_full_list_is_still_a_full_run(self):
        kwargs = self._run("--stages", ",".join(reversed(self.full)) + ",pl")
        self.assertEqual(kwargs["selection"].dispatch, ("without", "with"))
        self.assertEqual(kwargs["stages"], self.full)  # canonical order regardless

    def test_a_genuine_subset_keeps_the_with_only_default(self):
        kwargs = self._run("--stages", "PL,AR")
        self.assertEqual(kwargs["selection"].dispatch, ("with",))
        self.assertEqual(kwargs["stages"], ["PL", "AR"])

    def test_explicit_without_arm_still_overrides_a_subset(self):
        kwargs = self._run("--stages", "PL", "--without-arm", "real")
        self.assertEqual(kwargs["selection"].dispatch, ("without", "with"))

    def test_workdir_root_flag_reaches_dispatch_and_defaults_to_none(self):
        self.assertIsNone(self._run()["workdir_root"])
        self.assertEqual(self._run("--workdir-root", "/scratch/arms")["workdir_root"],
                         "/scratch/arms")

    def test_waiting_on_the_usage_limit_is_on_unless_switched_off(self):
        self.assertTrue(self._run()["wait_on_limit"])
        self.assertTrue(self._run("--wait-on-limit")["wait_on_limit"])
        self.assertFalse(self._run("--no-wait-on-limit")["wait_on_limit"])


# ---------------------------------------------------------------------------
# bench-deterministic — ARGV VALIDATION ONLY. A complete argv would build two
# Swift apps, so only refusal paths are exercised.
# ---------------------------------------------------------------------------

class TestBenchDeterministicArgv(CLITestCase):
    COMPLETE = ["--workdir", "w", "--run-id", "r", "--timestamp", "20200101T000000Z",
                "--git-sha", "abc1234", "--record", "rec.json",
                "--history", "h.json", "--runs-dir", "runs"]

    def _assert_usage_error(self, args, needle):
        proc = run_cli("bench-deterministic", args, self.tmp)
        self.assertEqual(64, proc.returncode, f"{args!r} -> {proc.stderr!r}")
        self.assertIn(needle, proc.stderr)
        self.assertNoRunArtifacts()

    def test_every_required_flag_is_individually_required(self):
        for flag in ("--workdir", "--run-id", "--timestamp", "--git-sha",
                     "--record", "--history", "--runs-dir"):
            with self.subTest(missing=flag):
                idx = self.COMPLETE.index(flag)
                args = self.COMPLETE[:idx] + self.COMPLETE[idx + 2:]
                self._assert_usage_error(args, f"missing required {flag}")

    def test_a_flag_without_a_value_is_incomplete_not_silently_dropped(self):
        self._assert_usage_error(["--workdir"], "unknown or incomplete arg '--workdir'")

    def test_unknown_flags_are_refused(self):
        self._assert_usage_error(["--wrkdir", "w"], "unknown or incomplete arg '--wrkdir'")

    def test_help_exits_zero_and_builds_nothing(self):
        proc = run_cli("bench-deterministic", ["--help"], self.tmp)
        self.assertEqual(0, proc.returncode)
        self.assertIn("bench-deterministic --workdir", proc.stdout)
        self.assertNoRunArtifacts()

    def test_help_wins_over_an_otherwise_complete_argv(self):
        # The safety property: --help short-circuits before deterministic_run.run
        # is ever reached, so no Swift build starts.
        proc = run_cli("bench-deterministic", self.COMPLETE + ["--help"], self.tmp)
        self.assertEqual(0, proc.returncode)
        self.assertIn("bench-deterministic --workdir", proc.stdout)
        self.assertNoRunArtifacts()


if __name__ == "__main__":
    unittest.main()
