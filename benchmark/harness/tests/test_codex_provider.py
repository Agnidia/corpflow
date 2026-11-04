"""Provider parity, isolation, and conservative Codex accounting without API calls."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from benchmarklive import dispatch, budget, baseline
from benchmarklive.arm_exec import ArmSpec, DispatchFailure
from benchmarklive.providers.codex import adapter, capture
from benchmarklive.usage_limit import LimitPolicy
from benchmarkkit import pairing, analysis
from benchmarkkit import report
from _helpers import make_live_sandbox, RecordingFakeDispatcher, load_json

ROOT = Path(__file__).resolve().parents[3]


def stream(total=1000, cached=500, out=100, failed=False):
    event = {"type": "turn.failed" if failed else "turn.completed",
             "usage": {"input_tokens": total, "cached_input_tokens": cached,
                       "output_tokens": out}}
    if failed:
        event["error"] = {"message": "usage limit reached"}
    return json.dumps(event)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.pricing = capture.load_pricing()

    def test_cached_input_is_subtracted_once(self):
        parsed = capture.parse(stream(), "gpt-6.1-sol", self.pricing)
        self.assertEqual((parsed.input_tokens, parsed.cache_read, parsed.output_tokens),
                         (500, 500, 100))
        self.assertAlmostEqual(parsed.cost_usd, .00205)

    def test_reasoning_is_already_in_output(self):
        event = json.loads(stream())
        event["usage"]["reasoning_output_tokens"] = 90
        parsed = capture.parse(json.dumps(event), "gpt-6.1-sol", self.pricing)
        self.assertEqual(parsed.output_tokens, 100)

    def test_unpriced_explicit_cache_writes_stop_accounting(self):
        event = json.loads(stream())
        event["usage"]["cache_write_input_tokens"] = 100
        with self.assertRaisesRegex(capture.AccountingError, "cache writes"):
            capture.parse(json.dumps(event), "gpt-6.1-sol", self.pricing)

    def test_invalid_usage_fails_closed(self):
        bad = ["", "not JSON", "[]", '{}', stream(cached=1001), stream(total=-1),
               stream(total=True), stream(out=None), stream() + "\n" + stream(),
               '{"type":"turn.completed","usage":[1]}',
               '{"type":"item.completed","item":"malformed"}']
        for text in bad:
            with self.subTest(text=text), self.assertRaises(capture.AccountingError):
                capture.parse(text, "gpt-6.1-sol", self.pricing)

    def test_unknown_model_has_no_free_fallback(self):
        with self.assertRaises(capture.AccountingError):
            capture.parse(stream(), "unpriced", self.pricing)

    def test_failed_attempt_can_retain_usage(self):
        self.assertGreater(capture.parse(stream(failed=True), "gpt-6-luna",
                                         self.pricing).cost_usd, 0)

    def test_invalid_price_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pricing.json"
            for rate in (None, -1, float("nan"), True):
                self.pricing["per_million"]["gpt-6.1-sol"]["output"] = rate
                path.write_text(json.dumps(self.pricing))
                with self.assertRaises(capture.AccountingError):
                    capture.load_pricing(path)


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name)
        self.provider = adapter.Provider(ROOT)
        self.auth = self.path / "source-auth"
        self.auth.mkdir()
        (self.auth / "auth.json").write_text('{"test_credential":"DO_NOT_CAPTURE"}')
        self.arms = self.path / "run"
        for arm in ("with", "without"):
            (self.arms / arm).mkdir(parents=True)

    def tearDown(self):
        self.provider.close()
        self.tmp.cleanup()

    def prepare(self):
        self.provider.prepare(self.arms, config_dir=self.auth,
                              login_runner=lambda: "Logged in using ChatGPT")

    def spec(self, name):
        return ArmSpec(name, name == "with", str(self.arms / name), "")

    def test_canonical_mapping_and_effort(self):
        expected = {"opus": "gpt-6.1-sol", "sonnet": "gpt-6.1-terra",
                    "haiku": "gpt-6-luna", "fable": "gpt-6-astra"}
        for tier, model in expected.items():
            self.assertEqual(adapter.model_for_tier(str(ROOT), tier), model)
        self.prepare()
        for stage, row in dispatch.STAGE_TABLE.items():
            a = self.provider.build_argv(self.spec("with"), stage)
            b = self.provider.build_argv(self.spec("without"), stage)
            self.assertEqual(a[a.index("--model") + 1], b[b.index("--model") + 1])
            self.assertIn(f'model_reasoning_effort="{row[2]}"', a)

    def test_api_auth_is_refused(self):
        with self.assertRaisesRegex(ValueError, "ChatGPT"):
            self.provider.prepare(self.arms, config_dir=self.auth,
                                  login_runner=lambda: "Logged in using an API key")

    def test_credentials_are_private_and_removed(self):
        self.prepare()
        homes = list(self.provider.homes.values())
        for home in homes:
            self.assertEqual((home / "auth.json").stat().st_mode & 0o777, 0o600)
        self.provider.close()
        self.assertTrue(all(not home.exists() for home in homes))

    def test_snapshot_and_bare_arm(self):
        self.prepare()
        self.assertTrue((self.provider.homes["with"] / "skills").is_symlink())
        self.assertFalse((self.provider.homes["without"] / "skills").exists())
        for name in ("with", "without"):
            argv = self.provider.build_argv(self.spec(name), "PL")
            joined = " ".join(argv)
            self.assertNotIn("DO_NOT_CAPTURE", joined)
            self.assertIn('default_permissions="benchmark"', argv)
            self.assertIn('"network"={"enabled"=false}', joined)
            self.assertIn("--ignore-user-config", argv)
            self.assertIn("--strict-config", argv)
            self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", argv)
            self.assertEqual(argv[-1], "-")
            role_args = [a for a in argv if a.startswith("developer_instructions=")]
            self.assertEqual(len(role_args), 1)
            self.assertIn(adapter.HEADLESS_RUNTIME_CONTRACT, joined)
            self.assertEqual("Plugin root:" in role_args[0], name == "with")
            self.assertNotIn("OPENAI_API_KEY", self.provider.env(name))
            self.assertNotIn("CLAUDE_CONFIG_DIR", self.provider.env(name))
            self.assertEqual("CLAUDE_PLUGIN_ROOT" in self.provider.env(name), name == "with")

    def test_snapshot_tampering_is_refused(self):
        self.prepare()
        (self.provider.snapshot / "agents/developer.md").write_text("changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.provider.build_argv(self.spec("with"), "DV")

    def test_snapshot_files_have_fresh_timestamps(self):
        started = time.time()
        self.prepare()
        self.assertGreaterEqual((self.provider.snapshot / "agents/developer.md").stat().st_mtime,
                                started - 1)

    def test_codex_failures_with_zero_exit_are_failures(self):
        with patch.object(adapter.SubprocessDispatcher, "run", return_value=stream(failed=True)):
            with self.assertRaises(DispatchFailure):
                adapter.CodexDispatcher().run(["codex"], "private prompt")

    def test_transport_errors_stop_even_with_terminal_usage(self):
        stdout = json.dumps({"type": "error", "message": "reconnecting"}) + "\n" + stream()
        with self.assertRaisesRegex(capture.AccountingError, "transport"):
            self.provider.parse(stdout, "PL")

    def test_effective_prompt_isolation_refuses_inherited_tools(self):
        self.prepare()
        effective = json.dumps([
            {"tools": [{"name": "collaboration"}]},
            {"content": [{"text": "(file: r0/skill) Plugin root: "
                          "Denied filesystem reads Network access is restricted"}]}])
        with patch.object(adapter.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, effective, "")):
            with self.assertRaisesRegex(ValueError, "isolation failed"):
                self.provider.verify_runtime({"with": self.spec("with")})

    def test_effective_prompt_requires_restrictions(self):
        self.prepare()
        effective = json.dumps([{"content": [{"text": "(file: r0/skill) Plugin root:"}]}])
        with patch.object(adapter.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, effective, "")):
            with self.assertRaisesRegex(ValueError, "restrictions"):
                self.provider.verify_runtime({"with": self.spec("with")})

    def test_rate_limit_only_classifies_error_events(self):
        self.assertIsNotNone(self.provider.detect_limit(stream(failed=True), None))
        self.assertIsNone(self.provider.detect_limit(json.dumps(
            {"type": "item.completed", "item": {"text": "usage limit"}}), None))


    def effective(self, with_role=True):
        names = sorted(p.name for p in (self.provider.homes["with"] / "skills").iterdir()) if with_role else []
        text = "\n".join(f"(file: r0/{name}/SKILL.md)" for name in names)
        text += " Denied filesystem reads Network access is restricted"
        if with_role:
            text += " Plugin root:"
        return json.dumps([{"tools": [{"name": "functions"}]}, {"content": [{"text": text}]}])

    def test_catalogue_is_stage_specific_without_exposing_snapshot_catalogue(self):
        self.prepare()
        self.provider.build_argv(self.spec("with"), "DV")
        before = {p.name for p in (self.provider.homes["with"] / "skills").iterdir()}
        self.provider.build_argv(self.spec("with"), "DR")
        after = {p.name for p in (self.provider.homes["with"] / "skills").iterdir()}
        self.assertIn("dv-screenshot-capture", before)
        self.assertNotIn("logging-conventions", after)
        self.assertNotEqual((self.provider.homes["with"] / "skills").resolve(), self.provider.snapshot / "skills")
        self.provider.build_argv(self.spec("without"), "DR")
        self.assertFalse((self.provider.homes["without"] / "skills").exists())
        self.assertFalse((self.arms / "without/.context/instructions-DR.json").exists())

    def test_effective_configuration_checks_selected_names_at_each_stage(self):
        self.prepare()
        for stage in ("PL", "DV", "DR"):
            self.provider.build_argv(self.spec("with"), stage)
            result = subprocess.CompletedProcess([], 0, self.effective(), "")
            with patch.object(adapter.subprocess, "run", return_value=result):
                self.provider.verify_stage(self.spec("with"), stage)
            self.assertIn(stage, self.provider.runtime_isolation["with"])
            runtime = json.loads((self.arms / f"with/.context/runtime-{stage}.json").read_text())
            self.assertTrue(runtime["restrictions_verified"])
        result = subprocess.CompletedProcess([], 0, self.effective().replace("r0/writing-style/", "r0/unselected/"), "")
        with patch.object(adapter.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "isolation"):
                self.provider.verify_stage(self.spec("with"), "DR")

    def test_canonical_prompt_uses_digest_and_resolves_task_requested_skill(self):
        self.prepare()
        context = self.arms / "with/.context"
        context.mkdir(exist_ok=True)
        (context / "state.json").write_text(json.dumps({"version": 2, "run_index": 0,
            "tasks": {"DV0": {"status": "pending", "metadata": {
                "context_refs": ["skills/design-review/SKILL.md"]}}}, "facts": {}}))
        prompt = dispatch.preamble.assemble_stage_prompt("DV", "task", ".context/planning-0.md", "{RAW_LEDGER}", "Implement the task")
        actual = self.provider.compose_prompt(self.spec("with"), "DV", prompt)
        self.assertNotIn("{RAW_LEDGER}", actual)
        self.assertIn("ledger: .context/state.json", actual)
        self.assertIn("## elicitation-sweep", actual)
        self.assertIn("design-review", self.provider.instruction_set("DV")["skills"])
        self.assertEqual(self.provider.compose_prompt(self.spec("without"), "DV", prompt), prompt)
        self.provider.build_argv(self.spec("with"), "DV")
        argv = self.provider.build_argv(self.spec("with"), "DV")
        developer = json.loads(next(arg.split("=", 1)[1] for arg in argv
                                    if arg.startswith("developer_instructions=")))
        self.assertEqual((developer + actual).count(self.provider.instruction_set("DV")["contract_reminder"]), 1)
        manifest = json.loads((context / "instructions-DV.json").read_text())
        self.assertIn("design-review", manifest["skills"])
        with self.assertRaisesRegex(ValueError, "composition failed"):
            self.provider.compose_prompt(self.spec("with"), "DV", prompt + " skills/absent-required/SKILL.md")

    def test_single_arm_stage_verification_does_not_change_pairing_controls(self):
        self.prepare()
        real_run = adapter.subprocess.run
        def fake(argv, **kwargs):
            if argv[0] == "codex" and "--version" in argv:
                return subprocess.CompletedProcess(argv, 0, "codex pinned", "")
            if argv[0] == "codex":
                with_role = any("Plugin root:" in arg for arg in argv)
                return subprocess.CompletedProcess(argv, 0, self.effective(with_role), "")
            return real_run(argv, **kwargs)
        with patch.object(adapter.subprocess, "run", side_effect=fake):
            self.provider.verify_runtime({name: self.spec(name) for name in ("with", "without")})
            with_era = self.provider.metadata()
            self.provider.verify_stage(self.spec("with"), "DV")
            self.assertNotIn("DV", with_era["runtime_isolation"]["with"])
            self.assertEqual(with_era, self.provider.metadata())
            self.provider.verify_stage(self.spec("without"), "DV")
            without_era = self.provider.metadata()
        from tests.test_bench_pair import arm_record
        self.assertEqual(pairing.comparability_refusals(arm_record("with", era=with_era),
                                                       arm_record("without", era=without_era)), [])


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.provider = adapter.Provider(ROOT)
        self.provider.build_argv = lambda arm, stage: ["codex", "exec", "--json", "-"]
        self.provider.validate_snapshot = lambda: None
        self.arm = ArmSpec("without", False, self.tmp.name, "")

    def tearDown(self):
        self.tmp.cleanup()

    def run_arm(self, fake, allowance=25, stages=None, policy=None):
        stages = stages or ["PL", "AR"]
        return dispatch.run_arm(
            self.arm, {s: "shared prompt" for s in stages}, fake,
            budget.RunningTally(allowance, strict=True), "", stages,
            captures_dir=self.tmp.name, provider_adapter=self.provider, limit_policy=policy)

    def test_missing_usage_stops_before_next_stage(self):
        fake = RecordingFakeDispatcher('{}')
        result = self.run_arm(fake)
        self.assertTrue(result.partial)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("unreliable", result.stop_reason)

    def test_admission_blocks_without_dispatch(self):
        fake = RecordingFakeDispatcher(stream())
        result = self.run_arm(fake, allowance=.001)
        self.assertEqual(fake.calls, [])
        self.assertTrue(result.partial)

    def test_overshoot_is_reported_and_stops_even_on_last_stage(self):
        result = self.run_arm(RecordingFakeDispatcher(stream(out=3_000_000)), stages=["PL"])
        self.assertTrue(result.partial)
        self.assertGreater(result.overshoot_usd, 5)

    def test_failed_attempt_with_unknown_usage_stops(self):
        class Fails:
            def run(self, argv, prompt):
                raise DispatchFailure(stdout='{"type":"turn.failed","error":{"message":"quota"}}')
        result = self.run_arm(Fails())
        self.assertEqual(result.stop_reason, "attempt accounting unreliable")
        self.assertEqual(len(result.attempts), 1)
        self.assertTrue(list(Path(self.tmp.name).glob("*.failed.jsonl")))

    def test_rate_limit_retry_charges_both_attempts(self):
        class Retries:
            calls = 0
            def run(self, argv, prompt):
                self.calls += 1
                if self.calls == 1:
                    raise DispatchFailure(stdout=stream(failed=True))
                return stream()
        fake = Retries()
        policy = LimitPolicy(wait=True, poll_s=1, sleep=lambda _s: None)
        result = self.run_arm(fake, stages=["PL"], policy=policy)
        self.assertEqual(fake.calls, 2)
        self.assertAlmostEqual(result.usages[0][1].cost_usd, .0041)
        self.assertEqual(len(result.attempts), 2)

    def test_effective_configuration_is_verified_before_every_stage_and_retry(self):
        self.provider.snapshot = ROOT
        self.provider.compose_prompt = lambda arm, stage, prompt: prompt
        dispatcher = adapter.CodexDispatcher()
        outputs = [stream(), DispatchFailure(stdout=stream(failed=True)), stream()]
        with patch.object(dispatcher, "run", side_effect=outputs), \
             patch.object(self.provider, "verify_stage") as verify:
            result = self.run_arm(dispatcher, stages=["PL", "AR"],
                                  policy=LimitPolicy(wait=True, poll_s=1, sleep=lambda _s: None))
        self.assertFalse(result.partial)
        self.assertEqual([call.args for call in verify.call_args_list],
                         [("without", "PL"), ("without", "AR"), ("without", "AR")])

    def test_second_stage_configuration_denial_preserves_prior_usage_and_actionable_evidence(self):
        self.provider.snapshot = ROOT
        self.provider.compose_prompt = lambda arm, stage, prompt: prompt
        dispatcher = adapter.CodexDispatcher()
        saved = []
        with patch.object(dispatcher, "run", return_value=stream()) as paid, \
             patch.object(self.provider, "verify_stage", side_effect=[None, ValueError("filesystem restrictions not applied")]):
            result = dispatch.run_arm(self.arm, {s: "prompt" for s in ("PL", "AR")}, dispatcher,
                budget.RunningTally(25, strict=True), "", ["PL", "AR"], captures_dir=self.tmp.name,
                provider_adapter=self.provider, persist_partial=lambda row: saved.append(list(row.usages)))
        self.assertEqual(paid.call_count, 1)
        self.assertEqual(result.stop_reason, "configuration verification blocked")
        self.assertTrue(result.partial)
        self.assertEqual(result.completed_stages, ["PL"])
        self.assertEqual(len(result.usages), 1)
        self.assertGreater(result.usages[0][1].cost_usd, 0)
        self.assertEqual(len(saved[-1]), 1)
        blocked = result.attempts[-1]
        self.assertEqual(blocked["stage"], "AR")
        self.assertEqual(blocked["status"], "blocked")
        self.assertIsNone(blocked["cost_usd"])
        self.assertFalse(blocked["provider_invoked"])
        self.assertIn("filesystem", blocked["reason"])
        evidence = json.loads(Path(blocked["evidence_ref"]).read_text())
        self.assertIn("before resuming", evidence["required_recovery"])

    def test_workload_fingerprint_preserves_original_bytes_and_normalizes_run_id(self):
        prompts = ROOT / "benchmark/live/prompts"
        stages = ["PL", "DV", "QA"]
        original = dispatch.assemble_prompts(str(prompts), stages, "", "run-one", ".context/planning-0.md")
        import hashlib
        expected = hashlib.sha256(dispatch.json_prompts({
            stage: text.replace("corpflow staged worktask", "staged task").replace("run-one", "<run_id>")
            for stage, text in original.items()}).encode()).hexdigest()
        self.assertEqual(dispatch.workload_fingerprint(str(prompts), stages, "", "run-one"), expected)
        self.assertEqual(dispatch.workload_fingerprint(str(prompts), stages, "", "run-two"), expected)

    def test_retry_rechecks_remaining_budget(self):
        class ExpensiveFailure:
            calls = 0
            def run(self, argv, prompt):
                self.calls += 1
                raise DispatchFailure(stdout=stream(out=2_000_000, failed=True))
        fake = ExpensiveFailure()
        result = self.run_arm(fake, policy=LimitPolicy(wait=True, sleep=lambda _s: None))
        self.assertEqual(fake.calls, 1)
        self.assertGreater(result.usages[0][1].cost_usd, 20)

    def test_partial_record_survives_failure_and_stops_other_arm(self):
        sb = make_live_sandbox(self.tmp.name)
        fake = RecordingFakeDispatcher('{}')
        provider = self.provider
        provider.prepare = lambda *a: None
        provider.metadata = lambda: {"provider": "codex", "model_pins": provider.models}
        provider.env = lambda name: {}
        provider.snapshot = ROOT
        with patch.object(dispatch, "_measure_arm", return_value=None):
            rc = dispatch._dispatch(
                sb.run_id, 50, sb.record_path, sb.benchmark_dir,
                dispatcher=fake, workdir_root=sb.workdir_root, stages=["PL", "AR"],
                selection=baseline.resolve_arm_selection("both", None, True),
                provider_adapter=provider, stderr=lambda _s: None)
        self.assertEqual(rc, 4)
        record = load_json(sb.record_path)
        self.assertTrue(record["live_partial"])
        self.assertEqual(record["era"]["provider"], "codex")
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(record["era"]["accounting"]["with"]["allowance_usd"], 25)
        self.assertEqual(record["era"]["accounting"]["with"]["stop_reason"], "not started")

    def test_codex_runs_no_claude_plugin_probe(self):
        sb = make_live_sandbox(self.tmp.name)
        provider = self.provider
        provider.prepare = lambda *a: None
        provider.metadata = lambda: {"provider": "codex", "model_pins": provider.models}
        provider.env = lambda name: {}
        provider.snapshot = ROOT

        def probe(*_args):
            raise AssertionError("codex must not run the claude preflight")

        with patch.object(dispatch, "_measure_arm", return_value=None), \
                patch.object(dispatch.preflight, "default_probe_runner", probe):
            dispatch._dispatch(
                sb.run_id, 50, sb.record_path, sb.benchmark_dir,
                dispatcher=RecordingFakeDispatcher('{}'), workdir_root=sb.workdir_root,
                stages=["PL"], selection=baseline.resolve_arm_selection("both", None, True),
                provider_adapter=provider, preflight_runner=probe, stderr=lambda _s: None)
        self.assertTrue(os.path.exists(sb.record_path))

    def test_pairing_rejects_provider_and_pricing_mismatch(self):
        for key in ("provider", "pricing", "source_digest", "model_pins", "cli_version"):
            with self.subTest(key=key):
                a = {"era": {"provider": "codex", key: "one"}}
                b = {"era": {"provider": "codex", key: "two"}}
                if key == "model_pins":
                    a["era"][key] = {"PL": "one"}
                    b["era"][key] = {"PL": "two"}
                self.assertIsNotNone(pairing._era_refusal(a["era"], b["era"]))

    def test_partial_provider_report_contains_provenance_and_stops(self):
        record = {"run_id": "probe", "mode": "live", "live_partial": True,
                  "era": {"provider": "codex", "pricing": {"id": "pinned"},
                          "accounting": {"with": {"stop_reason": "unreliable"}}}}
        html = report.render_html({"live": [record]})
        markdown = analysis.render_markdown(analysis.analyze(record))
        for output in (html, markdown):
            self.assertIn("API-equivalent", output)
            self.assertIn("unreliable", output)
            self.assertIn("pinned", output)

    def test_report_cli_renders_partial_without_rotating_history(self):
        record = {"run_id": "partial-probe", "mode": "live", "live_partial": True,
                  "era": {"provider": "codex"}}
        source = Path(self.tmp.name) / "partial.json"
        dest = Path(self.tmp.name) / "partial.html"
        source.write_text(json.dumps(record))
        result = subprocess.run(
            ["python3", str(ROOT / "benchmark/harness/bin/bench-report"),
             "--run", str(source), "--out", str(dest)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("partial-probe", dest.read_text())
        self.assertFalse((Path(self.tmp.name) / "history.json").exists())

    def test_invalid_cli_provider_or_budget_never_dispatches(self):
        cli = ROOT / "benchmark/harness/bin/bench-live"
        for extra in (["--provider", "other"], ["--budget", "nan"], ["--budget", "-1"]):
            result = subprocess.run(
                ["python3", str(cli), "--workdir", "probe", "--budget", "50",
                 "--record", str(Path(self.tmp.name) / "result.json"), *extra],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 64)
