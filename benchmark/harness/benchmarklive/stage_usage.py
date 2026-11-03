"""Per-stage telemetry extraction: what a dispatched stage spent and what it touched.

Layer 1 (stdout) → Layer 2 (audit.jsonl) → Layer 3 (all None); never fabricates. Pure
readers — nothing here dispatches or writes.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Callable, Optional

from benchmarkkit.metrics import StageCoverage

from . import capture

# *.swift under these dir names never counts as DV output (A5 tripwire, U2 measure).
NON_APP_DIRS = {".build", ".swiftpm", ".context"}


@dataclass
class StageUsage:
    input_tokens: Optional[int] = None
    output_tokens: Optional[int] = None
    cost_usd: Optional[float] = None
    capture_layer: Optional[int] = None  # 1, 2, or None (Layer 3 = degraded)
    cache_read: Optional[int] = None
    cache_creation: Optional[int] = None
    coverage: Optional[StageCoverage] = None
    duration_s: float = 0.0  # wall-clock of this dispatch; not part of the on-disk schema
    # Parent-session-only token figures, set when the totals above are sub-agent-inclusive.
    parent_input_tokens: Optional[int] = None
    parent_output_tokens: Optional[int] = None
    parent_cache_read: Optional[int] = None
    parent_cache_creation: Optional[int] = None
    diagnostics: Optional[dict] = None


def dv_produced_swift(arm_cwd: str) -> bool:
    """True when at least one *.swift landed outside {.build,.swiftpm,.context} (A5)."""
    for root, dirs, files in os.walk(arm_cwd):
        dirs[:] = [d for d in dirs if d not in NON_APP_DIRS]
        if any(f.endswith(".swift") for f in files):
            return True
    return False


def _audit_subagent_spawns(audit_path: str, stage: str,
                           now_fn: Optional[Callable[[], float]] = None) -> int:
    """Count canonical nested ``subagent_stopped`` rows attributed to ``stage`` (A4).

    Canonical only: rows with ``metadata.advisory`` truthy are mirror duplicates and
    skipped; identical ``dedupe_key`` values collapse to one. ``now_fn`` is accepted
    for symmetry with time-window callers but attribution here keys off the row's own
    ``metadata.stage`` (per-arm audit path already scopes the window structurally).
    """
    try:
        with open(audit_path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return 0
    seen: set = set()
    count = 0
    for line in text.split("\n"):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(rec, dict) or rec.get("action") != "subagent_stopped":
            continue
        meta = rec.get("metadata")
        if not isinstance(meta, dict) or meta.get("stage") != stage:
            continue
        if meta.get("advisory"):
            continue
        key = meta.get("dedupe_key")
        if key is not None:
            if key in seen:
                continue
            seen.add(key)
        count += 1
    return count


def capture_layer2(audit_path: str, stage: str) -> Optional[StageUsage]:
    """Layer 2: scan audit.jsonl for this stage's last external_dispatch usage."""
    try:
        with open(audit_path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    found = None
    for line in text.split("\n"):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(rec, dict) or rec.get("action") != "external_dispatch":
            continue
        meta = rec.get("metadata")
        if not isinstance(meta, dict) or meta.get("stage") != stage:
            continue
        usage = meta.get("usage") or {}
        in_tok = usage.get("input_tokens")
        out_tok = usage.get("output_tokens")
        cr = usage.get("cache_read_input_tokens")
        cc = usage.get("cache_creation_input_tokens")
        cost = usage.get("cost_usd")
        if cost is None:
            cost = usage.get("total_cost_usd")
        if in_tok is None and out_tok is None and cost is None and cr is None and cc is None:
            continue
        found = StageUsage(input_tokens=in_tok, output_tokens=out_tok, cost_usd=cost,
                           capture_layer=2, cache_read=cr, cache_creation=cc)
    return found


def capture_stage_usage(stdout: str, audit_path: str, stage: str,
                        now_fn: Optional[Callable[[], float]] = None) -> StageUsage:
    """Layer 1 (stdout) → Layer 2 (audit.jsonl) → Layer 3 (all None). Never fabricates.

    A4: coverage from stdout is augmented with nested background spawns read from the
    per-arm audit (emitted only when >0, preserving the 4-key StageCoverage shape)."""
    parsed = capture.parse(stdout)
    coverage = parsed.coverage if parsed else None
    nested = _audit_subagent_spawns(audit_path, stage, now_fn=now_fn)
    if nested and coverage is None:
        coverage = StageCoverage(agents=[], skills=[], commands=[], tool_calls=0)
    if nested and coverage is not None:
        coverage.nested_background = nested

    if parsed is not None and parsed.has_usage:
        return StageUsage(input_tokens=parsed.input_tokens, output_tokens=parsed.output_tokens,
                          cost_usd=parsed.cost_usd, capture_layer=1,
                          cache_read=parsed.cache_read, cache_creation=parsed.cache_creation,
                          coverage=coverage,
                          parent_input_tokens=parsed.parent_input_tokens,
                          parent_output_tokens=parsed.parent_output_tokens,
                          parent_cache_read=parsed.parent_cache_read,
                          parent_cache_creation=parsed.parent_cache_creation)
    layer2 = capture_layer2(audit_path, stage)
    if layer2 is not None:
        layer2.coverage = coverage
        return layer2
    return StageUsage(capture_layer=None, coverage=coverage)
