"""Canonical instruction ownership, routing, and generated-excerpt contracts."""
import importlib.util
import html
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INDEXES = [ROOT / "skills/worktask/references" / f"{name}.md" for name in (
    "workflow", "orchestration", "handoff-protocol", "pl0-procedure",
    "initialization-patterns", "return-arms", "resume", "scripts", "conductor-attachments",
)] + [ROOT / "skills/worktask/references" / f"{name}.md" for name in ("stage-contracts", "state-ledger")]


def prose(text):
    fence = None
    lines = text.splitlines()
    frontmatter = bool(lines and lines[0] == "---")
    for number, line in enumerate(lines):
        if frontmatter:
            if number and line == "---":
                frontmatter = False
            continue
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker[1]
            elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not line.strip().strip(fence[0]):
                fence = None
            continue
        if fence is None:
            yield line
    if fence:
        raise ValueError("unterminated fence")


def anchors(path):
    ids = set()
    counts = {}
    for line in prose(path.read_text()):
        ids.update(re.findall(r'<a id="([^"]+)"', line))
        ids.update(re.findall(r"\{#([^}]+)\}", line))
        if re.match(r"^#{1,6} ", line):
            title = html.unescape(re.sub(r"^#{1,6} |\{#[^}]+\}", "", line)).strip().lower()
            slug = re.sub(r"[^\w\- ]", "", title).replace(" ", "-")
            number = counts.get(slug, 0)
            counts[slug] = number + 1
            ids.add(slug + (f"-{number}" if number else ""))
    return ids


def modules():
    return [
        (index.parent / relative).resolve()
        for index in INDEXES
        for relative in re.findall(r"<!-- canonical-module: (.*?) -->", index.read_text(), re.MULTILINE)
    ]


def production_documents():
    return sorted(
        path
        for directory in ("agents", "commands", "skills", "hooks")
        for path in (ROOT / directory).rglob("*.md")
        if not {"fixtures", "tests", "evals"}.intersection(path.relative_to(ROOT).parts)
    )


def section_reference_errors(path, root=ROOT):
    normalize = lambda value: re.sub(r"[^a-z0-9]", "", value.lower())
    text = "\n".join(prose(path.read_text()))
    errors = []
    for quoted in re.findall(r"`([^`]+)`", text):
        match = re.fullmatch(r"((?:skills|agents|commands|hooks)/[\w./-]+\.md)(?:#[\w-]+)?\s+§\s+(.+)", quoted, re.DOTALL)
        if not match or any(token in quoted for token in ("<", ">", "${")):
            continue
        relative, section = match.groups()
        dest = root / relative
        if not dest.is_file():
            errors.append(f"missing file: {relative}")
            continue
        target = normalize(section)
        if not any(target.startswith(anchor) or anchor.startswith(target) for anchor in map(normalize, anchors(dest)) if anchor):
            errors.append(f"missing section: {quoted}")
    return errors


def plugin_anchor_references(text):
    pattern = r"((?:skills|agents|commands|hooks)/[a-zA-Z0-9_./-]+\.md)#([a-zA-Z][a-zA-Z0-9_-]*)"
    for match in re.finditer(pattern, text):
        if text[match.end():].startswith(("<", "${")):
            continue
        yield match.groups()


class WorktaskModulesTest(unittest.TestCase):
    def test_worktask_contracts_and_templates_have_local_ownership(self):
        references = ROOT / "skills/worktask/references"
        templates = ROOT / "skills/worktask/assets/templates"
        stages = {"pl", "ar", "tl", "dv", "dr", "sr", "qa", "dc", "re", "fn", "st", "ir", "et"}
        self.assertEqual({path.stem.removeprefix("template-") for path in templates.glob("template-*.md")}, stages)
        self.assertEqual({path.name for path in templates.glob("*.md")},
                         {f"template-{stage}.md" for stage in stages} |
                         {"planning.md", "attachments-pr-template.md", "attachments-review-template.md"})
        self.assertEqual(list((references / "contracts").glob("template-*.md")),
                         [references / "contracts/template-rules.md"])
        for name in ("stage-contracts", "state-ledger", "stage-codes", "worktask-stage-context"):
            self.assertTrue((references / f"{name}.md").is_file())
            self.assertFalse((ROOT / "skills/shared" / f"{name}.md").exists())
        self.assertFalse((ROOT / "skills/shared/contracts").exists())
        self.assertFalse((ROOT / "skills/worktask/templates").exists())

    def test_general_guidance_excludes_worktask_execution_rules(self):
        general = (ROOT / "skills/shared/testing-strategy.md").read_text()
        specific = (ROOT / "skills/worktask/references/testing-strategy.md").read_text()
        for title in ("Testing Pyramid", "Framework by platform", "AAA Pattern", "Strict-count runners"):
            self.assertIn(title, general)
        for title in ("DV vs QA Boundary", "Test-Execution Authority", "Test Selection Gate"):
            self.assertNotIn("## " + title, general)
            self.assertIn(title, specific)
        title = "Worktask stages: explicit, never inherited"
        self.assertNotIn(title, (ROOT / "skills/shared/model-selection.md").read_text())
        self.assertIn(title, (ROOT / "skills/worktask/references/dispatch-agent.md").read_text())

    def test_production_consumers_do_not_reference_removed_owners(self):
        removed = [f"skills/shared/{name}.md" for name in
                   ("stage-contracts", "state-ledger", "stage-codes", "worktask-stage-context")]
        removed += ["skills/shared/contracts/", "skills/worktask/templates/",
                    "skills/worktask/references/attachments-pr-template.md",
                    "skills/worktask/references/attachments-review-template.md"]
        for directory in ("agents", "commands", "skills", "hooks", "benchmark/harness", "evals"):
            for path in (ROOT / directory).rglob("*"):
                if (not path.is_file() or {"fixtures", "tests", "results", "__pycache__"}.intersection(path.parts)
                        or any(part.startswith("responses-") for part in path.parts)):
                    continue
                if path.suffix not in {".md", ".sh", ".py", ".json", ".yaml", ".yml", ".tsv"}:
                    continue
                with self.subTest(path=path):
                    text = path.read_text()
                    self.assertEqual([old for old in removed if old in text], [])

    def test_each_module_has_one_owner_and_a_reading_condition(self):
        leaves = modules()
        self.assertGreater(len(leaves), 50)
        self.assertEqual(len(leaves), len(set(leaves)))
        for path in leaves:
            with self.subTest(path=path):
                text = path.read_text()
                self.assertRegex(text, r"(?im)^Read (when|from|before|on|for|only|immediately|after)")
                self.assertEqual(text.count("<!-- canonical-body:start -->"), 1)
                self.assertNotIn("<!-- canonical-body:end -->", text)
                list(prose(text))

    def test_links_and_compatibility_anchors_resolve(self):
        for path in production_documents():
            for line in prose(path.read_text()):
                for target in re.findall(r"\]\(([^\s)]+)\)", line):
                    if re.match(r"\w+:", target) or target.startswith("<"):
                        continue
                    relative, _, anchor = target.partition("#")
                    dest = (path.parent / relative).resolve() if relative else path
                    with self.subTest(source=path, target=target):
                        self.assertTrue(dest.exists(), target)
                        if anchor:
                            self.assertTrue(dest.is_file(), target)
                            self.assertIn(anchor, anchors(dest), target)

    def test_duplicate_template_anchors_survive_the_split(self):
        index = ROOT / "skills/worktask/references/conductor-attachments.md"
        owner = ROOT / "skills/worktask/assets/templates/attachments-review-template.md"
        for number in range(1, 9):
            alias = f"template-part-{number}-1"
            self.assertIn(alias, anchors(index))
            self.assertIn(alias, anchors(owner))

    def test_heading_entities_are_decoded_before_slugging(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reference.md"
            path.write_text("# Resume &amp; retry\n")
            self.assertIn("resume--retry", anchors(path))
            self.assertNotIn("resume-amp-retry", anchors(path))

    def test_frontmatter_comments_are_not_section_anchors(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "agent.md"
            path.write_text("---\n# Metadata comment\nname: agent\n---\n# Actual section\n")
            self.assertNotIn("metadata-comment", anchors(path))
            self.assertIn("actual-section", anchors(path))

    def test_plugin_section_references_resolve(self):
        for path in production_documents():
            for line in prose(path.read_text()):
                for relative, anchor in plugin_anchor_references(line):
                    dest = ROOT / relative
                    with self.subTest(source=path, target=relative + "#" + anchor):
                        self.assertTrue(dest.is_file(), relative)
                        self.assertIn(anchor, anchors(dest), anchor)

    def test_static_shell_references_resolve(self):
        for directory in ("skills", "hooks"):
            for path in (ROOT / directory).rglob("*.sh"):
                if "selftest" in path.name or "self-test" in path.name:
                    continue
                for relative, anchor in plugin_anchor_references(path.read_text()):
                    dest = ROOT / relative
                    with self.subTest(source=path, target=relative + "#" + anchor):
                        self.assertTrue(dest.is_file(), relative)
                        self.assertIn(anchor, anchors(dest), anchor)

    def test_section_qualified_references_resolve(self):
        for path in production_documents():
            with self.subTest(source=path):
                self.assertEqual(section_reference_errors(path), [])

    def test_a_valid_anchor_does_not_hide_a_moved_section(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "skills").mkdir()
            owner = root / "skills/template.md"
            owner.write_text("# Template\n")
            consumer = root / "consumer.md"
            consumer.write_text("`skills/template.md#template § summary_line evidence`\n")
            self.assertIn("template", anchors(owner))
            self.assertEqual(len(section_reference_errors(consumer, root)), 1)
            evidence = root / "skills/evidence.md"
            evidence.write_text("# summary_line evidence\n")
            consumer.write_text("`skills/evidence.md#summary_line-evidence § summary_line evidence`\n")
            self.assertEqual(section_reference_errors(consumer, root), [])

    def test_pipeline_scoring_uses_its_own_canonical_rubric(self):
        owner = (ROOT / "skills/estimation-methodology/SKILL.md").read_text()
        estimate = owner.split("## 5-Factor Score\n", 1)[1].split("\n## ", 1)[0]
        pipeline = owner.split("## PL0 Complexity Score\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn("0-25", estimate)
        self.assertIn("0-50 total", pipeline)
        self.assertIn("High (6-10)", pipeline)
        self.assertNotIn("| **New patterns** |", "\n".join(path.read_text() for path in modules()))
        self.assertIn("#pl0-complexity-score", (ROOT / "agents/product-manager.md").read_text())

    def test_schemas_and_templates_have_one_definition(self):
        text = "\n".join(path.read_text() for path in modules())
        for stage in ("PL", "AR", "TL", "DV", "DR", "SR", "QA", "DC", "RE", "FN", "ST", "IR", "ET"):
            self.assertEqual(len(re.findall(r'^  "title": "' + stage + r'Handoff",$', text, re.MULTILINE)), 1)
            self.assertEqual(len(re.findall(r"^### #tpl-" + stage.lower() + r" ", text, re.MULTILINE)), 1)
        for rule in ("atomic-write", "frontmatter-schema", "state-json-schema", "stage-artifact-map", "cache-prefix", "anchor-allow-list"):
            self.assertEqual(len(re.findall(r"^## #" + rule + r"$", text, re.MULTILINE)), 1)

    def test_generated_runbooks_detect_and_repair_drift(self):
        source = ROOT / "skills/worktask/scripts/sync-runbooks.py"
        spec = importlib.util.spec_from_file_location("runbooks", source)
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        self.assertEqual(generator.sync(ROOT), [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (
                "agents/technical-lead.md", "agents/security-reviewer.md", "agents/product-manager.md",
                "skills/worktask/assets/templates/template-dr.md", "skills/worktask/assets/templates/template-sr.md",
                "skills/estimation-methodology/SKILL.md",
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text((ROOT / relative).read_text())
            path = root / "agents/technical-lead.md"
            path.write_text(path.read_text().replace("  stage: DR", "  stage: BAD"))
            self.assertEqual(generator.sync(root), ["agents/technical-lead.md"])
            self.assertEqual(generator.sync(root, write=True), ["agents/technical-lead.md"])
            self.assertEqual(generator.sync(root), [])


if __name__ == "__main__":
    unittest.main()
