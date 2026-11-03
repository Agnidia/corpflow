#!/usr/bin/env python3
"""Generate intentional runbook excerpts from their canonical owners."""
import argparse
import re
from pathlib import Path


def block(text, heading, kind):
    match = re.search(heading, text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing heading: {heading}")
    pattern = r"```yaml\n.*?\n```" if kind == "yaml" else r"^\|[^\n]*\n(?:\|[^\n]*\n)+"
    found = re.search(pattern, text[match.end():], re.MULTILINE | re.DOTALL if kind == "yaml" else re.MULTILINE)
    if not found:
        raise ValueError(f"missing {kind} after {heading}")
    return match.end() + found.start(), match.end() + found.end(), found.group()


def sync(root, write=False):
    specs = [
        ("technical-lead", r"^#### DR runbook — frontmatter", "skills/worktask/assets/templates/template-dr.md", r"^### #tpl-dr ", "yaml"),
        ("security-reviewer", r"^#### SR runbook — frontmatter", "skills/worktask/assets/templates/template-sr.md", r"^### #tpl-sr ", "yaml"),
        ("product-manager", r"^#### PL0 runbook — 3\. Size", "skills/estimation-methodology/SKILL.md", r"^### Stage set table", "table"),
    ]
    drift = []
    for agent, heading, source, canonical_heading, kind in specs:
        path = root / "agents" / f"{agent}.md"
        text = path.read_text()
        start, end, actual = block(text, heading, kind)
        _, _, expected = block((root / source).read_text(), canonical_heading, kind)
        if actual != expected:
            drift.append(str(path.relative_to(root)))
            if write:
                path.write_text(text[:start] + expected + text[end:])
    return drift


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args()
    try:
        drift = sync(args.root, args.write)
    except (OSError, ValueError) as error:
        parser.exit(2, f"sync-runbooks: {error}\n")
    for path in drift:
        print(f"sync-runbooks: {path}: {'updated' if args.write else 'drift'}")
    if not drift:
        print("sync-runbooks: canonical excerpts match")
    return int(bool(drift) and not args.write)


if __name__ == "__main__":
    raise SystemExit(main())
