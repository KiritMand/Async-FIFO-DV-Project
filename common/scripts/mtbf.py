#!/usr/bin/env python3
"""mtbf.py — synchronizer MTBF for 1, 2 and 3 flip-flop stages (M8, the B08 narrative).

    MTBF = e^(S / tau) / (T_W * f_clk * f_data)

tau    metastability resolution time constant of the flip-flop
T_W    metastability window (the aperture in which a data change can make the flop metastable)
f_clk  destination (sampling) clock frequency
f_data rate of changes of the synchronized signal (here: pointer updates = source clock x activity)
S      settling time the metastable stage gets before its output is used:
         1 stage : S = T_clk - t_pd - t_logic   (stage 1 feeds the flag logic directly, as in B08)
         n >= 2  : S = (n - 1) * (T_clk - t_pd)  (stage-to-stage paths have no logic)
       with t_pd = clock-to-Q + setup time of the flop.
This is the standard first-order model (e.g. R. Ginosar, "Metastability and Synchronizers: A
Tutorial", IEEE Design & Test, 2011). Work in log10, because e^(S/tau) overflows a float.

The defaults are ILLUSTRATIVE values of the order used in textbook examples for recent CMOS,
not a characterization of any library or FPGA. Replace them with vendor data (FPGA tools report
MTBF from their own characterization) before using a number in a design review.
Python >= 3.11, standard library only.
"""
from __future__ import annotations

import argparse
import math
import sys

LOG10_E = math.log10(math.e)
SECONDS_PER_YEAR = 365.25 * 24 * 3600


# Settling time in ps for n stages (see the module docstring).
def settling_ps(stages: int, t_clk_ps: float, t_pd_ps: float, t_logic_ps: float) -> float:
    if stages < 1:
        raise ValueError("stages must be >= 1")
    if stages == 1:
        return t_clk_ps - t_pd_ps - t_logic_ps
    return (stages - 1) * (t_clk_ps - t_pd_ps)


# log10 of the MTBF in seconds; frequencies in Hz, times in ps.
def log10_mtbf_s(stages: int, f_clk_hz: float, f_data_hz: float, tau_ps: float, tw_ps: float,
                 t_pd_ps: float, t_logic_ps: float) -> float:
    s = settling_ps(stages, 1e12 / f_clk_hz, t_pd_ps, t_logic_ps)
    if s <= 0:
        return -math.inf                     # no settling time at all: fails at the data rate
    return (s / tau_ps) * LOG10_E - math.log10(tw_ps * 1e-12 * f_clk_hz * f_data_hz)


# Human form of an MTBF given as log10(seconds): seconds, hours or years, in powers of ten.
def human(log10_s: float) -> str:
    if log10_s == -math.inf:
        return "0 (no settling time)"
    if log10_s < math.log10(3600):
        return f"{10 ** log10_s:.3g} s"
    if log10_s < math.log10(SECONDS_PER_YEAR):
        return f"{10 ** log10_s / 3600:.3g} h"
    ly = log10_s - math.log10(SECONDS_PER_YEAR)
    return f"{10 ** ly:.3g} years" if ly < 6 else f"1e{ly:.0f} years"


# Command line: one row per destination clock, one column per stage count; --markdown for docs.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tau-ps", type=float, default=20.0, help="resolution time constant (illustrative 20 ps)")
    ap.add_argument("--tw-ps", type=float, default=50.0, help="metastability window (illustrative 50 ps)")
    ap.add_argument("--tpd-ps", type=float, default=100.0, help="clock-to-Q + setup (illustrative 100 ps)")
    ap.add_argument("--tlogic-ps", type=float, default=600.0,
                    help="logic after a single stage: the full/empty compare (illustrative 600 ps)")
    ap.add_argument("--fclk-mhz", type=float, nargs="+", default=[250.0, 500.0, 800.0, 1000.0],
                    help="destination clock frequencies")
    ap.add_argument("--fsrc-ratio", type=float, default=1.0,
                    help="source clock = ratio x destination clock (pointer can change every source edge)")
    ap.add_argument("--activity", type=float, default=1.0, help="fraction of source edges that move the pointer")
    ap.add_argument("--stages", type=int, nargs="+", default=[1, 2, 3])
    ap.add_argument("--markdown", action="store_true", help="print a Markdown table")
    args = ap.parse_args(argv)
    if min(args.tau_ps, args.tw_ps, args.activity, args.fsrc_ratio) <= 0:
        print("mtbf: tau, T_W, activity and fsrc-ratio must be > 0", file=sys.stderr)
        return 2
    head = ["f_clk"] + [f"{n} stage{'s' if n > 1 else ''}" for n in args.stages]
    rows = []
    for f in args.fclk_mhz:
        fc = f * 1e6
        fd = fc * args.fsrc_ratio * args.activity
        rows.append([f"{f:g} MHz"] + [human(log10_mtbf_s(n, fc, fd, args.tau_ps, args.tw_ps, args.tpd_ps, args.tlogic_ps))
                                       for n in args.stages])
    params = (f"tau={args.tau_ps:g} ps, T_W={args.tw_ps:g} ps, t_pd={args.tpd_ps:g} ps, t_logic={args.tlogic_ps:g} ps, "
              f"f_data = {args.fsrc_ratio:g} x f_clk x activity {args.activity:g} (ILLUSTRATIVE values)")
    if args.markdown:
        print("| " + " | ".join(head) + " |")
        print("|" + "---|" * len(head))
        for r in rows:
            print("| " + " | ".join(r) + " |")
        print(f"\n{params}")
    else:
        w = max(len(c) for r in rows + [head] for c in r) + 2
        for r in [head] + rows:
            print("".join(c.ljust(w) for c in r))
        print(params)
    return 0


if __name__ == "__main__":
    sys.exit(main())
