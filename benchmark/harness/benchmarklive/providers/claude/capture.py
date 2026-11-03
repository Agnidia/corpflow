"""Dual-mode capture parser (was Coverage.swift; renamed to avoid the coverage.py
tool clash).

stream-json: NDJSON, one object per line — collect the coverage manifest (Task
subagent_type → agents, Skill names → skills, slash-commands → commands, tool_use
count) and read usage from the terminal ``result`` line. json: today's single result
object with usage + total_cost_usd; coverage manifest = None. Token totals sum
``modelUsage`` over every model (sub-agents included) and fall back to the parent-only
``usage`` when it is absent. NEVER fabricate: any
field the output doesn't yield → None; the whole coverage object is None when no
event data exists.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Optional

from benchmarkkit.metrics import StageCoverage


class FieldPaths:
    TASK_TOOL_NAME = "Task"
    AGENT_TOOL_NAME = "Agent"  # alias emitted by newer CLIs for a subagent spawn
    SUBAGENT_TYPE_KEY = "subagent_type"
    SKILL_TOOL_NAME = "Skill"
    SKILL_KEY = "skill"
    COMMAND_TOOL_NAME = "SlashCommand"
    COMMAND_KEY = "command"


@dataclass
class ParsedCapture:
    input_tokens: Optional[int] = None
    output_tokens: Optional[int] = None
    cache_read: Optional[int] = None
    cache_creation: Optional[int] = None
    cost_usd: Optional[float] = None
    coverage: Optional[StageCoverage] = None
    # Parent-session figures from ``result.usage``. Set only when the totals above came
    # from ``modelUsage`` (sub-agents included), so their absence means the two agree.
    parent_input_tokens: Optional[int] = None
    parent_output_tokens: Optional[int] = None
    parent_cache_read: Optional[int] = None
    parent_cache_creation: Optional[int] = None

    @property
    def has_usage(self) -> bool:
        return any(v is not None for v in (
            self.input_tokens, self.output_tokens, self.cache_read,
            self.cache_creation, self.cost_usd))

    @property
    def is_empty(self) -> bool:
        return not self.has_usage and self.coverage is None


# result.modelUsage[<model>] key -> ParsedCapture field it sums into.
_MODEL_USAGE_KEYS = {
    "inputTokens": "input_tokens",
    "outputTokens": "output_tokens",
    "cacheReadInputTokens": "cache_read",
    "cacheCreationInputTokens": "cache_creation",
}


def _model_usage_totals(model_usage) -> dict:
    """Sum each token key across every model the run used, sub-agents included.

    ``result.usage`` covers the parent session only, while ``total_cost_usd`` prices all
    of it, so a token figure read from ``usage`` understates what the cost paid for. A key
    no model reports is left out rather than summed to a fabricated zero.
    """
    if not isinstance(model_usage, dict):
        return {}
    totals = {}
    for key, field in _MODEL_USAGE_KEYS.items():
        values = [m[key] for m in model_usage.values()
                  if isinstance(m, dict) and isinstance(m.get(key), int)
                  and not isinstance(m.get(key), bool)]
        if values:
            totals[field] = sum(values)
    return totals


def parse_single_object(text: str) -> Optional[ParsedCapture]:
    """Layer-1 single-object parse (today's --output-format json result)."""
    try:
        obj = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict):
        return None
    usage = obj.get("usage")
    totals = _model_usage_totals(obj.get("modelUsage"))
    if not isinstance(usage, dict):
        if not totals:
            return None
        usage = {}
    parent = {
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "cache_read": usage.get("cache_read_input_tokens"),
        "cache_creation": usage.get("cache_creation_input_tokens"),
    }
    # A field modelUsage did not report still falls back to the parent figure.
    merged = {field: totals.get(field, parent[field]) for field in parent}
    cost = obj.get("total_cost_usd")
    if cost is None:
        cost = usage.get("total_cost_usd")
    if cost is None and all(v is None for v in merged.values()):
        return None
    parsed = ParsedCapture(
        input_tokens=merged["input_tokens"], output_tokens=merged["output_tokens"],
        cache_read=merged["cache_read"], cache_creation=merged["cache_creation"],
        cost_usd=cost)
    if totals:
        parsed.parent_input_tokens = parent["input_tokens"]
        parsed.parent_output_tokens = parent["output_tokens"]
        parsed.parent_cache_read = parent["cache_read"]
        parsed.parent_cache_creation = parent["cache_creation"]
    return parsed


def collect_tool_uses(event: dict, agents: set, skills: set, commands: set,
                      tool_calls: int) -> int:
    """Walk one NDJSON event for tool_use blocks, accumulating manifest data."""
    contents = []
    msg = event.get("message")
    if isinstance(msg, dict) and isinstance(msg.get("content"), list):
        contents = msg["content"]
    elif isinstance(event.get("content"), list):
        contents = event["content"]
    for block in contents:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        tool_calls += 1
        name = block.get("name") or ""
        inp = block.get("input") or {}
        if name in (FieldPaths.TASK_TOOL_NAME, FieldPaths.AGENT_TOOL_NAME):
            sub = inp.get(FieldPaths.SUBAGENT_TYPE_KEY)
            if sub:
                agents.add(sub)
        elif name == FieldPaths.SKILL_TOOL_NAME:
            skill = inp.get(FieldPaths.SKILL_KEY)
            if skill:
                (commands if skill.startswith("/") else skills).add(skill)
        elif name == FieldPaths.COMMAND_TOOL_NAME:
            cmd = inp.get(FieldPaths.COMMAND_KEY)
            if cmd:
                commands.add(cmd)
    return tool_calls


@dataclass
class InitPlugins:
    """The plugin facts a stream-json ``system/init`` event reports."""

    corpflow: list      # every plugins[] entry named "corpflow" (a shadow failure yields two)
    errors: list        # plugin_errors[] as reported; absent from init when nothing failed
    plugins: list       # every plugins[] entry, whatever its name


def parse_init_plugins(stdout: str) -> Optional[InitPlugins]:
    """Read the first ``system/init`` event's plugin list; None when the stream has none.

    ``--output-format json`` emits no init event, so None there means "unobservable",
    not "no plugin loaded".
    """
    for line in stdout.split("\n"):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") != "system" or event.get("subtype") != "init":
            continue
        plugins = event.get("plugins")
        errors = event.get("plugin_errors")
        entries = [p for p in plugins if isinstance(p, dict)] if isinstance(plugins, list) else []
        return InitPlugins(
            corpflow=[p for p in entries if p.get("name") == "corpflow"],
            errors=[e for e in errors if isinstance(e, dict)] if isinstance(errors, list) else [],
            plugins=entries)
    return None


def parse(stdout: str) -> Optional[ParsedCapture]:
    """Dual-mode: stream-json NDJSON first; single-object fallback. None when nothing real."""
    lines = [ln for ln in stdout.split("\n") if ln.strip()]
    if len(lines) <= 1:
        return parse_single_object(stdout)

    agents, skills, commands = set(), set(), set()
    tool_calls = 0
    usage = None
    saw_event = False
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        saw_event = True
        tool_calls = collect_tool_uses(event, agents, skills, commands, tool_calls)
        if event.get("type") == "result":
            u = parse_single_object(line)
            if u is not None:
                usage = u
    if not saw_event:
        return parse_single_object(stdout)

    coverage = None
    if tool_calls > 0 or agents or skills or commands:
        coverage = StageCoverage(agents=sorted(agents), skills=sorted(skills),
                                 commands=sorted(commands), tool_calls=tool_calls)
    result = usage or ParsedCapture()
    result.coverage = coverage
    return None if result.is_empty else result
