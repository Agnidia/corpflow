#!/usr/bin/env python3
"""Consolidate schema validation and canonical structural handoff budgets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[3]
HARNESS = Path(__file__).with_name("handoff-harness.sh")
PROXY = "estimated: whitespace words times 1.33; not provider tokenization"


def estimated_tokens(text):
    return int(len(text.split()) * 1.33)


def strip_real_references(content, artifact, state):
    def replace(match):
        value = match[0]
        if value.startswith(("http://", "https://")):
            try:
                host = urlsplit(value).hostname
                if host and len(host) <= 253 and all(0 < len(label) <= 63 for label in host.split(".")):
                    return ""
            except ValueError:
                pass
            return value
        if len(value) <= 1024:
            return value
        path = Path(value.split("#", 1)[0])
        if any(len(part) > 255 for part in path.parts) or len(str(path)) > 4096:
            return value
        for parent in (artifact.parent, state.parent.parent):
            try:
                if (parent / path).is_file():
                    return ""
            except OSError:
                pass
        return value
    return re.sub(r"https?://[^\s<>\"]+|[\w./-]+\.[A-Za-z0-9]+(?:#[\w-]+)?", replace, content)


def budgets():
    table = (ROOT / "skills/context-compression/SKILL.md").read_text()
    rows = {}
    for row in re.findall(r"^\| ([A-Z]{2}) \| (.+) \|$", table, re.MULTILINE):
        cells = [cell.strip() for cell in row[1].split("|")]
        if len(cells) == 5:
            number = lambda cell: int(re.search(r"\d+", cell)[0]) if re.search(r"\d+", cell) else None
            rows[row[0]] = {"artifact_lines": number(cells[1]), "return_tokens": number(cells[2])}
    if not rows:
        raise ValueError("canonical stage budget table is unavailable")
    return rows


def frontmatter(text):
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", text, re.DOTALL)
    if not match:
        raise ValueError("artifact has no leading frontmatter")
    return match[1]


def key_blocks(fm):
    matches = list(re.finditer(r"^  ([a-z_]+):.*$", fm, re.MULTILINE))
    return {m[1]: fm[m.start():matches[i + 1].start() if i + 1 < len(matches) else len(fm)]
            for i, m in enumerate(matches)}


def protected_content(text):
    fm = frontmatter(text)
    protected = {"frontmatter": fm, "critical_sections": []}
    matches = list(re.finditer(r"^(#{1,6}) (.+)$", text, re.MULTILINE))
    for i, match in enumerate(matches):
        if re.search(r"acceptance|requirement|scope|block|decision|evidence|test|verif|elicitation|"
                     r"finding|verdict|follow.?up|risk|open.?question|files.?changed|deviation",
                     match[2], re.IGNORECASE):
            end = next((later.start() for later in matches[i + 1:] if len(later[1]) <= len(match[1])), len(text))
            protected["critical_sections"].append({"heading": match[2], "level": len(match[1]),
                                                   "content": text[match.start():end]})
    protected["references"] = sorted(set(re.findall(
        r"(?:https?://[^\s<>]+|[\w./-]+\.[A-Za-z0-9]+(?:#[\w-]+)?)", text)))
    return protected


def legacy(mode, path, state=None):
    argv = ["bash", str(HARNESS), mode, str(path)]
    if state is not None:
        argv.extend(["--state", str(state), "--strict"])
    run = subprocess.run(argv, capture_output=True, text=True, check=False)
    return run.returncode, run.stdout + run.stderr


def validate(artifact, state, return_file):
    errors = []
    warnings = []
    estimates = {"token_proxy": PROXY, "provider_usage": "unavailable"}
    text = artifact.read_text()
    code, diagnostics = legacy("--validate-frontmatter", artifact, state)
    if code:
        failures = [line for line in diagnostics.splitlines() if line.startswith("fail:")]
        budget_only = bool(failures) and all("discretionary tokens > 200 budget" in line
                                               for line in failures)
        errors.append({"code": "budget" if budget_only else "schema",
                       "field": "discretionary_frontmatter_tokens" if budget_only else "schema",
                       "detail": diagnostics.strip()})
    code, state_diagnostics = legacy("--validate-state", state)
    if code:
        errors.append({"code": "state_schema", "detail": state_diagnostics.strip()})
    try:
        fm = frontmatter(text)
    except ValueError as exc:
        errors.append({"code": "schema", "detail": str(exc)})
        return errors, estimates, warnings
    blocks = key_blocks(fm)
    stage_match = re.search(r"^  stage:\s*['\"]?([A-Z]{2})", fm, re.MULTILINE)
    stage = stage_match[1] if stage_match else ""
    required = re.search(r'^' + re.escape(stage) + r'_REQ="([^"]+)"',
                         HARNESS.read_text(), re.MULTILINE)
    if not required:
        errors.append({"code": "schema", "detail": "missing or unknown stage"})
    else:
        for key in required[1].split():
            if key not in blocks or re.match(r"^  " + key + r":\s*(?:null|~)?\s*$", blocks[key]):
                errors.append({"code": "schema", "detail": "missing required field: " + key})
    caps = budgets().get(stage, {})
    estimates.update({"stage": stage, "frontmatter_tokens": estimated_tokens(fm),
                      "frontmatter_lines": len(fm.splitlines()),
                      "artifact_lines": len(text.splitlines())})
    stub_tokens = min(estimated_tokens(blocks.get("open_questions", "")), 64)
    tests = blocks.get("tests_executed", "")
    entries = len(re.findall(r"\brunner:", tests))
    test_tokens = min(estimated_tokens(tests), min(entries, 8) * 24)
    estimates["discretionary_frontmatter_tokens"] = estimated_tokens(fm) - stub_tokens - test_tokens
    limits = [("frontmatter_lines", 30), ("discretionary_frontmatter_tokens", 200),
              ("artifact_lines", caps.get("artifact_lines"))]
    ledger_text = state.read_text()
    estimates["ledger_tokens"] = estimated_tokens(ledger_text)
    if estimates["ledger_tokens"] > 500:
        warnings.append({"code": "budget", "field": "ledger_tokens",
                         "detail": f"{estimates['ledger_tokens']} > 500; existing warning severity retained; "
                                   "use canonical ledger eviction and preserve unresolved needs and evidence"})
    if return_file is None:
        if caps.get("return_tokens") is not None:
            errors.append({"code": "missing_return", "detail": "a final return file is required"})
    else:
        estimates["return_tokens"] = estimated_tokens(return_file.read_text())
        limits.append(("return_tokens", caps.get("return_tokens")))
    for key, cap in limits:
        if cap is not None and estimates[key] > cap:
            errors.append({"code": "budget", "field": key,
                           "detail": f"{estimates[key]} > {cap}"})
    for name, content in (("artifact", text), ("ledger", ledger_text),
                          ("return", return_file.read_text() if return_file else "")):
        prose = strip_real_references(content, artifact, state)
        if re.search(r"\S{1025}", prose):
            errors.append({"code": "structure", "field": name,
                           "detail": "an unbroken span exceeds 1024 Unicode characters"})
    return errors, estimates, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--return-file", type=Path)
    parser.add_argument("--compressor", type=Path)
    args = parser.parse_args(argv)
    errors, estimates, warnings = validate(args.artifact, args.state, args.return_file)
    report = {"result": "blocked" if errors else "pass", "errors": errors,
              "warnings": warnings, "estimates": estimates, "compression_attempted": False}
    artifact_errors = any(e.get("field") in {"frontmatter_lines", "artifact_lines",
                                           "discretionary_frontmatter_tokens"} for e in errors)
    if args.compressor and artifact_errors and all(e["code"] == "budget" for e in errors):
        original = args.artifact.read_bytes()
        digest = hashlib.sha256(original).hexdigest()
        marker = args.artifact.with_name(args.artifact.name + ".compression-" + digest + ".json")
        if marker.exists():
            report["compression"] = "already attempted for this artifact version"
        else:
            with marker.open("x") as stream:
                json.dump({"sha256": digest, "status": "attempted"}, stream)
            fd, candidate_name = tempfile.mkstemp(prefix=args.artifact.name + ".repair-",
                                                  dir=args.artifact.parent)
            os.close(fd)
            candidate = Path(candidate_name)
            shutil.copyfile(args.artifact, candidate)
            report.update({"compression_attempted": True, "repair_candidate": str(candidate)})
            log_dir = args.state.parent / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            log = log_dir / ("handoff-compression-" + digest + ".log")
            report["compression_evidence"] = str(log)
            with log.open("xb") as evidence:
                try:
                    run = subprocess.run([str(args.compressor.resolve()), str(candidate.resolve())],
                                         stdout=evidence, stderr=subprocess.STDOUT, check=False,
                                         timeout=60)
                    compression_code = run.returncode
                except (OSError, subprocess.TimeoutExpired) as exc:
                    evidence.write((str(exc) + "\n").encode())
                    compression_code = 127
            if compression_code:
                report["compression"] = "compressor failed; original and candidate preserved"
            elif protected_content(original.decode()) != protected_content(candidate.read_text()):
                report["compression"] = "protected content changed; original and candidate preserved"
            else:
                next_errors, next_estimates, next_warnings = validate(candidate, args.state, args.return_file)
                if next_errors:
                    report["compression"] = "still invalid; original and candidate preserved"
                    report["compression_errors"] = next_errors
                else:
                    backup = args.artifact.with_name(args.artifact.name + ".original-" + digest)
                    with backup.open("xb") as stream:
                        stream.write(original)
                    os.replace(candidate, args.artifact)
                    report.update({"result": "pass", "errors": [], "estimates": next_estimates,
                                   "warnings": next_warnings,
                                   "original_evidence": str(backup), "compression": "accepted"})
    print(json.dumps(report, ensure_ascii=False))
    return 1 if report["result"] == "blocked" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, UnicodeError) as exc:
        print(json.dumps({"result": "blocked", "errors": [{"code": "unavailable", "detail": str(exc)}]}))
        sys.exit(1)
