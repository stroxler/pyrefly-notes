"""Failure-classification and native temporal evidence controls (stdlib only)."""

import copy
from pathlib import Path
import tempfile
import unittest

import check


class OutcomeTests(unittest.TestCase):
    def fixture(self, sat=False):
        expected = {"Control": {
            "kind": "check", "sat": sat, "min_states": 1, "max_states": 4,
            "executions": 1, "threads": 1,
        }}
        command = {
            "type": "check", "minprefix": 1, "maxprefix": 4,
            "scopes": ["exactly 1 Execution", "exactly 1 ThreadState"],
        }
        lassos = {}
        if sat:
            values = {"Execution$0": {field: [] for field in check.FIELDS}}
            command.update(expects=1, solution=[{"instances": [{"values": values}]}])
            lassos["Control"] = {"states": 1, "loop_start": 0, "min_states": 1, "max_states": 4}
        receipt = {"commands": {"Control": command}}
        log = "00. check Control 0\b\b 1/1 SAT\n" if sat else "00. check Control 0 UNSAT\n"
        return receipt, expected, log, lassos

    def test_expected_assertion_failure_is_a_success(self):
        args = self.fixture(sat=True)
        self.assertEqual(check.validate(*args)["Control"]["status"], "SAT")

    def test_unsat_receipt_omits_zero_expectation(self):
        self.assertEqual(check.validate(*self.fixture())["Control"]["status"], "UNSAT")

    def test_unexpected_counterexample_is_a_failure(self):
        receipt, expected, log, lassos = self.fixture(sat=True)
        expected["Control"]["sat"] = False
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_tooling_error_is_not_unsat(self):
        receipt, expected, _, lassos = self.fixture()
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, "Syntax error: unresolved field", lassos)

    def test_incomplete_run_is_not_unsat(self):
        receipt, expected, _, lassos = self.fixture()
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, "00. check Control 0", lassos)

    def test_missing_receipt_command_is_a_failure(self):
        receipt, expected, log, lassos = self.fixture()
        receipt["commands"] = {}
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_changed_temporal_bound_is_a_failure(self):
        receipt, expected, log, lassos = self.fixture()
        receipt["commands"]["Control"]["maxprefix"] = 3
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_missing_loop_evidence_is_a_failure(self):
        receipt, expected, log, _ = self.fixture(sat=True)
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, {})

    def test_invalid_loop_target_is_a_failure(self):
        receipt, expected, log, lassos = self.fixture(sat=True)
        lassos["Control"]["loop_start"] = 1
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_incomplete_native_states_are_a_failure(self):
        receipt, expected, log, lassos = self.fixture(sat=True)
        lassos["Control"]["states"] = 2
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_missing_execution_field_is_a_failure(self):
        receipt, expected, log, lassos = self.fixture(sat=True)
        values = receipt["commands"]["Control"]["solution"][0]["instances"][0]["values"]
        del values["Execution$0"]["installed"]
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_out_of_order_native_states_are_a_failure(self):
        receipt, expected, log, lassos = self.fixture(sat=True)
        receipt["commands"]["Control"]["solution"][0]["instances"][0]["state"] = 2
        with self.assertRaises(ValueError):
            check.validate(receipt, expected, log, lassos)

    def test_thread_state_identities_remain_distinct(self):
        self.assertNotEqual(check.atom("m/ThreadState$0"), check.atom("m/ThreadState$1"))

    def test_xml_loop_bounds_and_count(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.xml"
            path.write_text('<alloy><instance tracelength="1" looplength="1" mintrace="1" maxtrace="4"/></alloy>')
            self.assertEqual(check.read_lasso(path)["loop_start"], 0)
            path.write_text('<alloy><instance tracelength="2" looplength="1" mintrace="1" maxtrace="4"/></alloy>')
            with self.assertRaises(ValueError):
                check.read_lasso(path)


if __name__ == "__main__":
    unittest.main()
