"""Plugin-isolation preflight: verdicts, probe argv parity, and the rc 5 gate.

Every probe goes through an injected runner and every stage through a fake
dispatcher, so no test here starts ``claude`` or spends money.
"""

import json
import os
import shutil
import sys as _sys
import tempfile
import unittest
from unittest import mock

from benchmarklive import baseline, budget, isolation
from benchmarklive.arm_exec import ArmSpec
from benchmarklive.dispatch import dispatch
from benchmarklive.providers.claude import models, plugin_load, preflight

_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import (  # noqa: E402
    RecordingFakeDispatcher,
    TripwireDispatcher,
    fake_estimate_runner,
    make_live_sandbox,
    single_object_usage,
    stub_git_sha,
)

_ENV = {"ANTHROPIC_API_KEY": "k"}
PRIVACY = {"name": "cc-plugin-privacy", "path": "builtin", "source": "cc-plugin-privacy@builtin"}
APPLE = {"name": "apple-developer", "path": "/cache/apple-developer",
         "source": "apple-developer@apple-developer", "version": "2.0.0"}
EXTRA = {"name": "swift-lsp", "path": "/cache/swift-lsp", "source": "swift-lsp@market",
         "version": "1.0.0"}


def corpflow(root):
    return {"name": "corpflow", "path": root, "version": "4.1.4"}


def probe_stdout(plugins, cost=0.003):
    init = json.dumps({"type": "system", "subtype": "init", "plugins": plugins,
                       "plugin_errors": []})
    return init + "\n" + single_object_usage(cost=cost)


class FakeProbeRunner:
    """Answers per arm, keyed by the cwd's basename (``with`` / ``without``)."""

    def __init__(self, by_arm):
        self.by_arm = by_arm
        self.calls = []

    def __call__(self, argv, prompt, env, cwd):
        arm = os.path.basename(cwd)
        self.calls.append({"arm": arm, "argv": list(argv), "prompt": prompt,
                           "env": dict(env), "cwd": cwd})
        out = self.by_arm[arm]
        if isinstance(out, Exception):
            raise out
        return out


def tripwire_seed(argv, env, cwd):
    raise AssertionError("ledger seed must not run after a preflight refusal")


class ExactPluginSetVerdict(unittest.TestCase):
    ROOT = os.path.realpath(tempfile.gettempdir())
    SIBLINGS = isolation.SIBLING_PLUGINS

    def check(self, plugins):
        return plugin_load.check_exact_plugin_set(probe_stdout(plugins), self.ROOT, self.SIBLINGS)

    def test_tree_under_test_plus_each_sibling_passes(self):
        result = self.check([corpflow(self.ROOT), APPLE])
        self.assertIsNone(result.error)
        self.assertEqual(result.plugins, ["corpflow@4.1.4", "apple-developer@2.0.0"])

    def test_a_missing_sibling_refuses(self):
        self.assertIn("apple-developer@apple-developer", self.check([corpflow(self.ROOT)]).error)

    def test_an_extra_plugin_refuses_and_is_named(self):
        error = self.check([corpflow(self.ROOT), APPLE, PRIVACY]).error
        self.assertIn("unexpected plugins", error)
        self.assertIn("cc-plugin-privacy", error)

    def test_a_sibling_loaded_twice_refuses(self):
        self.assertIn("more than once", self.check([corpflow(self.ROOT), APPLE, APPLE]).error)

    def test_corpflow_from_another_tree_refuses(self):
        self.assertIsNotNone(self.check([corpflow("/elsewhere/corpflow"), APPLE]).error)

    def test_name_is_the_key_when_source_is_absent(self):
        bare_apple = {k: v for k, v in APPLE.items() if k != "source"}
        self.assertIsNone(self.check([corpflow(self.ROOT), bare_apple]).error)
        bare_extra = {k: v for k, v in EXTRA.items() if k != "source"}
        self.assertIsNotNone(self.check([corpflow(self.ROOT), bare_apple, bare_extra]).error)

    def test_a_foreign_source_with_a_sibling_name_refuses(self):
        fork = dict(APPLE, source="apple-developer@someone-else")
        self.assertIsNotNone(self.check([corpflow(self.ROOT), fork]).error)

    def test_no_init_event_refuses(self):
        result = plugin_load.check_exact_plugin_set(single_object_usage(), self.ROOT, self.SIBLINGS)
        self.assertIn("no system/init", result.error)


class ProbeArmVerdict(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="probe-")
        self.settings = os.path.join(self.tmp, "settings.json")
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write('{"permissions": {"deny": []}}')
        self.arm = ArmSpec(name="without", bind_agent=False,
                           enabled_plugins=isolation.enabled_plugins(with_siblings=False),
                           cwd=os.path.join(self.tmp, "without"), audit_path="")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def verdict(self, out):
        return preflight.probe_arm(self.arm, self.settings, {}, FakeProbeRunner({"without": out}))

    def test_a_clean_baseline_passes_and_reports_the_cost(self):
        v = self.verdict(preflight.ProbeOutput(probe_stdout([], cost=0.0042), 0))
        self.assertTrue(v.ok)
        self.assertEqual(v.plugins, [])
        self.assertAlmostEqual(v.cost_usd, 0.0042)
        self.assertIn("$0.0042", preflight.describe(v))

    def test_a_failing_probe_refuses_even_with_a_clean_init(self):
        v = self.verdict(preflight.ProbeOutput(probe_stdout([]), 1))
        self.assertFalse(v.ok)
        self.assertIn("rc 1", v.reason)

    def test_a_timed_out_probe_refuses(self):
        v = self.verdict(preflight.ProbeOutput("", 124, "timed out"))
        self.assertFalse(v.ok)
        self.assertIn("timed out", v.reason)

    def test_a_probe_with_no_init_event_refuses(self):
        v = self.verdict(preflight.ProbeOutput(single_object_usage(), 0))
        self.assertFalse(v.ok)
        self.assertIn("no system/init", v.reason)

    def test_a_runner_that_raises_refuses(self):
        v = self.verdict(OSError("spawn failed"))
        self.assertFalse(v.ok)
        self.assertIn("spawn failed", v.reason)

    def test_a_usage_limit_on_the_probe_refuses_and_says_so(self):
        text = "You've hit your session limit · resets 7pm (Europe/Kiev)"
        stdout = "\n".join(json.dumps(e) for e in (
            {"type": "system", "subtype": "init", "plugins": []},
            {"type": "result", "is_error": True, "api_error_status": 429, "result": text}))
        v = self.verdict(preflight.ProbeOutput(stdout, 1))
        self.assertFalse(v.ok)
        self.assertIn("usage limit", v.reason)

    def test_an_unreadable_deny_list_refuses_instead_of_probing(self):
        os.remove(self.settings)
        v = self.verdict(preflight.ProbeOutput(probe_stdout([]), 0))
        self.assertFalse(v.ok)
        self.assertIn("deny-list", v.reason)


class PreflightGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="preflight-")
        self.sb = make_live_sandbox(self.tmp)
        self.root = os.path.realpath(self.tmp)
        self.config_dir = os.path.join(self.tmp, "eval-config")
        self.warnings = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def outputs(self, with_plugins=None, without_plugins=()):
        with_plugins = [corpflow(self.root), APPLE] if with_plugins is None else with_plugins
        return {"with": preflight.ProbeOutput(probe_stdout(with_plugins), 0),
                "without": preflight.ProbeOutput(probe_stdout(list(without_plugins)), 0)}

    def run_dispatch(self, runner, dispatcher, stages=("PL",), arm="both", **kw):
        return dispatch(
            workdir=self.sb.run_id, budget=100.0, record_path=self.sb.record_path,
            benchmark_dir=self.sb.benchmark_dir, workdir_root=self.sb.workdir_root,
            dispatcher=dispatcher, env=_ENV, estimate_runner=fake_estimate_runner(0.001),
            stages=list(stages), git_sha_runner=stub_git_sha, config_dir=self.config_dir,
            selection=baseline.resolve_arm_selection(
                arm, None, baseline.stages_subset(list(stages), budget.PIPELINE_STAGES)),
            preflight_runner=runner, stderr=self.warnings.append, **kw)

    def assert_refused_before_anything(self, rc):
        self.assertEqual(rc, 5)
        self.assertFalse(os.path.exists(self.sb.record_path))

    def test_privacy_builtin_on_the_baseline_refuses_with_zero_dispatches(self):
        runner = FakeProbeRunner(self.outputs(without_plugins=[PRIVACY]))
        rc = self.run_dispatch(runner, TripwireDispatcher(), seed_runner=tripwire_seed)
        self.assert_refused_before_anything(rc)
        refusal = [w for w in self.warnings if w.startswith("live run refused")]
        self.assertEqual(len(refusal), 1)
        self.assertIn("without arm", refusal[0])
        self.assertIn("cc-plugin-privacy", refusal[0])

    def test_with_arm_missing_a_sibling_refuses(self):
        runner = FakeProbeRunner(self.outputs(with_plugins=[corpflow(self.root)]))
        rc = self.run_dispatch(runner, TripwireDispatcher(), seed_runner=tripwire_seed)
        self.assert_refused_before_anything(rc)
        self.assertTrue(any("with arm" in w and "apple-developer" in w for w in self.warnings))

    def test_with_arm_with_an_extra_plugin_refuses(self):
        runner = FakeProbeRunner(self.outputs(with_plugins=[corpflow(self.root), APPLE, EXTRA]))
        rc = self.run_dispatch(runner, TripwireDispatcher(), seed_runner=tripwire_seed)
        self.assert_refused_before_anything(rc)
        self.assertTrue(any("swift-lsp" in w for w in self.warnings))

    def test_the_exact_sets_pass_and_the_stages_dispatch(self):
        fake = RecordingFakeDispatcher()
        rc = self.run_dispatch(FakeProbeRunner(self.outputs()), fake)
        self.assertEqual(rc, 0)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(sum(w.startswith("preflight: ") for w in self.warnings), 2)

    def test_every_probe_fault_refuses_with_zero_dispatches(self):
        faults = {"no init": preflight.ProbeOutput(single_object_usage(), 0),
                  "rc 1": preflight.ProbeOutput(probe_stdout([]), 1),
                  "timeout": preflight.ProbeOutput("", 124),
                  "raised": OSError("no claude on PATH")}
        for label, fault in faults.items():
            for arm in ("with", "without"):
                with self.subTest(fault=label, arm=arm):
                    outputs = self.outputs()
                    outputs[arm] = fault
                    rc = self.run_dispatch(FakeProbeRunner(outputs), TripwireDispatcher(),
                                           seed_runner=tripwire_seed)
                    self.assert_refused_before_anything(rc)

    def test_both_arms_are_probed_even_after_the_first_refuses(self):
        runner = FakeProbeRunner(self.outputs(without_plugins=[PRIVACY],
                                              with_plugins=[corpflow(self.root)]))
        self.run_dispatch(runner, TripwireDispatcher(), seed_runner=tripwire_seed)
        self.assertEqual([c["arm"] for c in runner.calls], ["without", "with"])
        self.assertEqual(sum(w.startswith("live run refused") for w in self.warnings), 2)

    def test_a_subset_or_single_arm_run_still_certifies_both_configurations(self):
        for label, arm in (("--stages PL subset", None), ("--arm with", "with")):
            with self.subTest(run=label):
                runner = FakeProbeRunner(self.outputs())
                rc = self.run_dispatch(runner, RecordingFakeDispatcher(), arm=arm)
                self.assertEqual(rc, 0)
                self.assertEqual(sorted(c["arm"] for c in runner.calls), ["with", "without"])

    def test_the_probe_runs_in_the_arm_cwd_under_the_eval_config_dir(self):
        runner = FakeProbeRunner(self.outputs())
        self.run_dispatch(runner, RecordingFakeDispatcher())
        for call in runner.calls:
            self.assertEqual(os.path.realpath(call["cwd"]),
                             os.path.realpath(self.sb.arm_dir(call["arm"])))
            self.assertEqual(call["env"]["CLAUDE_CONFIG_DIR"], os.path.abspath(self.config_dir))
            self.assertEqual(call["prompt"], preflight.PROBE_PROMPT)

    def test_an_injected_dispatcher_without_a_runner_never_probes(self):
        tripwire = mock.Mock(side_effect=AssertionError("default probe must not run"))
        with mock.patch.object(preflight, "default_probe_runner", tripwire):
            rc = self.run_dispatch(None, RecordingFakeDispatcher())
        self.assertEqual(rc, 0)
        tripwire.assert_not_called()

    def test_production_wiring_uses_the_default_runner(self):
        fake = FakeProbeRunner(self.outputs(without_plugins=[PRIVACY]))
        with mock.patch.object(preflight, "default_probe_runner", fake), \
                mock.patch("benchmarklive.arm_exec.SubprocessDispatcher.run",
                           side_effect=AssertionError("no stage may start")):
            rc = self.run_dispatch(None, None, seed_runner=tripwire_seed)
        self.assertEqual(rc, 5)
        self.assertEqual(len(fake.calls), 2)


class ProbeArgvParity(unittest.TestCase):
    """The probe's plugin-bearing flags equal the same arm's stage argv, value for value."""

    FLAGS = ("--setting-sources", "--settings", "--plugin-dir", "--permission-mode")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="probe-argv-")
        self.sb = make_live_sandbox(self.tmp)
        root = os.path.realpath(self.tmp)
        self.runner = FakeProbeRunner({
            "with": preflight.ProbeOutput(probe_stdout([corpflow(root), APPLE]), 0),
            "without": preflight.ProbeOutput(probe_stdout([]), 0)})
        self.fake = RecordingFakeDispatcher()
        rc = dispatch(
            workdir=self.sb.run_id, budget=100.0, record_path=self.sb.record_path,
            benchmark_dir=self.sb.benchmark_dir, workdir_root=self.sb.workdir_root,
            dispatcher=self.fake, env=_ENV, estimate_runner=fake_estimate_runner(0.001),
            stages=["PL"], git_sha_runner=stub_git_sha,
            selection=baseline.resolve_arm_selection("both", None, None),
            preflight_runner=self.runner, stderr=lambda _s: None)
        self.assertEqual(rc, 0)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    @staticmethod
    def value(argv, flag):
        return argv[argv.index(flag) + 1] if flag in argv else None

    def test_plugin_flags_match_the_stage_argv_field_by_field(self):
        stage = {("with" if "--agent" in argv else "without"): argv for argv, _ in self.fake.calls}
        probe = {c["arm"]: c["argv"] for c in self.runner.calls}
        self.assertEqual(sorted(stage), ["with", "without"])
        for arm in ("with", "without"):
            for flag in self.FLAGS:
                with self.subTest(arm=arm, flag=flag):
                    self.assertEqual(self.value(probe[arm], flag), self.value(stage[arm], flag))
        self.assertIsNotNone(self.value(probe["with"], "--plugin-dir"))
        self.assertIsNone(self.value(probe["without"], "--plugin-dir"))

    def test_probe_is_the_cheapest_model_streamed_and_capped_at_one_turn(self):
        self.assertEqual(preflight.PROBE_MODEL, models.MODEL_PINS["haiku"])
        for call in self.runner.calls:
            argv = call["argv"]
            self.assertEqual(argv[:2], ["claude", "-p"])
            self.assertEqual(self.value(argv, "--model"), "claude-haiku-5-5")
            self.assertEqual(self.value(argv, "--output-format"), "stream-json")
            self.assertIn("--verbose", argv)
            self.assertEqual(self.value(argv, "--max-turns"), "1")
            self.assertNotIn("--agent", argv)
            self.assertNotIn("--effort", argv)

    def test_the_baseline_settings_switch_off_every_builtin(self):
        probe = next(c["argv"] for c in self.runner.calls if c["arm"] == "without")
        plugins = json.loads(self.value(probe, "--settings"))["enabledPlugins"]
        self.assertEqual(plugins, {name: False for name in isolation.BUILTIN_PLUGINS})
        self.assertIn("cc-plugin-privacy@builtin", plugins)


if __name__ == "__main__":
    unittest.main()
