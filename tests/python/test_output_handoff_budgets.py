"""Evidence-preserving output bounds and handoff transition limits."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "skills/worktask/scripts"


def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class OutputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def run_output(self, body, status=0):
        log = self.root / ".context/logs/test-output.log"
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "bounded-output.py"), "--log", str(log), "--",
             sys.executable, "-c", "import sys;print(" + repr(body) + ");sys.exit(" + str(status) + ")"],
            cwd=self.root, capture_output=True, text=True)
        return result, log

    def test_verbose_success_preserves_complete_unicode_evidence(self):
        body = "початок🙂" + "я" * 20000 + "кінець🦉"
        result, log = self.run_output(body)
        self.assertEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout), 8000)
        self.assertIn("TRUNCATED", result.stdout)
        self.assertIn("кінець🦉", result.stdout)
        self.assertEqual(log.read_text(), body + "\n")

    def test_end_failure_is_visible_and_exit_status_is_preserved(self):
        result, log = self.run_output("x" * 20000 + "\nERROR: late failure", 7)
        self.assertEqual(result.returncode, 7)
        self.assertIn("exit_code=7", result.stdout)
        self.assertIn("ERROR: late failure", result.stdout)
        self.assertIn(str(log), result.stdout)
        self.assertEqual(len(log.read_text()), 20021)

    def test_existing_log_is_never_overwritten(self):
        result, log = self.run_output("first")
        again, _ = self.run_output("second")
        self.assertEqual(again.returncode, 2)
        self.assertEqual(log.read_text(), "first\n")

    def test_targeted_unicode_read_keeps_the_offset(self):
        result, log = self.run_output("я" * 10000 + "needle" + "z" * 10000)
        read = subprocess.run([sys.executable, str(SCRIPTS / "bounded-output.py"), "--read",
                               "--log", str(log), "--start", "10000"],
                              capture_output=True, text=True)
        self.assertEqual(read.returncode, 0)
        self.assertIn("exit_code=unavailable", read.stdout)
        self.assertIn("offset=10000\nneedle", read.stdout)
        self.assertLessEqual(len(read.stdout), 8000)

    def test_read_of_failed_command_does_not_claim_command_success(self):
        result, log = self.run_output("failure evidence", 8)
        read = subprocess.run([sys.executable, str(SCRIPTS / "bounded-output.py"), "--read",
                               "--log", str(log)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 8)
        self.assertIn("exit_code=unavailable", read.stdout)
        self.assertIn("failure evidence", read.stdout)

    def test_near_limit_metadata_cannot_create_negative_excerpt_slices(self):
        output = module("bounded-output").excerpt("x" * 10000, "h" * 180, 200)
        self.assertLessEqual(len(output), 200)
        self.assertIn("TRUNCATED", output)
        with self.assertRaisesRegex(ValueError, "cannot fit metadata"):
            module("bounded-output").excerpt("x" * 10000, "h" * 199, 200)


class HandoffBudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.artifact = self.root / "developer-review-0.md"
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"version": 2, "worktask_id": "x", "plan_file": "p.md",
                                         "platform": "all", "tasks": {}, "facts": {}, "handoffs": {}}))
        self.final_return = self.root / "return.txt"
        self.final_return.write_text("pass: the evidence is retained")
        self.text = ("---\nhandoff:\n  stage: DR\n  verdict: pass\n  summary: reviewed\n"
                     "  refs: {dev: development-0.md#files-changed}\n  key_decisions: []\n"
                     "  open_questions: []\n---\n\n## findings\n\nNo defects.\n"
                     "\n## verdict\n\npass\n\n## blockers\n\nNone.\n"
                     "\n## follow-ups\n\nNone.\n\n## elicitation-sweep\n\nnothing to elicit\n")
        self.artifact.write_text(self.text)

    def validate(self, compressor=None):
        args = ["bash", str(SCRIPTS / "handoff-harness.sh"), "--validate-transition",
                str(self.artifact), "--state", str(self.state), "--return-file", str(self.final_return)]
        if compressor:
            args.extend(["--compressor", str(compressor)])
        result = subprocess.run(args, capture_output=True, text=True)
        return result, json.loads(result.stdout)

    def compressor(self, code):
        script = self.root / "compress.py"
        script.write_text("#!" + sys.executable + "\nimport pathlib,sys\np=pathlib.Path(sys.argv[1])\n" + code)
        script.chmod(0o700)
        return script

    def test_valid_transition_reports_estimates_separately(self):
        result, report = self.validate()
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["result"], "pass")
        self.assertEqual(report["estimates"]["provider_usage"], "unavailable")
        self.assertIn("not provider tokenization", report["estimates"]["token_proxy"])

    def test_oversized_table_and_return_and_ledger_are_consolidated(self):
        self.artifact.write_text(self.text.replace("No defects.", "| x | y |\n" * 310))
        self.final_return.write_text("return " * 200)
        data = json.loads(self.state.read_text())
        data["facts"] = {"goal": "goal " * 500}
        self.state.write_text(json.dumps(data))
        result, report = self.validate()
        self.assertEqual(result.returncode, 1)
        fields = {e.get("field") for e in report["errors"]}
        self.assertTrue({"artifact_lines", "return_tokens"}.issubset(fields), report)
        self.assertTrue(any(w["field"] == "ledger_tokens" for w in report["warnings"]))

    def test_multistage_ledger_keeps_its_existing_warning_severity(self):
        data = json.loads(self.state.read_text())
        data["tasks"] = {f"DV{i}": {"status": "pending", "metadata": {"description": "stage " * 40}}
                         for i in range(11)}
        self.state.write_text(json.dumps(data))
        result, report = self.validate()
        self.assertEqual(result.returncode, 0, report)
        self.assertTrue(any(w["field"] == "ledger_tokens" for w in report["warnings"]))
        self.assertIn("existing warning severity retained", report["warnings"][0]["detail"])

    def test_missing_state_blocks_the_transition(self):
        self.state.unlink()
        result, report = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["result"], "blocked")

    def test_long_unbroken_prose_does_not_bypass_the_word_proxy(self):
        self.artifact.write_text(self.text.replace("No defects.", "x" * 5000))
        result, report = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertTrue(any(e["code"] == "structure" for e in report["errors"]))

    def test_a_fake_file_suffix_or_path_cannot_exempt_unbroken_prose(self):
        for text in ("x" * 5000 + ".txt", "missing/" * 300 + "fake.txt"):
            self.artifact.write_text(self.text.replace("No defects.", text))
            result, report = self.validate()
            self.assertEqual(result.returncode, 1)
            self.assertTrue(any(e["code"] == "structure" for e in report["errors"]))

    def test_a_genuine_url_remains_intact_and_exempt_from_the_prose_guard(self):
        url = "https://example.com/evidence?query=" + "x" * 2000
        text = self.text.replace("No defects.", url)
        self.artifact.write_text(text)
        result, report = self.validate()
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(self.artifact.read_text(), text)

    def test_frontmatter_line_budget_and_required_return_are_checked(self):
        self.artifact.write_text(self.text.replace("  summary: reviewed", "\n" * 31 + "  summary: reviewed"))
        args = ["bash", str(SCRIPTS / "handoff-harness.sh"), "--validate-transition",
                str(self.artifact), "--state", str(self.state)]
        result = subprocess.run(args, capture_output=True, text=True)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(any(e.get("field") == "frontmatter_lines" for e in report["errors"]))
        self.assertTrue(any(e["code"] == "missing_return" for e in report["errors"]))

    def test_required_fields_still_fail_with_budget_errors(self):
        self.artifact.write_text(self.text.replace("  summary: reviewed\n", "").replace("No defects.", "x\n" * 310))
        result, report = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertTrue(any("summary" in e["detail"] for e in report["errors"]))
        self.assertTrue(any(e.get("field") == "artifact_lines" for e in report["errors"]))

    def test_one_compression_attempt_retains_failed_candidate_and_original(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings"))
        original = self.artifact.read_bytes()
        script = self.compressor("sys.exit(9)\n")
        result, report = self.validate(script)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(report["compression_attempted"])
        self.assertEqual(self.artifact.read_bytes(), original)
        self.assertTrue(Path(report["repair_candidate"]).is_file())
        again, next_report = self.validate(script)
        self.assertFalse(next_report["compression_attempted"])
        self.assertIn("already attempted", next_report["compression"])

    def test_compression_cannot_remove_blockers_or_evidence(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings"))
        original = self.artifact.read_bytes()
        script = self.compressor("p.write_text(p.read_text().replace('x\\n'*310, 'None.\\n').replace('## blockers\\n\\nNone.', '## blockers\\n\\nRemoved.'))\n")
        result, report = self.validate(script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("protected content changed", report["compression"])
        self.assertEqual(self.artifact.read_bytes(), original)

    def test_ineffective_compression_stops_without_truncating_the_artifact(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings"))
        original = self.artifact.read_bytes()
        result, report = self.validate(self.compressor("pass\n"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("still invalid", report["compression"])
        self.assertEqual(self.artifact.read_bytes(), original)
        self.assertTrue(Path(report["repair_candidate"]).is_file())

    def test_summary_and_focus_cannot_hide_a_lost_pending_requirement(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings")
                                 .replace("summary: reviewed", "summary: pending host acceptance"))
        original = self.artifact.read_bytes()
        script = self.compressor("p.write_text(p.read_text().replace('x\\n'*310, 'None.\\n').replace('pending host acceptance', 'reviewed'))\n")
        result, report = self.validate(script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("protected content changed", report["compression"])
        self.assertEqual(self.artifact.read_bytes(), original)

    def test_duplicate_and_nested_blockers_are_all_protected(self):
        loaded = module("handoff-transition")
        duplicate = self.text + "\n## blockers\n\nSecond unresolved blocker.\n"
        removed = duplicate.replace("## blockers\n\nNone.\n", "")
        self.assertNotEqual(loaded.protected_content(duplicate), loaded.protected_content(removed))
        nested = self.text + "\n## re-review\n\n### blockers\n\nPending external evidence.\n"
        removed = nested.replace("### blockers\n\nPending external evidence.\n", "")
        self.assertNotEqual(loaded.protected_content(nested), loaded.protected_content(removed))

    def test_critical_parent_section_protects_all_nested_decisions(self):
        loaded = module("handoff-transition")
        original = self.text + "\n## re-review\n\n### decisions\n\n#### choice\n\nKeep the gate.\n"
        removed = original.replace("Keep the gate.", "Drop the gate.")
        self.assertNotEqual(loaded.protected_content(original), loaded.protected_content(removed))

    def test_unavailable_compressor_keeps_actionable_repair_evidence(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings"))
        result, report = self.validate(self.root / "missing-compressor")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(report["compression_attempted"])
        self.assertTrue(Path(report["repair_candidate"]).is_file())
        self.assertTrue(Path(report["compression_evidence"]).is_file())

    def test_successful_compression_keeps_original_evidence(self):
        self.artifact.write_text(self.text.replace("## findings", "x\n" * 310 + "## findings"))
        original = self.artifact.read_bytes()
        script = self.compressor("p.write_text(p.read_text().replace('x\\n'*310, 'None.\\n'))\n")
        result, report = self.validate(script)
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["compression"], "accepted")
        self.assertEqual(Path(report["original_evidence"]).read_bytes(), original)
        self.assertEqual(module("handoff-transition").protected_content(original.decode()),
                         module("handoff-transition").protected_content(self.artifact.read_text()))


if __name__ == "__main__":
    unittest.main()
