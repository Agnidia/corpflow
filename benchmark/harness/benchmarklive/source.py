"""Fingerprint the plugin and measurement sources without generated artifacts."""

import hashlib
from pathlib import Path


def source_digest(root):
    root = Path(root)
    digest = hashlib.sha256()
    names = ("skills", "agents", "hooks", "lib", "commands", ".claude-plugin",
             "benchmark/harness", "benchmark/live", "benchmark/ttt-template", "benchmark/oracle",
             "benchmark/run-benchmark.sh", "Makefile")
    for name in names:
        entry = root / name
        paths = sorted(entry.rglob("*")) if entry.is_dir() else [entry]
        for path in paths:
            if {"__pycache__", ".build", ".git", ".swiftpm"}.intersection(path.parts):
                continue
            if path.is_file():
                digest.update(str(path.relative_to(root)).encode() + b"\0")
                digest.update((str(path.readlink()).encode() if path.is_symlink()
                               else path.read_bytes()) + b"\0")
    return digest.hexdigest()
