# test_mcy.py — self-test for the M9 MCY scripts: cov_subset.py's greedy choice (every point kept,
# one run per entry first, a failing regression refused), mcy_run.py's config rendering, mutation
# parsing and short forms, scores, and the problems that keep a run from being done (missing or
# stale disposition, EQGAP, ERROR), and mcy_task.py's batch reading. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Import the scripts from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cov_subset  # noqa: E402
import mcy_run  # noqa: E402
import mcy_task  # noqa: E402

CMD = ("mutate -mode cnot1 -module async_fifo -cell $procdff$112 -port Q -portbit 0 -ctrlbit 1 "
       "-wire wq2_rptr -wirebit 0 -src async_fifo.sv:58.44-58.52 -src async_fifo.sv:101.3-109.6")


# A row as mcy_run.collect() builds it, with the given tags, results and disposition.
def row(i, tags, results=None, triage=None, short="inv w[0] at procdff.Q[0]"):
    res = results or {"test_sim": "FAIL", "test_eq": "FAIL", "test_fm": "FAIL"}
    return {"id": i, "mutation": "m", "short": short, "line": 1, "stmt": "x", "results": res,
            "tags": sorted(tags), "details": {"test_sim": {}, "test_eq": {}, "test_fm": {}}, "triage": triage}


# cov_subset.py: the choice and its refusal of a failing regression.
class CovSubset(unittest.TestCase):
    # Greedy: seeds one run per entry, then covers the rest; the universe is fully covered.
    def test_choose_covers_universe(self):
        runs = [{"id": "a", "seed": 1, "seconds": 1.0}, {"id": "a", "seed": 2, "seconds": 1.0},
                {"id": "b", "seed": 1, "seconds": 1.0}, {"id": "b", "seed": 2, "seconds": 0.5}]
        pts = [{"p1"}, {"p1", "p2", "p3"}, {"p4"}, {"p4", "p5"}]
        chosen, gains = cov_subset.choose(runs, pts, per_entry=1)
        self.assertEqual(set().union(*(pts[i] for i in chosen)), {"p1", "p2", "p3", "p4", "p5"})
        self.assertEqual(chosen, [1, 3])          # best of a, best of b; nothing else needed
        self.assertEqual(gains, [3, 2])

    # A regression with a failing run is refused (exit 1).
    def test_failing_regression_refused(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "results.json").write_text(json.dumps({"meta": {}, "runs": [
                {"id": "a", "test": "a", "seed": 1, "plusargs": "", "status": "FAIL", "run_dir": d, "seconds": 1}]}))
            self.assertEqual(cov_subset.main(["--regress", d, "--out", str(Path(d) / "x.toml")]), 1)


# mcy_run.py: rendering, parsing, scoring, problems.
class McyRun(unittest.TestCase):
    # The template's placeholders, size and seed lines are filled; a missing seed line is an error.
    def test_render_config(self):
        with tempfile.TemporaryDirectory() as d:
            t = Path(d) / "config.mcy"
            t.write_text("# a comment with @ in it\n[options]\nsize 300\nseed 1\n[script]\nchparam -set ASIZE @ASIZE@ x\n")
            out = mcy_run.render_config(t, 2, 4, 50, 7)
            self.assertIn("size 50\n", out)
            self.assertIn("seed 7\n", out)
            self.assertIn("-set ASIZE 2 ", out)
            t.write_text("[options]\nsize 300\n")
            with self.assertRaises(mcy_run.SetupError):
                mcy_run.render_config(t, 2, 4, 50, 7)

    # Options of a mutate command; the short form names mode, bit, cell port and ctrlbit.
    def test_parse_and_short(self):
        p = mcy_run.parse_mutation(CMD)
        self.assertEqual(p["wire"], "wq2_rptr")
        self.assertEqual(p["src"], ["async_fifo.sv:58.44-58.52", "async_fifo.sv:101.3-109.6"])
        self.assertEqual(mcy_run.short(p), "cnot1 wq2_rptr[0] at procdff.Q[0] ctrlbit 1")
        self.assertEqual(mcy_run.statement(p, ["l"] * 100 + ["  stmt;  "] + ["l"] * 10), (101, "stmt;"))

    # Scores: simulation misses FMONLY, formal misses SIMONLY, NOCHANGE is outside the denominator.
    def test_scores(self):
        rows = [row(1, {"COVERED"}), row(2, {"COVERED", "FMONLY"}), row(3, {"COVERED", "SIMONLY"}),
                row(4, {"UNCOVERED"}), row(5, {"NOCHANGE"})]
        sc = mcy_run.scores(rows)
        self.assertEqual(sc["denominator"], 4)
        self.assertEqual(sc["detected"], {"simulation": 2, "formal": 2, "combined": 3})
        self.assertEqual(sc["score"]["combined"], 75.0)

    # Problems: no disposition, stale disposition, EQGAP, ERROR; a current disposition is fine.
    def test_problems(self):
        ok = row(1, {"UNCOVERED"}, triage={"mutation": "inv w[0] at procdff.Q[0]"})
        self.assertEqual(mcy_run.problems([ok]), [])
        probs = mcy_run.problems([
            row(2, {"UNCOVERED"}),
            row(3, {"COVERED", "FMONLY"}, triage={"mutation": "other"}),
            row(4, {"EQGAP"}, triage={"mutation": "inv w[0] at procdff.Q[0]"}),
            row(5, {"COVERED"}, results={"test_sim": "ERROR", "test_eq": "FAIL", "test_fm": "FAIL"})])
        text = "\n".join(probs)
        self.assertIn("mutant 2", text)
        self.assertIn("stale disposition", text)
        self.assertIn("EQGAP", text)
        self.assertIn("ERROR", text)


# mcy_task.py: the batch as MCY hands it over.
class McyTask(unittest.TestCase):
    # input.txt idx/command pairs, joined with the database ids from MUTATIONS.
    def test_read_batch(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "input.txt"
            p.write_text("1 mutate -mode inv -x 1\n2 mutate -mode const0 -y 2\n")
            os.environ["MUTATIONS"] = "17 42"
            try:
                muts = mcy_task.read_batch(p)
            finally:
                del os.environ["MUTATIONS"]
            self.assertEqual([(m.idx, m.mid) for m in muts], [(1, 17), (2, 42)])
            self.assertEqual(muts[1].cmd, "mutate -mode const0 -y 2")


if __name__ == "__main__":
    unittest.main()
