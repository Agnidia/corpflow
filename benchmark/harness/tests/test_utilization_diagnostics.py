"""Additive utilization reporting preserves missing data and failure evidence."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from benchmarkkit import report
from benchmarkkit.metrics import StageAttribution
from benchmarklive import diagnostics, dispatch
from benchmarklive.arm_exec import ArmSpec, DispatchFailure
from benchmarklive.budget import RunningTally
from benchmarklive.records import _stage_attributions
from benchmarklive.stage_usage import StageUsage


def command(text, code=0, operation="xcodebuild test"):
    return json.dumps({"type": "item.completed", "item": {"type": "command_execution",
                       "command": operation, "aggregated_output": text, "exit_code": code}}, ensure_ascii=False)


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.context = self.root / ".context"
        self.context.mkdir()

    def test_unicode_tool_lengths_and_environment_repetitions_are_not_tokens(self):
        output = "Permission denied: simulator🙂"
        captured = "\n".join([command(output, 1), command(output, 1), command("OK", 0)])
        data = diagnostics.capture_diagnostics(captured, self.root, "DV")
        self.assertEqual(data["tool_output_characters"], 2 * len(output) + 2)
        self.assertEqual(data["environment_failure_count"], 2)
        self.assertEqual(data["environment_failure_repetitions"], 1)
        self.assertIn("not tokens", data["tool_output_unit"])
        self.assertIsNone(data["artifact_characters"])

    def test_missing_capture_measurements_remain_unavailable(self):
        for text in ("", "malformed capture", '{"type":"turn.completed"}'):
            with self.subTest(text=text):
                data = diagnostics.capture_diagnostics(text, self.root, "DV")
                for key in ("tool_output_characters", "environment_failure_repetitions", "truncation_count",
                            "artifact_characters", "instruction_fingerprint", "ledger_summary"):
                    self.assertIsNone(data[key])

    def test_empty_measured_output_is_a_real_zero(self):
        data = diagnostics.capture_diagnostics(command(""), self.root, "DV")
        self.assertEqual(data["tool_output_characters"], 0)
        self.assertEqual(data["truncation_count"], 0)

    def test_provider_limits_transients_and_implementation_errors_are_separate(self):
        captured = "\n".join([command("usage limit reached", 1), command("HTTP 503 service unavailable", 1),
                               command("assertion failed", 1), command("permission denied in fixture", 0)])
        data = diagnostics.capture_diagnostics(captured, self.root, "DV")
        self.assertEqual(data["environment_failure_count"], 0)

    def test_truncation_markers_and_claude_tool_results_are_measured(self):
        capture = json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "a", "is_error": True,
             "content": [{"type": "text", "text": "Permission denied\n<<<TRUNCATED>>>"}]}]}})
        data = diagnostics.capture_diagnostics(capture, self.root, "DR")
        self.assertEqual(data["truncation_count"], 1)
        self.assertEqual(data["environment_failure_count"], 1)

    def test_distinct_claude_tool_ids_resolve_to_the_same_failed_operation(self):
        events = []
        for identifier in ("first", "second"):
            events.extend([
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": identifier,
                  "name": "Bash", "input": {"command": "xcodebuild test"}}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": identifier,
                  "content": "Permission denied", "is_error": True}]}}])
        data = diagnostics.capture_diagnostics("\n".join(json.dumps(e) for e in events), self.root, "DV")
        self.assertEqual(data["environment_failure_repetitions"], 1)

    def test_artifact_sizes_and_instruction_fingerprint_have_separate_sources(self):
        artifact = self.context / "development-0.md"
        artifact.write_text("artifact🙂\nsecond line\n")
        (self.context / "state.json").write_text(json.dumps({"tasks": {
            "DV0": {"status": "completed", "verdict": "ok", "artifact": "development-0.md",
                    "metadata": {"stage": "DV"}}}}))
        fingerprint = "sha256:" + "a" * 64
        (self.context / "instructions-DV.json").write_text(json.dumps({"stage": "DV", "fingerprint": fingerprint}))
        data = diagnostics.capture_diagnostics(command("test output"), self.root, "DV", fingerprint)
        self.assertEqual(data["artifact_characters"], len(artifact.read_text()))
        self.assertEqual(data["handoff_sizes"][0]["lines"], 2)
        self.assertEqual(data["instruction_fingerprint"], fingerprint)
        self.assertNotEqual(data["tool_output_characters"], data["artifact_characters"])
        self.assertEqual(data["ledger_summary"]["approval"], "not evaluated; diagnostics only")

    def test_child_sidecar_cannot_override_the_authoritative_instruction_fingerprint(self):
        (self.context / "instructions-DV.json").write_text(json.dumps({"stage": "DV", "fingerprint": "sha256:" + "b" * 64}))
        authoritative = "sha256:" + "a" * 64
        data = diagnostics.capture_diagnostics("", self.root, "DV", authoritative)
        self.assertEqual(data["instruction_fingerprint"], authoritative)
        self.assertIsNone(diagnostics.capture_diagnostics("", self.root, "DV")["instruction_fingerprint"])

    def test_contradictory_status_and_missing_evidence_are_not_approved(self):
        (self.context / "state.json").write_text(json.dumps({"tasks": {
            "DV0": {"status": "completed", "verdict": "blocked", "artifact": "missing.md"},
            "QA0": {"status": "pending"}}}))
        data = diagnostics.capture_diagnostics("", self.root, "DV")
        summary = data["ledger_summary"]
        self.assertEqual(len(summary["contradictions"]), 2)
        self.assertEqual(summary["status_counts"], {"completed": 1, "pending": 1})
        self.assertFalse(data["handoff_sizes"][0]["available"])
        self.assertIsNone(data["artifact_characters"])

    def test_artifact_escape_is_reported_without_reading_the_target(self):
        (self.context / "state.json").write_text(json.dumps({"tasks": {
            "DV0": {"status": "completed", "artifact": "../../secret.md"}}}))
        data = diagnostics.capture_diagnostics("", self.root, "DV")
        self.assertIn("outside the context", data["ledger_summary"]["contradictions"][0])
        self.assertEqual(data["handoff_sizes"], [])

    def test_missing_manifest_cannot_be_fabricated_from_artifact_hashes(self):
        data = diagnostics.capture_diagnostics(command("x"), self.root, "DV")
        self.assertIsNone(data["instruction_fingerprint"])

    def test_repeated_environment_failures_across_attempts_are_aggregated(self):
        first = diagnostics.capture_diagnostics(command("Permission denied", 1), self.root, "DV")
        second = diagnostics.capture_diagnostics(command("Permission denied", 1), self.root, "DV")
        merged = diagnostics.merge_diagnostics(second, first)
        self.assertEqual(merged["environment_failure_count"], 2)
        self.assertEqual(merged["environment_failure_repetitions"], 1)

    def test_an_unmeasured_attempt_does_not_become_a_complete_known_total(self):
        missing = diagnostics.capture_diagnostics("", self.root, "DV")
        measured = diagnostics.capture_diagnostics(command("Permission denied", 1), self.root, "DV")
        for merged in (diagnostics.merge_diagnostics(measured, missing),
                       diagnostics.merge_diagnostics(missing, measured)):
            for key in ("tool_output_characters", "environment_failure_count", "environment_failure_repetitions",
                        "truncation_count", "environment_failures"):
                self.assertIsNone(merged[key])


class RecordReportTests(unittest.TestCase):
    def test_legacy_stage_roundtrip_does_not_gain_fields(self):
        old = {"stage": "DV", "fresh_in": 10, "cache_creation": 0, "cache_read": 40,
               "out": 5, "cost_usd": .01}
        self.assertEqual(StageAttribution.from_dict(old).to_dict(), old)

    def test_additive_diagnostics_and_duration_roundtrip(self):
        usage = StageUsage(input_tokens=10, output_tokens=5, cache_read=40, cost_usd=.01,
                           duration_s=3.5, diagnostics={"tool_output_characters": 500})
        stage = _stage_attributions([("DV", usage)], "with")[0].to_dict()
        self.assertEqual(StageAttribution.from_dict(stage).to_dict(), stage)
        self.assertEqual(stage["duration_s"], 3.5)
        self.assertEqual(stage["out"], 5)
        self.assertEqual(stage["diagnostics"]["tool_output_characters"], 500)

    def test_report_renders_legacy_measurements_as_unavailable(self):
        html = report.utilization_html({"stages": [{"stage": "DV", "fresh_in": 10,
                                        "cache_read": 40, "out": 5, "cost_usd": .01}]})
        self.assertIn("unavailable", html)
        self.assertIn("captured tool characters", html)
        self.assertIn("reasoning", html)
        self.assertIn("artifact length remains separate", html)

    def test_failed_unaccounted_attempt_still_renders_duration_and_unavailable_usage(self):
        html = report.utilization_html({"era": {"accounting": {"with": {"attempts": [
            {"stage": "DV", "attempt": 1, "status": "failed", "cost_usd": None, "duration_s": 2.5,
             "diagnostics": {"tool_output_characters": 100}}]}}}})
        self.assertIn("DV attempt 1 (failed)", html)
        self.assertIn("2.5", html)
        self.assertIn("unavailable", html)

    def test_failed_measured_attempt_renders_its_available_tokens(self):
        html = report.utilization_html({"era": {"accounting": {"with": {"attempts": [
            {"stage": "DV", "attempt": 1, "status": "failed", "cost_usd": .015, "duration_s": 2.5,
             "fresh_in": 120, "cache_read": 80, "cache_creation": 0, "out": 35}]}}}})
        for value in (120, 80, 35):
            self.assertIn(f"<td>{value}</td>", html)
        self.assertIn("utilization-scroll", html)

    def test_failed_attempt_durations_and_costs_are_retained(self):
        current = StageUsage(input_tokens=10, output_tokens=5, cost_usd=.2, duration_s=2,
                             diagnostics={"tool_output_characters": 100})
        previous = StageUsage(input_tokens=2, output_tokens=1, cost_usd=.1, duration_s=3,
                              diagnostics={"tool_output_characters": 50})
        dispatch.fold_interrupted(current, [previous])
        self.assertEqual(current.duration_s, 5)
        self.assertAlmostEqual(current.cost_usd, .3)
        self.assertEqual(current.diagnostics["tool_output_characters"], 150)

    def test_non_limit_dispatch_failure_retains_partial_record_and_duration(self):
        with tempfile.TemporaryDirectory() as tmp:
            stdout = json.dumps({"usage": {"input_tokens": 20, "output_tokens": 3}, "total_cost_usd": .15})
            class FailingDispatcher:
                def run(self, argv, prompt):
                    raise DispatchFailure("implementation failed", stdout=stdout, returncode=1)
            class Clock:
                elapsed = 2.5
                def start(self):
                    pass
            persisted = []
            arm = ArmSpec("with", True, tmp, str(Path(tmp) / "audit.jsonl"))
            with patch.object(dispatch, "Timer", Clock), self.assertRaises(DispatchFailure):
                dispatch.run_arm(arm, {"PL": "task"}, FailingDispatcher(), RunningTally(1), "estimate.py", ["PL"],
                                 estimate_runner=lambda _: '{"ai_cost":{"usd":0.01}}', captures_dir=tmp,
                                 persist_partial=persisted.append)
            self.assertTrue(persisted[-1].partial)
            usage = persisted[-1].usages[0][1]
            self.assertEqual(usage.duration_s, 2.5)
            self.assertEqual(usage.cost_usd, .15)
            self.assertEqual(usage.output_tokens, 3)
            self.assertTrue((Path(tmp) / "with-PL.attempt-1.diagnostics.json").is_file())
            attempt = json.loads((Path(tmp) / "with-PL.attempt-1.diagnostics.json").read_text())
            self.assertEqual(attempt["fresh_in"], 20)
            self.assertEqual(attempt["out"], 3)
            self.assertEqual(persisted[-1].attempts[0]["fresh_in"], 20)


if __name__ == "__main__":
    unittest.main()
