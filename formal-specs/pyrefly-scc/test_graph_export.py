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


def asymmetric_solution():
    case = solution(3)
    values = case["instances"][0]["values"]
    values["FullGraph$0"]["edges"] = [
        ["Node$0", "Node$0"],
        ["Node$0", "Node$1"],
        ["Node$1", "Node$1"],
        ["Node$2", "Node$0"],
    ]
    steps = [
        [["Node$0", "Node$0"], ["Node$1", "Node$1"], ["Node$2", "Node$0"]],
        [["Node$0", "Node$1"], ["Node$1", "Node$1"]],
        [["Node$0", "Node$0"]],
        [["Node$0", "Node$0"], ["Node$1", "Node$1"], ["Node$2", "Node$0"]],
    ]
    for index, edges in enumerate(steps):
        values[f"Step${index}"]["edges"] = edges
    return case


class GraphExportTests(unittest.TestCase):
    def export(self, root, node_count, case=None):
        source = root / "solution.json"
        output = root / "RawDynamicGraph.tla"
        source.write_text(
            json.dumps(case if case is not None else solution(node_count))
        )
        result = subprocess.run(
            [sys.executable, str(EXPORTER), str(source), str(output)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def test_single_node_function_is_total(self):
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

    def test_distinct_steps_and_empty_rows_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            text = self.export(Path(directory), 3, asymmetric_solution()).read_text()

            def section(name):
                return text.split(f"{name} ==\n", 1)[1].split("\n\n", 1)[0]

            self.assertIn('IF n = "n0" THEN {"n0", "n1"}', section("FullGraph"))
            self.assertIn('IF n = "n0" THEN {"n0"}', section("Step0"))
            self.assertIn('ELSE {"n0"}', section("Step0"))
            self.assertIn('IF n = "n0" THEN {"n1"}', section("Step1"))
            self.assertIn("ELSE {}", section("Step1"))
            self.assertIn('ELSE IF n = "n1" THEN {}', section("Step2"))
            self.assertNotEqual(section("Step1"), section("Step2"))

    @unittest.skipUnless(
        os.environ.get("TLA2TOOLS_JAR"), "Set TLA2TOOLS_JAR for syntax validation"
    )
    def test_generated_modules_parse(self):
        cases = [(1, None), (2, None), (4, None), (3, asymmetric_solution())]
        for count, case in cases:
            with self.subTest(nodes=count), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = self.export(root, count, case)
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
