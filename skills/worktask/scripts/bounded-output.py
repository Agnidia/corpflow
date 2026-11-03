#!/usr/bin/env python3
"""Capture complete command evidence and return a bounded Unicode excerpt."""

import argparse
from pathlib import Path
import subprocess
import sys

LIMIT = 8000


def excerpt(text, header="", limit=LIMIT):
    if len(header) >= limit:
        raise ValueError("result metadata exceeds the output limit")
    room = limit - len(header)
    if len(text) <= room:
        return header + text
    marker = "\n<<<TRUNCATED: retrieve additional sections from the evidence path>>>\n"
    if room <= len(marker):
        marker = "\n<<<TRUNCATED>>>\n"
        if room < len(marker):
            raise ValueError("the output limit cannot fit metadata and a truncation marker")
        return header + marker
    room -= len(marker)
    head = min(1000, room // 4)
    return header + text[:head] + marker + text[-(room - head):]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--read", action="store_true", help="excerpt existing evidence")
    parser.add_argument("--start", type=int, default=0, help="Unicode character offset for reads")
    parser.add_argument("--limit", type=int, default=LIMIT)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if not 200 <= args.limit <= LIMIT or args.start < 0:
        parser.error("limit must be 200..8000; start must be nonnegative")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.read:
        if command:
            parser.error("--read does not execute a command")
        raw = args.log.read_bytes()
        code = 0
        reported_code = "unavailable"
    else:
        if not command:
            parser.error("a command argv is required after --")
        log_root = (Path.cwd() / ".context/logs").resolve()
        if log_root not in args.log.resolve().parents:
            parser.error("command evidence must be under .context/logs")
        args.log.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation keeps a retry from overwriting the first attempt's evidence.
        with args.log.open("xb") as evidence:
            try:
                code = subprocess.run(command, stdout=evidence, stderr=subprocess.STDOUT,
                                      check=False).returncode
            except OSError as exc:
                evidence.write((str(exc) + "\n").encode("utf-8"))
                code = 127
        raw = args.log.read_bytes()
        reported_code = str(code)
    body = raw.decode("utf-8", errors="replace")[args.start:]
    header = (f"exit_code={reported_code}\nevidence={args.log}\n"
              f"output_characters={len(raw.decode('utf-8', errors='replace'))}\n"
              f"offset={args.start}\n")
    result = excerpt(body, header, args.limit)
    sys.stdout.write(result)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print(f"bounded-output: {exc}", file=sys.stderr)
        sys.exit(2)
