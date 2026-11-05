"""Comparability gate + join for two single-arm records (AC-8 to AC-11).

Pure: two parsed record dicts in, a list of refusals or a joined ``BenchmarkRecord``
out. No filesystem, no clock, no subprocess, and no ``benchmarklive`` import — the
join is analysis, not dispatch, and sits on the same side of the boundary as the
analyzer and the reporter. The one side effect is the join's stderr warning on unequal
arm budgets, which a caller can redirect through ``warn``.

The gate is fail-closed. A permissive gate is worse than no gate: it launders two
incomparable runs as a comparison, which is the exact misreading this work exists to
prevent. Every axis except the time gap refuses, and every axis is evaluated so a
reader sees all of them at once rather than fixing one and hitting the next.
"""

from __future__ import annotations

import hashlib
import sys
from typing import Callable, Optional

from . import analysis
from .metrics import (
    ARMS,
    BenchmarkRecord,
    PathMetrics,
    StageAttribution,
    build_comparison,
)


class PairingError(ValueError):
    """The two inputs are not a joinable pair of arm records (a usage fault)."""


#: What ``run-benchmark.sh`` and ``dispatch`` write when they cannot resolve a commit.
NO_SHA_SENTINEL = "nogit"


def _quoted(value) -> str:
    return "absent" if value is None else repr(value)


def _sha_is_unknown(sha) -> bool:
    return not sha or sha == NO_SHA_SENTINEL


def _sha_quoted(sha) -> str:
    if not sha:
        return "absent"
    # "nogit" is a sentinel for "no commit identity was available", not a commit id, so
    # the message must not read like two runs simply share an odd-looking sha.
    return f"unknown ({sha!r})" if sha == NO_SHA_SENTINEL else repr(sha)


def _digest_shape_fault(record: dict, arm: str) -> Optional[str]:
    """Name the block whose type would crash the digest accessor, or None.

    Mirrors ``analysis.oracle_cases_digests``' traversal and fires on exactly the values
    it reaches with ``.get``/``.items``. Its ``or {}`` defences already absorb absent and
    falsy blocks into an unstamped digest, so widening this to every non-dict would turn
    inputs that refuse today into usage faults.
    """
    paths = record.get("paths")
    if paths and not isinstance(paths, dict):
        return f"'paths' is a {type(paths).__name__}"
    pm = (paths or {}).get(arm)
    if pm and not isinstance(pm, dict):
        return f"'paths.{arm}' is a {type(pm).__name__}"
    oracle = (pm or {}).get("oracle")
    if oracle and not isinstance(oracle, dict):
        return f"'paths.{arm}.oracle' is a {type(oracle).__name__}"
    return None


def _own_digest(record: dict) -> Optional[str]:
    # Operator-supplied JSON is this gate's input domain, so a wrong-typed block below the
    # arm shape is input, not a bug: the module owes every unjoinable pair a PairingError,
    # and an AttributeError out of the accessor strands a caller writing `except
    # PairingError`. Converted here rather than in the accessor because a malformed block
    # must stay distinguishable from an unstamped one — the accessor answering None would
    # dress a usage fault (64) up as a comparability refusal (65).
    arm = analysis.single_arm(record)
    if arm is None:
        return None
    fault = _digest_shape_fault(record, arm)
    if fault is not None:
        raise PairingError(
            f"malformed arm record: run_id {record.get('run_id')!r} — {fault}, not an "
            "object, so its oracle case-set digest cannot be read")
    return analysis.oracle_cases_digests(record).get(arm)


# Each names what ONE arm loaded or touched (the WITHOUT arm passes no --plugin-dir and
# loads nothing; ``config_leaks`` is keyed by the arm that was scanned), so demanding a
# match would refuse every honest pair.
_ARM_SCOPED_ERA_KEYS = frozenset(
    {"plugin_path", "plugins_with", "plugins_without", "config_leaks", "accounting"})


def _join_era(with_era, without_era):
    """The WITH record's era, plus the arm-scoped keys only the WITHOUT record carries."""
    if not isinstance(with_era, dict) or not isinstance(without_era, dict):
        return with_era
    joined = dict(with_era)
    for key in sorted(_ARM_SCOPED_ERA_KEYS):
        if key not in joined and key in without_era:
            joined[key] = without_era[key]
        elif (key in ("config_leaks", "accounting") and isinstance(joined.get(key), dict)
              and isinstance(without_era.get(key), dict)):
            # Each single-arm record carries only its own arm's entry.
            joined[key] = {**without_era[key], **joined[key]}
    return joined


def _era_is_stamped(era) -> bool:
    return isinstance(era, dict) and bool(era)


def _era_refusal(era_a, era_b) -> Optional[str]:
    # An empty or non-dict era block is unstamped, not "stamped with nothing": `{} != {}`
    # is False and era_differences() finds no diffs, so an equality-only test would pass
    # a pair that R13 refuses. The isinstance half also keeps a hand-edited `era: "v3"`
    # from reaching era_differences() as an AttributeError instead of a refusal.
    if not _era_is_stamped(era_a) or not _era_is_stamped(era_b):
        def label(era):
            return "stamped" if _era_is_stamped(era) else "absent"
        return f"era: {label(era_a)} vs {label(era_b)}"
    diffs = analysis.era_differences(era_a, era_b)
    if diffs:
        return "era: " + "; ".join(diffs)
    # Full dict equality on top of the three-key diff: a future era key the analyzer's
    # advisory comparison does not inspect would otherwise pass the gate and then be
    # silently arbitrated by the join.
    shared_a = {k: v for k, v in era_a.items() if k not in _ARM_SCOPED_ERA_KEYS}
    shared_b = {k: v for k, v in era_b.items() if k not in _ARM_SCOPED_ERA_KEYS}
    if shared_a != shared_b:
        keys = sorted(k for k in set(shared_a) | set(shared_b)
                      if shared_a.get(k) != shared_b.get(k))
        return "era: " + "; ".join(
            f"{k}: {era_a.get(k)!r} vs {era_b.get(k)!r}" for k in keys)
    return None


def comparability_refusals(record_a: dict, record_b: dict) -> list:
    """Every reason these two records must not be joined, named with both values.

    Returns an empty list when the pair is comparable. The time gap is deliberately
    absent: at n=1 there is no variance envelope to derive a threshold from, so it is
    reported by :func:`join_arm_records` and never refused on.

    Raises :class:`PairingError` when a record is too malformed to gate — a refusal
    would claim the two runs were compared and found incomparable, which is a stronger
    statement than the input supports.
    """
    refusals = []

    era = _era_refusal(record_a.get("era"), record_b.get("era"))
    if era is not None:
        refusals.append(era)

    sha_a, sha_b = record_a.get("git_sha"), record_b.get("git_sha")
    # Unknown never compares equal to unknown. Two records that both lack a commit
    # identity — no `git_sha` key, or the "nogit" sentinel from an export with no .git —
    # can sit many commits apart, so certifying them as same-commit is exactly the
    # laundering this gate exists to prevent. Era and digest already refuse on absent;
    # sha was the only axis where "I don't know" read as "they match".
    if _sha_is_unknown(sha_a) or _sha_is_unknown(sha_b) or sha_a != sha_b:
        refusals.append(f"commit sha: {_sha_quoted(sha_a)} vs {_sha_quoted(sha_b)}")

    digest_a, digest_b = _own_digest(record_a), _own_digest(record_b)
    if digest_a is None or digest_b is None or digest_a != digest_b:
        refusals.append(
            f"oracle case-set digest: {_quoted(digest_a)} vs {_quoted(digest_b)}")

    return refusals


def _compact(timestamp: str) -> str:
    return timestamp.replace("-", "").replace(":", "")


def _source_tag(with_run_id, without_run_id) -> str:
    """Eight hex digits distinguishing this pair of sources from any other.

    Timestamp and sha are not enough: two joins whose later-arm timestamps and commit
    coincide would produce one run_id, and the rotation snippet reads a repeated run_id
    as a re-ingest — it exits 0 printing "rotated into history" having added nothing.
    That is silent data loss, so the id carries something only these two sources have.
    Keyed by arm, never by argument order, so a swapped join tags identically.
    """
    seed = f"{with_run_id or ''}\n{without_run_id or ''}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:8]


def _sum_budgets(a, b):
    present = [v for v in (a, b) if isinstance(v, (int, float))]
    return sum(present) if present else None


def arm_pair(record_a: dict, record_b: dict) -> dict:
    """Key the two inputs by their own ``arm``, which is what makes the join
    order-insensitive: nothing downstream reads argument position."""
    keyed = {}
    for record in (record_a, record_b):
        arm = analysis.single_arm(record)
        if arm is None:
            raise PairingError(
                f"not a single-arm record: run_id {record.get('run_id')!r} carries no "
                "'arm' key (a paired record cannot be an input to the join)")
        if arm in keyed:
            raise PairingError(
                f"both inputs are the {arm!r} arm: a join needs one of each")
        # R7's arm shape is a contract on read, not only on write. A record declaring one
        # arm while carrying both would have its opposite half silently dropped by the
        # join; one omitting its own arm is caught today only by the digest axis, which
        # is accidental coupling rather than validation.
        paths = record.get("paths")
        carried = sorted(paths) if isinstance(paths, dict) else None
        if carried != [arm]:
            raise PairingError(
                f"malformed arm record: run_id {record.get('run_id')!r} declares arm "
                f"{arm!r} but its 'paths' carries "
                f"{carried if carried is not None else 'no path block'} "
                f"(an arm record carries exactly its own arm)")
        keyed[arm] = record
    return keyed


def budget_mismatch(record_a: dict, record_b: dict) -> Optional[str]:
    """A warning naming both ``budget_usd`` values when the arms ran on different allowances.

    Warn-only, never a refusal: a resumed arm given the paired total instead of the
    per-arm share is still a real measurement, just not a like-for-like one.
    """
    keyed = {analysis.single_arm(r): r.get("budget_usd") for r in (record_a, record_b)}
    with_budget, without_budget = keyed.get(ARMS[0]), keyed.get(ARMS[1])
    if with_budget == without_budget:
        return None
    return (f"arm budgets differ: with budget_usd {_quoted(with_budget)} vs without "
            f"budget_usd {_quoted(without_budget)}; the joined comparison is not "
            "like-for-like")


def join_arm_records(record_a: dict, record_b: dict,
                     warn: Optional[Callable[[str], None]] = None) -> BenchmarkRecord:
    """Weld two comparable arm records into the existing paired shape.

    Raises :class:`PairingError` on a malformed pair *and* on any comparability
    refusal. The gate is re-run here rather than trusted to the caller so the
    fail-closed property belongs to this module: a second caller — a future
    ``bench-rotate``, a notebook, a test — cannot obtain a joined record that
    ``comparability_refusals`` would have refused. Derivations are all
    order-insensitive, so no normalisation step is needed to satisfy the
    swap-the-arguments requirement.
    """
    keyed = arm_pair(record_a, record_b)

    refusals = comparability_refusals(record_a, record_b)
    if refusals:
        raise PairingError(
            "refusing to join two incomparable records: " + "; ".join(refusals))
    mismatch = budget_mismatch(record_a, record_b)
    if mismatch is not None:
        (warn or (lambda s: sys.stderr.write(s + "\n")))(f"bench-pair: warning: {mismatch}")
    with_rec, without_rec = keyed[ARMS[0]], keyed[ARMS[1]]

    with_pm = PathMetrics.from_dict((with_rec.get("paths") or {}).get("with") or {})
    without_pm = PathMetrics.from_dict((without_rec.get("paths") or {}).get("without") or {})

    with_ts = with_rec.get("timestamp_utc") or ""
    without_ts = without_rec.get("timestamp_utc") or ""
    later_ts = max(with_ts, without_ts)  # zero-padded ISO sorts chronologically
    git_sha = with_rec.get("git_sha") or ""

    stages = [StageAttribution.from_dict(s) for s in (with_rec.get("stages") or [])]
    stages += [StageAttribution.from_dict(s) for s in (without_rec.get("stages") or [])]

    # The single warn-only axis, carried in the record rather than only printed, so a
    # later reader can judge the separation without re-running the join.
    joined_from = {
        "with": {"run_id": with_rec.get("run_id"), "timestamp_utc": with_ts},
        "without": {"run_id": without_rec.get("run_id"), "timestamp_utc": without_ts},
        "observed_gap_s": analysis.observed_gap_s(with_rec, without_rec),
    }

    source_tag = _source_tag(with_rec.get("run_id"), without_rec.get("run_id"))

    return BenchmarkRecord(
        run_id=f"live-{_compact(later_ts)}-{git_sha}-joined-{source_tag}",
        timestamp_utc=later_ts,
        mode="live",
        git_sha=git_sha,
        budget_usd=_sum_budgets(with_rec.get("budget_usd"), without_rec.get("budget_usd")),
        paths=[("with", with_pm), ("without", without_pm)],
        comparison=build_comparison(with_pm, without_pm, "live"),
        arm=None,
        live_partial=bool(with_rec.get("live_partial")) or bool(without_rec.get("live_partial")),
        stages=stages,
        era=_join_era(with_rec.get("era"), without_rec.get("era")),
        joined_from=joined_from,
    )
