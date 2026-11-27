#!/usr/bin/env python3
# cov_subset.py — pick a small subset of a finished regression that keeps all of its coverage
# (M9: the simulation runs every MCY mutant gets). DUT-agnostic; Python >= 3.11, standard library.
"""Choose regression runs that together hit every coverage point the whole regression hit.

Reads <regress>/results.json (regress.py) and each run's coverage database, then:

  1. every run must have passed: a subset of a failing regression would judge mutants against a
     broken baseline (exit 1);
  2. the universe is every point hit by at least one run: functional bins (ignore/illegal bins
     excluded), cover statements, and code coverage points (line, branch, toggle of the design);
  3. it seeds the subset with the best run of each regression entry (--per-entry, default 1), so
     every test's own end-of-test checks run on every mutant, then adds runs greedily (most new
     points first; ties: faster run, then entry order and seed) until the universe is covered.

Writes a TOML file of [[run]] tables (id, test, seed, plusargs, seconds, new points) with a header
that says where it came from, and prints a summary. Exit 0 on success, 1 if the regression had a
failing run or a missing database, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from pathlib import Path

# regress.py (same directory) holds the per-simulator coverage reader.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import regress  # noqa: E402


# Points one run hit, as {category: set(record keys)}: covergroup bins, covers, code points.
def run_points(cov: "regress.VerilatorCoverage", db: Path) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {"functional": set(), "cover": set(), "code": set()}
    for key, count in cov.read(db).items():
        if count <= 0:
            continue
        kv = cov.fields(key)
        if kv.get("t") == "covergroup":
            if kv.get("Bt") not in ("ignore", "illegal"):
                out["functional"].add(key)
        elif kv.get("t") == "user":
            out["cover"].add(key)
        else:
            out["code"].add(key)
    return out


# Greedy set cover: the seed runs first, then the run adding the most uncovered points each round.
def choose(runs: list[dict], points: list[set[str]], per_entry: int) -> tuple[list[int], list[int]]:
    universe = set().union(*points)
    order = {r["id"]: i for i, r in reversed(list(enumerate(runs)))}

    # Rank key: more points first, then faster, then entry order, then seed.
    def rank(i: int, gain: int) -> tuple:
        return (-gain, runs[i]["seconds"], order[runs[i]["id"]], runs[i]["seed"])

    chosen: list[int] = []
    gains: list[int] = []
    covered: set[str] = set()
    for entry in sorted(order, key=order.get):
        cands = sorted((i for i, r in enumerate(runs) if r["id"] == entry), key=lambda i: rank(i, len(points[i])))
        for i in cands[:per_entry]:
            gains.append(len(points[i] - covered))
            covered |= points[i]
            chosen.append(i)
    while covered != universe:
        best = min((i for i in range(len(runs)) if i not in chosen), key=lambda i: rank(i, len(points[i] - covered)))
        gains.append(len(points[best] - covered))
        covered |= points[best]
        chosen.append(best)
    return chosen, gains


# TOML string literal (the values here never hold a single quote: regress.py forbids it).
def q(s: str) -> str:
    return "'" + s + "'"


# Command line, checks, choice, output file and summary.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regress", required=True, type=Path, help="regression output dir holding results.json")
    ap.add_argument("--sim", default="verilator", choices=sorted(regress.SIMULATORS))
    ap.add_argument("--per-entry", type=int, default=1, help="runs of every regression entry kept first")
    ap.add_argument("--out", required=True, type=Path, help="TOML file to write")
    ap.add_argument("--repro", default="", help="command that reproduces this choice (written to the header)")
    a = ap.parse_args(argv)

    # Load the regression and refuse a failing one.
    res_path = a.regress / "results.json"
    if not res_path.is_file():
        print(f"cov_subset: no {res_path}", file=sys.stderr)
        return 2
    res = json.loads(res_path.read_text())
    runs = res["runs"]
    bad = [f"{r['id']}_{r['seed']}: {r['status']}" for r in runs if r["status"] != "PASS"]
    if bad:
        print(f"cov_subset FAIL: the regression has {len(bad)} non-passing runs, e.g. {bad[:3]}", file=sys.stderr)
        return 1
    cov = regress.SIMULATORS[a.sim]()
    points = []
    for r in runs:
        db = Path(r["run_dir"]) / cov.DB
        if not db.is_file():
            print(f"cov_subset FAIL: no coverage database {db}", file=sys.stderr)
            return 1
        points.append(run_points(cov, db))
    flat = [set().union(*p.values()) for p in points]

    # Choose, then count the universe per category for the header.
    chosen, gains = choose(runs, flat, a.per_entry)
    cats = {c: len(set().union(*(p[c] for p in points))) for c in ("functional", "cover", "code")}
    total = sum(r["seconds"] for r in runs)
    sub_s = sum(runs[i]["seconds"] for i in chosen)

    # Write the TOML file: provenance header, then one [[run]] per chosen run in choice order.
    # The file is committed, so paths in it are relative to the repository root.
    repo = str(HERE.parent.parent) + "/"
    meta = {k: (v.replace(repo, "") if isinstance(v, str) else v) for k, v in res.get("meta", {}).items()}
    lines = [
        "# Generated by common/scripts/cov_subset.py — do not edit; rerun the command below.",
        f"# Repro: {a.repro}" if a.repro else "# Repro: (not given)",
        f"# Source regression: {meta.get('repro', '?')} (git {meta.get('git', '?')}, {meta.get('generated', '?')}),",
        f"#   {len(runs)} runs, all PASS. Universe: {cats['functional']} functional bins, {cats['cover']} covers,",
        f"#   {cats['code']} code points hit by at least one run; the {len(chosen)} runs below hit all of them.",
        f"# Order: the best run of each entry first (--per-entry {a.per_entry}), then greedy by new points.",
        f"# Run time: {sub_s:.1f} s for the subset vs {total:.1f} s for the regression.",
        "",
        "[meta]",
        f"generated = {q(datetime.datetime.now().isoformat(timespec='seconds'))}",
        f"source = {q(meta.get('repro', '?'))}",
        f"runs_total = {len(runs)}",
        f"universe = {sum(cats.values())}",
        "",
    ]
    for i, g in zip(chosen, gains):
        r = runs[i]
        lines += ["[[run]]", f"id = {q(r['id'])}", f"test = {q(r['test'])}", f"seed = {r['seed']}",
                  f"plusargs = {q(r['plusargs'])}", f"seconds = {r['seconds']}", f"new_points = {g}", ""]
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text("\n".join(lines))

    # Summary line and reproduction command.
    per = {}
    for i in chosen:
        per[runs[i]["id"]] = per.get(runs[i]["id"], 0) + 1
    print(f"cov_subset: {len(chosen)} of {len(runs)} runs keep all {sum(cats.values())} points "
          f"({cats['functional']} functional, {cats['cover']} covers, {cats['code']} code); "
          f"{sub_s:.1f} s of {total:.1f} s; per entry: " + ", ".join(f"{k} {v}" for k, v in per.items()))
    print(f"  wrote {a.out}")
    if a.repro:
        print(f"  repro: {a.repro}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
