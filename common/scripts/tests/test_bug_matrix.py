# test_bug_matrix.py — self-test for bug_matrix.py's judging and reporting: bugs.toml validation,
# classification of a failing log line (assertion kinds, scoreboard, test checks), the actual
# value of every cell from saved results, the prediction comparison and its "unexplained" and
# "baseline not clean" problems, the fingerprint, and the rendered page. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import tempfile
import unittest
from pathlib import Path

# Import the script and the log rules from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bug_matrix as bm  # noqa: E402
import simlog  # noqa: E402

PATTERNS = Path(__file__).resolve().parents[2] / "sim" / "verilator.patterns"
KINDS = {"ast_e": "e2e", "ast_w": "white-box", "ast_z": "e2e"}
MATRIX = {"tests": ["a_test", "b_test"], "seeds": 2, "formal_asize": 2,
          "formal_tasks": ["bmc_bugs", "prove", "cover"], "formal_timeout": 60}

# A minimal bugs.toml; the patch file is created next to it by the tests.
TOML = """[matrix]
tests = ["a_test", "b_test"]
seeds = 2
formal_asize = 2
formal_tasks = ["bmc_bugs", "prove", "cover"]
formal_timeout = 60

[[bug]]
id = "B01"
patch = "B01_x.patch"
title = "x"
[bug.predict]
static = "no"
cdc = "no"
sim_sb = "stim"
sim_sva = "yes"
formal = "e2e"
prove = "fail"
covers_lost = []
why = "because"
"""


# Saved parts of one fake bug: two tests x two seeds, formal bmc/prove/cover.
def fake_parts(sb_fail=1, sva_fail=4, bmc_failed=("ast_e",), prove="FAIL", reached=("cov_a", "cov_b")):
    def runs(nfail):
        out = []
        for i, (t, s) in enumerate([("a_test", 1), ("a_test", 2), ("b_test", 1), ("b_test", 2)]):
            r = {"id": t, "seed": s, "status": "FAIL" if i < nfail else "PASS", "repro": f"make sim TEST={t} SEED={s}"}
            if i < nfail:
                r["first"] = {"cat": "scoreboard", "what": "SB_MISMATCH", "t": 10, "line": "UVM_ERROR x"}
            out.append(r)
        return out
    return {
        "static": {"lint": {"ok": True, "rc": 0, "seconds": 1, "repro": "make lint", "first": ""},
                   "synth": {"ok": True, "rc": 0, "seconds": 1, "repro": "make synth", "first": ""},
                   "cdc": {"ok": True, "rc": 0, "seconds": 1, "repro": "make cdc", "first": "", "rules": [],
                           "violations": []}},
        "sim_sb": {"rc": 1, "seconds": 5, "repro": "make regress", "runs": runs(sb_fail), "cov": None},
        "sim_sva": {"rc": 1, "seconds": 5, "repro": "make regress", "runs": runs(sva_fail), "cov": None},
        "formal": {
            "bmc_bugs": {"verdict": "FAIL" if bmc_failed else "PASS", "seconds": 3, "failed": list(bmc_failed),
                         "failed_steps": {lab: 4 for lab in bmc_failed}, "reached": [], "unreached": [],
                         "bad_warnings": [], "rc": 0, "repro": "make formal"},
            "prove": {"verdict": prove, "seconds": 1, "failed": [], "failed_steps": {}, "reached": [], "unreached": [],
                      "bad_warnings": [], "rc": 0, "repro": "make formal"},
            "cover": {"verdict": "PASS", "seconds": 2, "failed": [], "failed_steps": {}, "reached": list(reached),
                      "unreached": [c for c in ("cov_a", "cov_b") if c not in reached], "bad_warnings": [], "rc": 0,
                      "repro": "make formal"}}}


# Each test checks one rule of the script.
class TestBugMatrix(unittest.TestCase):
    # bugs.toml: a valid file loads with the built-in baseline first; bad values are refused.
    def test_load_bugs(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bugs.toml"
            (Path(d) / "B01_x.patch").write_text("")
            p.write_text(TOML)
            m, bugs = bm.load_bugs(p)
            self.assertEqual([b.id for b in bugs], ["base", "B01"])
            self.assertEqual(bugs[1].why, "because")
            self.assertEqual(m["seeds"], 2)
            p.write_text(TOML.replace('sim_sb = "stim"', 'sim_sb = "maybe"'))
            with self.assertRaisesRegex(ValueError, "sim_sb"):
                bm.load_bugs(p)
            p.write_text(TOML + '[bug.explain]\nnonsense = "x"\n')
            with self.assertRaisesRegex(ValueError, "unknown cells"):
                bm.load_bugs(p)
            p.write_text(TOML.replace("B01_x.patch", "missing.patch"))
            with self.assertRaisesRegex(ValueError, "not found"):
                bm.load_bugs(p)

    # A failing line is classified by the vplan kind of its label, or by the UVM message ID.
    def test_classify(self):
        f = bm.classify("[35] %Error: p.sv:9: Assertion failed in tb.dut.ast_w: msg", KINDS)
        self.assertEqual((f["cat"], f["what"], f["t"]), ("white-box", "ast_w", 35))
        self.assertEqual(bm.classify("[5] %Error: c.sv:1: Assertion failed in tb.u.cast_e", KINDS)["cat"], "e2e")
        self.assertEqual(bm.classify("[5] %Error: c.sv:1: Assertion failed in tb.u.asm_q: m", KINDS)["cat"], "assumption")
        u = bm.classify("UVM_ERROR /p/sb.sv(150) @ 1234: uvm_test_top.env.sb [SB_OVERFLOW] write #17", KINDS)
        self.assertEqual((u["cat"], u["what"], u["t"]), ("scoreboard", "SB_OVERFLOW", 1234))
        self.assertEqual(bm.classify("UVM_ERROR /p/v.sv(9) @ 7: uvm_test_top [F12_CAPACITY] r", KINDS)["cat"], "test check")
        self.assertEqual(bm.classify("%Error: something else", KINDS)["cat"], "simulator")

    # first_failure: the first line the real fail patterns match; a timeout has no log line.
    def test_first_failure(self):
        fail_res = simlog.load_rules(PATTERNS)["fail"]
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "sim.log"
            log.write_text("UVM_INFO @ 0: reporter [RNTST] Running\n"
                           "[40] %Error: p.sv:9: Assertion failed in tb.dut.ast_e: m\n"
                           "UVM_ERROR /p/sb.sv(1) @ 50: uvm_test_top.env.sb [SB_MISMATCH] d\n"
                           "UVM_ERROR :    1\n")
            self.assertEqual(bm.first_failure(log, "FAIL", fail_res, KINDS)["what"], "ast_e")
            self.assertEqual(bm.first_failure(log, "TIMEOUT", fail_res, KINDS)["cat"], "timeout")
            log.write_text("UVM_ERROR :    0\n")
            self.assertEqual(bm.first_failure(log, "FAIL", fail_res, KINDS)["cat"], "incomplete")

    # Actual cell values: stim vs yes vs no from run counts; e2e beats white-box; lost covers
    # are relative to the baseline's reached set.
    def test_actual_cells(self):
        c = bm.actual_cells(fake_parts(), KINDS, ["cov_a", "cov_b"])
        self.assertEqual(c, {"static": "no", "cdc": "no", "sim_sb": "stim", "sim_sva": "yes", "formal": "e2e",
                             "prove": "fail", "covers_lost": []})
        c = bm.actual_cells(fake_parts(sb_fail=0, sva_fail=0, bmc_failed=("ast_w",), prove="PASS",
                                       reached=("cov_a",)), KINDS, ["cov_a", "cov_b"])
        self.assertEqual((c["sim_sb"], c["sim_sva"], c["formal"], c["prove"], c["covers_lost"]),
                         ("no", "no", "white-box", "pass", ["cov_b"]))
        c = bm.actual_cells(fake_parts(bmc_failed=()), KINDS, None)
        self.assertEqual((c["formal"], c["covers_lost"]), ("no", None))
        self.assertEqual(bm.actual_cells({}, KINDS, None)["static"], None)

    # Differences: a mismatch without an explanation is a problem; with one it is not; a
    # baseline mismatch is always a problem; a missing part is reported.
    def test_problems(self):
        bug = bm.Bug("B01", "B01_x.patch", "x", {"static": "no", "cdc": "no", "sim_sb": "yes", "sim_sva": "yes", "formal": "e2e",
                                                "prove": "fail", "covers_lost": []})
        base = bm.Bug("base", "", "b", {"static": "no", "cdc": "no", "sim_sb": "no", "sim_sva": "no", "formal": "no",
                                       "prove": "pass", "covers_lost": []})
        clean = fake_parts(sb_fail=0, sva_fail=0, bmc_failed=(), prove="PASS")
        res = {"base": clean, "B01": fake_parts()}
        probs = bm.problems([base, bug], res, {}, KINDS)
        self.assertEqual(probs, ["B01: sim_sb differs from the prediction and has no explanation in bugs.toml"])
        bug.explain["sim_sb"] = "thrash tests never fill"
        self.assertEqual(bm.problems([base, bug], res, {}, KINDS), [])
        res["base"] = fake_parts(sb_fail=1, sva_fail=0, bmc_failed=(), prove="PASS")
        self.assertIn("baseline is not clean: sim_sb = stim", bm.problems([base, bug], res, {}, KINDS))
        del res["B01"]["formal"]
        self.assertTrue(any("no result for formal" in p for p in bm.problems([base, bug], res, {}, KINDS)))
        self.assertTrue(any("stale" in p for p in bm.problems([base, bug], res, {"B01": ["sim_sb"]}, KINDS)))

    # A timed-out cover run is bounded, not an error: unreached covers count as lost, the cell says so.
    def test_cover_timeout(self):
        parts = fake_parts(reached=("cov_a",))
        parts["formal"]["cover"].update(verdict="TIMEOUT", unreached=[], last_step=52)
        c = bm.actual_cells(parts, KINDS, ["cov_a", "cov_b"])
        self.assertEqual(c["covers_lost"], ["cov_b"])
        self.assertEqual(bm.show_cell("covers_lost", c["covers_lost"], parts, MATRIX), "1/2, lost 1 (timeout at step 52)")
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "logfile.txt"
            log.write_text("Checking cover reachability in step 51..\nChecking cover reachability in step 52..\n")
            self.assertEqual(bm.last_step(log), 52)
            self.assertIsNone(bm.last_step(Path(d) / "none.txt"))

    # The formal cell's step is the first failure of the reported kind: e2e at 10 even when a
    # white-box label failed first, at 5.
    def test_formal_step_by_kind(self):
        parts = fake_parts(bmc_failed=("ast_w", "ast_e"))
        parts["formal"]["bmc_bugs"]["failed_steps"] = {"ast_w": 5, "ast_e": 10}
        self.assertEqual(bm.show_cell("formal", "e2e", parts, MATRIX, KINDS), "e2e @10")

    # A failing cdc check is its own cell, separate from lint/synth.
    def test_cdc_cell(self):
        parts = fake_parts()
        parts["static"]["cdc"].update(ok=False, rc=1, rules=["R2"], violations=["stage 1 feeds logic"])
        c = bm.actual_cells(parts, KINDS, None)
        self.assertEqual((c["static"], c["cdc"]), ("no", "yes"))
        self.assertEqual(bm.show_cell("cdc", "yes", parts, MATRIX), "caught: R2")

    # Absolute repository paths leave the page: $PWD in a make variable, relative elsewhere.
    def test_shorten(self):
        t = "repro `make sim RTL_DIR=/r/x/out/b/rtl` and UVM_ERROR /r/x/ip/tb.sv(3)"
        self.assertEqual(bm.shorten(t, Path("/r/x")), "repro `make sim RTL_DIR=$PWD/out/b/rtl` and UVM_ERROR ip/tb.sv(3)")

    # The fingerprint follows file contents, the matrix settings and the patch.
    def test_fingerprint(self):
        with tempfile.TemporaryDirectory() as d:
            f, p = Path(d) / "a.sv", Path(d) / "p.patch"
            f.write_text("x")
            p.write_text("y")
            a = bm.fingerprint([f], "base", MATRIX, p)
            self.assertEqual(a, bm.fingerprint([f], "base", MATRIX, p))
            f.write_text("x2")
            self.assertNotEqual(a, bm.fingerprint([f], "base", MATRIX, p))
            self.assertNotEqual(bm.fingerprint([f], "base", MATRIX, None),
                                bm.fingerprint([f], "base", {**MATRIX, "seeds": 3}, None))

    # The page: summary row with a check mark or the differing prediction, per-test counts, the
    # bug section with its first failing run and the UNEXPLAINED marker.
    def test_render(self):
        base = bm.Bug("base", "", "b", {"static": "no", "cdc": "no", "sim_sb": "no", "sim_sva": "no", "formal": "no",
                                       "prove": "pass", "covers_lost": []}, why="baseline")
        bug = bm.Bug("B01", "B01_x.patch", "Full test wrong", {"static": "no", "cdc": "no", "sim_sb": "yes", "sim_sva": "yes",
                                                               "formal": "e2e", "prove": "fail", "covers_lost": []},
                     why="predicted so")
        res = {"base": fake_parts(sb_fail=0, sva_fail=0, bmc_failed=(), prove="PASS"), "B01": fake_parts()}
        page = bm.render([base, bug], res, {}, MATRIX, {"B01": {"bug": "x", "violates": "F06", "expected": "y"}},
                         KINDS, "make bugs")
        self.assertIn("| B01 Full test wrong | pass ✓ | pass ✓ | 1/4 **≠ yes** | 4/4 ✓ | e2e @4 ✓ | FAIL ✓ | 2/2 ✓ |", page)
        self.assertIn("| B01 | 1 · 2 | 0 · 2 |", page)
        self.assertIn("First failing run: a_test seed 1", page)
        self.assertIn("**UNEXPLAINED**", page)
        self.assertIn("Violates F06", page)


if __name__ == "__main__":
    unittest.main()
