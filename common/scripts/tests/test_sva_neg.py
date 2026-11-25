# test_sva_neg.py — self-test for sva_neg.py's judging rules with the real Verilator patterns:
# a case passes only when its label fails at the first failing time after the fault; the clean
# run must fire nothing; the bench's case list must match the plan. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import unittest
from pathlib import Path

# Import the script and its log rules from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import simlog  # noqa: E402
import sva_neg  # noqa: E402

PATTERNS = Path(__file__).resolve().parents[2] / "sim" / "verilator.patterns"


# Build a Verilator-style assertion failure line at time t for a label.
def fail_line(t: int, label: str) -> str:
    return f"[{t}] %Error: p.sv:9: Assertion failed in tb.dut.{label}: details"


# Each case is one log shape and the verdict it must get.
class TestSvaNeg(unittest.TestCase):
    # Load the real rules once.
    @classmethod
    def setUpClass(cls):
        cls.rules = simlog.load_rules(PATTERNS)

    # Judge a broken run's log for label ast_a.
    def judge(self, *lines: str) -> sva_neg.Case:
        return sva_neg.judge_case(sva_neg.Case(label="ast_a"), "\n".join(lines), self.rules)

    # Target and another label fail at the first failing time: PASS, the other is co-fired;
    # a later failure of a third label is not part of the set.
    def test_target_with_cofire_passes(self):
        c = self.judge("SVA_NEG inject ast_a at 5: force x", fail_line(40, "ast_b"), fail_line(40, "ast_a"),
                       fail_line(50, "ast_c"), "SVA_NEG end")
        self.assertEqual((c.status, c.fired, c.fault, c.first_time), ("PASS", ["ast_a", "ast_b"], "force x", "40"))

    # A failure before the fault line makes the case invalid.
    def test_failure_before_inject_fails(self):
        c = self.judge(fail_line(3, "ast_a"), "SVA_NEG inject ast_a at 5: force x", fail_line(40, "ast_a"))
        self.assertEqual(c.status, "FAIL")
        self.assertIn("before the fault", c.reasons[0])

    # The target fails only after another label's first failure: FAIL (it was not the first).
    def test_target_only_later_fails(self):
        c = self.judge("SVA_NEG inject ast_a at 5: f", fail_line(40, "ast_b"), fail_line(60, "ast_a"))
        self.assertEqual(c.status, "FAIL")
        self.assertIn("did not fail at the first failing time 40", c.reasons[0])

    # Nothing fails, or the case never ran, or a non-assertion error comes first: FAIL.
    def test_no_failure_or_no_inject_or_other_error(self):
        self.assertIn("nothing failed", self.judge("SVA_NEG inject ast_a at 5: f", "SVA_NEG end").reasons[0])
        self.assertIn("case not run", self.judge(fail_line(40, "ast_a")).reasons[0])
        c = self.judge("SVA_NEG inject ast_a at 5: f", "%Error: tb.sv:3: $fatal", fail_line(40, "ast_a"))
        self.assertIn("not an assertion", c.reasons[0])

    # Clean run: quiet with the end marker passes; any failure, a missing end or exit != 0 fails.
    def test_clean_run(self):
        self.assertEqual(sva_neg.judge_clean("SVA_NEG end", 0, self.rules), [])
        self.assertTrue(sva_neg.judge_clean(fail_line(9, "ast_a") + "\nSVA_NEG end", 0, self.rules))
        self.assertTrue(sva_neg.judge_clean("", 0, self.rules))
        self.assertTrue(sva_neg.judge_clean("SVA_NEG end", 1, self.rules))

    # Case list against the plan: a missing label, an unknown one and a duplicate are reported.
    def test_case_list_against_plan(self):
        self.assertEqual(sva_neg.check_cases(["ast_a", "asm_b"], ["ast_a"], {"asm_b": "why"}), [])
        probs = sva_neg.check_cases(["ast_a", "asm_b"], ["ast_a", "ast_a", "ast_z"], {})
        self.assertEqual(len(probs), 3)

    # Concurrent twins: found by label in source text; a twin must be in its immediate twin's
    # first-failure set; a missing set member or a twin without an immediate case is a problem.
    def test_twins(self):
        src = "cast_a: assert property (@(posedge c) x);\ncast_b: assert property (@(posedge c) y);\ncast_q: assert property (z);"
        twins = sva_neg.TWIN_RE.findall(src)
        self.assertEqual(twins, ["cast_a", "cast_b", "cast_q"])
        cases = [sva_neg.Case(label="ast_a", fired=["ast_a", "cast_a"]), sva_neg.Case(label="ast_b", fired=["ast_b"])]
        rows, probs = sva_neg.check_twins(twins, cases)
        self.assertEqual([ok for *_, ok in rows], [True, False, False])
        self.assertEqual(len(probs), 2)


if __name__ == "__main__":
    unittest.main()
