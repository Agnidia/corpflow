"""Render benchmark/results/history.json into a self-contained result.html.

Shows all metrics (WITH vs WITHOUT + deltas) per retained run/mode, newest first,
each app path, derived analysis rows (each degrades to an em-dash on missing
inputs), coverage rollup rows for live records, and a plugin-surface coverage
ratio. Operates on the raw parsed history dict. HTML is substring-gated, not
byte-gated.
"""

from __future__ import annotations

import html as _html
import json
import os
from typing import Optional

from .analysis import scan_generated_project
from .formatting import format_cost, format_cost_delta, group_int as _group_int

_HTML_NIL = "&mdash;"

# (accessor, label, is_delta_numeric)
METRIC_ROWS = [
    ("tokens.in", "tokens in", True),
    ("tokens.out", "tokens out", True),
    ("tokens.total", "tokens total", True),
    ("cost_usd", "cost (USD)", True),
    ("wall_clock_s", "wall clock (s)", True),
    ("loc_produced", "LOC produced", True),
    ("test_count", "test count", True),
    ("coverage_pct", "coverage %", True),
    ("estimate_complexity_score", "complexity score", True),
    ("stage_count", "stage count", True),
    ("tokens.cache_read", "cache read", True),
    ("tokens.cache_creation", "cache creation", True),
    ("pass_fail", "pass/fail", False),
    # The held-out quality signal; `implied` is the tier meant to separate the arms.
    ("oracle.cases_passed", "oracle cases passed", True),
    ("oracle.cases_total", "oracle cases total", True),
    ("oracle.tiers.specified.passed", "oracle specified passed", True),
    ("oracle.tiers.implied.passed", "oracle implied passed", True),
]


def _escape(s: str) -> str:
    return _html.escape(s, quote=True)


def _get(path_metrics: Optional[dict], accessor: str):
    if path_metrics is None:
        return None
    cursor = path_metrics
    for part in accessor.split("."):
        if not isinstance(cursor, dict):
            return None
        cursor = cursor.get(part)
    return cursor


def _group_decimal(s: str) -> str:
    parts = s.split(".", 1)
    try:
        n = int(parts[0])
    except (ValueError, IndexError):
        return s
    grouped = _group_int(n)
    return f"{grouped}.{parts[1]}" if len(parts) == 2 else grouped


def _fmt(v) -> str:
    if v is None:
        return "&mdash;"
    if isinstance(v, bool):
        return "pass" if v else "fail"
    if isinstance(v, int):
        return _group_int(v)
    if isinstance(v, float):
        if v == round(v):
            return _group_int(int(v))
        s = f"{v:.4f}".rstrip("0").rstrip(".")
        return _group_decimal(s)
    return _escape(str(v))


def _num_or_nil(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return None


def _delta(with_v, without_v) -> str:
    w = _num_or_nil(with_v)
    wo = _num_or_nil(without_v)
    if w is not None and wo is not None:
        d = w - wo
        sign = "+" if d > 0 else ""
        dv = int(d) if d == round(d) else d
        return f"{sign}{_fmt(dv)}"
    return "&mdash;"


def _app_path(rec: dict, which: str) -> str:
    paths = rec.get("paths") or {}
    # An arm the record does not carry has no workdir to point at; deriving one from
    # the run id would render a path that never existed as though it did.
    if which not in paths:
        return "—"
    pm = paths.get(which) or {}
    p = pm.get("app_path")
    if p:
        return p
    run_id = rec.get("run_id") or "unknown"
    return f"benchmark/workdirs/{run_id}/{which}"


def _ratio_fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return _group_decimal(s)


def analysis_rows(rec: dict) -> list:
    with_pm = (rec.get("paths") or {}).get("with") or {}
    without_pm = (rec.get("paths") or {}).get("without") or {}
    wt = with_pm.get("tokens") or {}
    ot = without_pm.get("tokens") or {}

    w_total = _num_or_nil(wt.get("total"))
    w_out = _num_or_nil(wt.get("out"))
    w_fresh = _num_or_nil(wt.get("in"))
    w_cr = _num_or_nil(wt.get("cache_read"))
    w_cc = _num_or_nil(wt.get("cache_creation"))
    w_loc = _num_or_nil(with_pm.get("loc_produced"))
    o_total = _num_or_nil(ot.get("total"))

    rows = []

    if w_total is not None and w_out not in (None, 0):
        rows.append(("input:output ratio", f"{_ratio_fmt(w_total / w_out)}:1"))
    else:
        rows.append(("input:output ratio", "&mdash;"))

    if w_cr is not None and w_cc is not None and w_fresh is not None:
        denom = w_fresh + w_cc + w_cr
        rows.append(("cache-hit %", f"{_ratio_fmt(w_cr / denom * 100)}%" if denom != 0 else "&mdash;"))
    else:
        rows.append(("cache-hit %", "&mdash;"))

    stage_totals = []
    for s in rec.get("stages") or []:
        fi = int(_num_or_nil(s.get("fresh_in")) or 0)
        cc = int(_num_or_nil(s.get("cache_creation")) or 0)
        cr = int(_num_or_nil(s.get("cache_read")) or 0)
        stage_totals.append((s.get("stage") or "?", s.get("arm"), fi + cc + cr))
    grand = sum(t for _, _, t in stage_totals)
    if stage_totals and grand != 0:
        # Arm tag disambiguates the paired path, where each stage name appears once per arm.
        parts = []
        for name, arm, t in stage_totals:
            label = f"{name} ({arm})" if arm in ("with", "without") else name
            parts.append(f"{_escape(label)} {_ratio_fmt(t / grand * 100)}%")
        rows.append(("per-stage token share", " &middot; ".join(parts)))
    else:
        rows.append(("per-stage token share", "&mdash;"))

    if w_total is not None and w_loc not in (None, 0):
        rows.append(("tokens per LOC", _ratio_fmt(w_total / w_loc)))
    else:
        rows.append(("tokens per LOC", "&mdash;"))

    if w_total is not None and o_total not in (None, 0):
        rows.append(("WITH-vs-WITHOUT premium", f"{_ratio_fmt((w_total - o_total) / o_total * 100)}%"))
    else:
        rows.append(("WITH-vs-WITHOUT premium", "&mdash;"))

    return rows


def coverage_rows(rec: dict) -> list:
    agents, skills, commands = set(), set(), set()
    tool_calls = 0
    any_cov = False
    for s in rec.get("stages") or []:
        cov = s.get("coverage")
        if not isinstance(cov, dict):
            continue
        any_cov = True
        agents.update(x for x in cov.get("agents", []) if isinstance(x, str))
        skills.update(x for x in cov.get("skills", []) if isinstance(x, str))
        commands.update(x for x in cov.get("commands", []) if isinstance(x, str))
        tool_calls += cov.get("tool_calls") or 0
    nested = 0
    for s in rec.get("stages") or []:
        cov = s.get("coverage")
        if isinstance(cov, dict):
            nested += cov.get("nested_background") or 0
    if not any_cov:
        return []
    rows = [
        ("agents exercised", _escape(", ".join(sorted(agents))) if agents else "&mdash;"),
        ("skills exercised", _escape(", ".join(sorted(skills))) if skills else "&mdash;"),
        ("commands exercised", _escape(", ".join(sorted(commands))) if commands else "&mdash;"),
        ("tool calls", str(tool_calls)),
    ]
    if nested:
        rows.append(("nested background spawns", str(nested)))
    return rows


def utilization_html(rec: dict) -> str:
    stages = list(rec.get("stages") or [])
    for arm, accounting in ((rec.get("era") or {}).get("accounting") or {}).items():
        for attempt in accounting.get("attempts", []):
            if attempt.get("status") == "failed":
                stages.append({**attempt, "stage": str(attempt.get("stage", "?"))
                               + f" attempt {attempt.get('attempt', '?')} (failed)", "arm": arm})
    if not stages:
        return ""
    columns = (("fresh_in", "fresh input"), ("cache_read", "cached input"),
               ("cache_creation", "cache writes"),
               ("out", "output tokens"), ("cost_usd", "cost USD"), ("duration_s", "duration s"))
    diagnostics_columns = (("tool_output_characters", "captured tool characters"),
                           ("environment_failure_repetitions", "environment failure repetitions"),
                           ("truncation_count", "truncations"), ("artifact_characters", "artifact characters"),
                           ("handoff_characters", "handoff characters"),
                           ("instruction_fingerprint", "instruction fingerprint"))
    def value(item):
        return "unavailable" if item is None else _fmt(item)
    body = []
    for stage in stages:
        diagnostics = stage.get("diagnostics") or {}
        name = stage.get("stage", "?") + (f" ({stage['arm']})" if stage.get("arm") else "")
        cells = [value(stage.get(key)) for key, _ in columns]
        cells.extend(value(diagnostics.get(key)) for key, _ in diagnostics_columns)
        body.append("<tr><td>" + _escape(name) + "</td>" + "".join("<td>" + cell + "</td>" for cell in cells) + "</tr>")
    headings = "".join("<th>" + label + "</th>" for _, label in columns + diagnostics_columns)
    return ("<details><summary>Stage utilization diagnostics</summary>"
            "<p>Tool output and artifact lengths are Unicode characters, not token counts. "
            "Provider output includes reasoning when reported; artifact length remains separate.</p>"
            "<p>Costs follow each record's pricing basis; Codex costs are API-equivalent estimates. "
            "Missing measurements are unavailable.</p>"
            "<div class='utilization-scroll'><table><thead><tr><th>stage</th>" + headings
            + "</tr></thead><tbody>" + "".join(body) + "</tbody></table></div></details>")


def _generated_html(rec: dict, plugin_root: Optional[str]) -> str:
    """Per-arm Generated-project section (U2): Swift file tree, per-file LOC, total,
    arm path. Resolved from each arm's app_path under plugin_root; empty when absent."""
    if not plugin_root:
        return ""
    blocks = []
    for arm in ("with", "without"):
        pm = (rec.get("paths") or {}).get(arm) or {}
        app_path = pm.get("app_path")
        if not app_path:
            continue
        scan = scan_generated_project(os.path.join(plugin_root, app_path))
        if scan is None:
            continue
        rows = "".join(
            f"<tr><td class='metric'><code>{_escape(rel)}</code></td>"
            f"<td class='analysis' colspan='3'>{loc}</td></tr>"
            for rel, loc in scan["files"]
        )
        blocks.append(
            '<table class="analysis-table"><thead><tr>'
            f"<th>generated project ({_escape(arm)}) &mdash; "
            f"<code>{_escape(app_path)}</code>, total LOC {scan['total_loc']}</th>"
            '<th colspan="3">LOC</th></tr></thead>'
            f"<tbody>{rows}</tbody></table>"
        )
    return "".join(blocks)


def declared_surface(plugin_root: str) -> tuple:
    def count_md(d: str) -> int:
        try:
            return len([n for n in os.listdir(d) if n.endswith(".md")])
        except OSError:
            return 0

    agents = count_md(os.path.join(plugin_root, "agents"))
    commands = count_md(os.path.join(plugin_root, "commands"))
    skills = 0
    skills_dir = os.path.join(plugin_root, "skills")
    try:
        for sub in os.listdir(skills_dir):
            if os.path.exists(os.path.join(skills_dir, sub, "SKILL.md")):
                skills += 1
    except OSError:
        pass
    return agents, skills, commands


def _record_html(rec: dict, plugin_root: Optional[str] = None) -> str:
    run_id = _escape(rec.get("run_id") or "?")
    ts = _escape(rec.get("timestamp_utc") or "?")
    mode = _escape(rec.get("mode") or "?")
    sha = _escape(rec.get("git_sha") or "?")
    budget = rec.get("budget_usd")
    partial = bool(rec.get("live_partial") or False)
    with_pm = (rec.get("paths") or {}).get("with")
    without_pm = (rec.get("paths") or {}).get("without")

    rows = ""
    for accessor, label, _ in METRIC_ROWS:
        wv = _get(with_pm, accessor)
        ov = _get(without_pm, accessor)
        # Coverage is unmeasured on the live path (both arms None): omit the row so absent
        # never renders as a real 0. A measured 0.0 (deterministic) still shows a 0 row.
        if accessor == "coverage_pct" and wv is None and ov is None:
            continue
        # Money gets fixed 2dp; the generic formatter trims trailing zeros, which
        # renders a dollar column at a different precision per row.
        is_cost = accessor == "cost_usd"
        rows += (
            f"<tr><td class='metric'>{_escape(label)}</td>"
            f"<td class='with'>{format_cost(wv, _HTML_NIL) if is_cost else _fmt(wv)}</td>"
            f"<td class='without'>{format_cost(ov, _HTML_NIL) if is_cost else _fmt(ov)}</td>"
            f"<td class='delta'>"
            f"{format_cost_delta(wv, ov, _HTML_NIL) if is_cost else _delta(wv, ov)}"
            "</td></tr>"
        )

    badges = f"<span class='badge mode-{mode}'>{mode}</span>"
    if budget is not None:
        badges += f"<span class='badge budget'>budget ${format_cost(budget, _HTML_NIL)}</span>"
    if partial:
        badges += "<span class='badge partial'>live_partial</span>"
    era = rec.get("era") or {}
    provider = era.get("provider")
    provider_section = ""
    if provider:
        badges += f"<span class='badge'>{_escape(str(provider))}</span>"
    if provider == "codex":
        provider_section = (
            "<p>Costs are API-equivalent estimates from ChatGPT-authenticated sessions. "
            "The allowance controls stage admission; a running stage can overshoot.</p>"
            "<p>The pass/fail metric grades the scripted CLI oracle. It does not validate "
            "native UI, simulator execution, or worktask approval gates.</p>"
            "<details><summary>Provider, pricing, and incomplete stages</summary><pre>"
            + _escape(json.dumps(era, indent=2, sort_keys=True)) + "</pre></details>")

    with_app = _escape(_app_path(rec, "with"))
    without_app = _escape(_app_path(rec, "without"))

    analysis = "".join(
        f"<tr><td class='metric'>{_escape(k)}</td><td class='analysis' colspan='3'>{v}</td></tr>"
        for k, v in analysis_rows(rec)
    )

    coverage = coverage_rows(rec)
    coverage_section = ""
    if coverage:
        cov_body = "".join(
            f"<tr><td class='metric'>{_escape(k)}</td><td class='analysis' colspan='3'>{v}</td></tr>"
            for k, v in coverage
        )
        coverage_section = (
            '<table class="analysis-table">'
            '<thead><tr><th>coverage manifest</th><th colspan="3">exercised</th></tr></thead>'
            f"<tbody>{cov_body}</tbody></table>"
        )

    return (
        '<section class="run">'
        f"<h3>{run_id} {badges}</h3>"
        f'<div class="meta">{ts} &middot; git {sha}</div>'
        f"{provider_section}"
        "<table><thead><tr><th>metric</th><th>WITH plugin</th><th>WITHOUT plugin</th>"
        "<th>&Delta; (with&minus;without)</th></tr></thead>"
        f"<tbody>{rows}</tbody></table>"
        '<table class="analysis-table"><thead><tr><th>analysis (derived)</th>'
        f'<th colspan="3">value</th></tr></thead><tbody>{analysis}</tbody></table>'
        f"{coverage_section}"
        f"{utilization_html(rec)}"
        f"{_generated_html(rec, plugin_root)}"
        '<div class="apps">'
        f'<div><span class="lbl">WITH app:</span> <code>{with_app}</code></div>'
        f'<div><span class="lbl">WITHOUT app:</span> <code>{without_app}</code></div>'
        "</div></section>"
    )


_CSS = (
    ":root{--with:#2563eb;--without:#64748b;--pos:#16a34a;--bg:#0b1020;--card:#141b2e;--fg:#e5e9f0;}"
    "body{margin:0;font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);"
    "color:var(--fg);padding:24px;}"
    "table{width:100%;border-collapse:collapse;}"
    "td.delta{color:#86efac;} td.analysis{color:#fcd34d;}"
    ".utilization-scroll{max-width:100%;overflow-x:auto;}"
    ".utilization-scroll table{min-width:1000px;}"
    ".utilization-scroll td:last-child{max-width:240px;overflow-wrap:anywhere;}"
)


def render_html(history: dict, plugin_root: Optional[str] = None) -> str:
    body_parts = []
    latest_ts = ""
    for mode in ("deterministic", "live"):
        recs = history.get(mode) if isinstance(history, dict) else None
        if not recs:
            continue
        body_parts.append(f"<h2>{_escape(mode)} &mdash; latest {len(recs)}</h2>")
        for rec in reversed(recs):
            if not latest_ts:
                latest_ts = rec.get("timestamp_utc") or ""
            body_parts.append(_record_html(rec, plugin_root=plugin_root))
    if not body_parts:
        body_parts.append("<p class='empty'>No benchmark results yet. Run <code>make benchmark</code>.</p>")

    surface_line = ""
    if plugin_root:
        da, ds, dc = declared_surface(plugin_root)
        ex_agents, ex_skills, ex_commands = set(), set(), set()
        for rec in (history.get("live") or []) if isinstance(history, dict) else []:
            for s in rec.get("stages") or []:
                cov = s.get("coverage")
                if not isinstance(cov, dict):
                    continue
                ex_agents.update(x for x in cov.get("agents", []) if isinstance(x, str))
                ex_skills.update(x for x in cov.get("skills", []) if isinstance(x, str))
                ex_commands.update(x for x in cov.get("commands", []) if isinstance(x, str))

        def ratio(ex: int, decl: int) -> str:
            return f"{ex}/{decl} ({_ratio_fmt(ex / decl * 100)}%)" if decl > 0 else f"{ex}/0"

        surface_line = (
            "<p class='sub'>Plugin-surface coverage — agents "
            f"{ratio(len(ex_agents), da)} &middot; skills "
            f"{ratio(len(ex_skills), ds)} &middot; commands "
            f"{ratio(len(ex_commands), dc)}.</p>"
        )

    asof = _escape(latest_ts) if latest_ts else "no runs"
    return (
        "<!DOCTYPE html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        "<title>corpflow benchmark &mdash; Tic-Tac-Toe with/without plugin</title>"
        f"<style>{_CSS}</style></head><body>"
        "<h1>Tic-Tac-Toe benchmark &mdash; WITH vs WITHOUT plugin</h1>"
        '<p class="sub">All metrics per retained run (latest-3 per mode). As of '
        f"{asof}. Deterministic tokens/cost are null by design; live fills them.</p>"
        f"{surface_line}"
        f"{''.join(body_parts)}"
        "<footer>Generated by bench-report from benchmark/results/history.json &middot; "
        "app paths point to gitignored per-run workdirs.</footer>"
        "</body></html>\n"
    )


def build_report(history_path: str, out_path: str, plugin_root: Optional[str] = None) -> str:
    history = {}
    try:
        import json
        with open(history_path, encoding="utf-8") as f:
            parsed = json.load(f)
        if isinstance(parsed, dict):
            history = parsed
    except (OSError, ValueError):
        history = {}
    html_text = render_html(history, plugin_root=plugin_root)
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html_text)
    return out_path
