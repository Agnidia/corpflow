"""STAGE_TABLE SSOT parity (port of StageTableSSOTTests): stage-codes.md model and
effort columns match STAGE_TABLE; DR row is opus/high; efforts are valid; the table
covers exactly the 10-stage PIPELINE_STAGES (SR included); and headless-dispatch.md's
per-stage flag table points at stage-codes.md for model/effort instead of restating them.

Retargeted (architecture-0.md#ad6): stage-codes.md's Primary Stages table lost its Model
and Effort columns to the agent-keyed `## Agent Model Matrix` (ad1) — model/effort parity
is now a two-hop join: stage -> agent from Primary Stages, agent -> (model, effort) from
`model-matrix.sh --resolve` (the wrapper consumer named in ad2), not a fourth regex parser
over the matrix table. STAGE_TABLE itself stays a hand-mirrored constant (pinned model ids,
not aliases) — out of scope, per planning-0.md#risks.
"""

import os
import re
import subprocess
import tempfile
import unittest

from benchmarklive.budget import PIPELINE_STAGES
from benchmarklive.dispatch import STAGE_TABLE

_HARNESS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_ROOT = os.path.dirname(os.path.dirname(_HARNESS))
_STAGE_CODES = os.path.join(_PLUGIN_ROOT, "skills", "worktask", "references", "stage-codes.md")
_MODEL_MATRIX_SH = os.path.join(
    _PLUGIN_ROOT, "skills", "worktask", "scripts", "model-matrix.sh"
)
_HEADLESS_DISPATCH = os.path.join(
    _PLUGIN_ROOT, "skills", "agent-coordination", "references", "headless-dispatch.md"
)

# § Primary Stages is a fixed 3-column table (Code | Stage | Agent) since ad1; scoped to the
# section (heading to next `##`) so a stray `| XX |` row elsewhere can never leak in.
_PRIMARY_STAGE_ROW = re.compile(
    r"^\|\s*([A-Z]{2})\s*\|[^|\n]*\|\s*([a-z][a-z0-9-]*)\s*\|$", re.MULTILINE
)

_DISPATCH_ROW = re.compile(
    r"^\|\s*\*\*([A-Z]{2})\*\*\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|",
    re.MULTILINE,
)

_MODEL_TERMS = {"opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"}
_EFFORT_TERMS = {"low", "medium", "high", "xhigh", "max"}


def _family(model_id: str) -> str:
    # "claude-opus-5-5" -> "opus"
    return model_id.split("-")[1]


def _primary_stage_agents() -> dict:
    """stage code -> agent, scoped to the `## Primary Stages` section alone."""
    with open(_STAGE_CODES, encoding="utf-8") as f:
        text = f.read()
    start = text.index("## Primary Stages")
    end = text.find("\n## ", start + 1)
    section = text[start:] if end == -1 else text[start:end]
    return dict(_PRIMARY_STAGE_ROW.findall(section))


def _resolve(agent: str) -> tuple:
    """(model_alias, effort) via the model-matrix.sh wrapper — the same consumer path a
    non-bash caller uses, so this test never reimplements the extractor."""
    # A bare --resolve reads state.models/CORPFLOW.md from the root ladder and the user-scope
    # config dir; pin both to an empty dir so the parity is against the matrix, not this
    # checkout's own ledger or the operator's ~/.claude/CORPFLOW.md.
    with tempfile.TemporaryDirectory() as ctx:
        out = subprocess.run(
            ["bash", _MODEL_MATRIX_SH, "--resolve", agent],
            capture_output=True, text=True, timeout=30, check=True,
            env={**os.environ, "CONTEXT_DIR": ctx, "CLAUDE_CONFIG_DIR": ctx},
        ).stdout.strip()
    model, effort, _source = out.split("\t")
    return model, effort


class StageTableSSOT(unittest.TestCase):
    def test_table_covers_exactly_pipeline_stages(self):
        self.assertEqual(set(STAGE_TABLE), set(PIPELINE_STAGES))
        self.assertIn("SR", STAGE_TABLE)  # SR is in the live pipeline (D3)
        self.assertEqual(len(STAGE_TABLE), 10)

    def test_dr_row_is_technical_lead_opus_high(self):
        agent, model, effort = STAGE_TABLE["DR"]
        self.assertIn("technical-lead", agent)
        self.assertEqual(_family(model), "opus")
        self.assertEqual(effort, "high")
        # Single-agent pair assertion, retargeted: the same pair the wrapper resolves for
        # technical-lead, independent of STAGE_TABLE's own hand-pinned literal.
        r_model, r_effort = _resolve("technical-lead")
        self.assertEqual(r_model, "opus")
        self.assertEqual(r_effort, "high")

    def test_reconciled_efforts_and_models(self):
        self.assertEqual(STAGE_TABLE["AR"][2], "high")
        self.assertEqual(STAGE_TABLE["DV"][2], "high")
        self.assertEqual(STAGE_TABLE["DR"][2], "high")
        self.assertEqual(STAGE_TABLE["QA"][2], "medium")
        self.assertEqual(STAGE_TABLE["ST"][2], "low")
        self.assertEqual(_family(STAGE_TABLE["FN"][1]), "sonnet")

    def test_efforts_are_valid(self):
        for _, _, effort in STAGE_TABLE.values():
            self.assertIn(effort, {"low", "medium", "high", "xhigh"})

    def test_model_families_match_stage_codes_md(self):
        agents = _primary_stage_agents()
        overlap = set(agents) & set(STAGE_TABLE)
        self.assertTrue(overlap, "no overlapping stage codes parsed from stage-codes.md")
        for code in overlap:
            resolved_model, _resolved_effort = _resolve(agents[code])
            self.assertEqual(_family(STAGE_TABLE[code][1]), resolved_model,
                             f"{code} model family mismatch vs stage-codes.md's matrix")

    def test_efforts_match_stage_codes_md(self):
        agents = _primary_stage_agents()
        overlap = set(agents) & set(STAGE_TABLE)
        self.assertTrue(overlap, "no overlapping stage codes parsed from stage-codes.md")
        for code in overlap:
            _resolved_model, resolved_effort = _resolve(agents[code])
            self.assertEqual(STAGE_TABLE[code][2], resolved_effort,
                             f"{code} effort mismatch vs stage-codes.md's matrix")

    def test_headless_dispatch_table_points_to_stage_codes(self):
        # headless-dispatch.md's flag table carries $AGENT and $MODE per stage but no
        # model or effort cell — those are looked up from stage-codes.md at call time
        # (§ Model & effort defaults). canon_codes is re-derived from the stage column of
        # § Primary Stages alone (ad6) rather than from a model-family regex match, since
        # that column no longer exists there.
        canon_codes = set(_primary_stage_agents())
        with open(_HEADLESS_DISPATCH, encoding="utf-8") as f:
            headless_text = f.read()
        rows = _DISPATCH_ROW.findall(headless_text)
        self.assertTrue(rows, "no stage rows parsed from headless-dispatch.md")
        for code, agent, mode in rows:
            self.assertIn(code, canon_codes, f"{code} is not a stage-codes.md stage")
            for cell in (agent, mode):
                self.assertNotIn(cell.strip().lower(), _MODEL_TERMS,
                                  f"{code} row restates a model: {cell!r}")
                self.assertNotIn(cell.strip().lower(), _EFFORT_TERMS,
                                  f"{code} row restates an effort tier: {cell!r}")
        self.assertIn("stage-codes.md", headless_text.split("Model & effort defaults", 1)[-1][:400])


if __name__ == "__main__":
    unittest.main()
