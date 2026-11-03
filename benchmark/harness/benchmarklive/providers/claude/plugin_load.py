"""Which corpflow tree a stage actually loaded, checked against the tree under test.

The stamped ``git_sha`` names the worktree; the CLI resolves plugins on its own, so
without this check an installed copy at a different commit could be what ran while
the record claims the worktree's sha.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from ... import capture


@dataclass
class LoadedPlugin:
    path: str                       # realpath of the corpflow tree the CLI reported
    version: Optional[str] = None


@dataclass
class PluginCheck:
    loaded: Optional[LoadedPlugin] = None
    error: Optional[str] = None
    plugins: Optional[list] = None   # every plugin the stage loaded, "name@version"; None if unobserved


def plugin_labels(entries: list) -> list:
    """``name@version`` per loaded plugin, in load order. A plugin with no version
    reports ``unversioned`` so the label stays one shape."""
    labels = []
    for e in entries:
        version = e.get("version")
        labels.append(f"{e.get('name')}@{version if isinstance(version, str) and version else 'unversioned'}")
    return labels


def _describe_errors(errors: list) -> str:
    if not errors:
        return ""
    parts = [f"{e.get('path')}: {e.get('message') or e.get('error') or e}" for e in errors]
    return " plugin_errors: " + "; ".join(parts)


def check_stage_plugin(stdout: str, expected_root: str) -> PluginCheck:
    """Fail closed unless exactly one corpflow loaded and it resolves to ``expected_root``.

    Two corpflow entries mean ``--plugin-dir`` did not shadow the installed copy, so
    the run is unattributable even when one of them is the right tree. A failed
    ``--plugin-dir`` load surfaces in ``plugin_errors`` with its ``path`` and is fatal
    when that path is the tree under test.
    """
    init = capture.parse_init_plugins(stdout)
    if init is None:
        return PluginCheck(error=(
            "no system/init event in stage output; cannot confirm which corpflow loaded "
            "(plugin verification needs --capture stream-json)"))
    check = _check_corpflow(init, expected_root)
    check.plugins = plugin_labels(init.plugins)
    return check


def check_stage_bare(stdout: str) -> PluginCheck:
    """Fail closed unless the stage's ``system/init`` reports zero plugins.

    The baseline arm is only a baseline if nothing was loaded; a single surviving
    plugin (account-synced, builtin, or enabled by a repo settings file) would make the
    comparison one of two configurations rather than plugin versus none.
    """
    init = capture.parse_init_plugins(stdout)
    if init is None:
        return PluginCheck(error=(
            "no system/init event in stage output; cannot confirm the baseline loaded no "
            "plugin (plugin verification needs --capture stream-json)"))
    labels = plugin_labels(init.plugins)
    if labels:
        return PluginCheck(plugins=labels, error=(
            f"baseline arm loaded plugins {labels}; expected none.{_describe_errors(init.errors)}"))
    return PluginCheck(plugins=labels)


def _check_corpflow(init: "capture.InitPlugins", expected_root: str) -> PluginCheck:
    want = os.path.realpath(expected_root)
    detail = _describe_errors(init.errors)
    paths = [os.path.realpath(str(e.get("path"))) for e in init.corpflow if e.get("path")]
    first = init.corpflow[0] if init.corpflow else None
    loaded = None
    if first is not None and paths:
        version = first.get("version")
        loaded = LoadedPlugin(path=paths[0], version=version if isinstance(version, str) else None)

    load_failed = any(e.get("path") and os.path.realpath(str(e["path"])) == want
                      for e in init.errors)
    if not paths:
        return PluginCheck(error=f"corpflow not loaded; expected {want}.{detail}")
    if len(paths) > 1:
        return PluginCheck(loaded=loaded, error=(
            f"--plugin-dir did not shadow the installed corpflow: loaded {paths}; "
            f"expected only {want}.{detail}"))
    if paths[0] != want or load_failed:
        return PluginCheck(loaded=loaded, error=(
            f"corpflow loaded from {paths[0]}, expected {want}; the record would be "
            f"stamped with a tree that did not run.{detail}"))
    return PluginCheck(loaded=loaded)
