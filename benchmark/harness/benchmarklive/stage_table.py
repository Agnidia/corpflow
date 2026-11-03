"""Per-stage dispatch contract and the era stamp that dates every record.

Bottom of the benchmarklive graph: the argv builder, the record builders and the
orchestrator all read the table from here, so nothing in this module may import back
up into them.
"""

from __future__ import annotations

import functools
import json
import os
import subprocess
from typing import Any, Optional
from .providers.claude.models import MODEL_PINS
from .source import source_digest

STAGE_CONTRACTS = {
    "PL": ("corpflow:product-manager", "opus", "high"),
    "AR": ("corpflow:software-architector", "opus", "high"),
    "TL": ("corpflow:team-lead", "sonnet", "medium"),
    "DV": ("corpflow:developer", "opus", "high"),
    "DR": ("corpflow:technical-lead", "opus", "high"),
    "SR": ("corpflow:security-reviewer", "opus", "xhigh"),
    "QA": ("corpflow:qa-engineer", "sonnet", "medium"),
    "DC": ("corpflow:technical-writer", "haiku", "low"),
    "FN": ("corpflow:project-manager", "sonnet", "medium"),
    "ST": ("corpflow:stakeholder", "sonnet", "low"),
}
STAGE_TABLE = {s: (role, MODEL_PINS[tier], effort)
               for s, (role, tier, effort) in STAGE_CONTRACTS.items()}

CAPTURE_JSON = "json"
CAPTURE_STREAM_JSON = "stream-json"

# Bumped by hand whenever the graded task text changes; a workload change makes
# token and quality figures incomparable just as surely as a model repin does.
PROMPT_CONTRACT = "scripted-cli-v5"
HARNESS_GENERATION = "python-3"

# Pins the contract text this version names, so editing the contract without
# bumping above fails a test instead of stamping stale records. Re-pin and bump
# together, and re-audit oracle tiers: a rule the contract now states has moved
# from `implied` to `specified`.
CLI_CONTRACT_DIGEST = "sha256:3e4ef30ed12839248d4e3acce8cb73d41c610d141adddd41f3b201623187a415"


@functools.lru_cache(maxsize=1)
def _plugin_version() -> Optional[str]:
    """Version of the plugin tree under measurement, or None if unreadable."""
    # <root>/benchmark/harness/benchmarklive/stage_table.py — four levels up is the plugin root.
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            version = json.load(f).get("version")
    except (OSError, ValueError):
        return None
    return version if isinstance(version, str) else None


@functools.lru_cache(maxsize=1)
def _cli_version() -> Optional[str]:
    """`claude --version`, or None when it cannot be probed.

    Absent rather than guessed: the gate refuses on a None mismatch, whereas a
    placeholder would certify two different CLIs as the same era.
    """
    try:
        done = subprocess.run(["claude", "--version"], capture_output=True,
                              text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() or None if done.returncode == 0 else None


@functools.lru_cache(maxsize=1)
def _source_digest():
    return source_digest(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))))


def build_era(plugin: Optional[Any] = None, arm_plugins: Optional[dict] = None,
              config_leaks: Optional[dict] = None) -> dict:
    """Stamp what this run's numbers are comparable against.

    Model pins are the axis that silently invalidated the stored baselines at
    v3.37.1, so they travel with every record rather than living only in a README.
    The two version fields close the axis that had no stamp at all: a CLI or plugin
    upgrade changes the thing being measured without touching anything else here.
    """
    era = {
        "harness": HARNESS_GENERATION,
        "provider": "claude",
        "source_digest": _source_digest(),
        "pricing": {"basis": "CLI-reported USD", "source": "result.total_cost_usd"},
        "prompt_contract": PROMPT_CONTRACT,
        "model_pins": {stage: model for stage, (_agent, model, _effort) in STAGE_TABLE.items()},
        "cli_version": _cli_version(),
        "plugin_version": _plugin_version(),
    }
    if plugin is not None:
        # What the CLI reported loading, not what was requested. The path is arm-scoped
        # (the WITHOUT arm has none), so the pairing gate excludes it from era equality.
        era["plugin_path"] = plugin.path
        if plugin.version:
            era["plugin_version"] = plugin.version
    for arm in ("with", "without"):
        # Everything the arm's stages loaded, not just corpflow: the baseline's claim is
        # the empty list, and the WITH arm's siblings are part of what was measured.
        if arm_plugins and arm_plugins.get(arm) is not None:
            era[f"plugins_{arm}"] = list(arm_plugins[arm])
    if config_leaks:
        # ``{arm: [prefix, ...]}`` for each arm that was scanned, `[]` when clean: a clean
        # guard is a claim the record makes, and an absent arm means it did not run
        # (json capture, or a pre-python-3 run).
        era["config_leaks"] = {arm: list(found) for arm, found in sorted(config_leaks.items())}
    return era
