# test_regress.py — self-test for regress.py: configuration rules, run classification (pass,
# fail, timeout, missing log), reports, and the coverage merge check, using a fake simulator so it
# runs in seconds. The real-tool merge case needs verilator_coverage on PATH (make adds it). Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import json
import os
import shutil
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

# Import the runner from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import regress  # noqa: E402

# A fake `make sim`: argv = id seed out mode bin. Writes <out>/run/<id>_<seed>/sim.log (a clean
# UVM-style log, or one with an error, or none), a coverage.dat whose covergroup bin <bin> is
# hit, and prints a repro line, as the real flow does.
FAKE_SIM = textwrap.dedent(r'''
    import sys, time, pathlib
    rid, seed, out, mode, hit = sys.argv[1:6]
    d = pathlib.Path(out) / "run" / f"{rid}_{seed}"; d.mkdir(parents=True, exist_ok=True)
    print(f"  repro: fake rerun {rid} {seed}")
    if mode == "hang": time.sleep(30)
    if mode == "nolog": sys.exit(0)
    err = "UVM_ERROR sb.sv(1) @ 5: sb [SB_MISMATCH] got 1\n" if mode == "fail" else ""
    d.joinpath("sim.log").write_text("UVM_INFO t.sv(1) @ 0: t [CFG] B2 integer\n" + err + "TB_DONE test=x\n"
        "--- UVM Report Summary ---\nUVM_ERROR :    %d\nUVM_FATAL :    0\n" % (1 if err else 0))
    def rec(b, c, ign=False):
        k = "\x01t\x02covergroup\x01page\x02v_covergroup/p::c::cg\x01f\x02x.sv\x01l\x0210\x01B\x02%s%s\x01h\x02p::c::cg.cp_a.%s" % (
            b, "\x01Bt\x02ignore" if ign else "", b)
        return "C '%s' %d\n" % (k, c)
    line = "C '\x01t\x02line\x01page\x02v_line/dut\x01f\x02dut.sv\x01l\x023\x01o\x02if\x01h\x02top.dut' 1\n"
    d.joinpath("coverage.dat").write_text("# SystemC::Coverage-3\n" + "".join(
        rec(b, 1 if b == hit else 0) for b in ("lo", "mid", "hi")) + rec("bad", 0, True) + line)
    sys.exit(1 if mode == "fail" else 0)
''')


# Each case builds its own temporary block: tests.toml, the fake simulator, an out/ directory.
class TestRegress(unittest.TestCase):
    # Fresh temporary tree per test.
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "fake_sim.py").write_text(FAKE_SIM)
        self.out = self.tmp / "out" / "blk"

    # Remove the temporary tree.
    def tearDown(self):
        shutil.rmtree(self.tmp)

    # Write tests.toml with the fake flow and the given [[test]] tables; return its path.
    def toml(self, tests: str, flow_extra: str = "") -> Path:
        p = self.tmp / "tests.toml"
        p.write_text(textwrap.dedent(f'''
            [flow]
            dir     = "."
            build   = "true"
            run     = "{sys.executable} fake_sim.py {{id}} {{seed}} {{out}} {{plusargs}}"
            run_dir = "{{out}}/run/{{id}}_{{seed}}"
            {flow_extra}
            [defaults]
            seeds = 2
            timeout_s = 20
        ''') + textwrap.dedent(tests))
        return p

    # Run main() quietly; return (exit status, results.json data or None).
    def regress(self, *args: str):
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc = regress.main(["--out", str(self.out), *args])
        res = self.out / "regress" / "results.json"
        return rc, json.loads(res.read_text()) if res.is_file() else None

    # Defaults fill missing keys; --seeds replaces the default only; --only filters by id.
    def test_config_defaults_override_filter(self):
        p = self.toml('''
            [[test]]
            name = "a"
            [[test]]
            name = "a"
            id = "a_b4"
            seeds = 5
            plusargs = "pass mid"
        ''')
        flow, es = regress.load_config(p)
        self.assertEqual([(e.id, e.name, e.seeds) for e in es], [("a", "a", 2), ("a_b4", "a", 5)])
        self.assertEqual(Path(flow["dir"]), self.tmp)
        _, es = regress.load_config(p, seeds=3)
        self.assertEqual([(e.id, e.seeds) for e in es], [("a", 3), ("a_b4", 5)])
        _, es = regress.load_config(p, only=["a_b4"])
        self.assertEqual([e.id for e in es], ["a_b4"])

    # Each malformed configuration is an error, never a partial run.
    def test_config_errors(self):
        bad = {
            "duplicate id": '[[test]]\nname = "a"\n[[test]]\nname = "a"\n',
            "unknown key": '[[test]]\nname = "a"\nseed = 3\n',
            "no name": '[[test]]\nid = "a"\n',
            "quote": '[[test]]\nname = "a"\nplusargs = "+X=\'1\'"\n',
        }
        for why, tests in bad.items():
            with self.subTest(why):
                with self.assertRaises(regress.ConfigError):
                    regress.load_config(self.toml(tests))
        with self.assertRaises(regress.ConfigError):
            regress.load_config(self.toml('[[test]]\nname = "a"\n', flow_extra='extra = "x"'))
        with self.assertRaises(regress.ConfigError):
            regress.fill("run {nope}", sim="v")
        with self.assertRaises(regress.ConfigError):
            regress.load_config(self.toml('[[test]]\nname = "a"\n'), only=["zz"])

    # Pass, fail, timeout and missing-log runs are classified; reports name every failure with
    # its rerun command; the exit status is 1. Uses a fake merge tool (see fake_merge).
    def test_classification_and_reports(self):
        self.fake_merge(correct=True)
        p = self.toml('''
            [[test]]
            name = "ok"
            plusargs = "pass lo"
            [[test]]
            name = "bad"
            seeds = 1
            plusargs = "fail lo"
            [[test]]
            name = "hang"
            seeds = 1
            timeout_s = 1
            plusargs = "hang lo"
            [[test]]
            name = "nolog"
            seeds = 1
            plusargs = "nolog lo"
        ''')
        rc, res = self.regress("--tests", str(p))
        self.assertEqual(rc, 1)
        st = {(r["id"], r["seed"]): r for r in res["runs"]}
        self.assertEqual([st[("ok", 1)]["status"], st[("ok", 2)]["status"]], ["PASS", "PASS"])
        self.assertEqual(st[("bad", 1)]["status"], "FAIL")
        self.assertIn("SB_MISMATCH", " ".join(st[("bad", 1)]["reasons"]))
        self.assertIn("make exit code 1", " ".join(st[("bad", 1)]["reasons"]))
        self.assertEqual(st[("hang", 1)]["status"], "TIMEOUT")
        self.assertLess(st[("hang", 1)]["seconds"], 10)
        self.assertEqual(st[("nolog", 1)]["status"], "FAIL")
        self.assertEqual(st[("bad", 1)]["repro"], "fake rerun bad 1")
        self.assertEqual(st[("ok", 1)]["cfg"], "B2 integer")
        summary = (self.out / "regress" / "summary.md").read_text()
        self.assertIn("rerun: `fake rerun bad 1`", summary)
        self.assertIn("FAIL: 2/5 runs passed", summary)
        suites = {s.get("name"): s for s in ET.parse(self.out / "regress" / "junit.xml").getroot()}
        self.assertEqual((suites["ok"].get("failures"), suites["bad"].get("failures")), ("0", "1"))
        # Only the two passing runs are merged.
        self.assertEqual(json.loads((self.out / "cov" / "functional.json").read_text())["merged_runs"], 2)

    # Install a fake verilator_coverage on PATH. correct=True: --write sums like the real tool;
    # False: writes every count as 0, which the per-run sum check must catch.
    def fake_merge(self, correct: bool):
        tool = self.tmp / "bin" / "verilator_coverage"
        tool.parent.mkdir()
        tool.write_text(textwrap.dedent(f'''\
            #!{sys.executable}
            import sys
            sys.path.insert(0, {str(Path(regress.__file__).parent)!r})
            import regress
            a = sys.argv[1:]
            if a[0] == "--annotate": sys.exit(0)
            tot = {{}}
            for f in a[2:]:
                for k, v in regress.VerilatorCoverage.read(__import__("pathlib").Path(f)).items():
                    tot[k] = tot.get(k, 0) + v
            open(a[1], "w", encoding="utf-8", errors="surrogateescape").write(
                "".join("C '%s' %d\\n" % (k, v if {correct} else 0) for k, v in tot.items()))
        '''))
        tool.chmod(0o755)
        old = os.environ["PATH"]
        os.environ["PATH"] = f"{tool.parent}{os.pathsep}{old}"
        self.addCleanup(os.environ.__setitem__, "PATH", old)

    # A merge tool that disagrees with the per-run sum fails the regression (plan M5 pitfall).
    def test_merge_mismatch_fails(self):
        self.fake_merge(correct=False)
        p = self.toml('[[test]]\nname = "ok"\nplusargs = "pass lo"\n')
        rc, _ = self.regress("--tests", str(p))
        self.assertEqual(rc, 1)
        self.assertIn("Merge failed", (self.out / "regress" / "summary.md").read_text())

    # With the real verilator_coverage: two runs hit different bins; the merge holds both, the
    # ignored bin is not live, code coverage is counted per file; --merge-only reproduces it.
    @unittest.skipUnless(shutil.which("verilator_coverage"), "verilator_coverage not on PATH")
    def test_real_merge_union(self):
        p = self.toml('''
            [[test]]
            name = "lo"
            seeds = 1
            plusargs = "pass lo"
            [[test]]
            name = "hi"
            seeds = 1
            plusargs = "pass hi"
        ''')
        rc, _ = self.regress("--tests", str(p))
        self.assertEqual(rc, 0)
        fj = json.loads((self.out / "cov" / "functional.json").read_text())
        item = fj["groups"]["cg"]["items"]["cp_a"]
        self.assertEqual(item["bins"], {"lo": 1, "mid": 0, "hi": 1})
        self.assertEqual(item["ignored"], {"bad": 0})
        self.assertEqual((fj["live"], fj["hit"]), (3, 2))
        cj = json.loads((self.out / "cov" / "code.json").read_text())
        self.assertEqual(cj["files"]["dut.sv"]["line"], {"points": 1, "hit": 1})
        rc, _ = self.regress("--tests", str(p), "--merge-only")
        self.assertEqual(rc, 0)
        self.assertIn("2/3 live bins (66.7%)", (self.out / "cov" / "functional.md").read_text())

    # A hole is never displayed as 100%.
    def test_pct_never_rounds_a_hole_up(self):
        self.assertEqual(regress.pct(1999, 2000), "99.9%")
        self.assertEqual(regress.pct(5, 5), "100.0%")

    # Reports may only go under an out/ tree (the report directory is wiped).
    def test_out_guard(self):
        p = self.toml('[[test]]\nname = "ok"\nplusargs = "pass lo"\n')
        self.out = self.tmp / "elsewhere"
        rc, _ = self.regress("--tests", str(p))
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
