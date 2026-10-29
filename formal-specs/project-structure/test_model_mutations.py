"""Real Alloy checks reject broken identities, edits, and configuration precedence."""

import contextlib
import io
import json
from pathlib import Path
import re
import tempfile
import unittest

import run_alloy

ROOT = Path(__file__).resolve().parent


class MutationTests(unittest.TestCase):
    def check_mutation(self, old, replacement, assertion, scope, kind="check", expected=0):
        core = (ROOT / "project_tree.als").read_text()
        checks = (ROOT / "project_tree_checks.als").read_text()
        self.assertEqual(core.count(old), 1)
        definitions = "\n".join(line for line in checks.splitlines()
                                if not line.startswith(("check ", "run ")))
        with tempfile.TemporaryDirectory(prefix="project-tree-mutant-") as temporary:
            directory = Path(temporary)
            (directory / "project_tree.als").write_text(core.replace(old, replacement))
            model = directory / "project_tree_checks.als"
            model.write_text(definitions + f"\n{kind} {assertion} for {scope} expect {expected}\n")
            output, diagnostics = io.StringIO(), io.StringIO()
            results = directory / "results"
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(diagnostics):
                result = run_alloy.main(["--model", str(model), "--timeout", "60",
                                         "--output", str(results)])
            self.assertEqual(result, 1, output.getvalue())
            actual = "SAT" if expected == 0 else "UNSAT"
            progress = diagnostics.getvalue().replace("\b", "").replace("\r", "")
            terminal = rf"(?m)^\d+\.\s+{kind}\s+{re.escape(assertion)}\s+[^\n]*?\b{actual}\b"
            self.assertRegex(progress, terminal)
            command = json.loads((results / "receipt.json").read_text())["commands"][assertion]
            self.assertEqual(command["type"], kind)
            self.assertEqual(command.get("expects", 0), expected)
            self.assertNotEqual(bool(command.get("solution")), bool(expected))

    def test_edit_that_leaves_old_contents_is_rejected(self):
        self.check_mutation(
            "Tree.contents' = Tree.contents ++ f -> c", "Tree.contents' = Tree.contents",
            "EditIdentityAndLocality", "1 Dir, 1 File, 2 Name, 2 Content, 1 Settings, 5 steps",
        )

    def test_unreachable_edit_witness_is_rejected(self):
        self.check_mutation(
            "pred edit[f: File, c: Content] {\n    f in files",
            "pred edit[f: File, c: Content] {\n    f not in files",
            "EditLifecycle", "1 Dir, 1 File, 2 Name, 2 Content, 1 Settings, 5 steps",
            kind="run", expected=1,
        )

    def test_create_that_reuses_retired_identity_is_rejected(self):
        self.check_mutation(
            "o not in Tree.issued", "o not in live",
            "RetiredNodesDoNotReturn", "1 Dir, 1 File, 2 Name, 1 Content, 1 Settings, 5 steps",
        )

    def test_outermost_configuration_is_rejected(self):
        self.check_mutation(
            "no (d.^children & candidates)", "no (d.^parent & candidates)",
            "NearestScopeWins", "2 Dir, 2 File, 2 Name, 2 Content, 3 Settings, 5 steps",
        )

    def test_missing_declaration_cannot_pass_config_witness(self):
        self.check_mutation(
            "(entry[d, ConfigName] & File).(Tree.contents).setting", "none",
            "NestedConfigLifecycle", "2 Dir, 3 File, 2 Name, 3 Content, 3 Settings, 8 steps",
            kind="run", expected=1,
        )

    def test_shallow_removal_cannot_pass_subtree_witness(self):
        self.check_mutation(
            "let removed = subtree[o] |", "let removed = o + o.children |",
            "RemoveNestedDirectory", "3 Dir, 1 File, 2 Name, 1 Content, 1 Settings, 6 steps",
            kind="run", expected=1,
        )

    def test_primary_model_stays_reviewable(self):
        self.assertLessEqual(len((ROOT / "project_tree.als").read_text().splitlines()), 200)


if __name__ == "__main__":
    unittest.main()
