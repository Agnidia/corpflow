"""Read utilization diagnostics without inferring tokens or qualitative acceptance."""

from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def _text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        strings = [_text(item) for item in value]
        return "".join(item for item in strings if item is not None) if any(
            item is not None for item in strings) else None
    if isinstance(value, dict) and isinstance(value.get("text"), str):
        return value["text"]
    if isinstance(value, dict) and "content" in value:
        return _text(value["content"])
    return None


def tool_results(stdout):
    commands = {}
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        item = event.get("item")
        if (event.get("type") == "item.completed" and isinstance(item, dict)
                and item.get("type") == "command_execution"):
            text = item.get("aggregated_output")
            if isinstance(text, str):
                yield text, item.get("exit_code") not in (None, 0), item.get("command")
        if (event.get("type") == "item.completed" and isinstance(item, dict)
                and item.get("type") == "mcp_tool_call"):
            text = _text(item.get("result"))
            if text is not None:
                yield text, item.get("status") == "failed", str(item.get("tool", "mcp"))
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else event.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    payload = block.get("input") or {}
                    operation = (payload.get("command") if isinstance(payload, dict) else None)
                    commands[block.get("id")] = operation or (
                        str(block.get("name", "tool")) + ":" + json.dumps(payload, sort_keys=True))
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    text = _text(block.get("content"))
                    if text is not None:
                        yield text, block.get("is_error") is True, commands.get(block.get("tool_use_id"))


def _environment_failure(text, failed):
    if not failed:
        return None
    lowered = text.lower()
    if re.search(r"\b(?:http|status)\s*[:=]?\s*5\d\d\b|rate limit|usage limit|\bquota\b", lowered):
        return None
    if any(word in lowered for word in ("permission denied", "operation not permitted", "sandbox denied")):
        return "permission"
    if any(word in lowered for word in ("connection refused", "service unavailable", "coresimulatorservice",
                                        "could not connect to the service")):
        return "unavailable_service"
    return None


def ledger_inventory(workdir, stage):
    context = (Path(workdir) / ".context").resolve()
    try:
        raw = (context / "state.json").read_text()
        state = json.loads(raw)
        tasks = state["tasks"]
        if not isinstance(tasks, dict) or not all(isinstance(task, dict) for task in tasks.values()):
            raise ValueError("invalid task rows")
    except (OSError, ValueError, KeyError, TypeError):
        return None
    counts = Counter(str(task.get("status", "unavailable")) for task in tasks.values())
    artifacts = []
    contradictions = []
    for task_id, task in tasks.items():
        meta = task.get("metadata") or {}
        if not isinstance(meta, dict):
            contradictions.append(task_id + ": malformed metadata")
            continue
        if task.get("status") == "completed" and task.get("verdict") in (
                "fail", "no-go", "blocked", "escalate", "reject"):
            contradictions.append(task_id + ": completed status conflicts with verdict")
        if meta.get("stage") != stage and not task_id.startswith(stage):
            continue
        path = task.get("artifact") or meta.get("artifact")
        if not isinstance(path, str):
            if task.get("status") == "completed":
                contradictions.append(task_id + ": completed artifact reference is missing")
            continue
        candidate = Path(path)
        candidate = candidate if candidate.is_absolute() else context / path.removeprefix(".context/")
        if context.resolve() not in candidate.resolve().parents:
            contradictions.append(task_id + ": artifact lies outside the context")
            continue
        entry = {"path": str(candidate.relative_to(context)), "available": candidate.is_file()}
        try:
            content = candidate.read_text()
            entry.update({"characters": len(content), "lines": len(content.splitlines()),
                          "sha256": hashlib.sha256(content.encode()).hexdigest(),
                          "estimated_tokens": int(len(content.split()) * 1.33),
                          "token_proxy": "whitespace words times 1.33; not provider usage"})
            fm = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", content, re.DOTALL)
            entry["handoff"] = ({"characters": len(fm[1]), "lines": len(fm[1].splitlines()),
                                  "estimated_tokens": int(len(fm[1].split()) * 1.33)} if fm else None)
        except (OSError, UnicodeError):
            entry["available"] = False
        if task.get("status") == "completed" and not entry["available"]:
            contradictions.append(task_id + ": completed artifact is missing")
        artifacts.append(entry)
    return {"status_counts": dict(sorted(counts.items())), "contradictions": contradictions,
            "artifacts": artifacts, "ledger_estimated_tokens": int(len(raw.split()) * 1.33),
            "approval": "not evaluated; diagnostics only"}


def capture_diagnostics(stdout, workdir, stage, instruction_fingerprint=None):
    outputs = list(tool_results(stdout))
    failures = Counter()
    for text, failed, command in outputs:
        kind = _environment_failure(text, failed)
        if kind:
            signature = re.sub(r"\s+", " ", str(command or text)).strip()
            failures[(signature, kind)] += 1
    inventory = ledger_inventory(workdir, stage) if workdir is not None else None
    artifacts = inventory["artifacts"] if inventory is not None else None
    measured_artifacts = [item for item in artifacts or [] if item["available"]]
    if not isinstance(instruction_fingerprint, str) or not re.fullmatch(
            r"sha256:[a-f0-9]{64}", instruction_fingerprint):
        instruction_fingerprint = None
    return {
        "tool_output_characters": sum(len(text) for text, _, _ in outputs) if outputs else None,
        "tool_output_unit": "Unicode characters; not tokens",
        "environment_failure_count": sum(failures.values()) if outputs else None,
        "environment_failure_repetitions": sum(max(0, count - 1) for count in failures.values()) if outputs else None,
        "environment_failures": [{"signature_sha256": hashlib.sha256(signature.encode()).hexdigest(),
                                  "kind": kind, "count": count}
                                 for (signature, kind), count in sorted(failures.items())] if outputs else None,
        "truncation_count": sum(bool(re.search(r"<<<TRUNCATED|Warning: truncated output|output truncated",
                                               text, re.IGNORECASE)) for text, _, _ in outputs) if outputs else None,
        "artifact_characters": sum(item["characters"] for item in measured_artifacts) if measured_artifacts else None,
        "handoff_characters": sum(item["handoff"]["characters"] for item in measured_artifacts)
                              if measured_artifacts and all(item["handoff"] is not None for item in measured_artifacts) else None,
        "handoff_sizes": artifacts,
        "instruction_fingerprint": instruction_fingerprint,
        "ledger_summary": inventory,
        "output_usage_basis": "provider-reported output; reasoning-inclusive when reported by the provider",
    }


def merge_diagnostics(current, previous):
    if current is None:
        return previous
    if previous is None:
        return current
    merged = dict(current)
    for key in ("tool_output_characters", "environment_failure_count", "environment_failure_repetitions", "truncation_count"):
        values = [item.get(key) for item in (current, previous)]
        merged[key] = sum(values) if all(value is not None for value in values) else None
    failures = {}
    measured = True
    for diagnostics in (previous, current):
        entries = diagnostics.get("environment_failures")
        if entries is None:
            measured = False
        for item in entries or []:
            key = (item["signature_sha256"], item["kind"])
            failures[key] = failures.get(key, 0) + item["count"]
    if measured:
        merged["environment_failures"] = [{"signature_sha256": key[0], "kind": key[1], "count": count}
                                          for key, count in sorted(failures.items())]
        merged["environment_failure_repetitions"] = sum(max(0, count - 1) for count in failures.values())
    else:
        merged["environment_failures"] = None
    return merged
