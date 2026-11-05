"""Process execution and app metrics for the two deterministic generators.

Runs the generated app's Swift Testing suite (REAL ``swift test`` — the retained
measurement instrument), counts REAL loc_produced (*.swift), and builds a
PathMetrics from measured values. Template materialization lives in ``treecopy``.
Never imports benchmarklive.

OI-1: the nested ``swift test`` materializes a heavy ``.build/`` inside the app
dir; a ``finally`` sweeps exactly ``<app_dir>/.build`` on every exit path, scoped
so the caller's app copy / --workdir survive (R3).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from typing import Optional

from .metrics import PathMetrics, Tokens


class Timer:
    """Monotonic wall-clock timer; ``elapsed`` is seconds since ``start()``."""

    def __init__(self) -> None:
        self._t0 = 0.0

    def start(self) -> None:
        self._t0 = time.monotonic()

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self._t0


@dataclass
class Subprocess:
    exit_code: int
    stdout: str
    stderr: str

    @staticmethod
    def run(argv: list, cwd: Optional[str] = None, input: Optional[str] = None,
            env: Optional[dict] = None, timeout: Optional[float] = None) -> "Subprocess":
        try:
            # No input → stdin is /dev/null (never inherit the caller's stdin; a
            # nested/headless child can block forever on an inherited tty).
            r = subprocess.run(
                argv,
                cwd=cwd,
                env=env,
                input=input,
                stdin=None if input is not None else subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            # rc 124 (shell/coreutils `timeout` convention); never leak the prompt.
            output = exc.stdout or ""
            if isinstance(output, bytes):
                output = output.decode("utf-8", "replace")
            return Subprocess(124, output, f"timed out after {timeout}s")
        except (OSError, ValueError) as exc:
            return Subprocess(127, "", f"spawn failed: {exc}")
        return Subprocess(r.returncode, r.stdout, r.stderr)


def plugin_root(benchmark_dir: str) -> str:
    return os.path.dirname(benchmark_dir)


def count_loc(app_dir: str, exclude_dirs: Optional[set] = None) -> int:
    """REAL loc_produced: non-blank, non-pure-comment lines across generated *.swift.

    ``exclude_dirs`` names (not paths) are pruned at the app_dir root only, so a
    WITH-root count can skip a sibling ``without/`` arm directory.
    """
    skip = {".build", ".swiftpm"} | (exclude_dirs or set())
    total = 0
    for root, dirs, files in os.walk(app_dir):
        if root == app_dir:
            dirs[:] = [d for d in dirs if d not in skip]
        else:
            dirs[:] = [d for d in dirs if d not in (".build", ".swiftpm")]
        for name in files:
            if not name.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, name), encoding="utf-8") as f:
                    text = f.read()
            except OSError:
                continue
            for line in text.split("\n"):
                s = line.strip()
                if s and not s.startswith("//"):
                    total += 1
    return total


def parse_test_count(log: str) -> int:
    """Swift Testing 'Test run with N test(s)'; XCTest 'Executed N tests' fallback."""
    m = re.search(r"Test run with (\d+) test", log)
    if m:
        return int(m.group(1))
    m = re.search(r"Executed (\d+) test", log)
    if m:
        return int(m.group(1))
    return 0


def run_app_tests(app_dir: str) -> tuple:
    """Run the generated app's suite. Returns (test_count, pass_fail).

    pass_fail from the EXIT CODE only; test_count from the summary regex. OI-1:
    ``<app_dir>/.build`` swept in ``finally`` on every path.
    """
    build_dir = os.path.join(app_dir, ".build")
    try:
        r = Subprocess.run(["swift", "test", "--package-path", app_dir], cwd=app_dir)
        combined = r.stdout + r.stderr
        return parse_test_count(combined), ("pass" if r.exit_code == 0 else "fail")
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)


def relative_path(path: str, base: str) -> str:
    p = os.path.normpath(path)
    b = os.path.normpath(base)
    if p.startswith(b + os.sep):
        return p[len(b) + 1:]
    return p


def build_path_metrics(app_dir: str, plugin_root_dir: str, stage_count: int,
                       estimate_complexity_score: int, cost_usd: Optional[float],
                       wall_clock_s: float, oracle_result: Optional[dict] = None) -> PathMetrics:
    test_count, self_graded = run_app_tests(app_dir)
    loc = count_loc(app_dir)
    # The held-out oracle outranks the arm's own suite wherever it ran.
    pass_fail = self_graded
    if oracle_result is not None:
        pass_fail = "pass" if oracle_result.get("pass_rate") == 1.0 else "fail"
    return PathMetrics(
        tokens=Tokens(input=None, output=None, total=None),
        cost_usd=cost_usd,
        wall_clock_s=round(wall_clock_s * 10000) / 10000,
        loc_produced=loc,
        test_count=test_count,
        coverage_pct=None,  # nothing here measures coverage; a real 0.0 would claim it did
        estimate_complexity_score=estimate_complexity_score,
        stage_count=stage_count,
        pass_fail=pass_fail,
        app_path=relative_path(app_dir, plugin_root_dir),
        oracle=oracle_result,
    )
