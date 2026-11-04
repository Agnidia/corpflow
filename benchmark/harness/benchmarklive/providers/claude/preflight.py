"""Plugin-isolation preflight: one cheap ``claude -p`` per arm before any paid stage.

A stage's own ``system/init`` check fires only after that stage was paid for. The probe
loads each arm's exact plugin configuration (same config dir, settings document,
``--plugin-dir`` and cwd) and refuses the run when either arm would load the wrong set.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Optional, Sequence

from benchmarkkit.genlib import Subprocess

from . import capture, isolation, plugin_load, usage_limit
from .models import MODEL_PINS
from .settings_argv import PERMISSION_MODE, _settings_argv

PROBE_MODEL = MODEL_PINS["haiku"]
PROBE_MAX_TURNS = 1
PROBE_TIMEOUT_S = 120.0
PROBE_PROMPT = "Reply with the single word ok."


@dataclass(frozen=True)
class ProbeOutput:
    stdout: str
    returncode: int
    stderr: str = ""


ProbeRunner = Callable[[list, str, dict, str], ProbeOutput]   # (argv, prompt, env, cwd)


@dataclass(frozen=True)
class ProbeVerdict:
    arm: str
    ok: bool
    plugins: Optional[list]
    reason: Optional[str]
    cost_usd: Optional[float]


def build_probe_argv(arm, settings_path: str) -> list:
    """Argv whose plugin-bearing flags equal the arm's stage argv byte for byte.

    No ``--agent`` and no ``--effort``: neither changes which plugins load.
    """
    argv = ["claude", "-p", "--model", PROBE_MODEL, "--permission-mode", PERMISSION_MODE,
            "--output-format", "stream-json", "--verbose", "--max-turns", str(PROBE_MAX_TURNS)]
    argv += _settings_argv(settings_path, arm.enabled_plugins)
    if arm.plugin_dir:
        argv += ["--plugin-dir", arm.plugin_dir]
    return argv


def default_probe_runner(argv: list, prompt: str, env: dict, cwd: str) -> ProbeOutput:
    r = Subprocess.run(argv, cwd=cwd, input=prompt, env=env, timeout=PROBE_TIMEOUT_S)
    return ProbeOutput(stdout=r.stdout, returncode=r.exit_code, stderr=r.stderr)


def _cost(stdout: str) -> Optional[float]:
    parsed = capture.parse(stdout)
    return parsed.cost_usd if parsed is not None else None


def _failure_reason(out: ProbeOutput) -> str:
    if out.returncode == 124:
        return f"probe timed out after {PROBE_TIMEOUT_S:g}s"
    reason = f"probe exited rc {out.returncode}"
    limit = usage_limit.detect(out.stdout, datetime.now(timezone.utc))
    if limit is not None:
        when = (limit.reset_at.strftime("%Y-%m-%dT%H:%M:%SZ") if limit.reset_at is not None
                else limit.reset_text or "unknown")
        reason += f" on the account usage limit {limit.message!r}, resets at {when}"
    return reason


def probe_arm(arm, settings_path: str, env: dict, runner: ProbeRunner) -> ProbeVerdict:
    """Probe one arm; every fault, including one the runner raises, is a refusal."""
    try:
        out = runner(build_probe_argv(arm, settings_path), PROBE_PROMPT, env, arm.cwd)
    except (ValueError, OSError) as exc:
        return ProbeVerdict(arm.name, False, None, f"probe could not run: {exc}", None)
    if arm.plugin_dir is not None:
        check = plugin_load.check_exact_plugin_set(
            out.stdout, arm.plugin_dir, isolation.SIBLING_PLUGINS)
    else:
        check = plugin_load.check_stage_bare(out.stdout)
    cost = _cost(out.stdout)
    if out.returncode != 0:
        return ProbeVerdict(arm.name, False, check.plugins, _failure_reason(out), cost)
    return ProbeVerdict(arm.name, check.error is None, check.plugins, check.error, cost)


def run_preflight(arms: Sequence, settings_path: str, env: dict,
                  runner: ProbeRunner) -> list:
    """Probe every arm, even after a refusal, so one run reports every broken arm."""
    return [probe_arm(arm, settings_path, env, runner) for arm in arms]


def describe(v: ProbeVerdict) -> str:
    if v.ok:
        cost = f"${v.cost_usd:.4f}" if v.cost_usd is not None else "$unknown"
        return f"preflight: {v.arm} ok, plugins {v.plugins}, cost {cost}"
    saw = v.plugins if v.plugins is not None else "no plugin list"
    return (f"live run refused: plugin-isolation preflight: {v.arm} arm {v.reason} "
            f"(saw {saw}); nothing was dispatched")
