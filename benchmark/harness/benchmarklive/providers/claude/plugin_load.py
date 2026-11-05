"""Which corpflow tree a stage actually loaded, checked against the tree under test.

The stamped ``git_sha`` names the worktree; the CLI resolves plugins on its own, so
without this check an installed copy at a different commit could be what ran while
the record claims the worktree's sha.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional, Sequence

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


def _sibling_key(entry: dict, siblings: Sequence[str]) -> Optional[str]:
    """The ``siblings`` entry this loaded plugin is, or None for a plugin nobody asked for.

    ``source`` (``name@marketplace``) is the exact identity when the CLI reports it; a
    build that omits it falls back to the bare name, which cannot tell two marketplaces'
    copies apart but still catches a missing or an extra plugin.
    """
    source = entry.get("source")
    if isinstance(source, str) and source:
        return source if source in siblings else None
    name = entry.get("name")
    for sibling in siblings:
        if name == sibling.split("@", 1)[0]:
            return sibling
    return None


def check_exact_plugin_set(stdout: str, expected_root: str,
                           siblings: Sequence[str]) -> PluginCheck:
    """Fail closed unless ``system/init`` lists the tree under test plus each sibling once.

    Stricter than :func:`check_stage_plugin`, which ignores everything but corpflow: a
    builtin or account-synced plugin beside the WITH arm would be measured as part of
    corpflow without anything saying so.
    """
    init = capture.parse_init_plugins(stdout)
    if init is None:
        return PluginCheck(error=(
            "no system/init event in output; cannot confirm which plugins loaded "
            "(plugin verification needs --output-format stream-json)"))
    labels = plugin_labels(init.plugins)
    check = _check_corpflow(init, expected_root)
    check.plugins = labels
    if check.error is not None:
        return check
    counts = {sibling: 0 for sibling in siblings}
    extra = []
    for entry in init.plugins:
        if entry.get("name") == "corpflow":
            continue
        key = _sibling_key(entry, siblings)
        if key is None:
            extra.extend(plugin_labels([entry]))
        else:
            counts[key] += 1
    problems = []
    missing = [s for s, n in counts.items() if n == 0]
    repeated = [s for s, n in counts.items() if n > 1]
    if missing:
        problems.append(f"sibling plugins not loaded {missing}")
    if repeated:
        problems.append(f"sibling plugins loaded more than once {repeated}")
    if extra:
        problems.append(f"unexpected plugins loaded {extra}")
    if problems:
        check.error = ("; ".join(problems) + f"; expected only corpflow and {list(siblings)}."
                       + _describe_errors(init.errors))
    return check


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
