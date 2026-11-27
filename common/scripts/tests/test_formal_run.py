# test_formal_run.py — self-test for formal_run.py: the .sby rewrite (sizes, absolute sources,
# timeout, refusal of a template without exactly one chparam line), log judging (verdicts,
# failed labels from both log forms, covers, cover-to-trace mapping, forbidden Yosys warnings)
# and the EXPECT rules. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import tempfile
import unittest
from pathlib import Path

# Import the script from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formal_run  # noqa: E402

# A minimal template in the shape of ip/async_fifo/formal/async_fifo.sby.
TEMPLATE = """[tasks]
prove
[options]
mode prove
multiclock on
[engines]
smtbmc yices
[script]
read -formal a.sv
chparam -set ASIZE 3 -set DSIZE 4 top
prep -top top
[files]
a.sv
"""

# SBY log fragments as the installed version writes them (seen in M7 runs).
LOG_INDUCT_FAIL = """SBY 1 [x] engine_0.induction: ##   0:00:01  Assert failed in top.p_e2e: ast_F03_order
SBY 1 [x] summary: counterexample trace [induction]: x/engine_0/trace_induct.vcd
SBY 1 [x] summary:   failed assertion top.p_e2e.ast_F03_order at f.sv:1.1-1.2
SBY 1 [x] DONE (UNKNOWN, rc=4)
"""
LOG_COVER = """SBY 1 [x] engine_0: ##   0:00:00  Reached cover statement in step 3 at top.p_e2e: cov_a
SBY 1 [x] engine_0: ##   0:00:00  Reached cover statement in step 9 at top: cov_b
SBY 1 [x] DONE (PASS, rc=0)
"""
STATUS_COVER = """cover trace: engine_0/trace0.vcd
cover trace: engine_0/trace0.yw
  reached cover statement top.p_e2e.cov_a at f.sv:1 step 3
cover trace: engine_0/trace1.vcd
  reached cover statement top.cov_b at f.sv:2 step 9
"""


# Each case is one template or log shape and what formal_run must make of it.
class TestFormalRun(unittest.TestCase):
    # Write the template and its source into a temporary directory.
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "a.sv").write_text("module top; endmodule\n")
        self.sby = self.dir / "t.sby"
        self.sby.write_text(TEMPLATE)

    # Remove the temporary directory.
    def tearDown(self):
        self.tmp.cleanup()

    # Sizes are rewritten, the source becomes "name absolute-path", the timeout lands in [options].
    def test_make_sby_rewrites(self):
        out = formal_run.make_sby(self.sby, 2, 5, {}, 60)
        self.assertIn("chparam -set ASIZE 2 -set DSIZE 5 top", out)
        self.assertIn(f"a.sv {(self.dir / 'a.sv').resolve()}", out)
        self.assertIn("[options]\ntimeout 60", out)

    # --opt replaces the template line with the same key, or adds a new one.
    def test_make_sby_options(self):
        out = formal_run.make_sby(self.sby, 3, 4, {}, None, ["mode bmc", "cover: depth 170"])
        self.assertIn("mode bmc", out)
        self.assertNotIn("mode prove", out)
        self.assertIn("cover: depth 170", out)

    # --src NAME=PATH replaces the default source (how RTL_DIR/DUT_SRCS reach formal).
    def test_make_sby_src_override(self):
        alt = self.dir / "patched.sv"
        alt.write_text("module top; endmodule\n")
        out = formal_run.make_sby(self.sby, 3, 4, {"a.sv": alt}, None)
        self.assertIn(f"a.sv {alt.resolve()}", out)
        self.assertNotIn("timeout", out)

    # A template without exactly one chparam line, or with a missing source, is refused.
    def test_make_sby_refuses(self):
        self.sby.write_text(TEMPLATE.replace("chparam -set ASIZE 3 -set DSIZE 4 top\n", ""))
        with self.assertRaises(ValueError):
            formal_run.make_sby(self.sby, 3, 4, {}, None)
        self.sby.write_text(TEMPLATE.replace("a.sv\n", "missing.sv\n"))
        with self.assertRaises(FileNotFoundError):
            formal_run.make_sby(self.sby, 3, 4, {}, None)

    # Induction failure: UNKNOWN, the label (from both log forms, once), the induction trace.
    def test_parse_induction_failure(self):
        r = formal_run.Run("prove", 3)
        formal_run.parse_log(r, LOG_INDUCT_FAIL)
        self.assertEqual((r.verdict, r.failed, r.traces), ("UNKNOWN", ["ast_F03_order"], ["x/engine_0/trace_induct.vcd"]))
        self.assertFalse(r.ok())
        r.expect = "any"
        self.assertTrue(r.ok())
        r.expect = "nopass"
        self.assertTrue(r.ok())

    # Cover: covers with their first step, and each cover mapped to its trace from the status file.
    def test_parse_keep_going_steps(self):
        # --keep-going bmc: each label's first failing step, repeats marked "[failed before]".
        log = ("SBY 1 [x] engine_0: ##   0:00:00  Checking assertions in step 4..\n"
               "SBY 1 [x] engine_0: ##   0:00:00  Assert failed in top: ast_a\n"
               "SBY 1 [x] engine_0: ##   0:00:00  Checking assertions in step 9..\n"
               "SBY 1 [x] engine_0: ##   0:00:00  Assert failed in top: ast_a [failed before]\n"
               "SBY 1 [x] engine_0: ##   0:00:00  Assert failed in top.p_e2e: ast_b\n"
               "SBY 1 [x] DONE (FAIL, rc=2)\n")
        r = formal_run.parse_run("bmc_bugs:2:fail")
        formal_run.parse_log(r, log)
        self.assertEqual(r.failed, ["ast_a", "ast_b"])
        self.assertEqual(r.failed_steps, {"ast_a": 4, "ast_b": 9})

    def test_parse_cover(self):
        r = formal_run.Run("cover", 3)
        formal_run.parse_log(r, LOG_COVER, STATUS_COVER)
        self.assertEqual(r.reached, {"cov_a": 3, "cov_b": 9})
        self.assertEqual(r.cover_traces, {"cov_a": "engine_0/trace0.vcd", "cov_b": "engine_0/trace1.vcd"})
        self.assertTrue(r.ok())

    # A hierarchical reference turned into a free wire (T18) fails even a passing run.
    def test_forbidden_warning(self):
        r = formal_run.Run("prove", 3)
        formal_run.parse_log(r, "base: f.sv:3: Warning: Identifier `\\u.c' is implicitly declared.\nDONE (PASS, rc=0)\n")
        self.assertEqual(r.verdict, "PASS")
        self.assertEqual(len(r.bad_warnings), 1)
        self.assertFalse(r.ok())

    # EXPECT fail accepts only FAIL; no DONE line at all is an ERROR; bad specs are refused.
    def test_expect_and_specs(self):
        r = formal_run.parse_run("audit_a01:2:fail")
        formal_run.parse_log(r, "DONE (FAIL, rc=2)\n")
        self.assertTrue(r.ok())
        formal_run.parse_log(r, "crashed\n")
        self.assertEqual(r.verdict, "ERROR")
        self.assertFalse(r.ok())
        for bad in ("prove", "prove:x", "prove:3:maybe"):
            with self.assertRaises(ValueError):
                formal_run.parse_run(bad)


if __name__ == "__main__":
    unittest.main()
