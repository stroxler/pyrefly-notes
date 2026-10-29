"""Real Alloy checks must reject three broken model variants in both outcome directions."""

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
        core = (ROOT / "flat_files.als").read_text()
        checks = (ROOT / "flat_files_checks.als").read_text()
        self.assertEqual(core.count(old), 1)
        # Retain assertion definitions, but run just the selected regression.
        definitions = "\n".join(line for line in checks.splitlines()
                                if not line.startswith(("check ", "run ")))
        with tempfile.TemporaryDirectory(prefix="flat-files-mutant-") as temporary:
            directory = Path(temporary)
            (directory / "flat_files.als").write_text(core.replace(old, replacement))
            model = directory / "flat_files_checks.als"
            model.write_text(definitions + f"\n{kind} {assertion} for {scope} expect {expected}\n")
            output = io.StringIO()
            results = directory / "results"
            diagnostics = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(diagnostics):
                result = run_alloy.main(["--model", str(model), "--timeout", "60",
                                         "--output", str(results)])
            self.assertEqual(result, 1, output.getvalue())
            actual = "SAT" if expected == 0 else "UNSAT"
            progress = diagnostics.getvalue().replace("\b", "").replace("\r", "")
            terminal = rf"(?m)^\d+\.\s+{kind}\s+{re.escape(assertion)}\s+[^\n]*?\b{actual}\b"
            self.assertRegex(progress, terminal)
            # The CLI itself may fail on an expectation mismatch. Inspect the
            # receipt so a parser error or timeout cannot pass this regression.
            receipt = json.loads((results / "receipt.json").read_text())
            command = receipt["commands"][assertion]
            self.assertEqual(command["type"], kind)
            self.assertEqual(command.get("expects", 0), expected)
            self.assertNotEqual(bool(command.get("solution")), bool(expected))

    def test_edit_that_leaves_old_contents_is_rejected(self):
        self.check_mutation(
            "Directory.contents' = Directory.contents ++ n.(Directory.entries) -> c",
            "Directory.contents' = Directory.contents",
            "EditIsLocal", "1 Name, 1 File, 2 Content, 5 steps",
        )

    def test_unreachable_edit_witness_is_rejected(self):
        self.check_mutation(
            "pred edit[n: Name, c: Content] {\n    some n.(Directory.entries)",
            "pred edit[n: Name, c: Content] {\n    no n.(Directory.entries)",
            "EditLifecycle", "1 Name, 1 File, 2 Content, 5 steps", kind="run", expected=1,
        )

    def test_create_that_reuses_retired_identity_is_rejected(self):
        self.check_mutation(
            "f not in Directory.issued", "f not in live",
            "RetiredFilesDoNotReturn", "1 Name, 1 File, 1 Content, 5 steps",
        )


if __name__ == "__main__":
    unittest.main()
