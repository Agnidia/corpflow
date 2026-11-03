"""Subprocess stdin parity (port of SubprocessStdinTests): no-input child stdin is
/dev/null (device probe) with immediate EOF (no hang); explicit input round-trips.
"""

import sys
import unittest

from benchmarkkit.genlib import Subprocess


class SubprocessStdin(unittest.TestCase):
    def test_no_input_stdin_is_dev_null(self):
        code = ("import os;print(os.fstat(0).st_rdev==os.stat('/dev/null').st_rdev)")
        r = Subprocess.run([sys.executable, "-c", code])
        self.assertEqual(r.exit_code, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "True")

    def test_no_input_child_sees_immediate_eof(self):
        # If stdin were an inherited open pipe this would hang; DEVNULL → instant EOF.
        code = "import sys;print('EOF' if sys.stdin.read()=='' else 'DATA')"
        r = Subprocess.run([sys.executable, "-c", code])
        self.assertEqual(r.stdout.strip(), "EOF")

    def test_explicit_input_round_trips(self):
        code = "import sys;sys.stdout.write(sys.stdin.read().strip())"
        r = Subprocess.run([sys.executable, "-c", code], input="hello-stdin")
        self.assertEqual(r.stdout, "hello-stdin")

    def test_timeout_returns_124(self):
        r = Subprocess.run([sys.executable, "-c", "import time;time.sleep(5)"], timeout=0.05)
        self.assertEqual(r.exit_code, 124)
        self.assertIn("timed out after", r.stderr)

    def test_timeout_keeps_already_emitted_capture(self):
        code = "import time;print('partial capture',flush=True);time.sleep(5)"
        r = Subprocess.run([sys.executable, "-c", code], timeout=0.2)
        self.assertEqual(r.exit_code, 124)
        self.assertEqual(r.stdout.strip(), "partial capture")


if __name__ == "__main__":
    unittest.main()
