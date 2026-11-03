"""Shared live orchestration for provider-isolated, budgeted benchmark arms."""

from __future__ import annotations

import functools
import os
import sys
import subprocess
from datetime import datetime, timezone
from typing import Callable, Optional

from benchmarkkit import oracle
from benchmarkkit.genlib import Subprocess, Timer
from benchmarkkit.metrics import BenchmarkRecord, write_record

from . import baseline as baseline_mod
from . import budget as budget_mod
from . import capture as capture_mod
from . import config_leak
from . import isolation
from . import ledger_seed
from . import plugin_load
from . import preamble
from . import usage_limit
from . import workdirs
from .diagnostics import capture_diagnostics, merge_diagnostics

# Re-export shim: callers and tests address these as ``dispatch.<name>``.
from .arm_exec import (  # noqa: F401
    STAGE_TIMEOUT_S,
    ArmResult,
    ArmSpec,
    DispatchFailure,
    Dispatching,
    SubprocessDispatcher,
    _arm_tokens,
    _sum_opt,
    _tok_total,
)
from .records import (  # noqa: F401
    PipelineResult,
    _arm_verdict,
    _oracle_conforms,
    _stage_attributions,
    build_arm_record,
    build_live_record,
)
from .settings_argv import (  # noqa: F401
    PERMISSION_MODE,
    SETTINGS_RELPATH,
    BenchmarkSettingsMissing,
    _settings_argv,
    build_arm_stage_argv,
    build_stage_argv,
    require_settings,
    settings_path_for,
)
from .stage_table import (  # noqa: F401
    CAPTURE_JSON,
    CAPTURE_STREAM_JSON,
    HARNESS_GENERATION,
    PROMPT_CONTRACT,
    STAGE_TABLE,
    build_era,
)
from .stage_usage import (  # noqa: F401
    NON_APP_DIRS,
    StageUsage,
    _audit_subagent_spawns,
    capture_layer2,
    capture_stage_usage,
    dv_produced_swift,
)

# Raw stage stdout over this size is persisted truncated with a marker (A3). Read
# through this module's globals so a caller can lower the cap by rebinding it here.
CAPTURE_TRUNCATE_BYTES = 25 * 1024 * 1024


def _write_capture(captures_dir: str, filename: str, stdout: str) -> None:
    try:
        os.makedirs(captures_dir, exist_ok=True)
        raw = stdout.encode("utf-8")
        truncated = len(raw) > CAPTURE_TRUNCATE_BYTES
        body = raw[:CAPTURE_TRUNCATE_BYTES].decode("utf-8", "ignore") if truncated else stdout
        with open(os.path.join(captures_dir, filename), "w", encoding="utf-8") as f:
            f.write(body)
            if truncated:
                f.write(f"\n<<<TRUNCATED at {CAPTURE_TRUNCATE_BYTES} bytes>>>\n")
    except OSError:
        pass


def persist_capture(captures_dir: Optional[str], arm: str, stage: str, stdout: str) -> None:
    """Persist raw stage stdout BEFORE parsing (A3). ``captures_dir=None`` is a no-op,
    keeping existing callers byte-stable; any failure is swallowed — persistence never
    kills a run. Over-cap payloads are written truncated with a marker."""
    if captures_dir is not None:
        _write_capture(captures_dir, f"{arm}-{stage}.jsonl", stdout)


def persist_failed_capture(captures_dir: Optional[str], arm: str, stage: str,
                           stdout: str) -> None:
    """Keep a failed stage's full stdout as ``<arm>-<STAGE>.failed.jsonl``.

    Apart from the success capture, so a retry's ``<arm>-<STAGE>.jsonl`` is never mixed
    with the attempt that died. An empty stdout has nothing to keep.
    """
    if captures_dir is not None and stdout:
        _write_capture(captures_dir, f"{arm}-{stage}.failed.jsonl", stdout)


def read_state_json_text(workdir_path: str) -> str:
    try:
        with open(os.path.join(workdir_path, ".context", "state.json"), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def assemble_prompts(prompts_dir: str, stages: list, state_json_text: str,
                     worktask_id: str, plan_file: str) -> dict:
    """Assemble each stage's stdin prompt ONCE from shared inputs so both arms consume
    byte-identical prompts (AC-16). Missing prompt file is a hard error."""
    out = {}
    for stage in stages:
        prompt_path = os.path.join(prompts_dir, f"{stage.lower()}.txt")
        with open(prompt_path, encoding="utf-8") as f:
            task_text = f.read()
        out[stage] = preamble.assemble_stage_prompt(
            stage, worktask_id=worktask_id, plan_file=plan_file,
            state_json_text=state_json_text, task_text=task_text)
    return out


def _attempt_tokens(parsed):
    return {key: getattr(parsed, field, None) for key, field in (
        ("fresh_in", "input_tokens"), ("cache_read", "cache_read"),
        ("cache_creation", "cache_creation"), ("out", "output_tokens"))}


def _instruction_fingerprint(provider, arm, stage):
    if provider is None or arm != "with":
        return None
    try:
        return provider.instruction_set(stage)["fingerprint"]
    except (AttributeError, KeyError, TypeError, ValueError, OSError):
        return None


def _record_configuration_block(arm, stage, attempts, captures_dir, workdir, reason, duration):
    import json
    attempt = sum(item["stage"] == stage for item in attempts) + 1 if attempts is not None else 1
    evidence = {"stage": stage, "operation": "prepare and verify stage configuration", "reason": str(reason),
                "required_recovery": "Restore the canonical role, skills, filesystem, and network restrictions before resuming this stage.",
                "provider_invoked": False}
    folder = captures_dir or (os.path.join(workdir, ".context/logs") if workdir else None)
    path = os.path.join(folder, f"{arm}-{stage}.attempt-{attempt}.verification.json") if folder else None
    if path is not None:
        try:
            os.makedirs(folder, exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(evidence, handle, indent=2)
                handle.write("\n")
        except OSError:
            path = None
    if attempts is not None:
        attempts.append({"stage": stage, "attempt": attempt, "status": "blocked", "cost_usd": None,
                         "duration_s": duration, "provider_invoked": False, "reason": str(reason),
                         "required_recovery": evidence["required_recovery"], "evidence_ref": path})


def _dispatch_stage(dispatcher: Dispatching, argv: list, prompt_text: str, arm: str,
                    stage: str, captures_dir: Optional[str],
                    tally: "budget_mod.RunningTally",
                    limit_policy: Optional[usage_limit.LimitPolicy], estimate: float,
                    interrupted: list, validate_attempt: Callable[[str], bool],
                    provider_adapter=None, attempts=None, workdir=None) -> tuple:
    """Dispatch one stage; returns ``(stdout, seconds)`` or ``(None, 0)`` when stopped.

    ``stdout`` and ``seconds`` are the attempt that succeeded. A failure is always persisted
    in full. One that is the account's usage limit is waited out and the SAME stage
    re-dispatched; quota waiting is excluded, but failed-attempt duration and spend are retained. The
    re-dispatch builds on its files, so its parsed usage is appended to the caller's
    ``interrupted`` list, and its cost is charged to the tally at once. Every retry is
    budget-gated, and an interrupted attempt must pass ``validate_attempt`` before waiting.
    Anything else propagates unchanged; a limit that cannot be waited out raises
    ``UsageLimitHit`` without losing the caller's interrupted usage.
    """
    while tally.can_afford(estimate):
        attempt = (sum(a["stage"] == stage for a in attempts) + 1
                   if attempts is not None else 1)
        timer = Timer()
        timer.start()
        if (provider_adapter is not None and isinstance(dispatcher, SubprocessDispatcher)
                and getattr(provider_adapter, "snapshot", None) is not None):
            try:
                provider_adapter.verify_stage(arm, stage)
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                _record_configuration_block(arm, stage, attempts, captures_dir, workdir, exc, timer.elapsed)
                return None, 0
        try:
            return dispatcher.run(argv, prompt_text), timer.elapsed
        except DispatchFailure as exc:
            failed_duration = timer.elapsed
            diagnostic = capture_diagnostics(exc.stdout, workdir, stage,
                                               _instruction_fingerprint(provider_adapter, arm, stage))
            persist_failed_capture(captures_dir, arm, stage, exc.stdout)
            if captures_dir is not None:
                import json
                _write_capture(captures_dir, f"{arm}-{stage}.attempt-{attempt}.diagnostics.json",
                               json.dumps({"status": "failed", "duration_s": failed_duration,
                                           "cost_usd": None, "diagnostics": diagnostic,
                                           **_attempt_tokens(None)}))
                _write_capture(captures_dir, f"{arm}-{stage}.attempt-{attempt}.failed.jsonl", exc.stdout)
            if provider_adapter is not None:
                try:
                    parsed = provider_adapter.parse(exc.stdout, stage)
                except ValueError:
                    parsed = None
                tally.add(parsed.cost_usd if parsed else None)
                if captures_dir is not None:
                    _write_capture(captures_dir, f"{arm}-{stage}.attempt-{attempt}.diagnostics.json",
                                   json.dumps({"status": "failed", "duration_s": failed_duration,
                                               "cost_usd": parsed.cost_usd if parsed else None,
                                               "diagnostics": diagnostic, **_attempt_tokens(parsed)}))
                if parsed is not None:
                    parsed.duration_s = failed_duration
                    parsed.diagnostics = diagnostic
                    interrupted.append(parsed)
                if attempts is not None:
                    attempts.append({"stage": stage, "attempt": attempt, "status": "failed",
                                     "cost_usd": parsed.cost_usd if parsed else None,
                                     "duration_s": failed_duration, "diagnostics": diagnostic,
                                     **_attempt_tokens(parsed)})
                policy = limit_policy or usage_limit.LimitPolicy(wait=False)
                try:
                    limit = provider_adapter.detect_limit(exc.stdout, policy.now())
                except ValueError:
                    limit = None
                if (parsed is None or limit is None or not validate_attempt(exc.stdout)
                        or not tally.can_afford(estimate)):
                    break
                policy.wait_out(limit, f"{arm} {stage}")
                continue
            policy = limit_policy or usage_limit.LimitPolicy(wait=False)
            limit = usage_limit.detect(exc.stdout, policy.now())
            parsed = capture_mod.parse(exc.stdout)
            tally.add(parsed.cost_usd if parsed is not None else None)
            if captures_dir is not None:
                _write_capture(captures_dir, f"{arm}-{stage}.attempt-{attempt}.diagnostics.json",
                               json.dumps({"status": "failed", "duration_s": failed_duration,
                                           "cost_usd": parsed.cost_usd if parsed else None,
                                           "diagnostics": diagnostic, **_attempt_tokens(parsed)}))
            if parsed is not None:
                parsed.duration_s = failed_duration
                parsed.diagnostics = diagnostic
                interrupted.append(parsed)
            if attempts is not None:
                attempts.append({"stage": stage, "attempt": attempt, "status": "failed",
                                 "cost_usd": parsed.cost_usd if parsed else None,
                                 "duration_s": failed_duration, "diagnostics": diagnostic,
                                 **_attempt_tokens(parsed)})
            if limit is None:
                raise
            if not validate_attempt(exc.stdout) or not tally.can_afford(estimate):
                break
            policy.wait_out(limit, f"{arm} {stage}")
    return None, 0.0


_FOLDED_FIELDS = ("input_tokens", "output_tokens", "cost_usd", "cache_read", "cache_creation",
                  "parent_input_tokens", "parent_output_tokens", "parent_cache_read",
                  "parent_cache_creation")


def fold_interrupted(usage: StageUsage, interrupted: list) -> None:
    """Add each interrupted attempt's figures to the stage's, field by field.

    A field stays None only when neither side reported it: a stage whose re-dispatch
    reported nothing still shows what the interrupted attempt spent.
    """
    for parsed in interrupted:
        usage.duration_s += getattr(parsed, "duration_s", 0.0)
        usage.diagnostics = merge_diagnostics(usage.diagnostics, getattr(parsed, "diagnostics", None))
        for name in _FOLDED_FIELDS:
            extra = getattr(parsed, name, None)
            if extra is None:
                continue
            current = getattr(usage, name)
            setattr(usage, name, extra if current is None else current + extra)


def _check_stage_isolation(stdout: str, arm: ArmSpec, result: ArmResult, stage: str,
                           capture_mode: str, config_dir: Optional[str]) -> bool:
    """Validate an attempt's plugin contract, retaining violations in the arm result."""
    if capture_mode != CAPTURE_STREAM_JSON or (
            arm.plugin_dir is None and arm.enabled_plugins is None):
        return True
    if arm.plugin_dir is not None:
        check = plugin_load.check_stage_plugin(stdout, arm.plugin_dir)
    else:
        check = plugin_load.check_stage_bare(stdout)
    if check.loaded is not None:
        result.plugin = check.loaded
    if check.plugins is not None:
        result.plugins = check.plugins
    if check.error is not None:
        result.plugin_error = f"stage {stage}: {check.error}"
        result.partial = True
    if config_dir is not None:
        found = config_leak.find_leaks(stdout, config_dir)
        result.config_leaks = sorted(set(result.config_leaks or []) | set(found))
        if found:
            leak = (f"stage {stage}: read plugin files outside CLAUDE_CONFIG_DIR "
                    f"{config_dir}: {found}")
            result.plugin_error = (f"{result.plugin_error}; {leak}"
                                   if result.plugin_error else leak)
            result.partial = True
    return result.plugin_error is None


def run_arm(arm: ArmSpec, prompts_by_stage: dict, dispatcher: Dispatching,
            tally: "budget_mod.RunningTally", estimate_calc_path: str,
            stages: list, estimate_runner: Optional[Callable[[list], str]] = None,
            capture_mode: str = CAPTURE_JSON, settings_path: Optional[str] = None,
            captures_dir: Optional[str] = None,
            persist_partial: Optional[Callable[["ArmResult"], None]] = None,
            now_fn: Optional[Callable[[], float]] = None,
            ledger_seeder: Optional[Callable[[str], None]] = None,
            config_dir: Optional[str] = None,
            limit_policy: Optional[usage_limit.LimitPolicy] = None,
            provider_adapter=None) -> ArmResult:
    """Dispatch one arm's ordered stage sequence under its own running-tally gate.

    Both arms call this with identical ``prompts_by_stage``; only ``arm.bind_agent``,
    ``arm.plugin_dir``, ``arm.enabled_plugins`` and ``arm.cwd`` differ. Gate (b) aborts
    before a breaching dispatch; A3 persists each raw stdout before parsing; A5 stops the
    arm if the DV stage lands no Swift. An arm stops at the first stage whose
    ``system/init`` breaks its plugin contract (wrong corpflow tree, or any plugin on the
    baseline), so a bad run spends one stage rather than ten (stream-json capture only;
    json emits no init event). ``ledger_seeder`` runs just before each dispatch. With
    ``config_dir`` set, either arm also stops at the first stage whose tool inputs name a
    plugin cache outside it (``config_leak``); stream-json only, like the load check.
    A stage that dies on the account usage limit is re-dispatched per ``limit_policy``
    only while its attempts stay isolated and affordable. Interrupted spend is retained
    even when the stage never completes; an unresolvable limit sets ``usage_limit``.
    """
    result = ArmResult(name=arm.name)
    for stage in stages:
        estimate = (provider_adapter.estimate(stage) if provider_adapter is not None else
                    budget_mod.estimate_stage_cost(estimate_calc_path, stage=stage,
                                                  runner=estimate_runner))
        if not tally.can_afford(estimate):
            result.partial = True
            result.stop_reason = "stage admission budget exhausted"
            break
        prompt_text = prompts_by_stage[stage]
        if ledger_seeder is not None:
            ledger_seeder(stage)
        configuration_timer = Timer()
        configuration_timer.start()
        try:
            if provider_adapter is not None and getattr(provider_adapter, "snapshot", None) is not None:
                prompt_text = provider_adapter.compose_prompt(arm, stage, prompt_text)
            argv = (provider_adapter.build_argv(arm, stage) if provider_adapter is not None else
                    build_arm_stage_argv(stage, bind_agent=arm.bind_agent,
                                        capture_mode=capture_mode, settings_path=settings_path,
                                        plugin_dir=arm.plugin_dir,
                                        enabled_plugins=arm.enabled_plugins))
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            _record_configuration_block(arm.name, stage, result.attempts, captures_dir, arm.cwd, exc, configuration_timer.elapsed)
            result.partial = True
            result.stop_reason = "configuration verification blocked"
            if persist_partial is not None:
                persist_partial(result)
            break
        interrupted = []
        validate_attempt = functools.partial(
            _check_stage_isolation, arm=arm, result=result, stage=stage,
            capture_mode=capture_mode, config_dir=config_dir)
        if provider_adapter is not None:
            def validate_attempt(_stdout):
                try:
                    provider_adapter.validate_snapshot()
                except ValueError as exc:
                    result.plugin_error = str(exc)
                    result.partial = True
                    return False
                return True
        # A throw here propagates with prior stages' partial ALREADY on disk (OI-2).
        try:
            stdout, elapsed = _dispatch_stage(
                dispatcher, argv, prompt_text, arm.name, stage, captures_dir, tally,
                limit_policy, estimate, interrupted, validate_attempt,
                provider_adapter=provider_adapter, attempts=result.attempts, workdir=arm.cwd)
        except usage_limit.UsageLimitHit as hit:
            result.usage_limit = hit
            stdout = None
        except DispatchFailure:
            if interrupted:
                usage = StageUsage(capture_layer=1)
                fold_interrupted(usage, interrupted)
                result.usages.append((stage, usage))
            result.partial = True
            result.stop_reason = "dispatch failed"
            if persist_partial is not None:
                persist_partial(result)
            raise
        if stdout is None:
            if any(parsed.has_usage for parsed in interrupted):
                usage = StageUsage(capture_layer=1)
                fold_interrupted(usage, interrupted)
                result.usages.append((stage, usage))
            result.partial = True
            configuration_blocked = bool(result.attempts and result.attempts[-1].get("status") == "blocked")
            result.stop_reason = ("configuration verification blocked" if configuration_blocked else
                                  "attempt accounting unreliable" if not tally.reliable else
                                  "stage failed or retry budget exhausted")
            result.overshoot_usd = max(0.0, tally.spent_usd - tally.budget)
            if persist_partial is not None:
                persist_partial(result)
            break
        persist_capture(captures_dir, arm.name, stage, stdout)
        if provider_adapter is not None:
            try:
                usage = provider_adapter.usage(stdout, stage)
            except ValueError:
                usage = StageUsage()
                result.stop_reason = "terminal token accounting unreliable"
            result.attempts.append({"stage": stage, "attempt":
                                    sum(a["stage"] == stage for a in result.attempts) + 1,
                                    "status": "completed", "cost_usd": usage.cost_usd})
        else:
            usage = capture_stage_usage(stdout, arm.audit_path, stage, now_fn=now_fn)
        usage.duration_s = elapsed
        usage.diagnostics = capture_diagnostics(stdout, arm.cwd, stage,
                                                _instruction_fingerprint(provider_adapter, arm.name, stage))
        if provider_adapter is not None:
            result.attempts[-1].update({"duration_s": elapsed, "diagnostics": usage.diagnostics,
                                       **_attempt_tokens(usage)})
        # The tally already holds the interrupted attempts' cost; charge only this one.
        tally.add(usage.cost_usd)
        result.overshoot_usd = max(0.0, tally.spent_usd - tally.budget)
        fold_interrupted(usage, interrupted)
        result.usages.append((stage, usage))
        result.dispatched += 1
        if provider_adapter is not None and usage.cost_usd is not None:
            result.completed_stages.append(stage)
        if usage.capture_layer is None:
            result.partial = True
        validate_attempt(stdout)
        if persist_partial is not None:
            persist_partial(result)
        if provider_adapter is not None and (not tally.reliable or result.overshoot_usd > 0):
            result.partial = True
            result.stop_reason = result.stop_reason or "running stage exceeded arm allowance"
            if persist_partial is not None:
                persist_partial(result)
            break
        if result.plugin_error is not None:
            break
        if stage == "DV" and not dv_produced_swift(arm.cwd):
            result.dv_gated = True
            result.partial = True
            break
    return result


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git_sha7(repo_root: str) -> str:
    r = Subprocess.run(["git", "-C", repo_root, "rev-parse", "--short=7", "HEAD"])
    sha = r.stdout.strip()
    return sha if (r.exit_code == 0 and sha) else "nogit"


def _measure_arm(arm_cwd: str, plugin_root: str, dispatched: int,
                 warn: Callable[[str], None],
                 grader: Optional[Callable] = None,
                 app_path: Optional[str] = None) -> Optional[baseline_mod.AppMeasure]:
    """Measure one arm, then grade it against the held-out oracle.

    Runs after dispatch, so oracle build time never lands in ``wall_clock_s``.
    ``app_path`` is the repo-relative path recorded for the arm; the arm itself runs
    outside the repo, so the path relative to ``plugin_root`` would be absolute.
    """
    def unmeasured() -> baseline_mod.AppMeasure:
        return baseline_mod.AppMeasure(
            loc_produced=0, test_count=0, pass_fail="fail",
            app_path=app_path or baseline_mod.genlib.relative_path(arm_cwd, plugin_root))

    try:
        app = baseline_mod.measure_app(arm_cwd, plugin_root)
        if app is None and dispatched > 0:
            app = unmeasured()
        if app is not None and app_path is not None:
            app.app_path = app_path
    except Exception as exc:  # noqa: BLE001 — measurement never loses the record write
        warn(f"app metrics fill failed for {arm_cwd}: {exc}")
        app = unmeasured() if dispatched > 0 else None

    if app is None:
        return None

    grade = grader if grader is not None else oracle.grade
    try:
        app.oracle = grade(arm_cwd, warn=warn).to_dict()
    except Exception as exc:  # noqa: BLE001 — an ungradeable arm stays unscored, not unrecorded
        warn(f"oracle grading failed for {arm_cwd}: {exc}")
    return app


def _run_goal(prompts_dir: str, stages: list) -> str:
    """The seeded ``facts.goal``: the PL prompt's task, else the first run stage's."""
    for code in ["PL"] + list(stages):
        try:
            with open(os.path.join(prompts_dir, f"{code.lower()}.txt"), encoding="utf-8") as f:
                return ledger_seed.goal_from_prompt(f.read())
        except OSError:
            continue
    return ""


def _dispatch(workdir: str, budget: float, record_path: str, benchmark_dir: str,
             dispatcher: Optional[Dispatching] = None, env: Optional[dict] = None,
             estimate_runner: Optional[Callable[[list], str]] = None,
             prompts_dir: Optional[str] = None, stages: Optional[list] = None,
             cli_login_runner: Optional[Callable[[], str]] = None,
             capture_mode: str = CAPTURE_JSON,
             stderr: Optional[Callable[[str], None]] = None,
             git_sha_runner: Optional[Callable[[str], str]] = None,
             without_arm: str = baseline_mod.ARM_SKIP,
             selection: Optional[baseline_mod.ArmSelection] = None,
             now_fn: Optional[Callable[[], float]] = None,
             config_dir: Optional[str] = None,
             seed_runner: Optional[ledger_seed.SeedRunner] = None,
             workdir_root: Optional[str] = None,
             git_runner: Optional[workdirs.GitRunner] = None,
             wait_on_limit: bool = False,
             limit_policy: Optional[usage_limit.LimitPolicy] = None,
             provider_adapter=None) -> int:
    """Run the live pipeline end-to-end and write the BenchmarkRecord.

    ``config_dir`` (else ``BENCH_CONFIG_DIR``, else ``~/.claude-eval``) is the
    ``CLAUDE_CONFIG_DIR`` both arms and the credential probe run under.

    ``workdir_root`` (else ``BENCH_WORKDIR_ROOT``, else ``${TMPDIR:-/tmp}/corpflow-bench``)
    holds ``<run_id>/{with,without}``, one git repo per arm. Captures stay under
    ``<benchmark_dir>/workdirs/<run_id>/``, which also links each arm.

    The WITH arm's ledger is seeded with the real ``seed-state.sh`` before anything is
    dispatched (``seed_runner`` stands in for every script call under test); a failure
    refuses the run with rc 1. ``wait_on_limit`` sleeps through the account usage limit
    and re-dispatches the stage; off, or over the cap, the run ends with rc 6.
    ``limit_policy`` replaces the policy ``wait_on_limit`` would build (tests inject a
    fake clock and sleep).

    ``selection`` drives which arms dispatch and what shape is recorded; when omitted
    it is derived from ``without_arm`` so every pre-existing caller keeps its exact
    behaviour. A single-arm selection records only its own arm and gets the whole
    budget — there is no second arm to reserve half for.
    """
    from . import credentials  # local import keeps credentials optional at import time

    stages = stages if stages is not None else budget_mod.PIPELINE_STAGES
    warn = stderr or (lambda s: sys.stderr.write(s + "\n"))
    # Persisted evidence (captures, arm links) stays in the repo tree; the arms do not.
    workdir_path = os.path.join(benchmark_dir, "workdirs", workdir)
    arms_root = os.path.join(workdirs.resolve_workdir_root(workdir_root, env), workdir)
    prompts = prompts_dir or os.path.join(benchmark_dir, "live", "prompts")
    plugin_root = os.path.dirname(benchmark_dir)
    estimate_calc = os.path.join(plugin_root, "skills", "estimation-methodology",
                                 "scripts", "estimate-calc.py")
    settings_path = settings_path_for(benchmark_dir)
    # Fail closed: headless dispatch runs under bypassPermissions, so a missing
    # deny-list would run fail-open. Refuse BEFORE any dispatch (SR-M1).
    if provider_adapter is None:
        require_settings(settings_path)
    captures_dir = os.path.join(workdir_path, "captures")
    if selection is None:
        selection = baseline_mod.resolve_arm_selection(
            None, without_arm,
            baseline_mod.stages_subset(stages, budget_mod.PIPELINE_STAGES))

    with_spec = ArmSpec(name="with", bind_agent=True, plugin_dir=os.path.realpath(plugin_root),
                        enabled_plugins=isolation.enabled_plugins(with_siblings=True),
                        cwd=os.path.join(arms_root, "with"),
                        audit_path=os.path.join(arms_root, "with", ".context", "logs", "audit.jsonl"))
    without_spec = ArmSpec(name="without", bind_agent=False,
                           enabled_plugins=isolation.enabled_plugins(with_siblings=False),
                           cwd=os.path.join(arms_root, "without"),
                           audit_path=os.path.join(arms_root, "without", ".context", "logs", "audit.jsonl"))
    for spec in (with_spec, without_spec):
        os.makedirs(os.path.join(spec.cwd, ".context", "logs"), exist_ok=True)
        problem = workdirs.init_arm_repo(spec.cwd, git_runner)
        if problem is not None:
            warn(f"{spec.name} arm is not its own git repo ({problem}); "
                 "git in that workdir will not resolve to the arm")
        problem = workdirs.link_persisted(workdir_path, spec.name, spec.cwd)
        if problem is not None:
            warn(f"{spec.name} arm not linked under the persisted workdir: {problem}")

    run_id = workdir
    timestamp_utc = now_iso()
    git_sha = git_sha_runner(plugin_root) if git_sha_runner else git_sha7(plugin_root)
    provider_era = None
    if provider_adapter is not None:
        try:
            provider_adapter.prepare(arms_root, env, config_dir, cli_login_runner)
        except ValueError as exc:
            warn(str(exc))
            return 3
        from .providers.codex.adapter import CodexDispatcher
        with_spec.plugin_dir = str(provider_adapter.snapshot)
        if dispatcher is None:
            provider_adapter.verify_runtime({"with": with_spec, "without": without_spec})
        with_dispatcher = dispatcher or CodexDispatcher(
            workdir=with_spec.cwd, env=provider_adapter.env("with"))
        without_dispatcher = dispatcher or CodexDispatcher(
            workdir=without_spec.cwd, env=provider_adapter.env("without"))
        provider_era = provider_adapter.metadata()
    else:
        config_dir = isolation.resolve_config_dir(config_dir, env)
        child_env = isolation.claude_env(config_dir)
        with_dispatcher = dispatcher or SubprocessDispatcher(workdir=with_spec.cwd, env=child_env)
        without_dispatcher = dispatcher or SubprocessDispatcher(workdir=without_spec.cwd, env=child_env)

    # 1. Credential probe — before ANY dispatch.
    try:
        if provider_adapter is None:
            credentials.require_credential(env=env, cli_login_runner=cli_login_runner,
                                           config_dir=config_dir)
    except credentials.CredentialError as e:
        warn(str(e))
        return 3

    # 2. Pre-flight budget gate. Every selected arm runs the same stage list.
    arms = len(selection.dispatch)
    try:
        if provider_adapter is None:
            budget_mod.assert_preflight_within_budget(
                budget, stages, estimate_calc, arms=arms, runner=estimate_runner)
        elif sum(provider_adapter.estimate(s) for s in stages) * arms > budget:
            raise budget_mod.BudgetExceeded("Codex pre-flight projection exceeds allowance")
    except budget_mod.BudgetExceeded as e:
        warn(str(e))
        return 2

    record_dir = os.path.dirname(record_path)
    if record_dir:
        os.makedirs(record_dir, exist_ok=True)

    # Before any dispatch, so a refusal spends nothing. The WITHOUT arm stays plugin-free
    # and ledger-free.
    if "with" in selection.dispatch:
        try:
            outcome = ledger_seed.seed_run(
                with_spec.cwd, (str(provider_adapter.snapshot)
                                if provider_adapter is not None else plugin_root), run_id,
                _run_goal(prompts, stages), runner=seed_runner)
        except ledger_seed.LedgerSeedError as exc:
            warn(f"live run refused: {exc}; nothing was dispatched")
            return 1
        warn(f"ledger {outcome} at {with_spec.cwd}/.context/state.json")
    policy = limit_policy or usage_limit.LimitPolicy(wait=wait_on_limit, log=warn)

    state_json_text = read_state_json_text(workdir_path)
    prompts_by_stage = assemble_prompts(prompts, stages, state_json_text, run_id,
                                        ".context/planning-0.md")
    if provider_adapter is not None:
        prompts_by_stage = {s: p.replace("corpflow staged worktask", "staged task")
                            for s, p in prompts_by_stage.items()}
        provider_era["workload_digest"] = workload_fingerprint(prompts, stages, state_json_text, run_id)
    # An equal share per selected arm, not one shared purse: the arm dispatched first
    # would otherwise spend the run and leave the second truncated, and a comparison
    # between a complete arm and a starved one measures the budget, not the agent.
    per_arm_budget = budget / arms

    specs = {"with": with_spec, "without": without_spec}
    dispatchers = {"with": with_dispatcher, "without": without_dispatcher}
    results: dict = {}
    apps: dict = {}

    def _base_record(partial: bool) -> BenchmarkRecord:
        arm_plugins = {n: r.plugins for n, r in results.items() if r.plugins is not None}
        leaks = {n: r.config_leaks for n, r in results.items() if r.config_leaks is not None}
        if selection.record_shape == baseline_mod.SHAPE_ARM:
            arm = selection.arm
            res = results.get(arm) or ArmResult(name=arm)
            return build_arm_record(run_id, timestamp_utc, git_sha, budget, arm,
                                    res.usages, res.dispatched, arm_partial=partial,
                                    app=apps.get(arm), plugin=res.plugin,
                                    arm_plugins=arm_plugins, config_leaks=leaks)
        with_res = results.get("with") or ArmResult(name="with")
        wo_res = results.get("without")
        return build_live_record(
            run_id, timestamp_utc, git_sha, budget, with_res.usages, with_res.dispatched,
            live_partial=partial, with_app=apps.get("with"), without_app=apps.get("without"),
            without_usages=wo_res.usages if wo_res is not None else None,
            without_dispatched=wo_res.dispatched if wo_res is not None else 0,
            without_partial=wo_res.partial if wo_res is not None else False,
            with_partial=with_res.partial, plugin=with_res.plugin, arm_plugins=arm_plugins,
            config_leaks=leaks)

    def _compose(partial: bool) -> BenchmarkRecord:
        record = _base_record(partial)
        if provider_era is not None:
            record.era.update(provider_era)
            record.era["accounting"] = {
                n: {"allowance_usd": per_arm_budget, "overshoot_usd": r.overshoot_usd,
                    "stop_reason": r.stop_reason, "attempts": r.attempts,
                    "reliable": r.stop_reason not in (
                        "attempt accounting unreliable", "terminal token accounting unreliable"),
                    "incomplete_stages": [s for s in stages
                                          if s not in r.completed_stages]}
                for n, r in results.items()}
            for n in selection.dispatch:
                record.era["accounting"].setdefault(
                    n, {"allowance_usd": per_arm_budget, "overshoot_usd": 0.0,
                        "stop_reason": "not started", "attempts": [],
                        "incomplete_stages": list(stages)})
        elif any(r.attempts for r in results.values()):
            record.era["accounting"] = {name: {"attempts": result.attempts}
                                        for name, result in results.items() if result.attempts}
        return record

    def _flush(partial: bool) -> None:
        write_record(_compose(partial), record_path)

    if provider_adapter is None and capture_mode != CAPTURE_STREAM_JSON:
        warn("plugin load unverified: --capture json emits no system/init event, so "
             "era.plugin_path and era.plugins_* are not stamped and the baseline's "
             "zero-plugin claim is unchecked; use stream-json")

    for name in selection.dispatch:
        if provider_adapter is not None:
            results[name] = ArmResult(name=name)
            _flush(partial=True)
        def _persist(res: ArmResult, _name: str = name) -> None:
            # OI-2: a budget breach returns an ArmResult, but a throw mid-arm returns
            # nothing, so completed stages only survive if flushed here.
            results[_name] = res
            _flush(partial=True)

        results[name] = run_arm(
            specs[name], prompts_by_stage, dispatchers[name],
            budget_mod.RunningTally(per_arm_budget, strict=provider_adapter is not None),
            estimate_calc, stages,
            estimate_runner=estimate_runner, capture_mode=capture_mode,
            settings_path=settings_path, captures_dir=captures_dir,
            persist_partial=_persist, now_fn=now_fn, config_dir=config_dir,
            limit_policy=policy, provider_adapter=provider_adapter,
            ledger_seeder=(functools.partial(ledger_seed.seed_stage, arm_cwd=specs[name].cwd,
                                             plugin_root=(str(provider_adapter.snapshot)
                                                          if provider_adapter is not None
                                                          else plugin_root), warn=warn,
                                             runner=seed_runner)
                           if name == "with" else None))
        # Flush as each arm completes so a later arm's breach cannot lose it.
        _flush(partial=True)
        if results[name].usage_limit is not None:
            warn(f"live run stopped: {name} arm hit the usage limit: "
                 f"{usage_limit.describe(results[name].usage_limit)}; partial record at "
                 f"{record_path}; completed stages are kept, rerun after the reset")
            return 6
        if results[name].plugin_error is not None:
            # Return before measuring: a wrong-tree run must not spend oracle build time
            # or reach the caller's history rotation, which keys off a zero exit.
            warn(f"live run refused: {name} arm broke its plugin contract: "
                 f"{results[name].plugin_error}; partial record at {record_path} "
                 "is not a measurement of this commit")
            return 5
        if provider_adapter is not None and results[name].stop_reason in (
                "attempt accounting unreliable", "terminal token accounting unreliable", "configuration verification blocked"):
            warn(f"live run stopped: {name} {results[name].stop_reason}; partial saved at {record_path}")
            break

    # Every dispatched arm is measured and graded, including a single-arm run: an arm
    # with no oracle payload carries no quality signal to compare against.
    for name in results:
        apps[name] = _measure_arm(
            specs[name].cwd, plugin_root, results[name].dispatched, warn,
            app_path=baseline_mod.genlib.relative_path(
                os.path.join(workdir_path, name), plugin_root))

    # Scoped to the arms that actually dispatched, so an arm that never ran cannot
    # raise the flag on the arm that did.
    final_partial = (len(results) != len(selection.dispatch)
                     or any(r.partial for r in results.values()))

    write_record(_compose(final_partial), record_path)

    if final_partial:
        dispatched = sum(r.dispatched for r in results.values())
        warn(f"live run partial: {dispatched}/{len(stages) * arms} stages across "
             f"{'+'.join(selection.dispatch)}; record written to {record_path}")
        return 4
    return 0


def workload_fingerprint(prompts_dir, stages, state_text="", run_id="<run_id>"):
    import hashlib
    prompts = assemble_prompts(prompts_dir, stages, state_text, run_id, ".context/planning-0.md")
    normalized = {stage: text.replace("corpflow staged worktask", "staged task")
                  .replace(run_id, "<run_id>") for stage, text in prompts.items()}
    return hashlib.sha256(json_prompts(normalized).encode()).hexdigest()


def json_prompts(prompts):
    import json
    return json.dumps(prompts, sort_keys=True)


def dispatch(*args, provider="claude", **kwargs):
    import math
    allowance = kwargs.get("budget") if "budget" in kwargs else args[1]
    if not math.isfinite(allowance) or allowance <= 0:
        raise ValueError("budget must be finite and positive")
    if provider not in ("claude", "codex"):
        raise ValueError("provider must be claude or codex")
    if provider == "claude":
        return _dispatch(*args, **kwargs)
    from .providers.codex.adapter import Provider
    benchmark_dir = kwargs.get("benchmark_dir") or args[3]
    adapter = Provider(os.path.dirname(benchmark_dir))
    try:
        return _dispatch(*args, provider_adapter=adapter, **kwargs)
    finally:
        adapter.close()
