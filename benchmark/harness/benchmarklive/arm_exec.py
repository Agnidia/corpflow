"""Arm identity, the dispatch seam, and per-arm token aggregation.

``Dispatching`` is the seam tests inject fakes through, so no real LLM call happens
under test; ``SubprocessDispatcher`` is the only implementation that shells out.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Protocol

from benchmarkkit.genlib import Subprocess

from . import baseline as baseline_mod
from .plugin_load import LoadedPlugin
from .usage_limit import UsageLimitHit

# Production dispatcher per-stage ceiling (D5); a hung child never blocks a run forever.
STAGE_TIMEOUT_S = 3600.0


@dataclass
class ArmSpec:
    """The sole legitimate A/B differences: ``bind_agent`` (→ --agent), ``plugin_dir``
    (→ --plugin-dir), the sibling plugins enabled in ``enabled_plugins`` and ``cwd``.
    Everything else (prompts, budget, capture shape, config dir) is shared by construction.

    ``plugin_dir`` is set only on the WITH arm. An arm with ``enabled_plugins`` and no
    ``plugin_dir`` is the plugin-free baseline: its stages must report zero plugins in
    ``system/init``. ``enabled_plugins=None`` leaves plugin config untouched."""

    name: str            # "with" | "without"
    bind_agent: bool
    cwd: str
    audit_path: str
    plugin_dir: Optional[str] = None   # verified against system/init when capture is stream-json
    enabled_plugins: Optional[dict] = None   # settings enabledPlugins; None = no isolation


@dataclass
class ArmResult:
    name: str
    usages: list = field(default_factory=list)   # [(stage, StageUsage)]
    dispatched: int = 0
    partial: bool = False
    dv_gated: bool = False
    app: Optional[baseline_mod.AppMeasure] = None
    plugin: Optional[LoadedPlugin] = None   # corpflow tree the CLI reported; None if unobserved
    plugin_error: Optional[str] = None      # set when the loaded plugins break the arm's contract
    plugins: Optional[list] = None          # every plugin the CLI reported, name@version; None if unobserved
    config_leaks: Optional[list] = None     # plugin-cache prefixes read outside the config dir; None if unscanned
    usage_limit: Optional[UsageLimitHit] = None   # set when a stage could not run for the account limit
    stop_reason: Optional[str] = None
    attempts: list = field(default_factory=list)
    overshoot_usd: float = 0.0
    completed_stages: list = field(default_factory=list)


class Dispatching(Protocol):
    def run(self, argv: list, prompt_text: str) -> str:
        ...


class DispatchFailure(Exception):
    """A failed stage's complete output, retained for accounting and diagnosis."""

    def __init__(self, message: str = "", *, stdout: str = "", stderr: str = "",
                 returncode: Optional[int] = None) -> None:
        super().__init__(message)
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class SubprocessDispatcher:
    """Run a provider CLI with stdin prompts and retain failure captures."""

    def __init__(self, workdir: Optional[str] = None, timeout: Optional[float] = STAGE_TIMEOUT_S,
                 env: Optional[dict] = None) -> None:
        self.workdir = workdir
        self.timeout = timeout
        self.env = env   # None inherits; the live path pins CLAUDE_CONFIG_DIR here

    def run(self, argv: list, prompt_text: str) -> str:
        r = Subprocess.run(argv, cwd=self.workdir, input=prompt_text, env=self.env,
                           timeout=self.timeout)
        if r.exit_code != 0:
            snippet = r.stderr.strip()[:400]
            # Under --output-format json the CLI reports API failures on stdout, not
            # stderr; without this the diagnostic is recoverable only from CLI transcripts.
            # The tail: the failure (a synthetic message, the result event) is emitted last.
            out_snippet = r.stdout.strip()[-400:]
            raise DispatchFailure(
                f"{argv[0]} dispatch failed (rc={r.exit_code})"
                + (f" stderr: {snippet}" if snippet else "")
                + (f" stdout tail: {out_snippet}" if out_snippet else ""),
                stdout=r.stdout, stderr=r.stderr, returncode=r.exit_code,
            )
        return r.stdout


def _sum_opt(values: list):
    real = [v for v in values if v is not None]
    return sum(real) if real else None


def _tok_total(input_tokens: Optional[int], output_tokens: Optional[int]) -> Optional[int]:
    if input_tokens is None and output_tokens is None:
        return None
    return (input_tokens or 0) + (output_tokens or 0)


def _arm_tokens(usages: list) -> tuple:
    su = [u for _, u in usages]
    in_total = _sum_opt([u.input_tokens for u in su])
    out_total = _sum_opt([u.output_tokens for u in su])
    tok_total = None if (in_total is None and out_total is None) else (in_total or 0) + (out_total or 0)
    cost_total = _sum_opt([u.cost_usd for u in su])
    cr_total = _sum_opt([u.cache_read for u in su])
    cc_total = _sum_opt([u.cache_creation for u in su])
    wall = round(sum(u.duration_s for u in su) * 10000) / 10000
    return in_total, out_total, tok_total, cost_total, cr_total, cc_total, wall
