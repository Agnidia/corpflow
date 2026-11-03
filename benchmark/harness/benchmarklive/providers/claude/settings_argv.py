"""Headless argv construction and the fail-closed deny-list guard.

The frozen argv shape is the AC-8 parity target, so it lives apart from the
orchestration that consumes it.
"""

from __future__ import annotations

import os
from typing import Optional

from ... import isolation
from ...stage_table import CAPTURE_JSON, CAPTURE_STREAM_JSON, STAGE_TABLE

# Headless has no interactive prompt, so safety rides on the deny-list settings file,
# not the mode. Mirrored verbatim in baseline.py (parity asserted by test, no import).
PERMISSION_MODE = "bypassPermissions"

SETTINGS_RELPATH = ("live", "settings", "benchmark-settings.json")


def settings_path_for(benchmark_dir: str) -> str:
    """Absolute path to the deny-list settings file for this benchmark tree."""
    return os.path.join(benchmark_dir, *SETTINGS_RELPATH)


def _settings_argv(settings_path: Optional[str], enabled_plugins: Optional[dict] = None) -> list:
    # Low-level argv builder: byte-stable, no I/O policy. Fail-closed enforcement
    # lives in require_settings() at the dispatch entry, NOT here, so the argv
    # shape stays pure/injectable for tests that don't care about the deny-list.
    if enabled_plugins is not None:
        # Isolation replaces the file argument: --settings takes one value, and the
        # deny-list must ride in the same document as the plugin switches.
        if not settings_path:
            raise ValueError("plugin isolation needs the deny-list settings path")
        return ["--setting-sources", isolation.SETTING_SOURCES,
                "--settings", isolation.settings_document(settings_path, enabled_plugins)]
    if settings_path and os.path.exists(settings_path):
        return ["--settings", settings_path]
    return []


class BenchmarkSettingsMissing(Exception):
    """Raised when a bypassPermissions dispatch would otherwise run with no deny-list.

    Headless ``claude -p`` has no interactive prompt, so under ``bypassPermissions``
    the ONLY guardrail is the deny-list settings file. If it is absent we fail closed
    rather than dispatch fail-open; the message names the expected path.
    """


def require_settings(settings_path: str, permission_mode: str = PERMISSION_MODE) -> None:
    """Fail closed BEFORE any dispatch when the deny-list settings file is missing.

    Enforced only under ``bypassPermissions`` (the sole headless mode); any other
    mode carries its own interactive guardrail and is left untouched. Pure and
    injectable — raises :class:`BenchmarkSettingsMissing` or returns ``None``.
    """
    if permission_mode == "bypassPermissions" and not os.path.exists(settings_path):
        raise BenchmarkSettingsMissing(
            "deny-list settings file is required under bypassPermissions but is "
            f"missing: {settings_path} — create it (see benchmark/live/settings/) "
            "before dispatching; refusing to run fail-open with no deny-list."
        )


def build_arm_stage_argv(stage: str, bind_agent: bool = True, capture_mode: str = CAPTURE_JSON,
                         settings_path: Optional[str] = None,
                         plugin_dir: Optional[str] = None,
                         enabled_plugins: Optional[dict] = None) -> list:
    """Frozen headless argv for one arm's stage. Bound and bare argvs are identical
    except ``--plugin-dir`` (only when ``plugin_dir`` is given), the ``enabledPlugins``
    map inside ``--settings`` and the trailing ``--agent`` (AC-8 parity target);
    stream-json adds --verbose.

    ``--plugin-dir`` pins the corpflow tree under test for this session; the CLI
    otherwise loads whichever copy is installed, which may sit at another commit.
    ``enabled_plugins`` (None = leave plugin config alone) also stops every settings
    layer from loading; ``benchmarklive.isolation`` says why."""
    entry = STAGE_TABLE.get(stage)
    if entry is None:
        return []
    agent, model, effort = entry
    argv = ["claude", "-p", "--model", model, "--effort", effort,
            "--permission-mode", PERMISSION_MODE, "--output-format", capture_mode]
    argv += _settings_argv(settings_path, enabled_plugins)
    if plugin_dir:
        argv += ["--plugin-dir", plugin_dir]
    if bind_agent:
        argv += ["--agent", agent]
    if capture_mode == CAPTURE_STREAM_JSON:
        argv.append("--verbose")
    return argv


def build_stage_argv(stage: str, capture_mode: str = CAPTURE_JSON,
                     settings_path: Optional[str] = None,
                     plugin_dir: Optional[str] = None,
                     enabled_plugins: Optional[dict] = None) -> list:
    """WITH-arm (agent-bound) argv — thin wrapper over the shared arm builder."""
    return build_arm_stage_argv(stage, bind_agent=True, capture_mode=capture_mode,
                                settings_path=settings_path, plugin_dir=plugin_dir,
                                enabled_plugins=enabled_plugins)
