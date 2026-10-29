import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import run_alloy


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"Invariant": ("check", 0), "Example": ("run", 1)}
        self.receipt = {"commands": {
            "Invariant": {"type": "check"},
            "Example": {"type": "run", "expects": 1, "solution": [{}]},
        }}

    def verify(self, receipt=None):
        with contextlib.redirect_stdout(io.StringIO()):
            run_alloy.verify_receipt(receipt or self.receipt, self.expected)

    def test_expected_sat_and_unsat(self):
        self.verify()

    def test_unexpected_counterexample_is_failure(self):
        self.receipt["commands"]["Invariant"]["solution"] = [{}]
        with self.assertRaisesRegex(ValueError, "Unexpected SAT"):
            self.verify()

    def test_unsatisfiable_example_is_failure(self):
        self.receipt["commands"]["Example"].pop("solution")
        with self.assertRaisesRegex(ValueError, "Unexpected UNSAT"):
            self.verify()

    def test_incomplete_receipt_is_failure(self):
        self.receipt["commands"].pop("Invariant")
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.verify()

    def test_wrong_type_is_failure(self):
        self.receipt["commands"]["Invariant"]["type"] = "run"
        with self.assertRaisesRegex(ValueError, "Wrong command type"):
            self.verify()

    def test_wrong_expectation_is_failure(self):
        self.receipt["commands"]["Invariant"]["expects"] = 1
        with self.assertRaisesRegex(ValueError, "Wrong receipt expectation"):
            self.verify()

    def test_malformed_solution_is_failure(self):
        self.receipt["commands"]["Example"]["solution"] = "SAT"
        with self.assertRaisesRegex(ValueError, "Malformed solutions"):
            self.verify()

    def test_manifest_requires_explicit_named_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "checks.als"
            model.write_text("check Invariant for 3 expect 0\nrun Example for 3 expect 1\n")
            self.assertEqual(run_alloy.expectations(model), self.expected)
            for source in ["sig File {}\n", "run { some File } for 3 expect 1\n",
                           "check Invariant for 3\n",
                           "check Invariant for 3 expect 0\ncheck Invariant for 3 expect 0\n"]:
                with self.subTest(source=source):
                    model.write_text(source)
                    with self.assertRaises(ValueError):
                        run_alloy.expectations(model)

    def run_main(self, model, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()), patch("run_alloy.run_checker", **kwargs):
            return run_alloy.main(["--model", str(model)])

    def test_zero_exit_without_receipt_is_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "checks.als"
            model.write_text("check Invariant for 3 expect 0\n")
            self.assertEqual(self.run_main(model, return_value=subprocess.CompletedProcess([], 0)), 1)

    def test_timeout_is_not_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "checks.als"
            model.write_text("check Invariant for 3 expect 0\n")
            error = subprocess.TimeoutExpired("alloy", 1)
            self.assertEqual(self.run_main(model, side_effect=error), 124)

    def test_checker_failure_is_not_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "checks.als"
            model.write_text("check Invariant for 3 expect 0\n")
            self.assertEqual(self.run_main(model, return_value=subprocess.CompletedProcess([], 7)), 7)

    def test_terminal_results_required(self):
        progress = "00. check Invariant 0 UNSAT\n01. run Example 0 1/1 SAT\n"
        run_alloy.verify_completions(progress, self.expected)
        with self.assertRaisesRegex(ValueError, "completion"):
            run_alloy.verify_completions("01. run Example 0 1/1 SAT\n", self.expected)
        with self.assertRaisesRegex(ValueError, "command error"):
            run_alloy.verify_completions(progress + "Error\n  0. command failed\n", self.expected)

    def test_zero_exit_and_failed_check_metadata_do_not_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "checks.als"
            model.write_text("check Invariant for 3 expect 0\nrun Example for 3 expect 1\n")
            def failed_command(command, env, timeout):
                output = Path(command[command.index("-o") + 1])
                output.mkdir()
                (output / "receipt.json").write_text(json.dumps(self.receipt))
                return subprocess.CompletedProcess(command, 0, "",
                    "00. check Invariant\n01. run Example 0 1/1 SAT\nError\n  0. command could not be solved\n")
            self.assertEqual(self.run_main(model, side_effect=failed_command), 1)

    def test_nonobject_receipt_is_failure(self):
        with self.assertRaisesRegex(ValueError, "JSON object"):
            run_alloy.verify_receipt([], self.expected)

    def test_interrupts_cleanup_process_group(self):
        previous = signal.getsignal(signal.SIGTERM)
        for kind, exception in [("interrupt", KeyboardInterrupt), ("terminate", SystemExit)]:
            with self.subTest(kind=kind):
                process = Mock(pid=123456)
                def communicate(**kwargs):
                    if process.communicate.call_count == 1:
                        if kind == "terminate":
                            signal.raise_signal(signal.SIGTERM)
                        raise KeyboardInterrupt
                    return "", ""
                process.communicate.side_effect = communicate
                with patch("run_alloy.subprocess.Popen", return_value=process), \
                        patch("run_alloy.os.killpg") as kill, self.assertRaises(exception):
                    run_alloy.run_checker(["alloy"], os.environ.copy(), 1)
                kill.assert_called_once_with(process.pid, signal.SIGKILL)
                self.assertEqual(process.communicate.call_count, 2)
                self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_interrupts_during_launch_cleanup_process_group(self):
        previous = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        for signum, exception in [(signal.SIGINT, KeyboardInterrupt), (signal.SIGTERM, SystemExit)]:
            with self.subTest(signum=signum):
                process = Mock(pid=123456)
                process.communicate.return_value = ("", "")
                def launch(*args, **kwargs):
                    signal.raise_signal(signum)
                    return process
                with patch("run_alloy.subprocess.Popen", side_effect=launch), \
                        patch("run_alloy.os.killpg") as kill, self.assertRaises(exception):
                    run_alloy.run_checker(["alloy"], os.environ.copy(), 1)
                kill.assert_called_once_with(process.pid, signal.SIGKILL)
                self.assertEqual(process.communicate.call_count, 1)
                for s, handler in previous.items():
                    self.assertEqual(signal.getsignal(s), handler)

    def test_timeout_stops_launcher_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            heartbeat = Path(temporary) / "heartbeat"
            child = ("import time; from pathlib import Path\n"
                     f"p = Path({str(heartbeat)!r})\n"
                     "while True:\n p.write_text(str(time.monotonic_ns()))\n time.sleep(.02)\n")
            launcher = ("import subprocess, sys, time\n"
                        f"subprocess.Popen([sys.executable, '-c', {child!r}])\n"
                        "time.sleep(60)\n")
            with self.assertRaises(subprocess.TimeoutExpired):
                run_alloy.run_checker([sys.executable, "-c", launcher], os.environ.copy(), .8)
            self.assertTrue(heartbeat.exists())
            time.sleep(.08)
            stopped = heartbeat.read_text()
            time.sleep(.08)
            self.assertEqual(heartbeat.read_text(), stopped)

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "results"
            output.mkdir()
            sentinel = output / "keep.txt"
            sentinel.write_text("keep")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                run_alloy.main(["--output", str(output)])
            self.assertEqual(error.exception.code, 2)
            self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
