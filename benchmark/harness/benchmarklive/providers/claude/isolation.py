"""Config isolation for both arms: which config dir, which settings layers, which plugins.

Both arms run ``claude -p`` against one dedicated config dir, so the operator's own
config and its plugins never reach a measurement. The WITHOUT arm must then load zero
plugins and the WITH arm exactly corpflow plus the siblings it delegates to.

Verified against Claude Code 2.1.284, in a cwd nested inside a git repo:

* The eval dir alone is not plugin-free. Account-synced plugins load regardless of
  ``enabledPlugins``, and the builtins in ``BUILTIN_PLUGINS`` load beside them
  (verified on 2.1.289).
* ``--setting-sources project,local`` still leaks: the repo's own
  ``.claude/settings.local.json`` enables plugins there, and a benchmark workdir sits
  inside that repo. An empty source list is the only value that loads no settings file.
* ``--settings`` cannot be repeated (the last one wins), so the deny-list and the
  plugin switches travel in one inline JSON document.
"""

from __future__ import annotations

import json
import os
from typing import Optional

CONFIG_DIR_ENV = "BENCH_CONFIG_DIR"
CLAUDE_CONFIG_ENV = "CLAUDE_CONFIG_DIR"
DEFAULT_CONFIG_DIR = "~/.claude-eval"

# Empty, not "project,local": see the module docstring. ``--settings`` still applies.
SETTING_SOURCES = ""

# Ship inside the CLI and load in every session. They are not the operator's plugins,
# but the WITHOUT arm's "loaded nothing" evidence would be unreadable with them present,
# so both arms switch them off. A future builtin surfaces as a WITHOUT-arm refusal
# naming it, never as a silent difference.
BUILTIN_PLUGINS = ("agents-md@builtin", "telemetry@builtin", "plugin-authoring@builtin")

# Plugins corpflow delegates to; they are part of the product under test, so the WITH
# arm enables them and the WITHOUT arm does not.
SIBLING_PLUGINS = ("apple-developer@apple-developer",)


def resolve_config_dir(explicit: Optional[str] = None, env: Optional[dict] = None) -> str:
    """Absolute eval config dir: ``--config-dir``, else ``BENCH_CONFIG_DIR``, else default."""
    source = env if env is not None else os.environ
    chosen = explicit or source.get(CONFIG_DIR_ENV) or DEFAULT_CONFIG_DIR
    return os.path.abspath(os.path.expanduser(chosen))


def claude_env(config_dir: str, base: Optional[dict] = None) -> dict:
    """Child environment with ``CLAUDE_CONFIG_DIR`` pinned; the caller's env is not mutated."""
    child = dict(base if base is not None else os.environ)
    child[CLAUDE_CONFIG_ENV] = config_dir
    return child


def enabled_plugins(with_siblings: bool) -> dict:
    """The ``enabledPlugins`` map for one arm: builtins off, siblings on for WITH only."""
    plugins = {name: False for name in BUILTIN_PLUGINS}
    if with_siblings:
        plugins.update({name: True for name in SIBLING_PLUGINS})
    return plugins


def settings_document(deny_list_path: str, plugins: dict) -> str:
    """Inline ``--settings`` JSON: the deny-list file's content plus ``enabledPlugins``.

    Raises ``ValueError`` when the deny-list is unreadable or not a JSON object; the
    caller must not fall back to dispatching without it.
    """
    try:
        with open(deny_list_path, encoding="utf-8") as f:
            document = json.load(f)
    except (OSError, ValueError) as exc:
        raise ValueError(f"deny-list settings unreadable at {deny_list_path}: {exc}") from exc
    if not isinstance(document, dict):
        raise ValueError(f"deny-list settings at {deny_list_path} is not a JSON object")
    document["enabledPlugins"] = plugins
    return json.dumps(document, sort_keys=True)
