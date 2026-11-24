# test_simlog.py — self-test for simlog.py with the real Verilator patterns: a clean log passes,
# and each way a run can go wrong fails with the matching reason. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import unittest
from pathlib import Path

# Import the judge from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import simlog  # noqa: E402

PATTERNS = Path(__file__).resolve().parents[2] / "sim" / "verilator.patterns"

# A minimal passing UVM log: summary with zero counts and the end-of-test marker.
CLEAN = """UVM_INFO tb.sv(1) @ 0: uvm_test_top [CFG] B2 integer rho=1.000
TB_DONE test=smoke_test
--- UVM Report Summary ---
UVM_INFO :   12
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
"""


# Each case edits the clean log one way and checks the verdict and the reason.
class TestSimlog(unittest.TestCase):
    # Load the real rules once.
    @classmethod
    def setUpClass(cls):
        cls.rules = simlog.load_rules(PATTERNS)

    # Run the judge and return (passed, all reasons joined).
    def verdict(self, text, rc=0):
        ok, reasons = simlog.judge(text, self.rules, rc)
        return ok, " | ".join(reasons)

    # Zero counts plus both markers: PASS with no reasons.
    def test_clean_log_passes(self):
        self.assertEqual(self.verdict(CLEAN), (True, ""))

    # A scoreboard error: reported by its message line and by the summary count.
    def test_error_message_and_count_fail(self):
        log = CLEAN.replace("UVM_ERROR :    0", "UVM_ERROR :    1").replace(
            "TB_DONE", "UVM_ERROR sb.sv(9) @ 5: sb [SB_MISMATCH] got 1\nTB_DONE")
        ok, why = self.verdict(log)
        self.assertFalse(ok)
        self.assertIn("SB_MISMATCH", why)
        self.assertIn("non-zero count", why)

    # A fatal (e.g. the watchdog) ends the run before report_phase: no TB_DONE marker.
    def test_fatal_without_marker_fails(self):
        log = "UVM_FATAL t.sv(3) @ 9: t [WATCHDOG] hang\n--- UVM Report Summary ---\nUVM_ERROR :    0\nUVM_FATAL :    1\n"
        ok, why = self.verdict(log)
        self.assertFalse(ok)
        self.assertIn("WATCHDOG", why)
        self.assertIn("TB_DONE", why)

    # A failed assertion (Verilator %Error line) fails even with clean UVM counts.
    def test_assertion_failure_fails(self):
        ok, why = self.verdict(CLEAN + "%Error: t.sv:5: Assertion failed in tb_top.dut.ast_F06_x\n")
        self.assertFalse(ok)
        self.assertIn("Assertion failed", why)

    # A log cut off before the summary (crash, kill) must not pass.
    def test_truncated_log_fails(self):
        ok, why = self.verdict(CLEAN.split("--- UVM")[0])
        self.assertFalse(ok)
        self.assertIn("missing count line", why)

    # A non-zero simulator exit code fails the run whatever the log says.
    def test_nonzero_exit_fails(self):
        ok, why = self.verdict(CLEAN, rc=134)
        self.assertFalse(ok)
        self.assertIn("exit code 134", why)


if __name__ == "__main__":
    unittest.main()
