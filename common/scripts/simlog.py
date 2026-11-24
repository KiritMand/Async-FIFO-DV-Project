#!/usr/bin/env python3
# simlog.py — decide PASS/FAIL of one simulation run from its log (plan M3 step 8).
# Simulator-agnostic: the rules come from common/sim/<sim>.patterns. M5's regress.py imports judge().
"""Judge a simulation log against a patterns file.

The patterns file is TOML with three lists of regexes (Python syntax, matched per line):
  fail     any matching line fails the run (the first one is reported)
  require  each must match at least one line (end-of-test markers)
  zero     one capture group each; the line must exist and every captured number must be 0
A non-zero simulator exit code also fails the run.

Prints one verdict line, plus the run's configuration line if the log has one.
Python >= 3.11, standard library only. Exit status: 0 PASS, 1 FAIL, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

# The testbench's one-line configuration (fifo_base_test prints it with ID [CFG]).
CFG_LINE = re.compile(r"\[CFG\]\s+(.*)$")


# Read and compile the rules; a bad file is a usage error, never a silent pass.
def load_rules(path: Path) -> dict[str, list[re.Pattern[str]]]:
    with path.open("rb") as f:
        raw = tomllib.load(f)
    unknown = set(raw) - {"fail", "require", "zero"}
    if unknown:
        raise ValueError(f"{path}: unknown keys {sorted(unknown)}")
    return {k: [re.compile(p) for p in raw.get(k, [])] for k in ("fail", "require", "zero")}


# Apply the rules to the log text. Returns (passed, reasons); reasons explain every failure.
def judge(text: str, rules: dict[str, list[re.Pattern[str]]], exit_code: int = 0) -> tuple[bool, list[str]]:
    lines = text.splitlines()
    reasons: list[str] = []
    # Simulator exit code.
    if exit_code != 0:
        reasons.append(f"simulator exit code {exit_code}")
    # First line matching any fail pattern.
    for ln in lines:
        if any(p.search(ln) for p in rules["fail"]):
            reasons.append(f"first failure: {ln.strip()[:200]}")
            break
    # Required markers.
    for p in rules["require"]:
        if not any(p.search(ln) for ln in lines):
            reasons.append(f"missing required line /{p.pattern}/ (run ended early?)")
    # Counts that must be present and zero.
    for p in rules["zero"]:
        counts = [int(m.group(1)) for ln in lines if (m := p.search(ln))]
        if not counts:
            reasons.append(f"missing count line /{p.pattern}/")
        elif any(counts):
            reasons.append(f"non-zero count /{p.pattern}/: {max(counts)}")
    return not reasons, reasons


# Command line: judge one log, print the verdict (and the configuration line), set the exit code.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", type=Path, help="simulation log")
    ap.add_argument("--patterns", type=Path, required=True, help="rules file, e.g. common/sim/verilator.patterns")
    ap.add_argument("--exit-code", type=int, default=0, help="the simulator's exit code")
    args = ap.parse_args(argv)
    try:
        rules = load_rules(args.patterns)
        text = args.log.read_text(errors="replace")
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        print(f"simlog: {e}", file=sys.stderr)
        return 2
    passed, reasons = judge(text, rules, args.exit_code)
    cfg = next((m.group(1) for ln in text.splitlines() if (m := CFG_LINE.search(ln))), None)
    if cfg:
        print(f"  cfg: {cfg}")
    print(f"sim {'PASS' if passed else 'FAIL'}: {args.log}")
    for r in reasons:
        print(f"  {r}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
