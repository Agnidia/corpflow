"""The WITH arm pins the corpflow tree under test and refuses to run any other.

``--plugin-dir`` reaches only the WITH argv; the stage's ``system/init`` event is the
evidence of what loaded, so a path that does not resolve to the tree the record is
stamped for (a stale installed copy, or a shadowing failure that loads both) refuses
the run with rc 5. All dispatch is fake — zero real `claude -p` calls.
"""

import importlib
import json
import os
import shutil
import tempfile
import unittest

from benchmarkkit import pairing
from benchmarklive import capture
from benchmarklive.dispatch import CAPTURE_STREAM_JSON, build_arm_stage_argv, dispatch
from benchmarklive import isolation
from benchmarklive.plugin_load import (
    LoadedPlugin,
    check_stage_bare,
    check_stage_plugin,
    plugin_labels,
)
from benchmarklive.stage_table import HARNESS_GENERATION, build_era

import sys as _sys
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import (
    RecordingFakeDispatcher,
    fake_estimate_runner,
    load_json,
    make_live_sandbox,
    single_object_usage,
    stub_git_sha,
)

_ENV = {"ANTHROPIC_API_KEY": "k"}
_INSTALLED = "/installed/corpflow"


def init_stream(corpflow_paths, errors=None, version="9.9.9") -> str:
    """NDJSON a stream-json stage emits: an init event, then the terminal result."""
    plugins = [{"name": "context7", "path": "/cache/context7", "source": "context7@x"}]
    plugins += [{"name": "corpflow", "path": p, "source": "corpflow@x", "version": version}
                for p in corpflow_paths]
    init = {"type": "system", "subtype": "init", "plugins": plugins}
    if errors is not None:
        init["plugin_errors"] = errors
    return json.dumps(init) + "\n" + single_object_usage()


def bare_init() -> str:
    """The init a plugin-free stage emits: an empty plugins[]."""
    init = {"type": "system", "subtype": "init", "plugins": []}
    return json.dumps(init) + "\n" + single_object_usage()


class ArmAwareDispatcher:
    """Serve the WITH arm (--agent bound) and the WITHOUT arm their own init stream."""

    def __init__(self, with_stdout, without_stdout=None):
        self.calls = []
        self._with = with_stdout
        self._without = without_stdout if without_stdout is not None else bare_init()

    def run(self, argv, prompt_text):
        self.calls.append((list(argv), prompt_text))
        return self._with if "--agent" in argv else self._without


class ArgvCarriesPluginDirOnWithOnly(unittest.TestCase):
    def test_with_argv_carries_plugin_dir(self):
        argv = build_arm_stage_argv("PL", bind_agent=True, plugin_dir="/tree")
        self.assertEqual(argv[argv.index("--plugin-dir") + 1], "/tree")
        self.assertIn("--agent", argv)

    def test_without_argv_has_no_plugin_dir(self):
        argv = build_arm_stage_argv("PL", bind_agent=False)
        self.assertNotIn("--plugin-dir", argv)
        self.assertNotIn("--agent", argv)

    def test_absent_plugin_dir_leaves_argv_byte_identical(self):
        self.assertEqual(build_arm_stage_argv("PL", bind_agent=True, plugin_dir=None),
                         build_arm_stage_argv("PL", bind_agent=True))


class InitParsing(unittest.TestCase):
    def test_reads_corpflow_entries_and_errors(self):
        stream = init_stream(["/a"], errors=[{"path": "/b", "message": "bad manifest"}])
        init = capture.parse_init_plugins(stream)
        self.assertEqual([p["path"] for p in init.corpflow], ["/a"])
        self.assertEqual(init.errors, [{"path": "/b", "message": "bad manifest"}])

    def test_no_init_event_is_none(self):
        self.assertIsNone(capture.parse_init_plugins(single_object_usage()))

    def test_absent_plugin_errors_is_empty(self):
        self.assertEqual(capture.parse_init_plugins(init_stream(["/a"])).errors, [])


class CheckStagePlugin(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="plg-")
        self.tree = os.path.realpath(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_match_returns_realpath_and_version(self):
        link = os.path.join(self.tmp, "link")
        os.symlink(self.tree, link)
        check = check_stage_plugin(init_stream([link]), self.tree)
        self.assertIsNone(check.error)
        self.assertEqual(check.loaded, LoadedPlugin(path=self.tree, version="9.9.9"))

    def test_other_path_is_refused_naming_both(self):
        check = check_stage_plugin(init_stream([_INSTALLED]), self.tree)
        self.assertIn(_INSTALLED, check.error)
        self.assertIn(self.tree, check.error)

    def test_both_loading_is_a_mismatch_even_if_one_is_right(self):
        check = check_stage_plugin(init_stream([_INSTALLED, self.tree]), self.tree)
        self.assertIn("did not shadow", check.error)

    def test_plugin_errors_are_surfaced(self):
        errors = [{"path": self.tree, "message": "manifest invalid"}]
        check = check_stage_plugin(init_stream([_INSTALLED], errors=errors), self.tree)
        self.assertIn("manifest invalid", check.error)
        self.assertIn("plugin_errors", check.error)

    def test_load_error_on_the_tree_under_test_is_fatal_despite_a_path_match(self):
        errors = [{"path": self.tree, "message": "hook failed"}]
        check = check_stage_plugin(init_stream([self.tree], errors=errors), self.tree)
        self.assertIn("hook failed", check.error)

    def test_unrelated_plugin_error_does_not_fail_a_match(self):
        errors = [{"path": "/cache/other", "message": "unrelated"}]
        self.assertIsNone(check_stage_plugin(init_stream([self.tree], errors=errors),
                                             self.tree).error)

    def test_no_corpflow_loaded_is_refused(self):
        self.assertIn("not loaded", check_stage_plugin(init_stream([]), self.tree).error)

    def test_missing_init_event_is_refused_not_assumed_ok(self):
        self.assertIn("system/init", check_stage_plugin(single_object_usage(), self.tree).error)


class DispatchVerifiesLoadedPlugin(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="plgd-")
        self.sb = make_live_sandbox(self.tmp)
        # plugin_root is dirname(benchmark_dir), i.e. the sandbox root.
        self.tree = os.path.realpath(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, stdout, stages=("PL", "AR"), capture_mode=CAPTURE_STREAM_JSON,
             without_arm="skip", without_stdout=None):
        fake = ArmAwareDispatcher(stdout, without_stdout)
        warnings = []
        rc = dispatch(
            workdir=self.sb.run_id, budget=100.0, record_path=self.sb.record_path,
            benchmark_dir=self.sb.benchmark_dir, workdir_root=self.sb.workdir_root, dispatcher=fake, env=_ENV,
            estimate_runner=fake_estimate_runner(0.001), stages=list(stages),
            git_sha_runner=stub_git_sha, without_arm=without_arm,
            capture_mode=capture_mode, stderr=warnings.append)
        return rc, fake, warnings

    def test_with_dispatch_carries_plugin_dir_and_without_does_not(self):
        rc, fake, _ = self._run(init_stream([self.tree]), stages=("PL",), without_arm="real")
        self.assertNotEqual(rc, 5)
        with_calls = [a for a, _ in fake.calls if "--agent" in a]
        without_calls = [a for a, _ in fake.calls if "--agent" not in a]
        self.assertEqual(len(with_calls), 1)
        self.assertEqual(len(without_calls), 1)
        self.assertEqual(with_calls[0][with_calls[0].index("--plugin-dir") + 1], self.tree)
        self.assertNotIn("--plugin-dir", without_calls[0])

    def test_matching_path_is_accepted_and_stamped_into_era(self):
        rc, fake, _ = self._run(init_stream([self.tree]))
        self.assertNotEqual(rc, 5)
        self.assertEqual(len(fake.calls), 2)
        era = load_json(self.sb.record_path)["era"]
        self.assertEqual(era["plugin_path"], self.tree)
        self.assertEqual(era["plugin_version"], "9.9.9")

    def test_mismatch_is_refused_after_one_stage_and_names_both_paths(self):
        rc, fake, warnings = self._run(init_stream([_INSTALLED]))
        self.assertEqual(rc, 5)
        self.assertEqual(len(fake.calls), 1)
        message = "\n".join(warnings)
        self.assertIn(_INSTALLED, message)
        self.assertIn(self.tree, message)

    def test_mismatch_record_is_partial_and_records_what_actually_loaded(self):
        self._run(init_stream([_INSTALLED]))
        record = load_json(self.sb.record_path)
        self.assertTrue(record["live_partial"])
        self.assertEqual(record["era"]["plugin_path"], _INSTALLED)

    def test_shadow_failure_with_both_loaded_is_refused(self):
        rc, _, warnings = self._run(init_stream([_INSTALLED, self.tree]))
        self.assertEqual(rc, 5)
        self.assertIn("did not shadow", "\n".join(warnings))

    def test_plugin_load_errors_are_surfaced_in_the_refusal(self):
        errors = [{"path": self.tree, "message": "manifest invalid"}]
        rc, _, warnings = self._run(init_stream([_INSTALLED], errors=errors))
        self.assertEqual(rc, 5)
        self.assertIn("manifest invalid", "\n".join(warnings))

    def test_stream_without_init_event_is_refused(self):
        rc, _, _ = self._run(single_object_usage())
        self.assertEqual(rc, 5)

    def test_json_capture_is_unverified_and_stamps_no_plugin_path(self):
        rc, _, warnings = self._run(single_object_usage(), capture_mode="json")
        self.assertNotEqual(rc, 5)
        era = load_json(self.sb.record_path)["era"]
        self.assertNotIn("plugin_path", era)
        self.assertNotIn("plugins_with", era)
        self.assertIn("unverified", "\n".join(warnings))


class BaselineIsPluginFree(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="plgb-")
        self.sb = make_live_sandbox(self.tmp)
        self.tree = os.path.realpath(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _paired(self, without_stdout, stages=("PL", "AR")):
        fake = ArmAwareDispatcher(init_stream([self.tree]), without_stdout)
        warnings = []
        rc = dispatch(
            workdir=self.sb.run_id, budget=100.0, record_path=self.sb.record_path,
            benchmark_dir=self.sb.benchmark_dir, workdir_root=self.sb.workdir_root, dispatcher=fake, env=_ENV,
            estimate_runner=fake_estimate_runner(0.001), stages=list(stages),
            git_sha_runner=stub_git_sha, without_arm="real",
            capture_mode=CAPTURE_STREAM_JSON, stderr=warnings.append)
        return rc, fake, warnings

    def test_bare_check_accepts_empty_plugins(self):
        check = check_stage_bare(bare_init())
        self.assertIsNone(check.error)
        self.assertEqual(check.plugins, [])

    def test_bare_check_refuses_any_plugin_and_names_it(self):
        check = check_stage_bare(init_stream([]))
        self.assertIn("context7@unversioned", check.error)
        self.assertEqual(check.plugins, ["context7@unversioned"])

    def test_bare_check_refuses_a_stream_without_init(self):
        self.assertIn("system/init", check_stage_bare(single_object_usage()).error)

    def test_plugin_labels_are_name_at_version(self):
        self.assertEqual(
            plugin_labels([{"name": "a", "version": "1.0"}, {"name": "b"}, {"name": "c", "version": ""}]),
            ["a@1.0", "b@unversioned", "c@unversioned"])

    def test_without_loading_a_plugin_is_refused_after_one_stage(self):
        rc, fake, warnings = self._paired(init_stream([]))
        # WITHOUT dispatches first when both run; it stops at its first stage.
        self.assertEqual(rc, 5)
        without_calls = [a for a, _ in fake.calls if "--agent" not in a]
        self.assertEqual(len(without_calls), 1)
        self.assertIn("baseline arm loaded plugins", "\n".join(warnings))
        self.assertTrue(load_json(self.sb.record_path)["live_partial"])

    def test_clean_pair_stamps_both_plugin_lists(self):
        rc, _, _ = self._paired(bare_init())
        self.assertNotEqual(rc, 5)
        era = load_json(self.sb.record_path)["era"]
        self.assertEqual(era["plugins_without"], [])
        self.assertEqual(era["plugins_with"], ["context7@unversioned", "corpflow@9.9.9"])

    def test_both_arms_share_the_isolation_flags_and_differ_in_plugins(self):
        _, fake, _ = self._paired(bare_init(), stages=("PL",))
        argvs = {("with" if "--agent" in a else "without"): a for a, _ in fake.calls}
        for argv in argvs.values():
            self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
        docs = {arm: json.loads(argv[argv.index("--settings") + 1]) for arm, argv in argvs.items()}
        self.assertEqual(docs["without"]["enabledPlugins"],
                         {"agents-md@builtin": False, "telemetry@builtin": False,
                          "plugin-authoring@builtin": False, "cc-plugin-privacy@builtin": False})
        self.assertTrue(docs["with"]["enabledPlugins"]["apple-developer@apple-developer"])
        # The deny-list survives inside the inline document.
        self.assertEqual(docs["with"]["permissions"], {"deny": []})
        self.assertEqual(docs["without"]["permissions"], {"deny": []})

    def test_default_argv_without_isolation_is_unchanged(self):
        argv = build_arm_stage_argv("PL", bind_agent=False, settings_path=None)
        self.assertNotIn("--setting-sources", argv)

    def test_isolation_without_a_deny_list_path_is_refused(self):
        with self.assertRaises(ValueError):
            build_arm_stage_argv("PL", bind_agent=False, enabled_plugins={})

    def test_unreadable_deny_list_is_refused_not_dropped(self):
        with self.assertRaises(ValueError):
            isolation.settings_document(os.path.join(self.tmp, "absent.json"), {})


class ConfigDir(unittest.TestCase):
    def test_default_is_the_eval_dir(self):
        self.assertEqual(isolation.resolve_config_dir(None, {}),
                         os.path.expanduser("~/.claude-eval"))

    def test_env_beats_default_and_flag_beats_env(self):
        env = {"BENCH_CONFIG_DIR": "/tmp/from-env"}
        self.assertEqual(isolation.resolve_config_dir(None, env), "/tmp/from-env")
        self.assertEqual(isolation.resolve_config_dir("/tmp/from-flag", env), "/tmp/from-flag")

    def test_claude_env_pins_the_dir_without_mutating_the_base(self):
        base = {"PATH": "/bin"}
        child = isolation.claude_env("/cfg", base)
        self.assertEqual(child, {"PATH": "/bin", "CLAUDE_CONFIG_DIR": "/cfg"})
        self.assertEqual(base, {"PATH": "/bin"})

    def test_dispatch_probes_login_in_the_resolved_config_dir(self):
        seen = []
        # Resolved now, not at import: test_import_isolation evicts benchmarklive from
        # sys.modules, and a stale module object would be patched instead of the live one.
        credentials = importlib.import_module("benchmarklive.credentials")
        dispatch = importlib.import_module("benchmarklive.dispatch").dispatch
        real = credentials.default_auth_status_runner
        credentials.default_auth_status_runner = lambda d=None: seen.append(d) or '{"loggedIn": true}'
        tmp = tempfile.mkdtemp(prefix="plgc-")
        try:
            sb = make_live_sandbox(tmp)
            dispatch(workdir=sb.run_id, budget=100.0, record_path=sb.record_path,
                     benchmark_dir=sb.benchmark_dir, workdir_root=sb.workdir_root, dispatcher=RecordingFakeDispatcher(),
                     env={}, estimate_runner=fake_estimate_runner(0.001), stages=["PL"],
                     git_sha_runner=stub_git_sha, config_dir="/tmp/eval-cfg",
                     stderr=lambda _m: None)
        finally:
            credentials.default_auth_status_runner = real
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertEqual(seen, ["/tmp/eval-cfg"])


class EraAndPairing(unittest.TestCase):
    def test_build_era_omits_plugin_path_when_unobserved(self):
        self.assertNotIn("plugin_path", build_era())

    def test_tree_version_is_read_from_the_plugin_manifest(self):
        # A wrong root left plugin_version None on every record; with a WITH-arm stamp
        # of the loaded version that would make the two arms of a joined pair disagree.
        root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))))
        manifest = load_json(os.path.join(root, ".claude-plugin", "plugin.json"))
        self.assertEqual(build_era()["plugin_version"], manifest["version"])

    def test_build_era_stamps_observed_path_and_version(self):
        era = build_era(LoadedPlugin(path="/tree", version="1.2.3"))
        self.assertEqual((era["plugin_path"], era["plugin_version"]), ("/tree", "1.2.3"))

    def test_plugin_path_on_the_with_arm_alone_does_not_refuse_the_pair(self):
        with_era = {"harness": HARNESS_GENERATION, "prompt_contract": "scripted-cli-v3",
                    "model_pins": {"PL": "claude-opus-5-5"}, "plugin_path": "/tree"}
        without_era = {k: v for k, v in with_era.items() if k != "plugin_path"}
        self.assertIsNone(pairing._era_refusal(with_era, without_era))

    def test_current_generation_is_python_3_and_refuses_a_python_2_pair(self):
        # Out-of-repo workdirs and sub-agent-inclusive tokens moved the era boundary.
        self.assertEqual(build_era()["harness"], "python-3")
        old = {"harness": "python-2", "prompt_contract": "scripted-cli-v3", "model_pins": {}}
        new = dict(old, harness=HARNESS_GENERATION)
        self.assertIn("harness", pairing._era_refusal(old, new))

    def test_per_arm_plugin_lists_do_not_refuse_the_pair(self):
        base = {"harness": HARNESS_GENERATION, "prompt_contract": "scripted-cli-v3", "model_pins": {}}
        with_era = dict(base, plugins_with=["corpflow@4.1.0"])
        without_era = dict(base, plugins_without=[])
        self.assertIsNone(pairing._era_refusal(with_era, without_era))

    def test_join_carries_the_without_arms_plugin_list(self):
        joined = pairing._join_era({"a": 1, "plugins_with": ["x@1"]}, {"a": 1, "plugins_without": []})
        self.assertEqual(joined["plugins_with"], ["x@1"])
        self.assertEqual(joined["plugins_without"], [])

    def test_build_era_stamps_each_observed_arm_list(self):
        era = build_era(arm_plugins={"with": ["a@1"], "without": []})
        self.assertEqual((era["plugins_with"], era["plugins_without"]), (["a@1"], []))
        self.assertNotIn("plugins_with", build_era(arm_plugins={"without": []}))

    def test_other_era_keys_still_refuse_when_plugin_path_differs(self):
        a = {"harness": HARNESS_GENERATION, "prompt_contract": "scripted-cli-v3",
             "model_pins": {}, "cli_version": "1", "plugin_path": "/tree"}
        b = dict(a, cli_version="2")
        del b["plugin_path"]
        self.assertIn("cli_version", pairing._era_refusal(a, b))


if __name__ == "__main__":
    unittest.main()
