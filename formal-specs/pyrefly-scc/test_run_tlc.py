"""Runner tests: input selection and truthful model-checker outcomes."""

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_tlc


class RunnerTests(unittest.TestCase):
    def invoke(self, outcome, graph=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jar = root / "test.jar"
            jar.write_bytes(b"mocked Java invocation")
            work = root / "run"
            work.mkdir()
            argv = ["run_tlc.py", "--jar", str(jar)]
            if graph is not None:
                source = root / "RawDynamicGraph.tla"
                source.write_text(graph)
                argv += ["--graph", str(source)]
            with (
                patch("sys.argv", argv),
                patch.object(run_tlc.tempfile, "mkdtemp", return_value=str(work)),
                patch.object(run_tlc.subprocess, "run", side_effect=outcome),
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                code = run_tlc.main()
            return code, (work / "RawDynamicGraph.tla").read_text()

    def test_preserves_model_checker_failure(self):
        code, _ = self.invoke(
            lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 7)
        )
        self.assertEqual(code, 7)

    def test_timeout_is_incomplete_not_success(self):
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], 1)

        code, _ = self.invoke(timeout)
        self.assertEqual(code, 124)

    def test_supplied_graph_replaces_only_disposable_copy(self):
        graph = "---- MODULE RawDynamicGraph ----\nNodes == {}\n====\n"
        code, actual = self.invoke(
            lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0), graph
        )
        self.assertEqual(code, 0)
        self.assertEqual(actual, graph)


if __name__ == "__main__":
    unittest.main()
