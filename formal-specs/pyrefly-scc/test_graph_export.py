"""Regression coverage for graph inputs emitted by the Alloy bridge."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

EXPORTER = (
    Path(__file__).resolve().parent / "graphs" / "alloy_trace_to_tla_constants.py"
)


def solution(node_count):
    nodes = [f"Node${i}" for i in range(node_count)]
    edges = [[node, node] for node in nodes]
    values = {node: {} for node in nodes}
    values["Params$0"] = {"step_count": [["4"]]}
    values["FullGraph$0"] = {"edges": edges}
    for index in range(4):
        values[f"Step${index}"] = {"idx": [[str(index)]], "edges": edges}
    return {"instances": [{"values": values}]}


class GraphExportTests(unittest.TestCase):
    def export(self, root, node_count):
        source = root / "solution.json"
        output = root / "RawDynamicGraph.tla"
        source.write_text(json.dumps(solution(node_count)))
        result = subprocess.run(
            [sys.executable, str(EXPORTER), str(source), str(output)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    @unittest.expectedFailure
    def test_single_node_function_is_total(self):
        # The historical exporter emits an IF without ELSE for this legal input.
        with tempfile.TemporaryDirectory() as directory:
            output = self.export(Path(directory), 1)
            self.assertNotIn('IF n = "n0"', output.read_text())

    def test_multiple_nodes_preserve_all_schedule_rows(self):
        for count in (2, 4):
            with (
                self.subTest(node_count=count),
                tempfile.TemporaryDirectory() as directory,
            ):
                text = self.export(Path(directory), count).read_text()
                for index in range(count):
                    self.assertIn(f'"n{index}"', text)
                self.assertIn("<<Step0, Step1, Step2, Step3>>", text)

    @unittest.skipUnless(
        os.environ.get("TLA2TOOLS_JAR"), "Set TLA2TOOLS_JAR for syntax validation"
    )
    @unittest.expectedFailure
    def test_single_node_module_parses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = self.export(root, 1)
            result = subprocess.run(
                [
                    "java",
                    "-cp",
                    os.environ["TLA2TOOLS_JAR"],
                    "tla2sany.SANY",
                    str(output),
                ],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("***Parse Error***", result.stdout)
            self.assertNotIn("*** Errors:", result.stdout)


if __name__ == "__main__":
    unittest.main()
