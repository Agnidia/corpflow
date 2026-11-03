"""Stage catalogue selection, canonical contracts, and reference isolation."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "skills/worktask/scripts/instruction-set.py"
SPEC = importlib.util.spec_from_file_location("instruction_set", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InstructionSetTests(unittest.TestCase):
    def fixture(self, root):
        for name in ("stage-inputs", "stage-outputs", "completion", "frontmatter", "required-fields"):
            path = root / f"skills/worktask/references/contracts/{name}.md"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"# {name}\nMandatory contract.\n")
        for path in ("skills/worktask/references/completion-boundary.md", "skills/shared/codex-runtime.md"):
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("# Contract\nMandatory contract.\n")
        reminder = root / "skills/worktask/references/contract-reminder.md"
        reminder.write_text("# Reminder\n```text\nStable security contract.\n```\n")
        cache = root / "skills/worktask/scripts/cache-lint.sh"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text("printf '%s\\tdeveloper\\tdevelopment\\trequired\\tfiles-changed\\n' \"$3\"\n")
        role = root / "agents/developer.md"
        role.parent.mkdir(parents=True)
        role.write_text("Role. Resolve skills/alpha/references/contract.md before acting.\n")
        for stage in ("dv", "qa"):
            template = root / f"skills/worktask/assets/templates/template-{stage}.md"
            template.parent.mkdir(parents=True, exist_ok=True)
            template.write_text(f"### #tpl-{stage} — Fixture\nRequired template contract.\n")
        for name in (*MODULE.BASE_SKILLS, "alpha", "beta"):
            skill = root / f"skills/{name}/SKILL.md"
            skill.parent.mkdir(parents=True, exist_ok=True)
            skill.write_text(f"---\nname: {name}\ndescription: Use for {name}.\n---\n"
                             + ("Resolve skills/beta/SKILL.md.\n" if name == "alpha" else ""))

    def test_real_stages_select_roles_and_retain_mandatory_contracts(self):
        dv = MODULE.compose(ROOT, "DV")
        dr = MODULE.compose(ROOT, "DR")
        self.assertEqual((dv["role"], dr["role"]), ("developer", "technical-lead"))
        self.assertIn("dv-screenshot-capture", dv["skills"])
        self.assertNotIn("logging-conventions", dr["skills"])
        self.assertIn("security-review-process", MODULE.compose(ROOT, "SR")["skills"])
        self.assertIn("skills/worktask/references/contracts/stage-outputs.md", dv["instructions"])
        self.assertIn("skills/worktask/references/contracts/completion.md", dv["instructions"])
        self.assertIn("skills/worktask/references/contracts/required-fields.md", dv["references"])
        self.assertLess(len(dv["skills"]), len(list((ROOT / "skills").glob("*/SKILL.md"))))
        for relative in dv["references"]:
            self.assertTrue((ROOT / relative).is_file())

    def test_task_skills_and_recursive_dependencies_are_resolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            selected = MODULE.compose(root, "DV", ["beta"])
            self.assertIn("alpha", selected["skills"])
            self.assertIn("beta", selected["skills"])
            (root / "skills/beta/SKILL.md").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.compose(root, "DV")

    def test_missing_task_skill_and_mandatory_source_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.compose(root, "DV", ["unknown"])
            (root / "skills/worktask/references/contracts/completion.md").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.compose(root, "DV")

    def test_off_root_skill_reference_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as other:
            root = Path(tmp)
            self.fixture(root)
            external = Path(other) / "SKILL.md"
            external.write_text("---\nname: beta\ndescription: External.\n---\n")
            (root / "skills/beta/SKILL.md").unlink()
            (root / "skills/beta/SKILL.md").symlink_to(external)
            with self.assertRaisesRegex(ValueError, "off-root"):
                MODULE.compose(root, "DV")

    def test_prefix_is_byte_identical_and_fingerprint_tracks_canonical_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            first = MODULE.compose(root, "DV")
            second = MODULE.compose(root, "QA")
            self.assertEqual(first["contract_reminder"], second["contract_reminder"])
            before = first["fingerprint"]
            (root / "skills/beta/SKILL.md").write_text("---\nname: beta\ndescription: Updated canonical description.\n---\n")
            self.assertNotEqual(before, MODULE.compose(root, "DV")["fingerprint"])

    def test_actual_local_role_and_task_text_control_skill_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / "agents/workflow-engineer.md").write_text("Resolve skills/beta/references/contract.md.\n")
            selected = MODULE.compose(root, "DV", role="workflow-engineer", task_text="$corpflow:alpha")
            self.assertEqual(selected["role"], "workflow-engineer")
            self.assertIn("alpha", selected["skills"])
            self.assertIn("beta", selected["skills"])
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.compose(root, "DV", role="missing-agent")
            with self.assertRaisesRegex(ValueError, "canonical local agent"):
                MODULE.compose(root, "DV", role="../foreign")

    def test_required_subresource_anchors_resolve_or_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            resource = root / "skills/alpha/references/contract.md"
            resource.parent.mkdir(parents=True)
            resource.write_text("# Contract\n## Required inputs\nCriteria.\n")
            ref = "skills/alpha/references/contract.md#required-inputs"
            selected = MODULE.compose(root, "DV", references=[ref])
            self.assertIn(ref, selected["references"])
            with self.assertRaisesRegex(ValueError, "anchor missing"):
                MODULE.compose(root, "DV", references=[ref + "-absent"])
            resource.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.compose(root, "DV", references=[ref])

    def test_production_entrypoint_owns_generated_content(self):
        result = subprocess.run(["bash", str(PATH.with_name("brief-compose.sh")), "--instruction-set", "DR"],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["fingerprint"], MODULE.compose(ROOT, "DR")["fingerprint"])
