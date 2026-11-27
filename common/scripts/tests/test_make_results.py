# test_make_results.py — self-test for provenance.py and make_results.py: which paths count as
# flow inputs, CURRENT/STALE/UNKNOWN on a throwaway git repository, the README block round trip
# and --check, and the judgment of the SO-2, CDC and Q-2 sections on hand-made saved results. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

# Import the scripts from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import make_results as mr  # noqa: E402
import provenance  # noqa: E402


# Run git quietly in a test repository.
def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


# A throwaway repository with one RTL file, one doc and one commit.
def make_repo(tmp: Path) -> Path:
    repo = tmp / "r"
    (repo / "ip/x/rtl").mkdir(parents=True)
    (repo / "ip/x/docs").mkdir(parents=True)
    (repo / "ip/x/rtl/x.sv").write_text("module x; endmodule\n")
    (repo / "ip/x/docs/notes.md").write_text("notes\n")
    git(repo, "init", "-q")
    git(repo, "add", ".")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c1")
    return repo


# Which repository paths are flow inputs.
class TestIsInput(unittest.TestCase):
    # RTL, scripts, Makefiles and the vplan count; prose, figures, CI and the generator do not.
    def test_rule(self):
        for p in ("ip/a/rtl/a.sv", "Makefile", "common/scripts/regress.py", "ip/a/docs/vplan.md",
                  "ip/a/mcy/sim_runs.toml", "ip/a/constraints/cdc.toml"):
            self.assertTrue(provenance.is_input(p), p)
        for p in ("README.md", "ip/a/docs/results.md", "docs/progress.md", "ip/a/docs/figures/f.svg",
                  ".github/workflows/ci.yml", "tools_smoke/T1/t.sv", "common/scripts/make_results.py",
                  "ip/a/constraints/a.xdc", "common/scripts/tests/test_x.py", "ip/a/bugs/bugs.toml",
                  "ip/a/mcy/triage.toml"):
            self.assertFalse(provenance.is_input(p), p)


# Provenance records against a real (temporary) git repository.
class TestProvenance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = make_repo(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    # A clean record is CURRENT; editing a doc keeps it CURRENT; editing an input makes it STALE.
    def test_current_then_stale(self):
        rec = provenance.record(self.repo)
        self.assertEqual(rec["dirty"], {})
        self.assertEqual(provenance.check(rec, self.repo)[0], "CURRENT")
        (self.repo / "ip/x/docs/notes.md").write_text("changed\n")
        self.assertEqual(provenance.check(rec, self.repo)[0], "CURRENT")
        (self.repo / "ip/x/rtl/x.sv").write_text("module x; wire w; endmodule\n")
        st, det = provenance.check(rec, self.repo)
        self.assertEqual(st, "STALE")
        self.assertIn("ip/x/rtl/x.sv", det)

    # An input that was uncommitted when the flow ran, then committed unchanged, stays CURRENT;
    # a new untracked input file appearing later makes the record STALE.
    def test_dirty_then_committed(self):
        (self.repo / "ip/x/rtl/x.sv").write_text("module x; wire w; endmodule\n")
        rec = provenance.record(self.repo)
        self.assertIn("ip/x/rtl/x.sv", rec["dirty"])
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "c2")
        self.assertEqual(provenance.check(rec, self.repo)[0], "CURRENT")
        (self.repo / "ip/x/rtl/y.sv").write_text("module y; endmodule\n")
        self.assertEqual(provenance.check(rec, self.repo)[0], "STALE")

    # No record, or a commit the repository does not have, is UNKNOWN.
    def test_unknown(self):
        self.assertEqual(provenance.check(None, self.repo)[0], "UNKNOWN")
        self.assertEqual(provenance.check({"rev": "0" * 40, "dirty": {}}, self.repo)[0], "UNKNOWN")


# The README block, --check, and the section judgments.
class TestMakeResults(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    # splice() replaces exactly the block; --check passes on equal blocks and fails otherwise.
    def test_block_and_check(self):
        block = [mr.BEGIN, "| a |", mr.END]
        readme = self.dir / "README.md"
        readme.write_text(f"top\n{mr.BEGIN}\nold\n{mr.END}\nbottom\n")
        readme.write_text(mr.splice(readme.read_text(), block))
        self.assertEqual(readme.read_text(), f"top\n{mr.BEGIN}\n| a |\n{mr.END}\nbottom\n")
        page = self.dir / "results.md"
        page.write_text("# p\n" + "\n".join(block) + "\n")
        args = ["--ip-root", str(self.dir), "--page", str(page), "--readme", str(readme), "--check"]
        self.assertEqual(mr.main(args), 0)
        page.write_text("# p\n" + "\n".join([mr.BEGIN, "| b |", mr.END]) + "\n")
        self.assertEqual(mr.main(args), 1)
        with self.assertRaises(ValueError):
            mr.splice("no markers", block)

    # SO-2: met only with every run passing, N seeds per test, assertions on and identical reruns.
    def test_regress_section(self):
        out = self.dir / "out"
        (out / "regress/recheck").mkdir(parents=True)
        runs = [{"id": "t", "test": "t", "seed": i, "status": "PASS", "plusargs": ""} for i in range(3)]
        meta = {"generated": "now", "sim": "verilator", "jobs": 1, "wall_s": 1.0, "repro": "make regress"}
        (out / "regress/results.json").write_text(json.dumps({"meta": meta, "runs": runs}))
        (out / "regress/recheck/recheck.json").write_text(json.dumps({"runs": [{"repro": "x", "identical": True}]}))
        mdl = SimpleNamespace(n_seeds=3)
        self.assertTrue(mr.sec_regress(out, mdl).ok)
        self.assertFalse(mr.sec_regress(out, SimpleNamespace(n_seeds=4)).ok)        # too few seeds
        runs[0]["status"] = "FAIL"
        (out / "regress/results.json").write_text(json.dumps({"meta": meta, "runs": runs}))
        s = mr.sec_regress(out, mdl)
        self.assertFalse(s.ok)
        self.assertIn("1 run(s) did not pass", s.problems)
        self.assertFalse(mr.sec_regress(self.dir / "none", mdl).found)

    # CDC: a waived violation is met, an open one is not.
    def test_cdc_section(self):
        out = self.dir / "out"
        (out / "cdc").mkdir(parents=True)
        v = {"rule": "R1", "dest": "d", "source": "s", "msg": "m", "waived_by": "reason"}
        (out / "cdc/report.json").write_text(json.dumps({"violations": [v], "notes": []}))
        self.assertTrue(mr.sec_cdc(out).ok)
        v["waived_by"] = ""
        (out / "cdc/report.json").write_text(json.dumps({"violations": [v], "notes": []}))
        self.assertFalse(mr.sec_cdc(out).ok)

    # Q-2: a set's own problems (a survivor without a disposition, a failed gate) are reported.
    def test_mcy_section(self):
        out = self.dir / "out"
        (out / "mcy/s1").mkdir(parents=True)
        summ = {"seed": 1, "size": 10, "denominator": 9, "problems": [], "finished": "t", "repro": "make mcy",
                "counts": {"UNCOVERED": 0, "EQGAP": 0, "NOCHANGE": 1},
                "score": {"simulation": 100.0, "formal": 100.0, "combined": 100.0}}
        (out / "mcy/s1/summary.json").write_text(json.dumps(summ))
        s = mr.sec_mcy(out, ["s1"])
        self.assertTrue(s.found and s.ok)
        self.assertIn("9 non-equivalent", s.result)
        summ["problems"] = ["gate failed"]
        (out / "mcy/s1/summary.json").write_text(json.dumps(summ))
        self.assertFalse(mr.sec_mcy(out, ["s1"]).ok)
        self.assertFalse(mr.sec_mcy(out, ["s2"]).found)


if __name__ == "__main__":
    unittest.main()
