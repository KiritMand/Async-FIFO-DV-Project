# test_vplan_check.py — self-test for vplan_check.py: a checker that can't fail proves nothing.
# Each case breaks one rule in a copy of the real vplan (env VPLAN, default: the async_fifo
# plan) and expects --structure to fail with the matching message; the --annotate cases feed
# synthetic merged coverage and expect --strict to fail on holes and mismatches. Run:
#   VPLAN=ip/async_fifo/docs/vplan.md python3 -m unittest discover -s common/scripts/tests
# The mutations anchor on rows and labels of the async_fifo plan; a new block adapts them.

import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

# Import the checker from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vplan_check  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VPLAN = Path(os.environ.get("VPLAN", REPO / "ip/async_fifo/docs/vplan.md"))


# Replace one cell of the table row whose first cell is `first` (exact match, backticks
# included). Fails the test if the row doesn't exist, so a stale anchor is never a silent pass.
def set_cell(text: str, first: str, col: int, value: str) -> str:
    out, hit = [], False
    for ln in text.splitlines():
        cells = vplan_check.split_row(ln) if ln.startswith("|") else []
        if cells and cells[0] == first:
            cells[col] = value
            ln = "| " + " | ".join(cells) + " |"
            hit = True
        out.append(ln)
    assert hit, f"no table row starting with {first!r}"
    return "\n".join(out) + "\n"


# Read one cell of the row whose first cell is `first`.
def get_cell(text: str, first: str, col: int) -> str:
    for ln in text.splitlines():
        cells = vplan_check.split_row(ln) if ln.startswith("|") else []
        if cells and cells[0] == first:
            return cells[col]
    raise AssertionError(f"no table row starting with {first!r}")


# Insert a line right after the first line that starts with `anchor`.
def insert_after(text: str, anchor: str, new_line: str) -> str:
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith(anchor):
            return "\n".join(lines[: i + 1] + [new_line] + lines[i + 1:]) + "\n"
    raise AssertionError(f"no line starting with {anchor!r}")


# Plain text substitution that must change something.
def replace(text: str, old: str, new: str) -> str:
    assert old in text, f"{old!r} not found"
    return text.replace(old, new, 1)


# Column indices used by the mutations (feature, property and ledger tables).
F_STIM, F_CHECK, F_COV, F_FORMAL = 2, 3, 4, 5
P_RUNS = 2
L_SIM = 4


# Runs --structure on a mutated copy of the plan and checks the outcome.
class StructureSelfTest(unittest.TestCase):
    base: str

    # Load the real plan once for all cases.
    @classmethod
    def setUpClass(cls):
        cls.base = VPLAN.read_text(encoding="utf-8")

    # Write `text` to a temporary vplan, run the checker, return (exit code, output).
    def run_check(self, text: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "vplan.md"
            p.write_text(text, encoding="utf-8")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = vplan_check.main(["--structure", "--vplan", str(p)])
        return rc, buf.getvalue()

    # The mutated plan must fail, and the output must contain the expected message.
    def assertFails(self, text: str, expected: str):
        rc, out = self.run_check(text)
        self.assertEqual(rc, 1, f"checker passed a broken plan; output:\n{out}")
        self.assertRegex(out, re.escape(expected))

    # The unmodified plan passes (otherwise every other case is meaningless).
    def test_baseline_passes(self):
        rc, out = self.run_check(self.base)
        self.assertEqual(rc, 0, out)

    # Feature rows: a checker is mandatory, n/a needs a reason, coverage or formal must exist.
    def test_checker_cannot_be_na(self):
        self.assertFails(set_cell(self.base, "F02", F_CHECK, "n/a: scoreboard later"),
                         "F02: Checker cannot be n/a")

    def test_blank_stimulus(self):
        self.assertFails(set_cell(self.base, "F03", F_STIM, ""), "F03: Stimulus is empty")

    def test_na_without_reason(self):
        self.assertFails(set_cell(self.base, "F09", F_COV, "n/a"), "F09: Coverage says n/a without a reason")

    def test_coverage_and_formal_both_na(self):
        t = set_cell(self.base, "F11", F_FORMAL, "n/a: later")
        self.assertFails(t, "F11: needs coverage or formal, both are n/a")

    # The Formal cell must agree with the Runs column of the row's own properties.
    def test_formal_cell_without_formal_property(self):
        t = set_cell(self.base, "`ast_F06_wfull_not_optimistic`", P_RUNS, "sim")
        self.assertFails(t, "F06: Formal cell is filled but no F06 property runs in formal")

    # IDs are unique and retired IDs never come back.
    def test_duplicate_feature_id(self):
        self.assertFails(set_cell(self.base, "F03", 0, "F02"), "duplicate ID F02")

    def test_retired_id_reused(self):
        self.assertFails(replace(self.base, "Retired IDs: none.", "Retired IDs: F17."),
                         "retired ID F17 is in use again")

    # Labels: referenced ones must be defined, defined ones referenced from their home row.
    def test_undefined_label(self):
        cell = get_cell(self.base, "F02", F_CHECK) + "<br>`ast_F02_ghost`"
        self.assertFails(set_cell(self.base, "F02", F_CHECK, cell),
                         "`ast_F02_ghost` is not defined in the property list")

    def test_orphan_property(self):
        t = insert_after(self.base, "| `ast_F01_wfull_low_in_reset`",
                         "| `ast_F02_orphan` | e2e | both | rclk | Never referenced. |")
        self.assertFails(t, "ast_F02_orphan is not referenced from its home row F02")

    def test_label_with_unknown_home(self):
        t = insert_after(self.base, "| `ast_F01_wfull_low_in_reset`",
                         "| `ast_F99_nowhere` | e2e | both | rclk | No such feature. |")
        self.assertFails(t, "home ID F99 is not in the feature table or ledger")

    def test_gclk_property_in_sim(self):
        t = set_cell(self.base, "`ast_F09_wptr_cdc_stable_off_edge`", P_RUNS, "sim")
        self.assertFails(t, "gclk exists only in formal")

    # Coverage items and tests must be defined before features may name them.
    def test_undefined_coverage_item(self):
        cell = get_cell(self.base, "F02", F_COV) + "<br>`cg_fill.cp_nope`"
        self.assertFails(set_cell(self.base, "F02", F_COV, cell),
                         "`cg_fill.cp_nope` is not defined in the coverage model")

    def test_undefined_test(self):
        cell = get_cell(self.base, "F02", F_STIM) + "<br>`ghost_test`"
        self.assertFails(set_cell(self.base, "F02", F_STIM, cell),
                         "test `ghost_test` is not in the test list")

    # Ledger: a formal assumption is also checked in simulation, under the same label.
    def test_assumption_missing_from_sim(self):
        t = set_cell(self.base, "A05", L_SIM, "n/a: not checked")
        self.assertFails(t, "asm_A05_wrst_stays_released runs in simulation but is missing")

    def test_formal_only_assumption(self):
        t = set_cell(self.base, "`asm_A05_wrst_stays_released`", P_RUNS, "formal")
        self.assertFails(t, "every formal assumption must also be checked in simulation")

    # Exclusions need the owner's approval on record.
    def test_exclusion_without_approval(self):
        header = "| Item | Reason | Approved by | Date |\n|---|---|---|---|\n"
        row = "| `cg_fill.cp_fill` | hard to hit |  | 2026-11-22 |\n"
        self.assertFails(replace(self.base, header, header + row), "exclusion: Approved by is empty")

    # Sign-off must state N; the template's sections must all be there.
    def test_missing_n(self):
        self.assertFails(replace(self.base, "**N = 200**", "N is 200"), "must state N once")

    def test_missing_section(self):
        self.assertFails(replace(self.base, "## 9. Out of scope", "## 9. Elsewhere"),
                         "missing section '## <n>. Out of scope'")


# Runs --annotate --strict on synthetic merged coverage built from the real plan's items: a
# complete database passes; a hole, a missing item or a bin count that differs from the plan's
# stated total fails; helper items the plan doesn't list are reported but don't fail; every
# simulation cover property must be hit (M6).
class AnnotateSelfTest(unittest.TestCase):
    # The plan's coverage items, in plan order, and its stated bin total.
    @classmethod
    def setUpClass(cls):
        vp = vplan_check.Vplan(VPLAN)
        cls.items = list(vplan_check.check_structure(vp).cov_items)
        cls.total = vplan_check.stated_bins(vp)

    # A functional.json in regress.py's format: every planned item, bins summing to the plan's
    # total (the first item takes the remainder), every bin hit once.
    def database(self) -> dict:
        groups: dict = {}
        for k, item in enumerate(self.items):
            g, i = item.split(".")
            n = self.total - (len(self.items) - 1) if k == 0 else 1
            groups.setdefault(g, {"items": {}})["items"][i] = {"bins": {f"b{j}": 1 for j in range(n)}, "ignored": {}}
        return {"sim": "verilator", "merged_runs": 3, "groups": groups}

    # Write the database, run the checker on the real plan, return (exit code, output, page).
    def run_annotate(self, db: dict) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as d:
            cov, status = Path(d) / "functional.json", Path(d) / "status.md"
            cov.write_text(json.dumps(db))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = vplan_check.main(["--annotate", "--strict", "--vplan", str(VPLAN), "--cov", str(cov),
                                       "--status-out", str(status)])
            return rc, buf.getvalue(), status.read_text()

    # Every planned bin hit: strict passes and the page says so.
    def test_complete_database_passes(self):
        rc, out, page = self.run_annotate(self.database())
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{self.total}/{self.total} planned bins hit (100%)", page)

    # One unhit bin fails and is named on the page.
    def test_hole_fails(self):
        db = self.database()
        g, i = self.items[1].split(".")
        db["groups"][g]["items"][i]["bins"]["b0"] = 0
        rc, _, page = self.run_annotate(db)
        self.assertEqual(rc, 1)
        self.assertRegex(page, rf"`{re.escape(self.items[1])}` \| 0/1 .*\*\*HOLES\*\* \| `b0`")

    # A planned item missing from the database fails (planned but not implemented).
    def test_missing_item_fails(self):
        db = self.database()
        g, i = self.items[-1].split(".")
        del db["groups"][g]["items"][i]
        rc, _, page = self.run_annotate(db)
        self.assertEqual(rc, 1)
        self.assertIn("NOT IN DATABASE", page)

    # One bin more than the plan states fails: plan and code must agree on the model's size.
    def test_bin_count_mismatch_fails(self):
        db = self.database()
        g, i = self.items[0].split(".")
        db["groups"][g]["items"][i]["bins"]["extra"] = 1
        rc, _, page = self.run_annotate(db)
        self.assertEqual(rc, 1)
        self.assertIn(f"differs from the plan's {self.total}", page)

    # A helper item the plan doesn't list is reported, not counted, and doesn't fail.
    def test_helper_item_reported(self):
        db = self.database()
        g = self.items[0].split(".")[0]
        db["groups"][g]["items"]["cp_helper"] = {"bins": {"x": 0}, "ignored": {}}
        rc, out, page = self.run_annotate(db)
        self.assertEqual(rc, 0, out)
        self.assertIn(f"`{g}.cp_helper`", page)

    # Simulation cover properties (M6): all of the plan's hit passes; one never hit fails and is
    # named on the page; formal-only covers are not required in simulation.
    def test_sim_covers(self):
        props = vplan_check.check_structure(vplan_check.Vplan(VPLAN)).props
        sim = [p for p, r in props.items() if p.startswith("cov_") and r["Runs"] in ("sim", "both")]
        db = {**self.database(), "covers": {c: 3 for c in sim}}
        rc, out, page = self.run_annotate(db)
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{len(sim)}/{len(sim)} simulation covers hit", page)
        db["covers"][sim[0]] = 0
        rc, _, page = self.run_annotate(db)
        self.assertEqual(rc, 1)
        self.assertIn(f"**MISSED:** `{sim[0]}`", page)


# --trace with --defer (M6): labels only (the other categories are emptied), code written to a
# temporary root. Formal-only labels may be absent when deferred; any other missing label, or
# the formal ones without --defer, count as missing.
class TraceDeferSelfTest(unittest.TestCase):
    # Count missing labels for a code file holding `labels`, with the given deferred Runs values.
    def missing(self, labels: list[str], defer: set[str]) -> int:
        mdl = vplan_check.check_structure(vplan_check.Vplan(VPLAN))
        mdl.cov_items, mdl.tests, mdl.other_refs = {}, {}, {}
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "props.sv").write_text("\n".join(f"{lab}: assert (1);" for lab in labels))
            with contextlib.redirect_stdout(io.StringIO()):
                return vplan_check.run_trace(mdl, [Path(d)], Path(d) / "Makefile", False, defer)

    # All non-formal labels present: 0 with formal deferred, the formal count without; one
    # simulation label removed counts even with formal deferred.
    def test_defer_formal(self):
        props = vplan_check.check_structure(vplan_check.Vplan(VPLAN)).props
        sim = [p for p, r in props.items() if r["Runs"] != "formal"]
        n_formal = len(props) - len(sim)
        self.assertEqual(self.missing(sim, {"formal"}), 0)
        self.assertEqual(self.missing(sim, set()), n_formal)
        self.assertEqual(self.missing(sim[1:], {"formal"}), 1)


if __name__ == "__main__":
    unittest.main()
