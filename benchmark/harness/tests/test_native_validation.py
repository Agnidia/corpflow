"""Native validation distinguishes missing runtimes, service denials, and test failures."""

import hashlib
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


loader = SourceFileLoader("bench_native_check", str(Path(__file__).parents[1] / "bin/bench-native-check"))
spec = spec_from_loader(loader.name, loader)
native = module_from_spec(spec)
loader.exec_module(native)


class NativeValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = Path(self.tmp.name)
        (self.app / "TicTacToe.xcodeproj").mkdir()
        self.record = self.app / "result.json"
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake(self, service_error=False, no_runtime=False, test_error=False, passed=28, failed=0):
        def run(argv, cwd, timeout):
            self.calls.append(argv)
            status = 0
            stdout = ""
            if "runtimes" in argv:
                if service_error:
                    return subprocess.CompletedProcess(argv, 1, "", "CoreSimulator permission denied")
                runtime = {"name": "iOS 27.2", "version": "27.2", "isAvailable": True,
                           "identifier": "runtime-ios", "supportedDeviceTypes": [
                               {"name": "iPhone 17", "identifier": "type-iphone"}]}
                stdout = json.dumps({"runtimes": [] if no_runtime else [runtime]})
            elif "devices" in argv:
                stdout = json.dumps({"devices": {}})
            elif "create" in argv:
                stdout = "00000000-0000-0000-0000-000000000001\n"
            elif argv[0] == "xcodebuild":
                status = 65 if test_error else 0
                stdout = "native test output"
            elif "xcresulttool" in argv:
                stdout = json.dumps({"passedTests": passed, "failedTests": failed})
            return subprocess.CompletedProcess(argv, status, stdout, "")
        return run

    def test_service_denial_is_blocked_and_never_skipped(self):
        result = native.validate(self.app, self.record, self.fake(service_error=True))
        self.assertEqual(result["status"], "blocked")
        self.assertIn("permission denied", result["reason"])
        self.assertFalse(any(c[0] == "xcodebuild" for c in self.calls))

    def test_confirmed_missing_runtime_skips_without_building(self):
        result = native.validate(self.app, self.record, self.fake(no_runtime=True))
        self.assertEqual(result["status"], "skipped")
        self.assertEqual(len(self.calls), 1)

    def test_real_test_failure_is_not_a_pass(self):
        result = native.validate(self.app, self.record, self.fake(test_error=True))
        self.assertEqual(result["status"], "failed")
        self.assertTrue(Path(result["log"]).is_file())

    def test_success_requires_positive_result_bundle_counts(self):
        result = native.validate(self.app, self.record, self.fake())
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["summary"]["passedTests"], 28)
        command = next(c for c in self.calls if c[0] == "xcodebuild")
        self.assertIn("ONLY_ACTIVE_ARCH=YES", command)
        self.assertIn("-disableAutomaticPackageResolution", command)
        self.assertEqual(result["api_cost_usd"], 0)

    def test_empty_or_failed_result_bundle_is_blocked(self):
        for passed, failed in ((0, 0), (27, 1)):
            result = native.validate(self.app, self.record, self.fake(passed=passed, failed=failed))
            self.assertEqual(result["status"], "blocked")

    def test_missing_project_is_blocked_before_native_commands(self):
        (self.app / "TicTacToe.xcodeproj").rmdir()
        result = native.validate(self.app, self.record, self.fake())
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(self.calls, [])
