"""Frozen BenchmarkRecord schema — byte-compatible with the on-disk history.json.

The existing history.json was written by ``json.dumps(obj, indent=2)`` with native
numeric types and no trailing newline, so this port serializes the same way: dict
insertion order is the key order, ints emit without a decimal, floats via Python's
shortest round-trip repr. No custom serializer is needed (the Swift port's
JSONValue/JSONParser existed only to emulate this).

AR deltas: D1 — Tokens always emits all 5 keys (value-or-null). D2 — StageAttribution
appends an optional ``coverage`` object after ``cost_usd`` only when present. D4 —
PathMetrics carries a trailing nullable ``app_path``. D-NUMTYPES — deltas keep native
type: int metrics yield int deltas, float metrics yield float deltas (no Swift-style
whole-float→int coercion). ``live_partial`` omit-when-false; ``stages`` omit-when-empty.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Optional, Union

Number = Union[int, float]

MODES = ["deterministic", "live"]

# Numeric comparison metrics present in both modes (order is on-disk order).
DETERMINISTIC_COMPARISON_KEYS = [
    "loc_produced",
    "test_count",
    "coverage_pct",
    "wall_clock_s",
    "estimate_complexity_score",
    "stage_count",
]


def _num_or(d: dict, key: str, default: Number) -> Number:
    v = d.get(key)
    return default if v is None else v


@dataclass
class Tokens:
    input: Optional[int] = None          # JSON "in"
    output: Optional[int] = None         # JSON "out"
    total: Optional[int] = None          # fresh in + out; cache tracked separately
    cache_read: Optional[int] = None
    cache_creation: Optional[int] = None

    def to_dict(self) -> dict:
        # D1: all 5 keys, fixed order, value-or-null.
        return {
            "in": self.input,
            "out": self.output,
            "total": self.total,
            "cache_read": self.cache_read,
            "cache_creation": self.cache_creation,
        }

    _KEYS = ("in", "out", "total", "cache_read", "cache_creation")

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> "Tokens":
        # Absent tokens are legal (a record may omit the block entirely); a PRESENT
        # block must carry all 5 keys. Partial blocks are rejected rather than
        # silently decoded, so a truncated writer surfaces instead of reading as
        # "measured, but no cache activity".
        if not d:
            return cls()
        missing = [k for k in cls._KEYS if k not in d]
        if missing:
            raise ValueError(f"tokens block missing required key(s): {', '.join(missing)}")
        return cls(
            input=d["in"],
            output=d["out"],
            total=d["total"],
            cache_read=d["cache_read"],
            cache_creation=d["cache_creation"],
        )


@dataclass
class StageCoverage:
    agents: list
    skills: list
    commands: list
    tool_calls: int
    nested_background: int = 0  # emitted only when >0; preserves the 4-key byte shape

    def to_dict(self) -> dict:
        d = {
            "agents": list(self.agents),
            "skills": list(self.skills),
            "commands": list(self.commands),
            "tool_calls": self.tool_calls,
        }
        if self.nested_background:
            d["nested_background"] = self.nested_background
        return d

    @classmethod
    def from_dict(cls, d) -> Optional["StageCoverage"]:
        if not isinstance(d, dict):
            return None
        return cls(
            agents=[x for x in d.get("agents", []) if isinstance(x, str)],
            skills=[x for x in d.get("skills", []) if isinstance(x, str)],
            commands=[x for x in d.get("commands", []) if isinstance(x, str)],
            tool_calls=d.get("tool_calls") or 0,
            nested_background=d.get("nested_background") or 0,
        )


_PARENT_KEYS = ("parent_fresh_in", "parent_cache_creation", "parent_cache_read", "parent_out")


@dataclass
class StageAttribution:
    stage: str
    fresh_in: Optional[int]
    cache_creation: Optional[int]
    cache_read: Optional[int]
    out: Optional[int]
    cost_usd: Optional[float]
    coverage: Optional[StageCoverage] = None  # D2: encoded only when present
    arm: Optional[str] = None  # "with"/"without"; encoded only on the paired path
    # Parent-session-only figures (``result.usage``); the fields above are summed over
    # ``result.modelUsage``, sub-agents included. Encoded only when the two differ in source.
    parent_fresh_in: Optional[int] = None
    parent_cache_creation: Optional[int] = None
    parent_cache_read: Optional[int] = None
    parent_out: Optional[int] = None
    duration_s: Optional[float] = None
    diagnostics: Optional[dict] = None

    def to_dict(self) -> dict:
        d = {
            "stage": self.stage,
            "fresh_in": self.fresh_in,
            "cache_creation": self.cache_creation,
            "cache_read": self.cache_read,
            "out": self.out,
            "cost_usd": self.cost_usd,
        }
        if self.coverage is not None:
            d["coverage"] = self.coverage.to_dict()
        if self.arm is not None:
            d["arm"] = self.arm
        for key in _PARENT_KEYS:
            if getattr(self, key) is not None:
                d[key] = getattr(self, key)
        if self.duration_s is not None:
            d["duration_s"] = self.duration_s
        if self.diagnostics is not None:
            d["diagnostics"] = self.diagnostics
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "StageAttribution":
        return cls(
            stage=d.get("stage") or "",
            fresh_in=d.get("fresh_in"),
            cache_creation=d.get("cache_creation"),
            cache_read=d.get("cache_read"),
            out=d.get("out"),
            cost_usd=d.get("cost_usd"),
            coverage=StageCoverage.from_dict(d.get("coverage")),
            arm=d.get("arm"),
            **{key: d.get(key) for key in _PARENT_KEYS},
            duration_s=d.get("duration_s"), diagnostics=d.get("diagnostics"),
        )


@dataclass
class PathMetrics:
    tokens: Tokens
    cost_usd: Optional[float]
    wall_clock_s: float
    loc_produced: int
    test_count: int
    coverage_pct: Optional[float]  # None marks unmeasured (live); a real 0.0 is measured-zero
    estimate_complexity_score: int
    stage_count: int
    pass_fail: str          # "pass" | "fail"
    app_path: Optional[str] = None  # D4: repo-relative; null for live/no-app
    # Held-out conformance score; omitted (not null) when the oracle did not run,
    # so records written before it existed round-trip byte-identically.
    oracle: Optional[dict] = None

    def to_dict(self) -> dict:
        d = {
            "tokens": self.tokens.to_dict(),
            "cost_usd": self.cost_usd,
            "wall_clock_s": self.wall_clock_s,
            "loc_produced": self.loc_produced,
            "test_count": self.test_count,
            "coverage_pct": self.coverage_pct,
            "estimate_complexity_score": self.estimate_complexity_score,
            "stage_count": self.stage_count,
            "pass_fail": self.pass_fail,
            "app_path": self.app_path,
        }
        if self.oracle is not None:
            d["oracle"] = self.oracle
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "PathMetrics":
        return cls(
            tokens=Tokens.from_dict(d.get("tokens")),
            cost_usd=d.get("cost_usd"),
            wall_clock_s=_num_or(d, "wall_clock_s", 0.0),
            loc_produced=_num_or(d, "loc_produced", 0),
            test_count=_num_or(d, "test_count", 0),
            coverage_pct=d.get("coverage_pct"),  # preserve None so absent stays distinct from 0.0
            estimate_complexity_score=_num_or(d, "estimate_complexity_score", 0),
            stage_count=_num_or(d, "stage_count", 0),
            pass_fail=d.get("pass_fail") or "",
            app_path=d.get("app_path"),
            oracle=d.get("oracle"),
        )


@dataclass
class MetricDelta:
    with_: Optional[Number]   # JSON "with"
    without: Optional[Number]
    delta: Optional[Number]

    def to_dict(self) -> dict:
        # D-NUMTYPES: no coercion — native int/float flows straight through.
        return {"with": self.with_, "without": self.without, "delta": self.delta}

    @classmethod
    def from_dict(cls, d: dict) -> "MetricDelta":
        return cls(with_=d.get("with"), without=d.get("without"), delta=d.get("delta"))

    @classmethod
    def of(cls, with_v: Optional[Number], without_v: Optional[Number]) -> "MetricDelta":
        if with_v is None or without_v is None:
            return cls(with_=with_v, without=without_v, delta=None)
        return cls(with_=with_v, without=without_v, delta=with_v - without_v)


@dataclass
class BenchmarkRecord:
    run_id: str
    timestamp_utc: str
    mode: str
    git_sha: str
    budget_usd: Optional[float]
    paths: list            # ordered [("with", PathMetrics), ("without", PathMetrics)]
    comparison: list       # ordered [(key, MetricDelta), ...]
    # Single-arm discriminator: "with" | "without". Absent on paired records, and a
    # record carrying it populates its own arm's key only — the opposite key is
    # omitted rather than null-filled, so it can never be read as a dispatched arm.
    arm: Optional[str] = None
    live_partial: bool = False
    stages: list = field(default_factory=list)
    # What the numbers are comparable against. Omitted (not null) when absent, so
    # records written before era stamping round-trip byte-identically.
    era: Optional[dict] = None
    # Provenance of a joined record: the two source runs and their observed gap.
    # Omitted on natively-paired records, so a reader can always tell the two apart.
    joined_from: Optional[dict] = None

    def to_dict(self) -> dict:
        d = {
            "run_id": self.run_id,
            "timestamp_utc": self.timestamp_utc,
            "mode": self.mode,
            "git_sha": self.git_sha,
            "budget_usd": self.budget_usd,
            "paths": {name: pm.to_dict() for name, pm in self.paths},
        }
        # An arm record has nothing to compare itself against; an empty block would
        # read downstream as a present-but-zero comparison rather than an absent one.
        if self.comparison:
            d["comparison"] = {key: md.to_dict() for key, md in self.comparison}
        if self.arm is not None:
            d["arm"] = self.arm
        if self.live_partial:
            d["live_partial"] = True
        if self.stages:
            d["stages"] = [s.to_dict() for s in self.stages]
        if self.era is not None:
            d["era"] = self.era
        if self.joined_from is not None:
            d["joined_from"] = self.joined_from
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "BenchmarkRecord":
        paths = [(k, PathMetrics.from_dict(v)) for k, v in (d.get("paths") or {}).items()]
        comparison = [
            (k, MetricDelta.from_dict(v)) for k, v in (d.get("comparison") or {}).items()
        ]
        stages = [StageAttribution.from_dict(s) for s in (d.get("stages") or [])]
        return cls(
            run_id=d.get("run_id") or "",
            timestamp_utc=d.get("timestamp_utc") or "",
            mode=d.get("mode") or "deterministic",
            git_sha=d.get("git_sha") or "",
            budget_usd=d.get("budget_usd"),
            paths=paths,
            comparison=comparison,
            arm=d.get("arm"),
            live_partial=bool(d.get("live_partial") or False),
            stages=stages,
            era=d.get("era"),
            joined_from=d.get("joined_from"),
        )

    @property
    def path_with(self) -> Optional[PathMetrics]:
        for name, pm in self.paths:
            if name == "with":
                return pm
        return None

    @property
    def path_without(self) -> Optional[PathMetrics]:
        for name, pm in self.paths:
            if name == "without":
                return pm
        return None


def build_comparison(with_pm: PathMetrics, without_pm: PathMetrics, mode: str) -> list:
    def metric(key: str, p: PathMetrics) -> Number:
        return {
            "loc_produced": p.loc_produced,
            "test_count": p.test_count,
            "coverage_pct": p.coverage_pct,
            "wall_clock_s": p.wall_clock_s,
            "estimate_complexity_score": p.estimate_complexity_score,
            "stage_count": p.stage_count,
        }[key]

    comp = [
        (key, MetricDelta.of(metric(key, with_pm), metric(key, without_pm)))
        for key in DETERMINISTIC_COMPARISON_KEYS
    ]
    if mode == "live":
        comp.append(
            ("tokens_total", MetricDelta.of(with_pm.tokens.total, without_pm.tokens.total))
        )
        comp.append(("cost_usd", MetricDelta.of(with_pm.cost_usd, without_pm.cost_usd)))
    return comp


def make_record(
    run_id: str,
    timestamp_utc: str,
    mode: str,
    git_sha: str,
    budget_usd: Optional[float],
    with_pm: PathMetrics,
    without_pm: PathMetrics,
    live_partial: bool = False,
    stages: Optional[list] = None,
    era: Optional[dict] = None,
) -> BenchmarkRecord:
    return BenchmarkRecord(
        run_id=run_id,
        timestamp_utc=timestamp_utc,
        mode=mode,
        git_sha=git_sha,
        budget_usd=budget_usd,
        paths=[("with", with_pm), ("without", without_pm)],
        comparison=build_comparison(with_pm, without_pm, mode),
        live_partial=live_partial,
        stages=stages or [],
        era=era,
    )


ARMS = ("with", "without")


def make_arm_record(
    run_id: str,
    timestamp_utc: str,
    mode: str,
    git_sha: str,
    budget_usd: Optional[float],
    arm: str,
    pm: PathMetrics,
    live_partial: bool = False,
    stages: Optional[list] = None,
    era: Optional[dict] = None,
) -> BenchmarkRecord:
    """Build a single-arm record: one ``paths`` entry, no comparison, ``arm`` stamped.

    A sibling of :func:`make_record` rather than a mode of it — the paired byte shape
    is protected by that function not being reachable from this path at all.
    """
    if arm not in ARMS:
        raise ValueError(f"arm must be one of {ARMS}, got {arm!r}")
    return BenchmarkRecord(
        run_id=run_id,
        timestamp_utc=timestamp_utc,
        mode=mode,
        git_sha=git_sha,
        budget_usd=budget_usd,
        paths=[(arm, pm)],
        comparison=[],
        arm=arm,
        live_partial=live_partial,
        stages=stages or [],
        era=era,
    )


def skip_placeholder_without() -> PathMetrics:
    """The WITHOUT block a ``--without-arm skip`` run stands in for a never-dispatched arm.

    Reserved for that one meaning. It reads ``pass_fail="pass"`` with a stage count of
    one, so reusing it to mean "this arm ran elsewhere" would render a fabricated pass
    beside real numbers — an arm record omits the opposite key instead.
    """
    return PathMetrics(
        tokens=Tokens(input=None, output=None, total=None),
        cost_usd=None, wall_clock_s=0.0, loc_produced=0, test_count=0, coverage_pct=None,
        estimate_complexity_score=0, stage_count=1, pass_fail="pass", app_path=None)


def dumps(record: BenchmarkRecord, indent: int = 2) -> str:
    return json.dumps(record.to_dict(), indent=indent)


def loads(text: str) -> BenchmarkRecord:
    return BenchmarkRecord.from_dict(json.loads(text))


def write_record(record: BenchmarkRecord, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(dumps(record))


def read_record(path: str) -> BenchmarkRecord:
    with open(path, encoding="utf-8") as f:
        return loads(f.read())
