# test_vcd2svg.py — self-test for vcd2svg.py: VCD parsing (scopes, shared id codes, scalar and
# vector changes, bit-select declarations), suffix lookup, the text table and the SVG output.
# Run: python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import unittest
from pathlib import Path

# Import the script from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vcd2svg  # noqa: E402

# A small trace: a clock, a 4-bit counter (declared with a bit-select), and the same counter
# seen from a sub-scope under the same id code; an unknown value at time 0.
VCD = """$date today $end
$timescale 1ns $end
$scope module top $end
$var wire 1 ! clk $end
$var wire 4 " cnt [3:0] $end
$scope module u $end
$var wire 4 " cnt $end
$var wire 1 # x $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
0!
bxxxx "
1#
$end
#5
1!
b0001 "
#10
0!
b1010 "
"""


# Each case checks one part of the reader or the writers.
class TestVcd2Svg(unittest.TestCase):
    # Parse the trace once per test.
    def setUp(self):
        self.tr = vcd2svg.parse_vcd(VCD)

    # Scopes give full names; a shared id code feeds both names; timestamps are collected.
    def test_parse(self):
        self.assertEqual(sorted(self.tr.signals), ["top.clk", "top.cnt", "top.u.cnt", "top.u.x"])
        self.assertEqual(self.tr.times, [0, 5, 10])
        self.assertEqual(self.tr.signals["top.u.cnt"].changes, self.tr.signals["top.cnt"].changes)

    # Values: latest change at or before t; vectors in hex; unknown bits print as x.
    def test_values(self):
        cnt = self.tr.find("top.cnt")
        self.assertEqual([vcd2svg.fmt(cnt.at(t), 4) for t in (0, 5, 7, 10)], ["x", "1", "1", "a"])
        self.assertEqual(vcd2svg.fmt(self.tr.find("clk").at(5), 1), "1")

    # Suffix lookup: unique suffixes resolve, ambiguous or unknown ones raise.
    def test_find(self):
        self.assertEqual(self.tr.find("u.cnt").name, "top.u.cnt")
        with self.assertRaises(KeyError):
            self.tr.find("cnt")
        with self.assertRaises(KeyError):
            self.tr.find("nope")

    # Table: header plus one row per timestamp; SVG: one lane label per signal, values drawn.
    def test_outputs(self):
        sigs = [self.tr.find("clk"), self.tr.find("top.cnt")]
        rows = vcd2svg.table(self.tr, sigs).splitlines()
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[-1].split(), ["10", "0", "a"])
        out = vcd2svg.svg(self.tr, sigs, "T & title", {"top.cnt": "count"})
        self.assertTrue(out.startswith("<svg"))
        self.assertIn("T &amp; title", out)
        self.assertIn(">count</text>", out)
        self.assertIn(">a</text>", out)


if __name__ == "__main__":
    unittest.main()
