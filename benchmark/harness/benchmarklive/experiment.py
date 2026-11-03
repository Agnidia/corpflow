"""Offline preparation and analysis of intentional WITH-versus-WITH source experiments."""

import ast
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import uuid

from benchmarkkit.oracle import oracle_cases_digest
from .source import source_digest

UNAVAILABLE = "unavailable"
VARIANTS = ("baseline", "optimized")
UNICODE_CHECKS = ("equivalentUnicodeNamesAreRejected", "unicodeCaseFoldedTiesUseOriginalNameOrder")
SOURCE_NAMES = ("skills", "agents", "hooks", "lib", "commands", ".claude-plugin",
                "benchmark/harness", "benchmark/live", "benchmark/ttt-template", "benchmark/oracle",
                "benchmark/run-benchmark.sh", "Makefile")
COMMON_NAMES = ("Sources", "Tests", "Apps", "TicTacToe.xcodeproj", "Package.swift", "Scripts", "Makefile")
IGNORED = {".git", ".build", ".swiftpm", "__pycache__", ".context", ".benchmark-home", "DerivedData"}
RECORD_AXES = ("provider", "model_pins", "efforts", "pricing", "cli_version", "context_window",
               "native_validation", "workload_digest")


def read_json(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()


def files(root, names):
    root = Path(root).resolve(strict=True)
    result = {}
    for name in names:
        entry = root / name
        if entry.is_symlink():
            raise ValueError(f"experiment inputs cannot contain symlinks: {entry}")
        if not entry.exists():
            raise ValueError(f"required experiment input missing: {entry}")
        paths = sorted(entry.rglob("*")) if entry.is_dir() else [entry]
        for path in paths:
            if IGNORED.intersection(path.relative_to(root).parts) or path.suffix in {".pyc", ".profraw", ".profdata"} or path.name == ".DS_Store":
                continue
            if path.is_symlink():
                raise ValueError(f"experiment inputs cannot contain symlinks: {path}")
            if path.is_file():
                result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def _literal_assignment(tree, name):
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name
                                               for t in node.targets):
            return ast.literal_eval(node.value)
    raise ValueError(f"canonical assignment missing: {name}")


def controls(root):
    root = Path(root)
    stage_path = root / "benchmark/harness/benchmarklive/stage_table.py"
    tree = ast.parse(stage_path.read_text())
    stages = _literal_assignment(tree, "STAGE_CONTRACTS")
    resolver = (root / "skills/shared/lib/codex-runtime.sh").read_text()
    models = dict(re.findall(r"(haiku|sonnet|opus|fable)\) printf '%s' '([^']+)'", resolver))
    if set(models) != {"haiku", "sonnet", "opus", "fable"}:
        raise ValueError("canonical Codex model mapping is incomplete")
    adapter = root / "benchmark/harness/benchmarklive/providers/codex/adapter.py"
    adapter_tree = ast.parse(adapter.read_text())
    overrides = next((n.value for n in ast.walk(adapter_tree)
                      if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "overrides"
                                                           for t in n.targets)), None)
    if not isinstance(overrides, ast.Dict):
        raise ValueError("Codex restrictions cannot be verified statically")
    required = {"approval_policy", "default_permissions", "permissions", "allow_login_shell",
                "shell_environment_policy.inherit", "web_search", "features.multi_agent",
                "features.computer_use", "features.browser_use", "features.apps"}
    restrictions = {}
    for key, value in zip(overrides.keys, overrides.values):
        name = ast.literal_eval(key)
        if (name in required or name.startswith(("features.", "permissions", "shell_environment_policy."))
                or name in {"model_context_window", "service_tier", "project_doc_max_bytes",
                            "plugins._default.enabled", "skills.bundled.enabled", "agents.enabled"}):
            try:
                restrictions[name] = ast.literal_eval(value)
            except (ValueError, TypeError):
                restrictions[name] = ast.dump(value, include_attributes=False)
    if not required.issubset(restrictions):
        raise ValueError("Codex restriction contract is incomplete")
    try:
        runtime = _literal_assignment(adapter_tree, "HEADLESS_RUNTIME_CONTRACT")
    except (ValueError, TypeError):
        runtime_source = (root / "skills/shared/codex-runtime.md").read_text()
        marker = "```text runtime-capabilities\n"
        if runtime_source.count(marker) != 1:
            raise ValueError("runtime capability contract cannot be resolved")
        runtime, end, _ = runtime_source.split(marker, 1)[1].partition("\n```")
        if not end:
            raise ValueError("runtime capability contract is incomplete")
    normalized = " ".join(runtime.lower().split())
    capabilities = {name: text in normalized for name, text in {
        "swiftpm": "swiftpm builds", "unit_cli_tests": "unit/cli tests",
        "native_gui_host_only": "native gui capture", "coresimulator_host_only": "coresimulator",
        "xcode_host_only": "all xcode commands", "trusted_host": "trusted host",
        "sandbox_preserved": "weaken the sandbox"}.items()}
    if not all(capabilities.values()):
        raise ValueError("supported/host-only runtime operations cannot be verified")
    return {"model_pins": {s: models[row[1]] for s, row in stages.items()},
            "efforts": {s: row[2] for s, row in stages.items()},
            "prompt_contract": _literal_assignment(tree, "PROMPT_CONTRACT"),
            "pricing": read_json(root / "benchmark/harness/benchmarklive/providers/codex/pricing.json"),
            "restrictions": restrictions, "capabilities": capabilities}


def workload_digest(root, stage_names):
    from .dispatch import workload_fingerprint
    return workload_fingerprint(str(Path(root) / "benchmark/live/prompts"), list(stage_names))


def invariants(root):
    return {"workload": files(root, ("benchmark/live/prompts", "benchmark/ttt-template", "benchmark/oracle")),
            "quality_checks": files(root, ("benchmark/harness/bin/bench-native-check",
                                           "benchmark/harness/tests/test_native_validation.py")),
            "controls": controls(root),
            "oracle_cases_digest": oracle_cases_digest(read_json(Path(root) / "benchmark/oracle/cases.json")["cases"])}


def _common_fixes(root):
    root = Path(root).resolve(strict=True)
    snapshot = files(root, COMMON_NAMES)
    model_tests = (root / "Tests/TicTacToeKitTests/ModelTests.swift").read_text()
    if not all(re.search(r"\bfunc\s+" + check + r"\b", model_tests) for check in UNICODE_CHECKS):
        raise ValueError("common fixes must include both Unicode regression tests")
    for name in ("Tests/TicTacToeUITests/NativeUITests.swift", "Tests/TicTacToeCLITests/ScriptedCLITests.swift",
                 "TicTacToe.xcodeproj/xcshareddata/xcschemes/TicTacToe-iOS.xcscheme"):
        if name not in snapshot:
            raise ValueError(f"common native acceptance input missing: {name}")
    historical = root / ".context/native-validation/result.json"
    return snapshot, read_json(historical)


def _group(path):
    if "/tests/" in path or path.startswith("tests/"):
        return "tests"
    if path.startswith("benchmark/"):
        return "dispatch-and-measurement"
    return "instructions-and-runtime-helpers"


def prepare(baseline_root, optimized_root, common_fixes_root, output_dir, pairs=3, required_findings=()):
    if isinstance(pairs, bool) or not isinstance(pairs, int) or pairs < 3:
        raise ValueError("an experiment requires at least three pairs")
    roots = {"baseline": Path(baseline_root).resolve(strict=True),
             "optimized": Path(optimized_root).resolve(strict=True)}
    shared = {variant: invariants(root) for variant, root in roots.items()}
    if shared["baseline"] != shared["optimized"]:
        axes = [k for k in shared["baseline"] if shared["baseline"][k] != shared["optimized"][k]]
        raise ValueError("experiment invariant mismatch: " + ", ".join(axes))
    fix_root = Path(common_fixes_root).resolve(strict=True)
    common_files, provenance = _common_fixes(fix_root)
    sources = {v: files(root, tuple(n for n in SOURCE_NAMES if (root / n).exists()))
               for v, root in roots.items()}
    changes = [{"path": p, "baseline": sources["baseline"].get(p),
                "optimized": sources["optimized"].get(p), "group": _group(p)}
               for p in sorted(set(sources["baseline"]) | set(sources["optimized"]))
               if sources["baseline"].get(p) != sources["optimized"].get(p)]
    if not changes:
        raise ValueError("experiment variants have no intentional source differences")
    if any(not isinstance(v, str) or not v.strip() for v in required_findings):
        raise ValueError("required findings must be non-empty identifiers")
    output = Path(output_dir).resolve()
    if output.exists():
        raise ValueError("experiment output already exists; preserve the previous preparation")
    manifest = {
        "schema_version": 1, "kind": "corpflow-utilization-with-vs-with", "status": "prepared_offline",
        "live_execution": "requires separate budget authorization", "experimental_reduction_target_pct": [20, 30],
        "variants": {v: {"root": str(root), "source_digest": source_digest(root)} for v, root in roots.items()},
        "invariants": shared["baseline"], "intentional_source_changes": changes,
        "workload_digest": workload_digest(roots["optimized"], shared["optimized"]["controls"]["model_pins"]),
        "common_fixes": {"root": str(fix_root), "files": common_files,
                         "digest": fingerprint(common_files), "historical_native_provenance": provenance,
                         "historical_evidence_is_trial_acceptance": False},
        "workload_start": "identical remediated app overlay; distinct from the original clean-build workload",
        "required_findings": sorted(set(required_findings)), "unicode_checks": list(UNICODE_CHECKS),
        "quality_policy": "fresh oracle, Unicode, native, findings and blocker evidence for every completed trial",
        "schedule": [{"pair": i, "order": list(VARIANTS if i % 2 else reversed(VARIANTS))}
                     for i in range(1, pairs + 1)],
    }
    manifest["manifest_id"] = fingerprint(manifest)
    output.mkdir(parents=True)
    for variant in VARIANTS:
        destination = output / "workloads" / variant
        for name in common_files:
            source = fix_root / name
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        if files(destination, COMMON_NAMES) != common_files:
            raise ValueError("common fixes overlay verification failed")
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    return manifest


def verify(manifest, experiment_dir):
    problems = []
    unsigned = {k: v for k, v in manifest.items() if k != "manifest_id"}
    if manifest.get("manifest_id") != fingerprint(unsigned):
        problems.append("manifest fingerprint mismatch")
    if manifest.get("schema_version") != 1 or manifest.get("kind") != "corpflow-utilization-with-vs-with":
        problems.append("unsupported experiment manifest")
    schedule = manifest.get("schedule")
    if not isinstance(schedule, list) or len(schedule) < 3:
        problems.append("at least three scheduled pairs are required")
    else:
        for i, entry in enumerate(schedule, 1):
            if entry != {"pair": i, "order": list(VARIANTS if i % 2 else reversed(VARIANTS))}:
                problems.append("execution order must alternate baseline and optimized")
    try:
        for variant in VARIANTS:
            root = manifest["variants"][variant]["root"]
            if source_digest(root) != manifest["variants"][variant]["source_digest"]:
                problems.append(f"{variant} source fingerprint changed")
            if invariants(root) != manifest["invariants"]:
                problems.append(f"{variant} experiment invariants changed")
            if workload_digest(root, manifest["invariants"]["controls"]["model_pins"]) != manifest.get("workload_digest"):
                problems.append(f"{variant} workload digest changed")
            if files(Path(experiment_dir) / "workloads" / variant, COMMON_NAMES) != manifest["common_fixes"]["files"]:
                problems.append(f"{variant} common fixes overlay changed")
        original, _ = _common_fixes(manifest["common_fixes"]["root"])
        if original != manifest["common_fixes"]["files"]:
            problems.append("original common fixes source changed")
    except (OSError, ValueError, KeyError, TypeError, SyntaxError) as exc:
        problems.append(str(exc))
    return problems


def _seal(value, path):
    value["receipt_id"] = fingerprint(value)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    return value


def _receipt(path, kind):
    value = read_json(path)
    unsigned = {k: v for k, v in value.items() if k != "receipt_id"}
    if value.get("kind") != kind or value.get("receipt_id") != fingerprint(unsigned):
        raise ValueError("invalid or modified " + kind + " receipt")
    return value


def prepare_trial(manifest, experiment_dir, variant, run_id, app, record_path):
    problems = verify(manifest, experiment_dir)
    if problems:
        raise ValueError("; ".join(problems))
    if variant not in VARIANTS or not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", run_id):
        raise ValueError("invalid trial variant or run identifier")
    app, record_path = Path(app).resolve(), Path(record_path).resolve()
    if app.name != "with" or app.parent.name != run_id:
        raise ValueError("trial app must use the harness layout WORKDIR_ROOT/RUN_ID/with")
    receipts = Path(experiment_dir).resolve() / "receipts"
    receipt_path = receipts / (run_id + ".prepared.json")
    if app.exists() or record_path.exists() or receipt_path.exists():
        raise ValueError("trial app, record and preparation receipt must be fresh paths")
    protected = [Path(v["root"]).resolve() for v in manifest["variants"].values()]
    protected += [Path(manifest["common_fixes"]["root"]).resolve(), Path(experiment_dir).resolve()]
    if any(app == root or root in app.parents or app in root.parents for root in protected):
        raise ValueError("trial app must be outside the immutable experiment inputs")
    if app == record_path or app in record_path.parents:
        raise ValueError("trial record must remain outside the coding workspace")
    source = Path(experiment_dir) / "workloads" / variant
    for name in manifest["common_fixes"]["files"]:
        target = app / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((source / name).read_bytes())
    initial = files(app, COMMON_NAMES)
    if initial != manifest["common_fixes"]["files"]:
        raise ValueError("trial common fixes overlay verification failed")
    variant_root = Path(manifest["variants"][variant]["root"])
    argv_template = [sys.executable, str(variant_root / "benchmark/harness/bin/bench-live"),
                     "--provider", "codex", "--arm", "with", "--workdir", run_id,
                     "--workdir-root", str(app.parent.parent), "--record", str(record_path),
                     "--benchmark-dir", str(variant_root / "benchmark"),
                     "--prompts-dir", str(variant_root / "benchmark/live/prompts"),
                     "--budget", "<separately-authorized-budget-usd>"]
    value = {"schema_version": 1, "kind": "trial-preparation", "manifest_id": manifest["manifest_id"],
             "variant": variant, "run_id": run_id, "app": str(app), "record_path": str(record_path),
             "source_digest": manifest["variants"][variant]["source_digest"],
             "workload_digest": manifest["workload_digest"], "common_fixes_digest": fingerprint(initial),
             "initial_inputs": initial, "argv_template": argv_template, "created_at": datetime.now(timezone.utc).isoformat()}
    _seal(value, receipt_path)
    return {"preparation_receipt": str(receipt_path), "app": str(app), "record_path": str(record_path),
            "workload_digest": value["workload_digest"], "run_id": run_id, "argv_template": argv_template}



def _trial_app(manifest, variant, path):
    if not isinstance(path, str) or not path:
        raise ValueError("trial app path unavailable")
    app = Path(path)
    if not app.is_absolute():
        app = Path(manifest["variants"][variant]["root"]) / app
    return app.resolve()


def _preparation(manifest, receipt_path, record, record_path):
    receipt = _receipt(receipt_path, "trial-preparation")
    variant = receipt.get("variant")
    if variant not in VARIANTS:
        raise ValueError("trial receipt variant unavailable")
    expected = {"manifest_id": manifest["manifest_id"], "source_digest": manifest["variants"][variant]["source_digest"],
                "workload_digest": manifest["workload_digest"], "common_fixes_digest": manifest["common_fixes"]["digest"],
                "initial_inputs": manifest["common_fixes"]["files"], "run_id": record.get("run_id"),
                "record_path": str(Path(record_path).resolve())}
    if any(receipt.get(k) != v for k, v in expected.items()):
        raise ValueError("trial preparation does not match manifest, source, workload, overlay or run")
    era = record.get("era") or {}
    if era.get("source_digest") != receipt["source_digest"]:
        raise ValueError("record source differs from its verified trial preparation")
    if era.get("workload_digest") != receipt["workload_digest"]:
        raise ValueError("record workload differs from its verified trial preparation")
    app = ((record.get("paths") or {}).get("with") or {}).get("app_path")
    if _trial_app(manifest, variant, app) != Path(receipt["app"]):
        raise ValueError("record app differs from its verified trial preparation")
    return receipt


def _hash_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _bundle_digest(path):
    path = Path(path)
    if not path.is_dir() or not any(path.iterdir()):
        raise ValueError("native result bundle unavailable")
    return fingerprint(files(path, (".",)))


def app_inputs(app):
    return files(app, (".",))


def validate_native(manifest, experiment_dir, preparation_receipt, runner=None):
    """Bind one future trusted-host invocation to immutable trial inputs and evidence."""
    problems = verify(manifest, experiment_dir)
    if problems:
        raise ValueError("; ".join(problems))
    preparation = _receipt(preparation_receipt, "trial-preparation")
    record_path = Path(preparation["record_path"])
    record = read_json(record_path)
    preparation = _preparation(manifest, preparation_receipt, record, record_path)
    app = Path(preparation["app"])
    before = app_inputs(app)
    invocation = uuid.uuid4().hex
    receipt_root = Path(experiment_dir).resolve() / "receipts"
    native_path = receipt_root / (preparation["run_id"] + "." + invocation + ".native.json")
    unicode_path = receipt_root / (preparation["run_id"] + "." + invocation + ".unicode.json")
    unicode_log = receipt_root / (preparation["run_id"] + "." + invocation + ".unicode.log")
    invocation_log = receipt_root / (preparation["run_id"] + "." + invocation + ".host.log")
    script = Path(manifest["variants"][preparation["variant"]]["root"]) / "benchmark/harness/bin/bench-native-check"
    argv = [sys.executable, str(script), "--app", str(app), "--record", str(native_path)]
    value = {"schema_version": 1, "kind": "native-validation", "manifest_id": manifest["manifest_id"],
             "preparation_id": preparation["receipt_id"], "run_id": preparation["run_id"],
             "invocation_id": invocation, "app": str(app), "record_path": str(record_path),
             "record_sha256": _hash_file(record_path), "inputs_before": fingerprint(before),
             "native_record": str(native_path), "invocation_log": str(invocation_log),
             "started_at": datetime.now(timezone.utc).isoformat(), "status": "blocked"}
    def call(command):
        if runner is None:
            clean_env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "DEVELOPER_DIR")
                         if key in os.environ}
            return subprocess.run(command, cwd=app, env=clean_env, text=True, capture_output=True, timeout=1500)
        return runner(command, str(app), 1500)

    try:
        unicode_proc = call(["swift", "test", "--filter", "|".join(UNICODE_CHECKS)])
        unicode_output = (unicode_proc.stdout or "") + "\n" + (unicode_proc.stderr or "")
        unicode_log.write_text(unicode_output)
        unicode_result = {"run_id": preparation["run_id"], "app": str(app), "log": str(unicode_log),
                          "checks": [name for name in UNICODE_CHECKS if name in unicode_output],
                          "returncode": unicode_proc.returncode,
                          "status": "passed" if unicode_proc.returncode == 0 and all(name in unicode_output for name in UNICODE_CHECKS)
                                    else "failed"}
        unicode_path.write_text(json.dumps(unicode_result, indent=2) + "\n")
        proc = call(argv)
        invocation_log.write_text((proc.stdout or "") + "\n" + (proc.stderr or ""))
        native = read_json(native_path)
        after = app_inputs(app)
        native_log = _evidence(native.get("log"), app)
        value.update(returncode=proc.returncode, inputs_after=fingerprint(after),
                     native_record_sha256=_hash_file(native_path), native_log=str(native_log),
                     native_log_sha256=_hash_file(native_log), native_bundle=native.get("result_bundle"),
                     native_bundle_digest=_bundle_digest(native.get("result_bundle")),
                     invocation_log_sha256=_hash_file(invocation_log), unicode_record=str(unicode_path),
                     unicode_record_sha256=_hash_file(unicode_path), unicode_log=str(unicode_log),
                     unicode_log_sha256=_hash_file(unicode_log))
        if (proc.returncode == 0 and before == after and native.get("status") == "passed"
                and unicode_result["status"] == "passed"):
            value["status"] = "passed"
        elif before != after:
            value["reason"] = "app source or tests changed during native validation"
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        value["reason"] = str(exc)
        value["inputs_after"] = fingerprint(app_inputs(app))
    value["finished_at"] = datetime.now(timezone.utc).isoformat()
    receipt_path = receipt_root / (preparation["run_id"] + "." + invocation + ".validated.json")
    _seal(value, receipt_path)
    return {"native_receipt": str(receipt_path), "native_record": str(native_path),
            "unicode_record": str(unicode_path), "status": value["status"]}


def _native_evidence(quality, manifest, base, record, preparation):
    receipt = _receipt(_evidence(quality.get("native_receipt"), base), "native-validation")
    expected = {"manifest_id": manifest["manifest_id"], "preparation_id": preparation["receipt_id"],
                "run_id": record.get("run_id"), "app": preparation["app"],
                "record_path": preparation["record_path"], "record_sha256": _hash_file(preparation["record_path"]),
                "inputs_before": fingerprint(app_inputs(preparation["app"])),
                "inputs_after": fingerprint(app_inputs(preparation["app"])), "status": "passed"}
    if any(receipt.get(k) != v for k, v in expected.items()) or not receipt.get("invocation_id"):
        raise ValueError("native validation receipt is stale or belongs to another app, record or invocation")
    for key, digest_key in (("native_record", "native_record_sha256"), ("native_log", "native_log_sha256"),
                            ("invocation_log", "invocation_log_sha256"),
                            ("unicode_record", "unicode_record_sha256"), ("unicode_log", "unicode_log_sha256")):
        if _hash_file(_evidence(receipt.get(key), base)) != receipt.get(digest_key):
            raise ValueError("native invocation evidence changed: " + key)
    if _bundle_digest(receipt.get("native_bundle")) != receipt.get("native_bundle_digest"):
        raise ValueError("native result bundle changed after validation")
    native = read_json(receipt["native_record"])
    if quality.get("native_record") and Path(quality["native_record"]).resolve() != Path(receipt["native_record"]):
        raise ValueError("quality native record differs from its invocation receipt")
    unicode_path = Path(quality.get("unicode_record", ""))
    unicode_path = unicode_path if unicode_path.is_absolute() else Path(base) / unicode_path
    if unicode_path.resolve() != Path(receipt["unicode_record"]):
        raise ValueError("Unicode evidence differs from its verified host invocation")
    return native


def _number(value):
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value) and value >= 0)

def _total(values):
    return sum(values) if values and all(_number(v) for v in values) else UNAVAILABLE


def _evidence(path, base):
    if not isinstance(path, str) or not path:
        raise ValueError("missing quality evidence path")
    candidate = Path(path)
    candidate = candidate if candidate.is_absolute() else Path(base) / candidate
    if not candidate.is_file() or candidate.stat().st_size == 0:
        raise ValueError(f"quality evidence is missing or empty: {candidate}")
    return candidate


def _quality(quality, manifest, base, record, preparation):
    faults = []
    if not isinstance(quality, dict):
        return ["fresh quality evidence unavailable"]
    try:
        if quality.get("run_id") != record.get("run_id") or not record.get("run_id"):
            faults.append("quality evidence belongs to another trial")
        app = ((record.get("paths") or {}).get("with") or {}).get("app_path")
        app = _trial_app(manifest, preparation["variant"], app)
        native = _native_evidence(quality, manifest, base, record, preparation)
        if _trial_app(manifest, preparation["variant"], native.get("app")) != app:
            faults.append("native acceptance belongs to another app")
        _evidence(native.get("log"), base)
        bundle = native.get("result_bundle")
        bundle = Path(bundle) if isinstance(bundle, str) else None
        if bundle is None or not bundle.is_dir() or not any(bundle.iterdir()):
            faults.append("native result bundle unavailable")
        summary = native.get("summary") or {}
        if (native.get("status") != "passed" or native.get("returncode") != 0
                or not _number(summary.get("passedTests")) or summary["passedTests"] < 1
                or summary.get("failedTests") != 0):
            faults.append("native acceptance did not pass")
        unicode = read_json(_evidence(quality.get("unicode_record"), base))
        if (unicode.get("run_id") != record.get("run_id") or not unicode.get("app")
                or _trial_app(manifest, preparation["variant"], unicode["app"]) != app):
            faults.append("Unicode acceptance belongs to another app or trial")
        if unicode.get("status") != "passed" or not set(manifest["unicode_checks"]).issubset(unicode.get("checks", [])):
            faults.append("Unicode regression evidence is missing or failed")
        _evidence(unicode.get("log"), base)
        findings = quality.get("findings")
        if not isinstance(findings, list) or any(not isinstance(f, dict) or not f.get("id") for f in findings):
            faults.append("findings inventory unavailable")
            findings = []
        if not set(manifest["required_findings"]).issubset(f["id"] for f in findings):
            faults.append("required findings were lost")
        for finding in findings:
            _evidence(finding.get("evidence"), base)
        blockers = quality.get("blockers")
        if not isinstance(blockers, list):
            faults.append("blocker inventory unavailable")
        else:
            for blocker in blockers:
                if not isinstance(blocker, dict) or not blocker.get("operation"):
                    faults.append("malformed blocker inventory")
                    continue
                _evidence(blocker.get("evidence"), base)
                if blocker.get("status") != "resolved":
                    faults.append("acceptance blocker remains pending: " + blocker["operation"])
                elif not blocker.get("recovery_condition_changed"):
                    faults.append("blocker resolution lacks a changed recovery condition")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        faults.append(str(exc))
    return faults


def _trial(entry, manifest, base):
    variant = entry["variant"]
    attempts = entry.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        raise ValueError("every trial must retain its attempts")
    result = {"variant": variant, "attempts": [], "quality_faults": []}
    metrics = {k: [] for k in ("fresh_plus_output", "cached_input", "estimated_cost_usd", "duration_s")}
    latest_era = None
    for index, attempt in enumerate(attempts):
        if not isinstance(attempt, dict):
            raise ValueError("malformed trial attempt")
        record_path = _evidence(attempt.get("record"), base)
        record = read_json(record_path)
        preparation = None
        try:
            preparation = _preparation(manifest, _evidence(attempt.get("preparation_receipt"), base), record, record_path)
            if preparation["variant"] != variant:
                raise ValueError("trial preparation belongs to another source variant")
        except (OSError, ValueError, KeyError, TypeError) as exc:
            result["quality_faults"].append(str(exc))
        result["attempts"].append({"record": record, "quality": deepcopy(attempt.get("quality")),
                                   "record_path": attempt["record"], "preparation_receipt": attempt.get("preparation_receipt")})
        era = record.get("era") or {}
        own = (record.get("paths") or {}).get("with") or {}
        tokens = own.get("tokens") or {}
        latest_era = era
        if record.get("arm") != "with" or set(record.get("paths") or {}) != {"with"}:
            result["quality_faults"].append("experiment requires WITH-only records")
        expected = manifest["variants"][variant]["source_digest"]
        if era.get("source_digest") != expected:
            result["quality_faults"].append("trial source does not match its declared variant")
        controls = manifest["invariants"]["controls"]
        for axis in ("model_pins", "efforts", "pricing", "prompt_contract"):
            if era.get(axis) != controls[axis]:
                result["quality_faults"].append("trial invariant mismatch: " + axis)
        if era.get("provider") != "codex":
            result["quality_faults"].append("trial provider must be codex")
        if not era.get("cli_version"):
            result["quality_faults"].append("trial CLI version unavailable")
        metrics["fresh_plus_output"].append(_total([tokens.get("in"), tokens.get("out")]))
        metrics["cached_input"].append(tokens.get("cache_read"))
        metrics["estimated_cost_usd"].append(own.get("cost_usd"))
        metrics["duration_s"].append(own.get("wall_clock_s"))
        if index == len(attempts) - 1:
            if record.get("live_partial") or own.get("pass_fail") != "pass":
                result["quality_faults"].append("final attempt is failed or partial")
            oracle = own.get("oracle") or {}
            if (oracle.get("built") is not True or oracle.get("pass_rate") != 1.0
                    or not _number(oracle.get("cases_total")) or oracle["cases_total"] < 1
                    or oracle.get("cases_passed") != oracle["cases_total"]
                    or oracle.get("cases_digest") != manifest["invariants"]["oracle_cases_digest"]):
                result["quality_faults"].append("oracle acceptance is missing or failed")
            if preparation is not None:
                result["quality_faults"] += _quality(attempt.get("quality"), manifest, base, record, preparation)
            else:
                result["quality_faults"].append("verified trial preparation unavailable")
    result.update({key: _total(values) for key, values in metrics.items()})
    if any(value == UNAVAILABLE for value in result.values() if isinstance(value, str)):
        result["quality_faults"].append("attempt accounting is incomplete")
    result["quality"] = "pass" if not result["quality_faults"] else "rejected"
    result["era"] = {key: latest_era.get(key) for key in RECORD_AXES}
    return result


def analyze(manifest, assignments, base="."):
    if assignments.get("manifest_id") != manifest.get("manifest_id"):
        raise ValueError("trial assignments belong to another experiment")
    trials = assignments.get("trials")
    if not isinstance(trials, list):
        raise ValueError("trial assignments must be a list")
    scheduled = {entry["pair"]: entry["order"] for entry in manifest["schedule"]}
    grouped = {}
    execution = []
    run_ids = set()
    for trial in trials:
        if (not isinstance(trial, dict) or trial.get("pair") not in scheduled
                or trial.get("variant") not in VARIANTS):
            raise ValueError("trial is outside the declared schedule")
        pair, variant = trial["pair"], trial["variant"]
        if variant in grouped.setdefault(pair, {}):
            raise ValueError("duplicate trial; retain retries inside its attempts list")
        execution.append((pair, variant))
        grouped[pair][variant] = _trial(trial, manifest, base)
        for attempt in grouped[pair][variant]["attempts"]:
            run_id = attempt["record"].get("run_id")
            if not isinstance(run_id, str) or not run_id or run_id in run_ids:
                raise ValueError("attempt run identifiers must be present and unique across the experiment")
            run_ids.add(run_id)
    expected_order = [(pair, variant) for pair, order in scheduled.items() for variant in order]
    if execution != expected_order[:len(execution)]:
        raise ValueError("observed trial order does not match the alternating schedule")
    pairs = []
    for pair, order in scheduled.items():
        row = {"pair": pair, "order": order, "trials": grouped.get(pair, {}), "quality": UNAVAILABLE}
        if set(row["trials"]) == set(VARIANTS):
            baseline, optimized = (row["trials"][v] for v in VARIANTS)
            faults = baseline["quality_faults"] + optimized["quality_faults"]
            if baseline["era"] != optimized["era"]:
                faults.append("pair CLI/provider/control configuration differs")
            base_quality = baseline["attempts"][-1]["quality"] or {}
            opt_quality = optimized["attempts"][-1]["quality"] or {}
            base_findings = {f.get("id") for f in (base_quality.get("findings") or []) if isinstance(f, dict)}
            opt_findings = {f.get("id") for f in (opt_quality.get("findings") or []) if isinstance(f, dict)}
            if not base_findings.issubset(opt_findings):
                faults.append("optimized trial lost baseline findings")
            base_blockers = {b.get("operation") for b in (base_quality.get("blockers") or []) if isinstance(b, dict)}
            opt_blockers = {b.get("operation") for b in (opt_quality.get("blockers") or []) if isinstance(b, dict)}
            if not base_blockers.issubset(opt_blockers):
                faults.append("optimized trial concealed baseline blockers")
            row["quality"] = "pass" if not faults else "rejected"
            row["quality_faults"] = faults
            for metric in ("fresh_plus_output", "cached_input", "estimated_cost_usd", "duration_s"):
                before, after = baseline[metric], optimized[metric]
                row[metric] = {"baseline": before, "optimized": after,
                               "reduction_pct": ((before - after) / before * 100
                                                 if _number(before) and before > 0 and _number(after)
                                                 else UNAVAILABLE)}
        pairs.append(row)
    complete = all(row["quality"] != UNAVAILABLE for row in pairs)
    accepted = complete and all(row["quality"] == "pass" for row in pairs)
    medians = {}
    for metric in ("fresh_plus_output", "cached_input", "estimated_cost_usd", "duration_s"):
        values = [row.get(metric, {}).get("reduction_pct") for row in pairs]
        medians[metric + "_reduction_pct"] = (statistics.median(values)
                                               if complete and all(isinstance(v, (int, float)) and not isinstance(v, bool)
                                                                   and math.isfinite(v) for v in values) else UNAVAILABLE)
    totals = {}
    for metric in ("fresh_plus_output", "cached_input", "estimated_cost_usd", "duration_s"):
        totals[metric] = {variant: _total([row["trials"][variant][metric] for row in pairs
                                          if variant in row["trials"]]) for variant in VARIANTS}
        medians[metric] = {variant: (statistics.median([row["trials"][variant][metric] for row in pairs])
                                     if complete and all(_number(row["trials"][variant][metric])
                                                         for row in pairs) else UNAVAILABLE)
                           for variant in VARIANTS}
    return {"manifest_id": manifest["manifest_id"], "status": "accepted" if accepted else "rejected" if complete else "incomplete",
            "experimental_target_pct": [20, 30], "comparison_valid": accepted,
            "observed_savings_accepted": (accepted and _number(medians["fresh_plus_output_reduction_pct"])
                                          and medians["fresh_plus_output_reduction_pct"] > 0),
            "cost_basis": "API-equivalent estimates; not subscription charges", "pairs": pairs, "medians": medians,
            "observed_totals": totals,
            "ordinary_pairing": "unchanged; this manifest declares intentional source differences"}
