"""Offline experiment preparation rejects drift and incomplete quality evidence."""

from copy import deepcopy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from benchmarklive import experiment

ROOT = Path(__file__).resolve().parents[3]


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.baseline = self.root / "baseline"
        self.optimized = self.root / "optimized"
        self.common = self.root / "common"
        self.output = self.root / "prepared"
        for name in ("benchmark/harness/benchmarklive/stage_table.py",
                     "skills/shared/lib/codex-runtime.sh",
                     "benchmark/harness/benchmarklive/providers/codex/adapter.py",
                     "skills/shared/codex-runtime.md",
                     "benchmark/harness/benchmarklive/providers/codex/pricing.json",
                     "benchmark/harness/bin/bench-native-check",
                     "benchmark/harness/tests/test_native_validation.py"):
            target = self.baseline / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        for name, text in {
            "benchmark/live/prompts/dv.txt": "identical workload with Unicode case folding",
            "benchmark/ttt-template/Tests/Case.swift": "fixture quality test",
            "benchmark/oracle/cases.json": '{"cases":[{"id":"one","tier":"specified","args":[]}]}',
            "skills/cost-optimization/SKILL.md": "baseline instructions"}.items():
            self.write(self.baseline / name, text)
        for stage in ("pl", "ar", "tl", "dv", "dr", "sr", "qa", "dc", "fn", "st"):
            self.write(self.baseline / "benchmark/live/prompts" / (stage + ".txt"), "TASK: Identical test workload")
        shutil.copytree(self.baseline, self.optimized)
        self.write(self.optimized / "skills/cost-optimization/SKILL.md", "optimized instructions")
        for name in experiment.COMMON_NAMES:
            if "." in Path(name).name and name != "TicTacToe.xcodeproj":
                self.write(self.common / name, "common fix")
            else:
                self.write(self.common / name / "fixture.swift", "common fix")
        for name, text in {
            "Tests/TicTacToeKitTests/ModelTests.swift": "\n".join(f"func {name}() {{}}" for name in experiment.UNICODE_CHECKS),
            "Tests/TicTacToeUITests/NativeUITests.swift": "native UI regression",
            "Tests/TicTacToeCLITests/ScriptedCLITests.swift": "native CLI regression",
            "TicTacToe.xcodeproj/xcshareddata/xcschemes/TicTacToe-iOS.xcscheme": "native scheme",
            ".context/native-validation/result.json": '{"status":"passed","historical":true}'}.items():
            self.write(self.common / name, text)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def json(self, path, value):
        self.write(path, json.dumps(value))
        return str(path)

    def prepare(self):
        return experiment.prepare(self.baseline, self.optimized, self.common, self.output,
                                  required_findings=["hidden-defect"])

    def fake_native(self, argv, cwd, timeout):
        if argv[0] == "swift":
            return subprocess.CompletedProcess(argv, 0, "\n".join(experiment.UNICODE_CHECKS) + "\nTest run passed", "")
        native_path = Path(argv[argv.index("--record") + 1])
        app = Path(cwd)
        log = app / ".context" / (native_path.stem + ".log")
        self.write(log, "fresh native invocation output")
        bundle = app / ".context" / (native_path.stem + ".xcresult")
        self.write(bundle / "data", "result bundle")
        self.json(native_path, {"status": "passed", "app": str(app), "returncode": 0, "log": str(log),
                                "result_bundle": str(bundle), "summary": {"passedTests": 28, "failedTests": 0}})
        return subprocess.CompletedProcess(argv, 0, "native validation completed", "")

    def attempt(self, manifest, pair, variant, suffix="", partial=False):
        run = f"{pair}-{variant}{suffix}"
        app = self.root / "apps" / run / "with"
        record_path = self.root / "records" / f"{run}.json"
        prepared = experiment.prepare_trial(manifest, self.output, variant, run, app, record_path)
        log = app / ".context/test.log"
        self.write(log, "complete test evidence")
        unicode_path = self.json(app / ".context/unicode.json", {
            "status": "passed", "run_id": run, "app": str(app), "log": str(log),
            "checks": list(experiment.UNICODE_CHECKS)})
        controls = manifest["invariants"]["controls"]
        count = 100 if variant == "baseline" else getattr(self, "optimized_count", 75)
        record = {
            "run_id": run, "arm": "with", "mode": "live",
            "era": {**{k: controls[k] for k in ("model_pins", "efforts", "pricing", "prompt_contract")},
                    "provider": "codex", "cli_version": "codex fixture", "context_window": 200000,
                    "native_validation": "trusted-host-after-dispatch", "workload_digest": manifest["workload_digest"],
                    "source_digest": manifest["variants"][variant]["source_digest"]},
            "paths": {"with": {"tokens": {"in": count, "out": count, "cache_read": 50},
                               "cost_usd": .10 if variant == "baseline" else .08,
                               "wall_clock_s": 10 if variant == "baseline" else 8,
                               "pass_fail": "fail" if partial else "pass", "app_path": str(app),
                               "oracle": {"built": True, "pass_rate": 1.0, "cases_total": 42,
                                          "cases_passed": 42,
                                          "cases_digest": manifest["invariants"]["oracle_cases_digest"]}}}}
        if partial:
            record["live_partial"] = True
        self.json(record_path, record)
        attempt = {"record": str(record_path), "preparation_receipt": prepared["preparation_receipt"]}
        if not partial:
            validated = experiment.validate_native(manifest, self.output, prepared["preparation_receipt"], self.fake_native)
            self.assertEqual(validated["status"], "passed")
            attempt["quality"] = {"run_id": run, "native_record": validated["native_record"],
                                  "native_receipt": validated["native_receipt"], "unicode_record": validated["unicode_record"],
                                  "findings": [{"id": "hidden-defect", "evidence": str(log)}], "blockers": []}
        return attempt

    def assignments(self, manifest):
        result = {"manifest_id": manifest["manifest_id"], "trials": []}
        for scheduled in manifest["schedule"]:
            for variant in scheduled["order"]:
                result["trials"].append({"pair": scheduled["pair"], "variant": variant,
                                         "attempts": [self.attempt(manifest, scheduled["pair"], variant)]})
        return result

    def test_prepare_snapshots_both_overlays_and_alternates_three_pairs(self):
        manifest = self.prepare()
        self.assertEqual(manifest["status"], "prepared_offline")
        self.assertIn("separate budget", manifest["live_execution"])
        self.assertEqual([s["order"][0] for s in manifest["schedule"]], ["baseline", "optimized", "baseline"])
        self.assertEqual(experiment.verify(manifest, self.output), [])
        self.assertTrue(manifest["intentional_source_changes"])
        self.assertFalse(manifest["common_fixes"]["historical_evidence_is_trial_acceptance"])
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.prepare()

    def test_control_workload_or_native_drift_refuses_preparation(self):
        cases = [("benchmark/live/prompts/dv.txt", "different task"),
                 ("benchmark/harness/bin/bench-native-check", "different quality check"),
                 ("benchmark/harness/benchmarklive/providers/codex/pricing.json", "{}")]
        for name, text in cases:
            with self.subTest(name=name):
                path = self.optimized / name
                original = path.read_text()
                path.write_text(text)
                with self.assertRaisesRegex(ValueError, "invariant mismatch"):
                    self.prepare()
                path.write_text(original)

    def test_changed_model_effort_and_restrictions_refuse_preparation(self):
        changes = [("benchmark/harness/benchmarklive/stage_table.py", '"high"', '"low"'),
                   ("skills/shared/lib/codex-runtime.sh", "gpt-6.1-sol", "gpt-other"),
                   ("benchmark/harness/benchmarklive/providers/codex/adapter.py", '"approval_policy": "never"',
                    '"approval_policy": "on-request"')]
        for name, before, after in changes:
            with self.subTest(name=name):
                path = self.optimized / name
                original = path.read_text()
                self.assertIn(before, original)
                path.write_text(original.replace(before, after))
                with self.assertRaisesRegex(ValueError, "invariant mismatch"):
                    self.prepare()
                path.write_text(original)

    def test_missing_unicode_or_native_overlay_blocks_readiness(self):
        path = self.common / "Tests/TicTacToeKitTests/ModelTests.swift"
        path.write_text("no regression checks")
        with self.assertRaisesRegex(ValueError, "Unicode"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_fewer_than_three_pairs_and_symlinks_are_refused(self):
        with self.assertRaisesRegex(ValueError, "at least three"):
            experiment.prepare(self.baseline, self.optimized, self.common, self.output, pairs=2)
        target = self.common / "Sources/fixture.swift"
        target.unlink()
        target.symlink_to(self.common / "Package.swift")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.prepare()

    def test_verify_detects_source_overlay_and_manifest_tampering(self):
        manifest = self.prepare()
        target = self.output / "workloads/optimized/Sources/fixture.swift"
        target.write_text("changed overlay")
        self.assertIn("optimized common fixes overlay changed", experiment.verify(manifest, self.output))
        manifest["schedule"][0]["order"].reverse()
        faults = experiment.verify(manifest, self.output)
        self.assertIn("manifest fingerprint mismatch", faults)
        self.assertIn("execution order must alternate baseline and optimized", faults)
        self.write(self.optimized / "skills/extra.md", "source drift")
        self.assertIn("optimized source fingerprint changed", experiment.verify(manifest, self.output))

    def test_complete_pairs_report_individuals_and_medians(self):
        manifest = self.prepare()
        result = experiment.analyze(manifest, self.assignments(manifest))
        self.assertEqual(result["status"], "accepted")
        self.assertEqual(len(result["pairs"]), 3)
        self.assertEqual(result["medians"]["fresh_plus_output_reduction_pct"], 25)
        self.assertEqual(result["pairs"][0]["fresh_plus_output"]["optimized"], 150)
        self.assertIn("API-equivalent", result["cost_basis"])

    def test_empty_trials_do_not_claim_observed_savings(self):
        manifest = self.prepare()
        result = experiment.analyze(manifest, {"manifest_id": manifest["manifest_id"], "trials": []})
        self.assertEqual(result["status"], "incomplete")
        self.assertFalse(result["observed_savings_accepted"])
        self.assertEqual(result["medians"]["fresh_plus_output_reduction_pct"], "unavailable")

    def test_missing_quality_rejects_even_when_original_42_oracles_pass(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        assignments["trials"][1]["attempts"][0].pop("quality")
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["status"], "rejected")
        self.assertFalse(result["observed_savings_accepted"])
        self.assertIn("fresh quality evidence unavailable", result["pairs"][0]["quality_faults"])

    def test_lost_findings_and_hidden_blockers_reject_optimization(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        baseline, optimized = assignments["trials"][:2]
        quality = baseline["attempts"][0]["quality"]
        evidence = quality["findings"][0]["evidence"]
        quality["findings"].append({"id": "outside-handoff", "evidence": evidence})
        quality["blockers"].append({"operation": "simulator", "status": "resolved",
                                     "recovery_condition_changed": "trusted host available", "evidence": evidence})
        optimized["attempts"][0]["quality"]["findings"] = []
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["status"], "rejected")
        faults = result["pairs"][0]["quality_faults"]
        self.assertIn("required findings were lost", faults)
        self.assertIn("optimized trial lost baseline findings", faults)
        self.assertIn("optimized trial concealed baseline blockers", faults)

    def test_pending_native_missing_bundle_and_wrong_app_reject(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        native_path = Path(assignments["trials"][1]["attempts"][0]["quality"]["native_record"])
        native = json.loads(native_path.read_text())
        native.update(status="blocked", app="/another-app", result_bundle="/missing-bundle")
        native_path.write_text(json.dumps(native))
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["status"], "rejected")
        faults = result["pairs"][0]["quality_faults"]
        self.assertTrue(any("native invocation evidence changed" in f for f in faults))

    def test_wrong_variant_source_or_without_records_reject(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        path = Path(assignments["trials"][1]["attempts"][0]["record"])
        record = json.loads(path.read_text())
        record["era"]["source_digest"] = "wrong-source"
        record["arm"] = "without"
        path.write_text(json.dumps(record))
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["status"], "rejected")
        self.assertIn("experiment requires WITH-only records", result["pairs"][0]["quality_faults"])
        self.assertIn("trial source does not match its declared variant", result["pairs"][0]["quality_faults"])

    def test_failed_attempts_and_costs_are_retained_before_recovered_trial(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        trial = assignments["trials"][0]
        failed = self.attempt(manifest, 1, "baseline", suffix="-failed", partial=True)
        trial["attempts"].insert(0, failed)
        result = experiment.analyze(manifest, assignments)
        attempts = result["pairs"][0]["trials"]["baseline"]["attempts"]
        self.assertEqual(len(attempts), 2)
        self.assertTrue(attempts[0]["record"]["live_partial"])
        self.assertEqual(result["pairs"][0]["estimated_cost_usd"]["baseline"], .2)
        self.assertEqual(result["status"], "accepted")

    def test_unknown_attempt_cost_is_unavailable_and_never_zero(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        path = Path(assignments["trials"][0]["attempts"][0]["record"])
        record = json.loads(path.read_text())
        record["paths"]["with"]["cost_usd"] = None
        path.write_text(json.dumps(record))
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["pairs"][0]["estimated_cost_usd"]["baseline"], "unavailable")
        self.assertEqual(result["status"], "rejected")

    def test_duplicate_attempt_ids_cannot_masquerade_as_repeated_trials(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        first = assignments["trials"][0]["attempts"][0]
        assignments["trials"][3]["attempts"] = [deepcopy(first)]
        with self.assertRaisesRegex(ValueError, "unique"):
            experiment.analyze(manifest, assignments)

    def test_offline_preparation_and_analysis_never_launch_subprocesses(self):
        with patch("subprocess.run", side_effect=AssertionError("offline experiment launched a command")):
            manifest = self.prepare()
            self.assertEqual(experiment.verify(manifest, self.output), [])
            result = experiment.analyze(manifest, self.assignments(manifest))
        self.assertEqual(result["status"], "accepted")
        self.assertAlmostEqual(result["observed_totals"]["estimated_cost_usd"]["baseline"], .3)
        self.assertEqual(result["medians"]["fresh_plus_output"], {"baseline": 200, "optimized": 150})

    def test_trial_layout_and_returned_argv_match_the_real_harness(self):
        from benchmarklive.workdirs import resolve_workdir_root
        manifest = self.prepare()
        scratch = Path(resolve_workdir_root(str(self.root / "scratch")))
        app = scratch / "layout-trial" / "with"
        prepared = experiment.prepare_trial(manifest, self.output, "baseline", "layout-trial", app,
                                            self.root / "layout-record.json")
        argv = prepared["argv_template"]
        self.assertEqual(argv[argv.index("--workdir-root") + 1], str(scratch))
        self.assertEqual(Path(argv[argv.index("--workdir-root") + 1]) /
                         argv[argv.index("--workdir") + 1] / "with", Path(prepared["app"]))
        self.assertIn("<separately-authorized-budget-usd>", argv)
        self.assertEqual(experiment.files(app, experiment.COMMON_NAMES), manifest["common_fixes"]["files"])
        with self.assertRaisesRegex(ValueError, "harness layout"):
            experiment.prepare_trial(manifest, self.output, "baseline", "wrong-layout", self.root / "unused-app",
                                      self.root / "unused-record.json")

    def test_wrong_workload_and_common_overlay_receipts_reject(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        attempt = assignments["trials"][0]["attempts"][0]
        record_path = Path(attempt["record"])
        record = json.loads(record_path.read_text())
        record["era"]["workload_digest"] = "another-workload"
        self.json(record_path, record)
        result = experiment.analyze(manifest, assignments)
        self.assertTrue(any("record workload differs" in fault for fault in result["pairs"][0]["quality_faults"]))
        record["era"]["workload_digest"] = manifest["workload_digest"]
        self.json(record_path, record)
        receipt_path = Path(attempt["preparation_receipt"])
        receipt = json.loads(receipt_path.read_text())
        receipt["common_fixes_digest"] = "wrong-overlay"
        receipt["receipt_id"] = experiment.fingerprint({k: v for k, v in receipt.items() if k != "receipt_id"})
        self.json(receipt_path, receipt)
        result = experiment.analyze(manifest, assignments)
        self.assertTrue(any("overlay or run" in fault for fault in result["pairs"][0]["quality_faults"]))

    def test_missing_trial_preparation_never_accepts_operator_era_assertions(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        assignments["trials"][0]["attempts"][0].pop("preparation_receipt")
        result = experiment.analyze(manifest, assignments)
        self.assertEqual(result["status"], "rejected")
        self.assertIn("verified trial preparation unavailable", result["pairs"][0]["quality_faults"])

    def test_stale_native_evidence_rejects_changed_source_in_the_same_app(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        attempt = assignments["trials"][0]["attempts"][0]
        record = json.loads(Path(attempt["record"]).read_text())
        app = Path(record["paths"]["with"]["app_path"])
        self.write(app / "Sources/fixture.swift", "changed after validation")
        result = experiment.analyze(manifest, assignments)
        self.assertTrue(any("stale or belongs" in fault for fault in result["pairs"][0]["quality_faults"]))

    def test_other_invocation_and_tampered_native_log_are_rejected(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        attempt = assignments["trials"][0]["attempts"][0]
        first = attempt["quality"]
        next_run = experiment.validate_native(manifest, self.output, attempt["preparation_receipt"], self.fake_native)
        first["native_record"] = next_run["native_record"]
        result = experiment.analyze(manifest, assignments)
        self.assertTrue(any("differs from its invocation" in fault for fault in result["pairs"][0]["quality_faults"]))
        first.update(next_run)
        native = json.loads(Path(first["native_record"]).read_text())
        self.write(Path(native["log"]), "modified after invocation")
        result = experiment.analyze(manifest, assignments)
        self.assertTrue(any("native invocation evidence changed" in fault for fault in result["pairs"][0]["quality_faults"]))

    def test_app_changes_during_validation_are_recorded_and_blocked(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        attempt = assignments["trials"][0]["attempts"][0]
        def changing(argv, cwd, timeout):
            result = self.fake_native(argv, cwd, timeout)
            if argv[0] != "swift":
                self.write(Path(cwd) / "Sources/new-source.swift", "changed during invocation")
            return result
        receipt = experiment.validate_native(manifest, self.output, attempt["preparation_receipt"], changing)
        self.assertEqual(receipt["status"], "blocked")
        retained = json.loads(Path(receipt["native_receipt"]).read_text())
        self.assertNotEqual(retained["inputs_before"], retained["inputs_after"])
        self.assertIn("changed during", retained["reason"])

    def test_token_increase_is_comparable_but_never_claimed_as_savings(self):
        manifest = self.prepare()
        self.optimized_count = 130
        result = experiment.analyze(manifest, self.assignments(manifest))
        self.assertTrue(result["comparison_valid"])
        self.assertFalse(result["observed_savings_accepted"])
        self.assertEqual(result["medians"]["fresh_plus_output_reduction_pct"], -30)

    def test_real_persisted_relative_app_paths_resolve_from_each_variant_root(self):
        from benchmarklive.workdirs import link_persisted
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        for trial in assignments["trials"]:
            attempt = trial["attempts"][0]
            path = Path(attempt["record"])
            record = json.loads(path.read_text())
            app = record["paths"]["with"]["app_path"]
            source_root = Path(manifest["variants"][trial["variant"]]["root"])
            persist = source_root / "benchmark/workdirs" / record["run_id"]
            self.assertIsNone(link_persisted(str(persist), "with", app))
            record["paths"]["with"]["app_path"] = f'benchmark/workdirs/{record["run_id"]}/with'
            self.json(path, record)
            validated = experiment.validate_native(manifest, self.output, attempt["preparation_receipt"], self.fake_native)
            attempt["quality"].update(validated)
        unrelated = self.root / "assignments-elsewhere"
        unrelated.mkdir()
        result = experiment.analyze(manifest, assignments, unrelated)
        self.assertTrue(result["comparison_valid"])
        self.assertTrue(result["observed_savings_accepted"])
        first = assignments["trials"][0]["attempts"][0]
        record = json.loads(Path(first["record"]).read_text())
        record["paths"]["with"]["app_path"] = "benchmark/workdirs/other-run/with"
        self.json(Path(first["record"]), record)
        rejected = experiment.analyze(manifest, assignments, unrelated)
        self.assertFalse(rejected["comparison_valid"])
        self.assertTrue(any("record app differs" in fault for fault in rejected["pairs"][0]["quality_faults"]))

    def test_alternating_execution_order_and_duplicate_records_are_enforced(self):
        manifest = self.prepare()
        assignments = self.assignments(manifest)
        assignments["trials"][:2] = reversed(assignments["trials"][:2])
        with self.assertRaisesRegex(ValueError, "order"):
            experiment.analyze(manifest, assignments)
        assignments["trials"][:2] = reversed(assignments["trials"][:2])
        assignments["trials"].insert(1, deepcopy(assignments["trials"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            experiment.analyze(manifest, assignments)


if __name__ == "__main__":
    unittest.main()
