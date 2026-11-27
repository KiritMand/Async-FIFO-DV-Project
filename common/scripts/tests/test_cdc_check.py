# test_cdc_check.py — self-test for cdc_check.py's rules on hand-built Yosys-style netlists (no
# Yosys needed): a clean two-flop synchronizer passes; logic on the crossing breaks R1, a stage 1
# that feeds anything but stage 2 breaks R2, a flop reset by the other domain breaks R3; a waiver
# matching rule, destination and source suppresses its violation; a multi-bit synchronizer gets
# the R4 note. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import sys
import unittest
from pathlib import Path

# Import the script from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cdc_check  # noqa: E402

CFG = {"top": "t", "domains": {"wclk": "wrst_n", "rclk": "rrst_n"}, "ports": {"din": "wclk", "dout": "rclk"}}
# Bits: clocks and resets, the data input, then the flops' outputs.
WCLK, RCLK, WRST, RRST, DIN = 2, 3, 4, 5, 6


# An async-reset flop cell.
def ff(d, q, clk, rst):
    return {"type": "$adff", "parameters": {}, "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
            "connections": {"CLK": [clk], "ARST": [rst], "D": d, "Q": q}}


# A one-input logic cell.
def gate(a, y):
    return {"type": "$not", "parameters": {}, "port_directions": {"A": "input", "Y": "output"},
            "connections": {"A": a, "Y": y}}


# A netlist: source flop on wclk -> stage 1 -> stage 2 on rclk -> dout. Options break one rule each.
def netlist(logic=False, s1_to_out=False, s1_rst=RRST, width=1):
    src = [10 + i for i in range(width)]
    s1 = [20 + i for i in range(width)]
    s2 = [30 + i for i in range(width)]
    cells = {"src": ff([DIN] * width, src, WCLK, WRST), "s2": ff(s1, s2, RCLK, RRST)}
    if logic:
        cells["inv"] = gate(src, [40 + i for i in range(width)])
        cells["s1"] = ff([40 + i for i in range(width)], s1, RCLK, s1_rst)
    else:
        cells["s1"] = ff(src, s1, RCLK, s1_rst)
    names = {"wclk": [WCLK], "rclk": [RCLK], "wrst_n": [WRST], "rrst_n": [RRST], "din": [DIN],
             "src": src, "s1": s1, "s2": s2}
    ports = {"wclk": {"direction": "input", "bits": [WCLK]}, "rclk": {"direction": "input", "bits": [RCLK]},
             "wrst_n": {"direction": "input", "bits": [WRST]}, "rrst_n": {"direction": "input", "bits": [RRST]},
             "din": {"direction": "input", "bits": [DIN]},
             "dout": {"direction": "output", "bits": s1 if s1_to_out else s2}}
    return {"modules": {"t": {"ports": ports, "cells": cells,
                              "netnames": {n: {"bits": b} for n, b in names.items()}}}}


# Rules found (unwaived violations) for a netlist and config.
def rules(data, cfg=CFG):
    viol, notes = cdc_check.check(cdc_check.Netlist(data, "t", cfg), cfg)
    return sorted(v.rule for v in viol if not v.waived_by), sorted(n.rule for n in notes)


# Each test checks one rule.
class TestCdcCheck(unittest.TestCase):
    # Source flop -> stage 1 -> stage 2, both on the destination reset: clean.
    def test_clean(self):
        self.assertEqual(rules(netlist()), ([], []))

    # Logic between the source flop and stage 1.
    def test_r1_logic(self):
        self.assertEqual(rules(netlist(logic=True)), (["R1"], []))

    # Stage 1 drives an output port, not only stage 2.
    def test_r2_fanout(self):
        self.assertEqual(rules(netlist(s1_to_out=True)), (["R2"], []))

    # Stage 1 reset by the source domain's reset.
    def test_r3_reset(self):
        self.assertEqual(rules(netlist(s1_rst=WRST)), (["R3"], []))

    # A matching waiver suppresses R1; one for another destination does not.
    def test_waiver(self):
        w = {**CFG, "waiver": [{"rule": "R1", "dest": "s1", "source": "src", "reason": "test"}]}
        self.assertEqual(rules(netlist(logic=True), w), ([], []))
        w["waiver"][0]["dest"] = "s2"
        self.assertEqual(rules(netlist(logic=True), w), (["R1"], []))

    # A multi-bit synchronizer is noted (encoding is not visible in structure).
    def test_r4_note(self):
        self.assertEqual(rules(netlist(width=3)), ([], ["R4"]))


if __name__ == "__main__":
    unittest.main()
