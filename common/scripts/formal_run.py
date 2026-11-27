#!/usr/bin/env python3
"""formal_run.py — run SymbiYosys jobs for a block and judge them (M7; `make formal*`).

For each requested run TASK:ASIZE[:EXPECT] it writes a copy of the block's .sby with that size
and absolute source paths (so RTL_DIR/DUT_SRCS overrides reach formal), runs
`sby -f -d <out>/a<ASIZE>_d<DSIZE>/<task> <copy> <task>`, and reads the log:

  * verdict (PASS / FAIL / UNKNOWN / TIMEOUT / ERROR), wall time;
  * failed assertion labels (with the bmc step where each first failed), reached and unreached
    covers (with steps), trace files;
  * Yosys warnings that make a proof meaningless: an implicitly declared net (a hierarchical
    reference becomes a free wire, toolchain T18) or a net with no driver. Either is an error.

EXPECT is pass (default), fail (an audit or planted bug must fail), nopass (anything but PASS:
a broken proof is often UNKNOWN, an induction failure before the base case reaches the bug) or
any (record only; a timeout is TIMEOUT).
Writes <out>/<cfg>/<task>/summary.json per run and, with --summary X.md, a Markdown table of all
runs plus X.json (every run, its ok flag, DSIZE, time, repro) for `vplan_check.py --formal`. Exit 0 when every run met its expectation, 1 otherwise, 2 on a setup error.
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Log lines SBY writes (one regex each); labels are the last component of the property path.
DONE_RE = re.compile(r"DONE \((\w+), rc=(\d+)\)")
FAILED_RE = re.compile(r"summary:\s+failed assertion (\S+) at")
ASSERT_FAILED_RE = re.compile(r"Assert failed in (\S+): (\S+)")
STEP_RE = re.compile(r"Checking assertions in step (\d+)")
REACHED_RE = re.compile(r"Reached cover statement in step (\d+) at (\S+): (\S+)")
UNREACHED_RE = re.compile(r"[Uu]nreached cover statement at (\S+): (\S+)|summary:\s+unreached cover statement (\S+) at")
TRACE_RE = re.compile(r"(?:counterexample|cover) trace(?: \[\w+\])?: (\S+\.vcd)")
SUM_REACHED_RE = re.compile(r"reached cover statement (\S+) at")
BAD_WARN_RE = re.compile(r"is implicitly declared|is used but has no driver")
CHPARAM_RE = re.compile(r"^(\s*chparam\s+)(.*?)(\s+\S+\s*)$")


# One requested run and, after it ran, what the log says.
@dataclass
class Run:
    task: str
    asize: int
    expect: str = "pass"
    verdict: str = "NOT RUN"
    seconds: float = 0.0
    failed: list[str] = field(default_factory=list)
    failed_steps: dict[str, int] = field(default_factory=dict)
    reached: dict[str, int] = field(default_factory=dict)
    unreached: list[str] = field(default_factory=list)
    traces: list[str] = field(default_factory=list)
    cover_traces: dict[str, str] = field(default_factory=dict)
    bad_warnings: list[str] = field(default_factory=list)
    workdir: str = ""

    # Did the run meet its expectation? Forbidden warnings always fail it.
    def ok(self) -> bool:
        if self.bad_warnings:
            return False
        if self.expect == "any":                  # record only: any verdict SBY reached
            return self.verdict in ("PASS", "FAIL", "UNKNOWN", "TIMEOUT")
        if self.expect == "nopass":               # the proof must not pass (FAIL or UNKNOWN)
            return self.verdict in ("FAIL", "UNKNOWN")
        return self.verdict == ("PASS" if self.expect == "pass" else "FAIL")


# Parse "TASK:ASIZE[:EXPECT]".
def parse_run(spec: str) -> Run:
    parts = spec.split(":")
    if len(parts) not in (2, 3) or not parts[1].isdigit() or (len(parts) == 3 and parts[2] not in ("pass", "fail", "nopass", "any")):
        raise ValueError(f"bad run spec '{spec}' (want TASK:ASIZE[:pass|fail|nopass|any])")
    return Run(parts[0], int(parts[1]), parts[2] if len(parts) == 3 else "pass")


# Key of an [options] line: "tag: name" for a task-specific line, else "name".
def opt_key(line: str) -> tuple[str, ...]:
    toks = line.split()
    return tuple(toks[:2]) if toks and toks[0].endswith(":") else tuple(toks[:1])


# Rewrite the template .sby: the chparam line gets the requested sizes (exactly one such line
# must exist), every [files] entry gets an absolute source (from --src NAME=PATH by file name,
# else resolved next to the template), a timeout is added to [options] if asked, and each
# --opt line replaces the template's [options] line with the same key (e.g. "cover: depth 170"
# replaces "cover: depth 100") or is added if there is none.
def make_sby(template: Path, asize: int, dsize: int, srcs: dict[str, Path], timeout: int | None,
             opts: list[str] | None = None) -> str:
    lines = template.read_text(encoding="utf-8").splitlines()
    over = {opt_key(o): o for o in (opts or [])}
    in_tpl, sec = set(), ""
    for raw in lines:
        line = raw.strip()
        sec = line if line.startswith("[") and line.endswith("]") else sec
        if sec == "[options]" and not line.startswith("["):
            in_tpl.add(opt_key(line))
    out, section, n_chparam = [], "", 0
    for raw in lines:
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line
            out.append(raw)
            if section == "[options]":
                if timeout:
                    out.append(f"timeout {timeout}")
                out += [o for k, o in over.items() if k not in in_tpl]
            continue
        if section == "[options]" and line and opt_key(line) in over:
            out.append(over[opt_key(line)])
            continue
        if section == "[script]" and line.startswith("chparam"):
            m = CHPARAM_RE.match(raw)
            if not m:
                raise ValueError(f"cannot parse chparam line: {raw}")
            out.append(f"{m.group(1)}-set ASIZE {asize} -set DSIZE {dsize}{m.group(3)}")
            n_chparam += 1
            continue
        if section == "[files]" and line and not line.startswith("#"):
            parts = line.split()
            src = Path(parts[-1])
            name = parts[0] if len(parts) == 2 else src.name
            path = srcs.get(name) or (template.parent / src).resolve()
            if not Path(path).is_file():
                raise FileNotFoundError(f"[files] {name}: {path} not found")
            out.append(f"{name} {Path(path).resolve()}")
            continue
        out.append(raw)
    if n_chparam != 1:
        raise ValueError(f"{template}: expected exactly one chparam line in [script], found {n_chparam}")
    return "\n".join(out) + "\n"


# Read one task's log into the Run (verdict, labels, covers, traces, forbidden warnings).
# `status` is the task's status file (<workdir>/<VERDICT>): its summary lists every cover trace,
# each "cover trace: X.vcd" line followed by the cover it reached; the log shows only the first few.
def parse_log(run: Run, text: str, status: str = "") -> None:
    m = None
    for m in DONE_RE.finditer(text):
        pass
    run.verdict = m.group(1) if m else "ERROR"
    labels = {f.split(".")[-1] for f in FAILED_RE.findall(text)}
    labels |= {lab for _, lab in ASSERT_FAILED_RE.findall(text)}
    run.failed = sorted(labels)
    # First failing step per label: bmc prints "Checking assertions in step N" before the
    # failures it finds there (--keep-going repeats them later, marked "[failed before]").
    step = None
    for ln in text.splitlines():
        if (m2 := STEP_RE.search(ln)):
            step = int(m2.group(1))
        elif (m2 := ASSERT_FAILED_RE.search(ln)) and step is not None:
            run.failed_steps.setdefault(m2.group(2), step)
    for step, _, lab in REACHED_RE.findall(text):
        run.reached.setdefault(lab, int(step))
    for a, b, c in UNREACHED_RE.findall(text):
        lab = b or (c.split(".")[-1] if c else "")
        if lab and lab not in run.unreached:
            run.unreached.append(lab)
    run.traces = sorted(set(TRACE_RE.findall(text)) | set(TRACE_RE.findall(status)))
    last = ""
    for ln in status.splitlines():
        if (t := TRACE_RE.search(ln)):
            last = t.group(1)
        elif (c := SUM_REACHED_RE.search(ln)) and last:
            run.cover_traces[c.group(1).split(".")[-1]] = last
    run.bad_warnings = sorted({ln.strip() for ln in text.splitlines() if BAD_WARN_RE.search(ln)})


# Run one job in <out>/a<n>_d<m>/<task>; print the command; fill in the Run.
def execute(run: Run, args: argparse.Namespace, srcs: dict[str, Path]) -> None:
    cfg = args.out / f"a{run.asize}_d{args.dsize}"
    cfg.mkdir(parents=True, exist_ok=True)
    sby = cfg / args.sby.name
    sby.write_text(make_sby(args.sby, run.asize, args.dsize, srcs, args.timeout, args.opt), encoding="utf-8")
    wd = cfg / run.task
    cmd = ["sby", "-f", "-d", str(wd), str(sby), run.task]
    print("+ " + " ".join(cmd), flush=True)
    t0 = time.monotonic()
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    run.seconds = round(time.monotonic() - t0, 1)
    run.workdir = str(wd)
    log = proc.stdout
    (cfg / f"{run.task}.log").write_text(log, encoding="utf-8")
    status = next((f.read_text(encoding="utf-8", errors="replace") for f in
                   (wd / v for v in ("PASS", "FAIL", "UNKNOWN", "TIMEOUT", "ERROR")) if f.is_file()), "")
    parse_log(run, log, status)
    wd.mkdir(parents=True, exist_ok=True)
    (wd / "summary.json").write_text(json.dumps(asdict(run), indent=2) + "\n", encoding="utf-8")


# One-line verdict per run (what make prints), plus details that point at the evidence.
def report(run: Run) -> str:
    tag = "ok" if run.ok() else "UNEXPECTED"
    s = f"{run.task:10} ASIZE={run.asize}  {run.verdict:7} (expect {run.expect}, {tag})  {run.seconds:7.1f} s"
    if run.reached or run.unreached:
        s += f"  covers {len(run.reached)}/{len(run.reached) + len(run.unreached)}"
    if run.failed:
        s += "  failed: " + ", ".join(run.failed)
    for w in run.bad_warnings:
        s += f"\n    forbidden Yosys warning: {w}"
    for u in run.unreached:
        s += f"\n    unreached cover: {u}"
    for t in run.traces[:3]:
        s += f"\n    trace: {t}"
    return s


# Markdown table of every run (committed as the sign-off summary).
def summary_md(runs: list[Run], dsize: int, repro: str) -> str:
    rows = ["| Task | ASIZE | DSIZE | Verdict | Expected | Time (s) | Covers | Failed labels |",
            "|---|---|---|---|---|---|---|---|"]
    for r in runs:
        cov = f"{len(r.reached)}/{len(r.reached) + len(r.unreached)}" if (r.reached or r.unreached) else ""
        rows.append(f"| {r.task} | {r.asize} | {dsize} | {r.verdict} | {r.expect} | {r.seconds} | {cov} | "
                    f"{'<br>'.join(f'`{x}`' for x in r.failed)} |")
    return "\n".join(rows) + f"\n\nRepro: `{repro}`\n"


# Command line (see the module docstring).
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sby", type=Path, required=True, help="template .sby (committed)")
    ap.add_argument("--out", type=Path, required=True, help="output directory (under out/)")
    ap.add_argument("--run", nargs="+", required=True, metavar="TASK:ASIZE[:EXPECT]")
    ap.add_argument("--dsize", type=int, default=4)
    ap.add_argument("--src", action="append", default=[], metavar="NAME=PATH",
                    help="source for a [files] entry, by file name (RTL_DIR/DUT_SRCS overrides)")
    ap.add_argument("--timeout", type=int, help="SBY timeout per run, seconds")
    ap.add_argument("--opt", action="append", default=[], metavar="LINE",
                    help='[options] line to replace or add, e.g. "cover: depth 170"')
    ap.add_argument("--summary", type=Path, help="write a Markdown table of all runs here")
    ap.add_argument("--repro", default="", help="reproduction command to print")
    args = ap.parse_args(argv)
    try:
        runs = [parse_run(s) for s in args.run]
        srcs = {k: Path(v) for k, v in (s.split("=", 1) for s in args.src)}
        for r in runs:
            execute(r, args, srcs)
            print(report(r), flush=True)
    except (ValueError, FileNotFoundError) as e:
        print(f"formal_run: {e}", file=sys.stderr)
        return 2
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(summary_md(runs, args.dsize, args.repro), encoding="utf-8")
        meta = {"dsize": args.dsize, "generated": time.strftime("%Y-%m-%dT%H:%M:%S"), "repro": args.repro}
        data = {"meta": meta, "runs": [{**asdict(r), "ok": r.ok()} for r in runs]}
        args.summary.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"formal_run: summary {args.summary} (+ .json)")
    bad = [r for r in runs if not r.ok()]
    print(f"formal {'PASS' if not bad else 'FAIL'}: {len(runs) - len(bad)}/{len(runs)} runs as expected"
          + (f"   repro: {args.repro}" if args.repro else ""))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
