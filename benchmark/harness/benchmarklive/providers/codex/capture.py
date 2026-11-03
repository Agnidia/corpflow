"""Price terminal Codex usage; cached tokens are included in input tokens."""

import json
import math
from pathlib import Path

from benchmarkkit.metrics import StageCoverage
from ..claude.capture import ParsedCapture


class AccountingError(ValueError):
    pass


def load_pricing(path=None):
    with open(path or Path(__file__).with_name("pricing.json"), encoding="utf-8") as stream:
        pricing = json.load(stream)
    if not isinstance(pricing, dict) or not all(
            pricing.get(k) for k in ("id", "source", "verified_at", "per_million")):
        raise AccountingError("pricing provenance is incomplete")
    if not isinstance(pricing["per_million"], dict):
        raise AccountingError("invalid pricing table")
    for rates in pricing["per_million"].values():
        if not isinstance(rates, dict):
            raise AccountingError("invalid pricing rates")
        for key in ("input", "cached_input", "output"):
            value = rates.get(key)
            if (isinstance(value, bool) or not isinstance(value, (int, float))
                    or not math.isfinite(value) or value < 0):
                raise AccountingError("invalid pricing rate")
    return pricing


def events(stdout):
    for line in stdout.splitlines():
        if line.strip():
            try:
                event = json.loads(line)
            except (ValueError, TypeError) as exc:
                raise AccountingError("invalid Codex JSONL capture") from exc
            if not isinstance(event, dict):
                raise AccountingError("invalid Codex event")
            yield event


def price(model, input_tokens, cached_tokens, output_tokens, pricing):
    rates = pricing["per_million"].get(model)
    if rates is None:
        raise AccountingError(f"no pinned pricing for {model}")
    return ((input_tokens - cached_tokens) * rates["input"]
            + cached_tokens * rates["cached_input"]
            + output_tokens * rates["output"]) / 1_000_000


def parse(stdout, model, pricing):
    terminal = []
    tools = 0
    for event in events(stdout):
        if event.get("type") in ("turn.completed", "turn.failed"):
            terminal.append(event)
        item = event.get("item") or {}
        if not isinstance(item, dict):
            raise AccountingError("invalid Codex item")
        if event.get("type") == "item.completed" and item.get("type") in (
                "command_execution", "file_change", "mcp_tool_call", "web_search"):
            tools += 1
    if len(terminal) != 1:
        raise AccountingError("expected exactly one terminal usage event")
    usage = terminal[0].get("usage") or {}
    if not isinstance(usage, dict):
        raise AccountingError("invalid terminal usage")
    writes = usage.get("cache_write_input_tokens", 0)
    if isinstance(writes, bool) or not isinstance(writes, int) or writes != 0:
        raise AccountingError("explicit cache writes require separately pinned pricing")
    values = [usage.get(k) for k in ("input_tokens", "cached_input_tokens", "output_tokens")]
    if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in values):
        raise AccountingError("missing or invalid terminal token usage")
    total_in, cached, out = values
    if cached > total_in:
        raise AccountingError("cached input exceeds total input")
    return ParsedCapture(
        input_tokens=total_in - cached, output_tokens=out, cache_read=cached,
        cache_creation=0, cost_usd=price(model, total_in, cached, out, pricing),
        coverage=StageCoverage(agents=[], skills=[], commands=[], tool_calls=tools))
