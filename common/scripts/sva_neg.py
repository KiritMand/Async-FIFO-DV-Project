#!/usr/bin/env python3
# sva_neg.py — run the assertion negative tests and judge them (plan M6 step 4).
# DUT-agnostic: the bench lists its cases, the vplan says which labels need one, and
# common/sim/<sim>.patterns says what a failed assertion looks like in the log.
"""Show that every simulation assertion can fail.

The negative-test bench (for the FIFO: ip/async_fifo/tb/sva_neg/tb_sva_neg.sv) is built once
by make. This script
  1. asks it for its cases with +LIST: "SVA_NEG case <label>" and "SVA_NEG nocase <label> <why>";
  2. checks them against the vplan: every ast_/asm_ label with Runs = sim or both has a case or a
     nocase line with a reason, and the bench names no label the plan lacks;
  3. runs the clean case (no +BREAK): it must reach "SVA_NEG end" with no failure line at all;
  4. runs every case with +BREAK=<label> (plus --sim-args, e.g. a raised error limit) and passes
     it when the "SVA_NEG inject" line comes before every failure line, the first failure line is
     a failed assertion, and <label> is among the labels that failed at the first failing time.
     The other labels that failed at that time are reported as co-fired;
  5. with --twins <file>, checks that every concurrent twin cast_<x> labeled in that file is among
     the labels that failed first in the case of its immediate twin ast_<x>.
It writes results.json and summary.md to --out, and the Markdown page to --doc.

Python >= 3.11, standard library only. Exit status: 0 all pass, 1 a check failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import shlex
import subprocess
import sys
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Sibling scripts: the log rules (simlog) and the vplan parser (vplan_check).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import simlog  # noqa: E402
import vplan_check  # noqa: E402

# Bench output lines (see the module docstring).
CASE_RE = re.compile(r"^SVA_NEG case (\w+)\s*$")
NOCASE_RE = re.compile(r"^SVA_NEG nocase (\w+)\s+(.+)$")
INJECT_RE = re.compile(r"^SVA_NEG inject (\w+) at \S+: (.*)$")
END_RE = re.compile(r"^SVA_NEG end")
# A concurrent twin's label in its source file: cast_<x> is the twin of ast_<x>.
TWIN_RE = re.compile(r"\b(cast_\w+)\s*:")


# One case's verdict, as written to results.json.
@dataclass
class Case:
    label: str
    status: str = "FAIL"
    fault: str = ""
    first_time: str = ""
    fired: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    log: str = ""


# ---------------------------------------------------------------------------------------------
# Judging (pure functions, covered by tests/test_sva_neg.py)
# ---------------------------------------------------------------------------------------------

# Compare the bench's cases with the plan. Returns problems (empty = consistent).
def check_cases(needed: list[str], cases: list[str], nocases: dict[str, str]) -> list[str]:
    probs = [f"{lab}: no case and no 'nocase' reason in the bench" for lab in needed
             if lab not in cases and lab not in nocases]
    probs += [f"{lab}: case in the bench, but not a simulation assertion in the vplan"
              for lab in [*cases, *nocases] if lab not in needed]
    probs += [f"{lab}: listed twice" for lab in {c for c in cases if cases.count(c) > 1}]
    return probs


# Index of the first line matching any fail rule, or None.
def first_fail(lines: list[str], rules: dict) -> int | None:
    return next((i for i, ln in enumerate(lines) if any(p.search(ln) for p in rules["fail"])), None)


# The clean run: exit 0, the end marker, and no failure line. Returns reasons (empty = pass).
def judge_clean(text: str, rc: int, rules: dict) -> list[str]:
    lines = text.splitlines()
    reasons = [f"exit code {rc}"] if rc != 0 else []
    if (i := first_fail(lines, rules)) is not None:
        reasons.append(f"failure in the clean run: {lines[i].strip()[:160]}")
    if not any(END_RE.search(ln) for ln in lines):
        reasons.append("no 'SVA_NEG end' line (run ended early)")
    return reasons


# One broken run: fills in the case from its log (see the module docstring for the rules).
def judge_case(case: Case, text: str, rules: dict) -> Case:
    lines = text.splitlines()
    pat = rules["assertion"][0]
    inj = next((i for i, ln in enumerate(lines) if (m := INJECT_RE.search(ln)) and m.group(1) == case.label), None)
    if inj is None:
        case.reasons.append("no 'SVA_NEG inject' line for this label (case not run)")
        return case
    case.fault = INJECT_RE.search(lines[inj]).group(2).strip()
    ff = first_fail(lines, rules)
    if ff is None:
        case.reasons.append("nothing failed after the fault")
        return case
    if ff < inj:
        case.reasons.append(f"a failure came before the fault: {lines[ff].strip()[:160]}")
        return case
    m = pat.search(lines[ff])
    if not m:
        case.reasons.append(f"first failure is not an assertion: {lines[ff].strip()[:160]}")
        return case
    case.first_time = m.group("time")
    case.fired = sorted({mm.group("label") for ln in lines[ff:]
                         if (mm := pat.search(ln)) and mm.group("time") == case.first_time})
    if case.label not in case.fired:
        case.reasons.append(f"{case.label} did not fail at the first failing time {case.first_time} "
                            f"(failed there: {', '.join(case.fired)})")
    else:
        case.status = "PASS"
    return case


# Concurrent twins: each must fail first in its immediate twin's case. Returns (rows, problems);
# a row is (twin, immediate label, fired?).
def check_twins(twins: list[str], cases: list[Case]) -> tuple[list[tuple[str, str, bool]], list[str]]:
    by_label = {c.label: c for c in cases}
    rows, probs = [], []
    for t in twins:
        imm = "ast_" + t.removeprefix("cast_")
        c = by_label.get(imm)
        ok = c is not None and t in c.fired
        rows.append((t, imm, ok))
        if c is None:
            probs.append(f"{t}: no case for its immediate twin {imm}")
        elif not ok:
            probs.append(f"{t}: did not fail at the first failing time of the {imm} case")
    return rows, probs


# ---------------------------------------------------------------------------------------------
# Running and reporting
# ---------------------------------------------------------------------------------------------

# Run the bench once in run_dir; returns (exit code, log text). The log is kept for debugging.
def run_bench(exe: Path, args: list[str], run_dir: Path, name: str, timeout: int) -> tuple[int, str, Path]:
    run_dir.mkdir(parents=True, exist_ok=True)
    log = run_dir / f"{name}.log"
    try:
        p = subprocess.run([str(exe), *args], cwd=run_dir, capture_output=True, text=True, timeout=timeout)
        rc, text = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        rc, text = -1, f"{e.stdout or ''}\nTIMEOUT after {timeout} s\n"
    log.write_text(text)
    return rc, text, log


# The Markdown page: method, the result table, the labels without a case, reproduction.
def page(cases: list[Case], nocases: dict[str, str], clean_ok: bool, repro: str, title: str,
         config: str = "", twins: list[tuple[str, str, bool]] | None = None) -> str:
    n_pass = sum(c.status == "PASS" for c in cases)
    rows = []
    for c in cases:
        co = [f"`{x}`" for x in c.fired if x != c.label]
        rows.append(f"| `{c.label}` | {c.fault or '—'} | {'fires' if c.status == 'PASS' else '**FAIL**'} "
                    f"| {', '.join(co) or '—'} |")
    lines = [
        f"# {title} — assertion negative tests",
        "",
        f"Generated by `sva_neg.py` on {datetime.datetime.now().isoformat(timespec='seconds')}"
        + (f" at {config}" if config else "") + f". Do not edit by hand: rerun `{repro}`.",
        "",
        "Each simulation assertion of the verification plan (vplan §4, Runs = sim or both) is broken on",
        "purpose in its own run of the negative-test bench: a `force` on a DUT register or net, or",
        "stimulus that breaks an assumption. A case passes when its label fails at the first failing",
        "time and nothing failed before the fault. Labels that fail at the same time are listed as",
        "co-fired: the fault breaks those properties too. A clean run with no fault must fire nothing.",
        "",
        f"**Result:** {n_pass}/{len(cases)} cases fire; clean run {'passes' if clean_ok else '**FAILS**'}.",
        "",
        "| Label | Fault | Result | Co-fired at the same time |",
        "|---|---|---|---|",
        *rows,
        "",
        "## Labels without a case",
        "",
        *([f"- `{k}`: {v}" for k, v in nocases.items()] or ["None."]),
        "",
    ]
    if twins:
        lines += [
            "## Concurrent twins",
            "",
            "The simulation-only concurrent SVA versions (`cast_` labels) must fail together with",
            "their immediate twins, at the same first failing time of the twin's case.",
            "",
            f"**Result:** {sum(ok for *_, ok in twins)}/{len(twins)} twins fire.",
            "",
            "| Concurrent label | Case | Result |",
            "|---|---|---|",
            *[f"| `{t}` | `{imm}` | {'fires' if ok else '**FAIL**'} |" for t, imm, ok in twins],
            "",
        ]
    return "\n".join(lines)


# Command line: list, cross-check, run clean and every case, write the reports.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", type=Path, required=True, help="the built negative-test bench")
    ap.add_argument("--vplan", type=Path, required=True, help="the block's docs/vplan.md")
    ap.add_argument("--patterns", type=Path, required=True, help="common/sim/<sim>.patterns")
    ap.add_argument("--out", type=Path, required=True, help="output directory (run logs, results)")
    ap.add_argument("--doc", type=Path, help="write the Markdown page here too")
    ap.add_argument("--sim-args", default="", help="extra run arguments for every broken run")
    ap.add_argument("--timeout", type=int, default=60, help="seconds per run")
    ap.add_argument("--repro", default="make sva-neg", help="command printed for reproduction")
    ap.add_argument("--config", default="", help="configuration shown on the page, e.g. 'ASIZE=4 DSIZE=8'")
    ap.add_argument("--twins", type=Path, help="source file of concurrent twins (cast_ labels) to check")
    args = ap.parse_args(argv)
    try:
        twins = TWIN_RE.findall(args.twins.read_text()) if args.twins else []
        rules = simlog.load_rules(args.patterns)
        if not rules["assertion"]:
            raise ValueError(f"{args.patterns}: no 'assertion' pattern")
        vp = vplan_check.Vplan(args.vplan)
        mdl = vplan_check.check_structure(vp)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        print(f"sva_neg: {e}", file=sys.stderr)
        return 2
    needed = [lab for lab, r in mdl.props.items()
              if lab.startswith(("ast_", "asm_")) and r["Runs"] in ("sim", "both")]

    # 1-2: the bench's case list against the plan.
    rc, text, _ = run_bench(args.exe, ["+LIST"], args.out, "list", args.timeout)
    cases = [m.group(1) for ln in text.splitlines() if (m := CASE_RE.search(ln))]
    nocases = {m.group(1): m.group(2) for ln in text.splitlines() if (m := NOCASE_RE.search(ln))}
    problems = check_cases(needed, cases, nocases)
    if rc != 0 or not cases:
        problems.append(f"+LIST failed (exit {rc}, {len(cases)} cases)")

    # 3: the clean run.
    rc, text, log = run_bench(args.exe, [], args.out, "clean", args.timeout)
    clean_reasons = judge_clean(text, rc, rules)
    problems += [f"clean run: {r} (log {log})" for r in clean_reasons]

    # 4: one run per case.
    extra = shlex.split(args.sim_args)
    results = []
    for lab in cases:
        _, text, log = run_bench(args.exe, [f"+BREAK={lab}", *extra], args.out, lab, args.timeout)
        c = judge_case(Case(label=lab, log=str(log)), text, rules)
        results.append(c)
        co = [x for x in c.fired if x != lab]
        print(f"  {c.status}  {lab}" + (f"  (co-fired: {', '.join(co)})" if co else "")
              + (f"  — {'; '.join(c.reasons)}" if c.reasons else ""))
        problems += [f"{lab}: {r} (log {log})" for r in c.reasons]

    # 5: concurrent twins.
    twin_rows, twin_probs = check_twins(twins, results)
    problems += twin_probs

    # Reports: JSON for tools, Markdown for people (also copied to --doc).
    title = args.vplan.resolve().parent.parent.name
    md = page(results, nocases, not clean_reasons, args.repro, title, args.config, twin_rows)
    (args.out / "results.json").write_text(json.dumps(
        {"clean": {"ok": not clean_reasons, "reasons": clean_reasons}, "nocases": nocases,
         "cases": [asdict(c) for c in results],
         "twins": [{"twin": t, "case": imm, "fires": ok} for t, imm, ok in twin_rows],
         "problems": problems}, indent=1))
    (args.out / "summary.md").write_text(md)
    if args.doc:
        args.doc.write_text(md)
    n_pass = sum(c.status == "PASS" for c in results)
    for p in problems:
        print(f"  problem: {p}")
    verdict = "PASS" if not problems else "FAIL"
    twin_txt = f", {sum(ok for *_, ok in twin_rows)}/{len(twin_rows)} concurrent twins fire" if twin_rows else ""
    print(f"sva-neg {verdict}: {n_pass}/{len(results)} cases fire{twin_txt}, clean run "
          f"{'passes' if not clean_reasons else 'FAILS'}, {len(nocases)} label(s) without a case   repro: {args.repro}")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
