"""Detect a stage reaching into a plugin cache that is not the arm's own config dir.

Isolation pins ``CLAUDE_CONFIG_DIR`` for the CLI, but nothing stops a sub-agent from
opening ``~/.claude/plugins/cache/...`` by absolute path, which loads a plugin version
the session never did and prices a tree that is not the one under test. The scan reads
only what the model *passed* in tool inputs: a path that shows up in a tool result
(``ls`` output, an error message) is evidence of the filesystem, not of a read.
"""

from __future__ import annotations

import json
import os
import re
from typing import Iterator, Optional

# One plugin-tree root per match: `<anything>/plugins/(cache|marketplaces)/<first name>`.
# `~` and `$HOME` are accepted because a Bash command spells the home dir that way; the
# lookbehind stops a relative `a/plugins/cache/x` matching from its inner slash, and
# permits `=` so `P=/abs/plugins/cache/x` is seen.
_PLUGIN_TREE = re.compile(
    r"(?<![\w.\-/~$}])"
    r"(?P<root>(?:~|\$\{?HOME\}?|/)[^\s\"'`;|&<>()=,]*?/plugins/(?:cache|marketplaces))"
    r"/(?P<name>[^/\s\"'`;|&<>()=,]+)")


def _strings(value) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from _strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from _strings(v)


def _tool_input_strings(stdout: str) -> Iterator[str]:
    """Every string in every tool_use input, parent and sub-agent events alike."""
    for line in stdout.split("\n"):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict) or event.get("type") != "assistant":
            continue
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield from _strings(block.get("input"))


def _expand(root: str, home: str) -> str:
    if root == "~" or root.startswith("~/"):
        root = home + root[1:]
    elif root.startswith("${HOME}"):
        root = home + root[len("${HOME}"):]
    elif root.startswith("$HOME"):
        root = home + root[len("$HOME"):]
    return os.path.normpath(root)


def _within(path: str, directory: str) -> bool:
    # Both spellings of the config dir: the model may quote the symlinked or the
    # resolved form of a path (macOS /var vs /private/var).
    for candidate in {directory, os.path.realpath(directory)}:
        if path == candidate or path.startswith(candidate.rstrip(os.sep) + os.sep):
            return True
    return False


def find_leaks(stdout: str, config_dir: str, home: Optional[str] = None) -> list:
    """Distinct ``<plugins dir>/<first entry>`` prefixes read from outside ``config_dir``.

    Sorted, so the stamped ``era.config_leaks`` is stable across runs. Empty when the
    stage stayed inside its own config dir.
    """
    home = home if home is not None else os.path.expanduser("~")
    leaks = set()
    for text in _tool_input_strings(stdout):
        for match in _PLUGIN_TREE.finditer(text):
            root = _expand(match.group("root"), home)
            if not _within(root, config_dir):
                leaks.add(f"{root}/{match.group('name')}")
    return sorted(leaks)
