#!/usr/bin/env python3
"""bug_matrix.py — the planted-bug detection matrix (M8, report Q-1; `make bugs`).

For the baseline (rtl-v1 unchanged, id `base`) and every bug listed in <ip>/bugs/bugs.toml:
  1. copy rtl-v1's RTL to <out>/<id>/rtl/ and `git apply` the bug's patch (rtl/ is never touched);
  2. static: `make lint`, `make synth` and `make cdc` (structural CDC rules) on that RTL;
  3. sim_sb: `make regress SVA=0` (the UVM build without assertions: scoreboard and test checks
     only) on the [matrix] test subset, seeds 1..seeds; sim_sva: the same with every assertion;
  4. formal: `make formal` for each [matrix] formal task (bmc_bugs, prove, cover);
then writes docs/bug_matrix.md: each cell's actual result next to the prediction made before
any run, and the explanation of every difference (bugs.toml [bug.explain]).

Static checks and simulation run in one lane (UVM builds need the memory), formal in a second
lane at the same time. Every flow is a make command, so every cell has a reproduction command.
Each part's result is saved as <out>/<id>/<part>.json together with a fingerprint of the
verification environment; --report-only rebuilds the page from the saved results, and a result
whose fingerprint differs from the current tree is reported STALE.

Exit status: 0 = every result is present and current, the baseline is clean and every
difference from a prediction is explained; 1 = otherwise; 2 = setup error.
Python >= 3.11, standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

# Sibling scripts: simlog's fail patterns judge a log line, vplan_check parses the plan.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import simlog  # noqa: E402
import vplan_check  # noqa: E402

# The parts a bug is run through, the cells they fill, and the values a cell can take.
PARTS = ("static", "sim_sb", "sim_sva", "formal")
CELLS = ("static", "cdc", "sim_sb", "sim_sva", "formal", "prove", "covers_lost")
VALUES = {"static": ("yes", "no"), "cdc": ("yes", "no"), "sim_sb": ("yes", "stim", "no"), "sim_sva": ("yes", "stim", "no"),
          "formal": ("e2e", "white-box", "no"), "prove": ("pass", "fail")}
CELL_TITLE = {"static": "Static (lint, synth)", "cdc": "Structural CDC", "sim_sb": "Sim: UVM checks only", "sim_sva": "Sim: all assertions",
              "formal": "Formal: spec bmc", "prove": "Formal: prove", "covers_lost": "Formal: covers lost"}
BASE_ID, BASE_TAG, RTL_REL = "base", "rtl-v1", "rtl/async_fifo.sv"
BUG_ID_RE = re.compile(r"^B\d{2}$")

# Log formats: a failed assertion (Verilator, toolchain T14) and a UVM error or fatal message
# ("UVM_ERROR file(line) @ time: path [ID] text"; the summary count lines have no "@").
ASSERT_RE = re.compile(r"^\[(\d+)\] %Error: \S+:\d+: Assertion failed in (?:\S+\.)?(\w+)")
UVM_RE = re.compile(r"^UVM_(?:ERROR|FATAL)\b.*?@\s*(\d+):\s*\S+\s+\[(\w+)\]")
# First problem line of a lint/synth/build log.
PROBLEM_RE = re.compile(r"%(?:Error|Warning)|\bERROR\b|\bFAIL\b")
# A bmc or cover step starting in an SBY log.
STEP_RE = re.compile(r"Checking (?:cover reachability|assertions) in step (\d+)")


# One entry of bugs.toml (the baseline is built in, with the "nothing fails" predictions).
@dataclass
class Bug:
    id: str
    patch: str
    title: str
    predict: dict
    explain: dict = field(default_factory=dict)
    why: str = ""


# Everything a run needs: paths, the [matrix] settings, property kinds, output lock.
@dataclass
class Ctx:
    repo: Path
    ip_root: Path
    out: Path
    matrix: dict
    kinds: dict[str, str]
    base_text: str
    sim_vars: dict[str, str]
    jobs: int
    keep_builds: bool = False
    lock: threading.Lock = field(default_factory=threading.Lock)

    # One status line, never interleaved between the two lanes.
    def say(self, msg: str) -> None:
        with self.lock:
            print(msg, flush=True)


# ---------------------------------------------------------------------------------------------
# Inputs: bugs.toml, the vplan, the environment fingerprint
# ---------------------------------------------------------------------------------------------

# Read and validate bugs.toml: [matrix] settings and the [[bug]] list (the baseline comes first).
def load_bugs(path: Path) -> tuple[dict, list[Bug]]:
    with path.open("rb") as f:
        raw = tomllib.load(f)
    m = raw.get("matrix", {})
    for key in ("tests", "seeds", "formal_asize", "formal_tasks", "formal_timeout"):
        if key not in m:
            raise ValueError(f"{path}: [matrix] needs '{key}'")
    base = Bug(BASE_ID, "", "rtl-v1 unchanged (baseline)",
               {"static": "no", "cdc": "no", "sim_sb": "no", "sim_sva": "no", "formal": "no", "prove": "pass",
                "covers_lost": []},
               why="The matrix means nothing unless the unmodified design passes every method.")
    bugs, seen = [base], set()
    for b in raw.get("bug", []):
        bid = b.get("id", "")
        if not BUG_ID_RE.match(bid) or bid in seen:
            raise ValueError(f"{path}: bad or duplicate bug id '{bid}'")
        seen.add(bid)
        pred = b.get("predict", {})
        for cell, allowed in VALUES.items():
            if pred.get(cell) not in allowed:
                raise ValueError(f"{path}: {bid} predict.{cell} = {pred.get(cell)!r}, want one of {allowed}")
        if not isinstance(pred.get("covers_lost"), list):
            raise ValueError(f"{path}: {bid} predict.covers_lost must be a list")
        expl = b.get("explain", {})
        bad = set(expl) - set(CELLS)
        if bad:
            raise ValueError(f"{path}: {bid} explain has unknown cells {sorted(bad)}")
        if not (path.parent / b.get("patch", "")).is_file():
            raise ValueError(f"{path}: {bid} patch '{b.get('patch')}' not found next to bugs.toml")
        bugs.append(Bug(bid, b["patch"], b.get("title", ""), pred, expl, pred.get("why", "").strip()))
    return m, bugs


# The [report] findings text of bugs.toml: conclusions written after the run. Kept out of the
# [matrix] settings so editing it never makes a saved result stale.
def load_findings(path: Path) -> str:
    with path.open("rb") as f:
        return tomllib.load(f).get("report", {}).get("findings", "")


# Property kinds from vplan §4 (label -> e2e | white-box) and the §6 bug rows.
def load_vplan(path: Path) -> tuple[dict[str, str], dict[str, dict]]:
    vp = vplan_check.Vplan(path)
    mdl = vplan_check.check_structure(vp)
    kinds = {lab: r["Kind"] for lab, r in mdl.props.items()}
    rows = {bid: {"bug": r["Bug"], "violates": r["Violates"], "expected": r["Expected catch"]} for bid, r in mdl.bugs.items()}
    return kinds, rows


# The files whose change can change a result: properties, testbench, flows, scripts, the
# [matrix] settings and the bug's own patch. A saved result with another fingerprint is STALE.
def env_files(repo: Path, ip_root: Path) -> list[Path]:
    files = [ip_root / "rtl/async_fifo_props.svh", ip_root / "Makefile", ip_root / "regress/tests.toml",
             ip_root / "formal/async_fifo.sby", ip_root / "constraints/cdc.toml", repo / "common/tools.mk"]
    for d in (ip_root / "sva", ip_root / "tb/uvm", repo / "common/uvm", repo / "common/sim"):
        files += sorted(p for p in d.rglob("*") if p.is_file())
    files += [repo / "common/scripts" / n for n in ("regress.py", "formal_run.py", "simlog.py", "cdc_check.py")]
    return files


# Hash of the environment files, the base RTL, the matrix settings and the patch.
def fingerprint(files: list[Path], base_text: str, matrix: dict, patch: Path | None) -> str:
    h = hashlib.sha256()
    for f in files + ([patch] if patch else []):
        h.update(f.name.encode() + b"\0" + f.read_bytes() + b"\0")
    h.update(base_text.encode())
    h.update(json.dumps(matrix, sort_keys=True).encode())
    return h.hexdigest()[:16]


# ---------------------------------------------------------------------------------------------
# Running the flows
# ---------------------------------------------------------------------------------------------

# Environment for nested make: no MAKEFLAGS from an outer `make bugs`, so its command-line
# variables (OUT=, BUGS=) cannot leak into the per-bug flows.
def clean_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MAKEOVERRIDES", "MFLAGS", "MAKELEVEL")}


# Run `make <target> VARS` in the block directory, log everything; return (rc, seconds, repro).
def run_make(ctx: Ctx, target: str, vars_: dict[str, str], log: Path) -> tuple[int, float, str]:
    args = [target] + [f"{k}={v}" for k, v in vars_.items()]
    repro = "make " + " ".join(shlex.quote(a) for a in args)
    log.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    with log.open("w", encoding="utf-8") as f:
        f.write(f"+ {repro}\n")
        f.flush()
        rc = subprocess.run(["make", "-C", str(ctx.ip_root), "--no-print-directory"] + args, stdout=f,
                            stderr=subprocess.STDOUT, env=clean_env()).returncode
    return rc, round(time.monotonic() - t0, 1), repro


# The first line of a log that names a problem (lint warning, Yosys error, FAIL line), shortened.
def first_problem(text: str) -> str:
    for ln in text.splitlines():
        if PROBLEM_RE.search(ln) and not ln.startswith("+ "):
            return ln.strip()[:220]
    return ""


# Copy rtl-v1's RTL into <out>/<id>/rtl/ and apply the patch there. GIT_CEILING_DIRECTORIES
# keeps git from finding the repository (out/ is inside it), so paths are relative to the copy.
def prepare(ctx: Ctx, bug: Bug) -> Path:
    bdir = ctx.out / bug.id
    rtl = bdir / "rtl"
    shutil.rmtree(rtl, ignore_errors=True)
    rtl.mkdir(parents=True)
    (rtl / "async_fifo.sv").write_text(ctx.base_text, encoding="utf-8")
    if bug.patch:
        env = dict(clean_env(), GIT_CEILING_DIRECTORIES=str(bdir.parent))
        p = subprocess.run(["git", "apply", "-p3", str(ctx.ip_root / "bugs" / bug.patch)], cwd=bdir,
                           capture_output=True, text=True, env=env)
        if p.returncode != 0:
            raise RuntimeError(f"{bug.id}: git apply failed: {p.stderr.strip()}")
    return rtl


# Static part: lint, synth and the structural CDC check on the patched RTL at the simulation size;
# for cdc also the rules it found violated (its report.json).
def run_static(ctx: Ctx, bug: Bug, rtl: Path) -> dict:
    res = {}
    for target in ("lint", "synth", "cdc"):
        log = ctx.out / bug.id / f"static_{target}.log"
        rc, secs, repro = run_make(ctx, target, {**ctx.sim_vars, "RTL_DIR": str(rtl),
                                                 "OUT": str(ctx.out / bug.id / "static")}, log)
        res[target] = {"ok": rc == 0, "rc": rc, "seconds": secs, "repro": repro,
                       "first": "" if rc == 0 else first_problem(log.read_text(encoding="utf-8", errors="replace"))}
    rep = ctx.out / bug.id / "static" / "cdc" / "report.json"
    if rep.is_file():
        viol = json.loads(rep.read_text(encoding="utf-8"))["violations"]
        res["cdc"]["rules"] = sorted({v["rule"] for v in viol if not v["waived_by"]})
        res["cdc"]["violations"] = [v["msg"] for v in viol if not v["waived_by"]]
    return res


# What made a failing run fail: the first log line that the fail patterns match, classified as
# an assertion (by its vplan kind), a scoreboard or test check, or something else.
def first_failure(log: Path, status: str, fail_res: list[re.Pattern[str]], kinds: dict[str, str]) -> dict:
    if status == "TIMEOUT":
        return {"cat": "timeout", "what": "TIMEOUT", "t": None, "line": ""}
    text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    for ln in text.splitlines():
        if any(r.search(ln) for r in fail_res):
            return classify(ln, kinds)
    return {"cat": "incomplete", "what": "log incomplete", "t": None, "line": ""}


# Classify one failing log line (see first_failure).
def classify(line: str, kinds: dict[str, str]) -> dict:
    if (m := ASSERT_RE.match(line)):
        lab = m.group(2)
        if lab.startswith("cast_"):
            cat = "e2e"                      # concurrent twin of an e2e assertion (simulation only)
        elif lab.startswith("asm_"):
            cat = "assumption"               # the testbench broke a formal assumption
        else:
            cat = kinds.get(lab, "assertion")
        return {"cat": cat, "what": lab, "t": int(m.group(1)), "line": line.strip()[:220]}
    if (m := UVM_RE.match(line)):
        uid = m.group(2)
        cat = "scoreboard" if uid.startswith("SB_") else ("watchdog" if uid == "WATCHDOG" else "test check")
        return {"cat": cat, "what": uid, "t": int(m.group(1)), "line": line.strip()[:220]}
    return {"cat": "simulator", "what": line.strip()[:60], "t": None, "line": line.strip()[:220]}


# Coverage of the passing runs (regress.py merges only those): every cover and covergroup bin.
def read_cov(path: Path) -> dict | None:
    if not path.is_file():
        return None
    d = json.loads(path.read_text(encoding="utf-8"))
    bins = {}
    for g, gd in d.get("groups", {}).items():
        for it, idata in gd.get("items", {}).items():
            for b, n in idata.get("bins", {}).items():
                bins[f"{g}.{it}.{b}"] = n
    return {"merged": d.get("merged_runs", 0), "covers": d.get("covers", {}), "bins": bins}


# Remove a finished build's objects (about 0.9 GB per UVM build), keeping its build.log.
def prune_builds(build_root: Path) -> None:
    for d in build_root.glob("*/"):
        for p in d.iterdir():
            if p.name != "build.log":
                shutil.rmtree(p) if p.is_dir() else p.unlink()


# Simulation part: one regression of the [matrix] subset, with (sim_sva) or without (sim_sb)
# assertions; per-run status and first failure, plus the merged coverage of the passing runs.
def run_sim(ctx: Ctx, bug: Bug, rtl: Path, sva: bool, jobs: int) -> dict:
    part = "sim_sva" if sva else "sim_sb"
    out = ctx.out / bug.id / part
    res_json = out / "regress" / "results.json"
    if res_json.exists():
        res_json.unlink()
    vars_ = {"SIM": "verilator", **ctx.sim_vars, "RTL_DIR": str(rtl), "OUT": str(out),
             "N": str(ctx.matrix["seeds"]), "TESTS": " ".join(ctx.matrix["tests"]), "J": str(jobs)}
    if not sva:
        vars_["SVA"] = "0"
    log = ctx.out / bug.id / f"{part}.log"
    rc, secs, repro = run_make(ctx, "regress", vars_, log)
    # make itself exits 2 whenever a recipe fails, so its status cannot tell failing runs from a
    # broken flow. regress.py writes results.json only after a successful build: no file, no runs.
    if not res_json.is_file():
        return {"error": first_problem(log.read_text(encoding="utf-8", errors="replace")) or f"regress exit {rc}",
                "rc": rc, "seconds": secs, "repro": repro, "runs": []}
    fail_res = simlog.load_rules(ctx.repo / "common/sim/verilator.patterns")["fail"]
    runs = []
    for r in json.loads(res_json.read_text(encoding="utf-8"))["runs"]:
        rec = {"id": r["id"], "seed": r["seed"], "status": r["status"], "repro": r["repro"]}
        if r["status"] != "PASS":
            rec["first"] = first_failure(Path(r["run_dir"]) / "sim.log", r["status"], fail_res, ctx.kinds)
        runs.append(rec)
    if not ctx.keep_builds:
        prune_builds(out / "build")
    return {"rc": rc, "seconds": secs, "repro": repro, "runs": runs, "cov": read_cov(out / "cov" / "functional.json")}


# Formal part: each [matrix] formal task on the patched RTL (EXPECT=any: record, never judge).
def run_formal(ctx: Ctx, bug: Bug, rtl: Path) -> dict:
    a, d = ctx.matrix["formal_asize"], 4
    res = {}
    for task in ctx.matrix["formal_tasks"]:
        vars_ = {"TASK": task, "ASIZE": str(a), "DSIZE": str(d), "EXPECT": "any", "RTL_DIR": str(rtl),
                 "OUT": str(ctx.out / bug.id), "TIMEOUT": str(ctx.matrix["formal_timeout"])}
        rc, secs, repro = run_make(ctx, "formal", vars_, ctx.out / bug.id / f"formal_{task}.log")
        summ = ctx.out / bug.id / "formal" / f"a{a}_d{d}" / task / "summary.json"
        s = json.loads(summ.read_text(encoding="utf-8")) if summ.is_file() else {}
        res[task] = {"verdict": s.get("verdict", "ERROR"), "seconds": s.get("seconds", secs), "failed": s.get("failed", []),
                     "failed_steps": s.get("failed_steps", {}), "reached": sorted(s.get("reached", {})),
                     "unreached": s.get("unreached", []), "bad_warnings": s.get("bad_warnings", []), "rc": rc, "repro": repro,
                     "last_step": last_step(Path(s["workdir"]) / "logfile.txt" if s.get("workdir") else None)}
    return res


# Deepest bmc/cover step an SBY task started (how far a timed-out run got), from its log.
def last_step(log: Path | None) -> int | None:
    if not log or not log.is_file():
        return None
    steps = STEP_RE.findall(log.read_text(encoding="utf-8", errors="replace"))
    return int(steps[-1]) if steps else None


# Save one part's result with the fingerprint it was produced under.
def save_part(ctx: Ctx, bug: Bug, part: str, fp: str, data: dict) -> None:
    p = ctx.out / bug.id / f"{part}.json"
    p.write_text(json.dumps({"fingerprint": fp, "finished": time.strftime("%Y-%m-%dT%H:%M:%S"), "data": data},
                            indent=1) + "\n", encoding="utf-8")


# Run the selected parts of the selected bugs: the static+sim lane and the formal lane at once.
def run_all(ctx: Ctx, bugs: list[Bug], parts: list[str], fps: dict[str, str]) -> None:
    rtls = {b.id: prepare(ctx, b) for b in bugs}
    errors: list[str] = []
    sim_jobs = max(1, ctx.jobs - 1) if "formal" in parts else ctx.jobs

    # Lane 1: static checks, then the two simulation regressions, bug by bug.
    def sim_lane() -> None:
        for b in bugs:
            for part in ("static", "sim_sb", "sim_sva"):
                if part not in parts:
                    continue
                t0 = time.monotonic()
                ctx.say(f"[{b.id}] {part} ...")
                try:
                    data = run_static(ctx, b, rtls[b.id]) if part == "static" else \
                        run_sim(ctx, b, rtls[b.id], part == "sim_sva", sim_jobs)
                except Exception as e:   # record and go on: one broken bug must not stop the matrix
                    errors.append(f"{b.id} {part}: {e}")
                    continue
                save_part(ctx, b, part, fps[b.id], data)
                ctx.say(f"[{b.id}] {part} done in {time.monotonic() - t0:.0f} s: {short(part, data)}")

    # Lane 2: the formal tasks, bug by bug.
    def formal_lane() -> None:
        for b in bugs:
            t0 = time.monotonic()
            ctx.say(f"[{b.id}] formal ...")
            try:
                data = run_formal(ctx, b, rtls[b.id])
            except Exception as e:
                errors.append(f"{b.id} formal: {e}")
                continue
            save_part(ctx, b, "formal", fps[b.id], data)
            ctx.say(f"[{b.id}] formal done in {time.monotonic() - t0:.0f} s: {short('formal', data)}")

    lanes = []
    if any(p in parts for p in ("static", "sim_sb", "sim_sva")):
        lanes.append(threading.Thread(target=sim_lane))
    if "formal" in parts:
        lanes.append(threading.Thread(target=formal_lane))
    for t in lanes:
        t.start()
    for t in lanes:
        t.join()
    for e in errors:
        ctx.say(f"bug_matrix: ERROR {e}")


# One-line summary of a part's result, for the progress lines.
def short(part: str, data: dict) -> str:
    if part == "static":
        return ", ".join(f"{t} {'PASS' if r['ok'] else 'FAIL'}" for t, r in data.items())
    if part == "formal":
        return ", ".join(f"{t} {r['verdict']}" for t, r in data.items())
    if data.get("error"):
        return f"ERROR {data['error']}"
    n = len(data["runs"])
    return f"{sum(r['status'] != 'PASS' for r in data['runs'])}/{n} runs failed"


# ---------------------------------------------------------------------------------------------
# Judging: actual cell values, comparison with the predictions
# ---------------------------------------------------------------------------------------------

# Actual value of every cell from a bug's saved parts (None = not run, "error" = flow broke).
def actual_cells(parts: dict[str, dict], kinds: dict[str, str], base_reached: list[str] | None) -> dict:
    cells: dict = {}
    st = parts.get("static")
    cells["static"] = None if st is None else ("yes" if not (st["lint"]["ok"] and st["synth"]["ok"]) else "no")
    cells["cdc"] = None if not st or "cdc" not in st else ("no" if st["cdc"]["ok"] else "yes")
    for p in ("sim_sb", "sim_sva"):
        d = parts.get(p)
        if d is None:
            cells[p] = None
        elif d.get("error") or not d["runs"]:
            cells[p] = "error"
        else:
            nf = sum(r["status"] != "PASS" for r in d["runs"])
            cells[p] = "yes" if nf == len(d["runs"]) else ("stim" if nf else "no")
    fm = parts.get("formal")
    cells["formal"] = cells["prove"] = cells["covers_lost"] = None
    if fm:
        b = fm.get("bmc_bugs")
        if b:
            ks = {kinds.get(lab, "other") for lab in b["failed"]}
            if b["verdict"] not in ("PASS", "FAIL") or b["bad_warnings"]:
                cells["formal"] = "error"
            else:
                cells["formal"] = "e2e" if "e2e" in ks else ("white-box" if "white-box" in ks else
                                                            ("no" if b["verdict"] == "PASS" else "other"))
        pr = fm.get("prove")
        if pr:
            cells["prove"] = {"PASS": "pass", "FAIL": "fail", "UNKNOWN": "fail"}.get(pr["verdict"], "error")
        cv = fm.get("cover")
        if cv and base_reached is not None:
            # A TIMEOUT is a bounded result: covers not reached before the time limit count as lost,
            # and the page says so with the step the search had reached.
            cells["covers_lost"] = sorted(set(base_reached) - set(cv["reached"])) \
                if cv["verdict"] in ("PASS", "FAIL", "TIMEOUT") else "error"
    return cells


# Cells whose actual value differs from the prediction (not-run cells are not compared).
def differences(bug: Bug, cells: dict) -> list[str]:
    out = []
    for c in CELLS:
        a, p = cells.get(c), bug.predict.get(c)
        if a is None:
            continue
        if (sorted(a) if isinstance(a, list) else a) != (sorted(p) if isinstance(p, list) else p):
            out.append(c)
    return out


# ---------------------------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------------------------

# Markdown cell for a code-like name.
def code(s: str) -> str:
    return f"`{s}`"


# Human form of an actual value in the summary table, from the part data.
def show_cell(cell: str, value, parts: dict, matrix: dict, kinds: dict[str, str] | None = None) -> str:
    if value is None:
        return "not run"
    if value == "error":
        return "ERROR"
    if cell == "static":
        st = parts["static"]
        bad = [t for t in ("lint", "synth") if not st[t]["ok"]]
        return f"caught: {', '.join(bad)}" if bad else "pass"
    if cell == "cdc":
        c = parts["static"]["cdc"]
        return "pass" if c["ok"] else f"caught: {', '.join(c.get('rules') or ['error'])}"
    if cell in ("sim_sb", "sim_sva"):
        runs = parts[cell]["runs"]
        nf = sum(r["status"] != "PASS" for r in runs)
        return f"{nf}/{len(runs)}"
    fm = parts["formal"]
    if cell == "formal":
        b = fm["bmc_bugs"]
        if value == "no":
            return "none (depth 20)"
        # The step shown is the first failure of the kind reported (e2e or white-box), not of any label.
        steps = [b["failed_steps"][lab] for lab in b["failed"]
                 if lab in b["failed_steps"] and (kinds is None or kinds.get(lab) == value)]
        return f"{value} @{min(steps)}" if steps else value
    if cell == "prove":
        return fm["prove"]["verdict"]
    cv = fm["cover"]
    total = max(len(cv["reached"]) + len(cv["unreached"]), len(cv["reached"]) + len(value))
    bound = f" (timeout at step {cv.get('last_step', '?')})" if cv["verdict"] == "TIMEOUT" else ""
    return f"{len(cv['reached'])}/{total}" + (f", lost {len(value)}" if value else "") + bound


# Summary-table cell: the actual value, then a check mark or the differing prediction.
def table_cell(bug: Bug, cell: str, cells: dict, parts: dict, matrix: dict, kinds: dict[str, str]) -> str:
    s = show_cell(cell, cells.get(cell), parts, matrix, kinds)
    if cells.get(cell) is None:
        return s
    p = bug.predict[cell]
    if cell in differences(bug, {cell: cells[cell]}):
        ptxt = (", ".join(p) if p else "none") if isinstance(p, list) else p
        return f"{s} **≠ {ptxt}**"
    return f"{s} ✓"


# Per-test failing counts of one simulation part, in [matrix] test order.
def per_test(runs: list[dict], tests: list[str]) -> dict[str, tuple[int, int]]:
    out = {t: [0, 0] for t in tests}
    for r in runs:
        if r["id"] in out:
            out[r["id"]][1] += 1
            out[r["id"]][0] += r["status"] != "PASS"
    return {t: (f, n) for t, (f, n) in out.items()}


# First failure of a simulation part (in test order, then seed) and the first-catcher histogram.
def sim_story(runs: list[dict], tests: list[str]) -> tuple[dict | None, list[tuple[str, int]]]:
    order = {t: i for i, t in enumerate(tests)}
    bad = sorted((r for r in runs if r["status"] != "PASS"), key=lambda r: (order.get(r["id"], 99), r["seed"]))
    hist: dict[str, int] = {}
    for r in bad:
        f = r["first"]
        key = f"{f['cat']} {code(f['what'])}"
        hist[key] = hist.get(key, 0) + 1
    return (bad[0] if bad else None), sorted(hist.items(), key=lambda kv: (-kv[1], kv[0]))


# Coverage that the baseline's passing runs hit and the bug's passing runs never hit.
def sim_cov_lost(base: dict | None, bug: dict | None) -> tuple[list[str], int] | None:
    if not base or not bug or not bug.get("merged"):
        return None
    lost = [c for c, n in base["covers"].items() if n and not bug["covers"].get(c)]
    lost += [b for b, n in base["bins"].items() if n and not bug["bins"].get(b)]
    return sorted(lost), bug["merged"]


# The whole page.
def render(bugs: list[Bug], results: dict[str, dict], stale: dict[str, list[str]], matrix: dict,
           vrows: dict[str, dict], kinds: dict[str, str], repro: str, findings: str = "") -> str:
    tests = matrix["tests"]
    nruns = len(tests) * matrix["seeds"]
    base_parts = results.get(BASE_ID, {})
    base_reached = base_parts.get("formal", {}).get("cover", {}).get("reached")
    L = ["# Planted-bug detection matrix (report Q-1)", "",
         f"Generated by `common/scripts/bug_matrix.py` (`{repro}`) on {time.strftime('%Y-%m-%d')}; "
         "do not edit by hand. Bugs, predictions and explanations: `ip/async_fifo/bugs/bugs.toml`; "
         "patches: `ip/async_fifo/bugs/*.patch` (against tag `rtl-v1`). Plan: vplan §6.", "",
         "**Methods.** Each bug runs through these checks:",
         "- **Static.** `make lint` (Verilator `-Wall`) and `make synth` (Yosys `check -assert` and a flop count).",
         "- **Structural CDC.** `make cdc` (`common/scripts/cdc_check.py`, rules R1–R3 on the Yosys netlist; "
         "waivers in `constraints/cdc.toml`).",
         f"- **Sim: UVM checks only.** `make regress SVA=0` builds the UVM testbench with `--no-assert`, which "
         f"leaves the scoreboard and the test-level checks. It runs {len(tests)} tests × seeds "
         f"1–{matrix['seeds']} = {nruns} runs at ASIZE=4, DSIZE=8.",
         "- **Sim: all assertions.** The same runs with the white-box, e2e and `asm_` assertions on (the "
         "SO-2 build). The first assertion failure stops a run, so the catcher listed is the first check to fire.",
         f"- **Formal** at ASIZE={matrix['formal_asize']}, DSIZE=4:",
         "  - `bmc_bugs`: the spec properties without the invariants, depth 20, `--keep-going`. "
         "It lists every label that fails, with its step.",
         "  - `prove`: k-induction with the invariants.",
         "  - `cover`: which covers stay reachable. Cover mode ignores assertions (toolchain T19).", "",
         "Reproduction commands run from the repository root. ($PWD is the root.)", "",
         "**Reading a cell.** ✓ means the result matched the prediction written before any run; "
         "**≠ x** means the prediction was x. Simulation cells give failing runs out of the total. "
         "`e2e @n` means an end-to-end (ports-only) property failed, first at formal step n. "
         "`white-box` means only properties on internal signals failed. Every ≠ is explained under its bug. "
         "A `cast_` label is the concurrent twin of the e2e assertion with the same name (simulation only); "
         "both fail in the same time step, and the log lists the twin first.", ""]
    # Summary table.
    L += ["## Summary", "", "| Bug | " + " | ".join(CELL_TITLE[c] for c in CELLS) + " |",
          "|---" * (len(CELLS) + 1) + "|"]
    for b in bugs:
        parts = results.get(b.id, {})
        cells = actual_cells(parts, kinds, base_reached)
        name = "baseline (rtl-v1)" if b.id == BASE_ID else f"{b.id} {b.title}"
        L.append(f"| {name}{' **STALE**' if stale.get(b.id) else ''} | "
                 + " | ".join(table_cell(b, c, cells, parts, matrix, kinds) for c in CELLS) + " |")
    # Conclusions written after the run (bugs.toml [report] findings), right below the summary.
    if findings.strip():
        L += ["", "## Findings", "", findings.strip()]
    # Per-test table.
    L += ["", "## Failing runs per test", "",
          f"Failing runs out of {matrix['seeds']} per test: UVM checks only · all assertions.", "",
          "| Bug | " + " | ".join(t.removesuffix("_test") for t in tests) + " |", "|---" * (len(tests) + 1) + "|"]
    for b in bugs:
        parts = results.get(b.id, {})
        if not parts.get("sim_sb") or not parts.get("sim_sva"):
            continue
        a, s = per_test(parts["sim_sb"]["runs"], tests), per_test(parts["sim_sva"]["runs"], tests)
        L.append(f"| {b.id} | " + " | ".join(f"{a[t][0]} · {s[t][0]}" for t in tests) + " |")
    # Per-bug details.
    L += ["", "## Bugs", ""]
    for b in bugs:
        L += render_bug(b, results.get(b.id, {}), stale.get(b.id, []), vrows.get(b.id), base_parts, base_reached,
                        kinds, tests)
    return "\n".join(L).rstrip() + "\n"


# One bug's section: prediction, what each method saw, repro commands, explained differences.
def render_bug(b: Bug, parts: dict, stale: list[str], vrow: dict | None, base_parts: dict,
               base_reached: list[str] | None, kinds: dict[str, str], tests: list[str]) -> list[str]:
    title = "Baseline: rtl-v1 unchanged" if b.id == BASE_ID else f"{b.id}: {b.title}"
    L = [f"### {title}", ""]
    if b.patch:
        L.append(f"Patch `bugs/{b.patch}`." + (f" Violates {vrow['violates']} (vplan §6)." if vrow else ""))
    if stale:
        L.append(f"**STALE:** {', '.join(stale)} ran under another environment fingerprint; rerun `make bugs BUGS={b.id}`.")
    L += ["", f"**Prediction** (written before the run): {b.why}", ""]
    st = parts.get("static")
    if st:
        for t, r in st.items():
            what = "; ".join(r["violations"]) if r.get("violations") else (r["first"] or "see log")
            L.append(f"- **{t}:** {'PASS' if r['ok'] else 'FAIL: ' + code(what)}" + ("" if r["ok"] else f" · repro `{r['repro']}`"))
    for p in ("sim_sb", "sim_sva"):
        d = parts.get(p)
        if not d:
            continue
        if d.get("error"):
            L.append(f"- **{CELL_TITLE[p]}:** ERROR {code(d['error'])} · repro `{d['repro']}`")
            continue
        first, hist = sim_story(d["runs"], tests)
        nf = sum(r["status"] != "PASS" for r in d["runs"])
        line = f"- **{CELL_TITLE[p]}:** {nf}/{len(d['runs'])} runs fail"
        if first:
            line += (f"; first caught by {', '.join(f'{k} ×{n}' for k, n in hist)}. First failing run: "
                     f"{first['id']} seed {first['seed']}: {code(first['first']['line'] or first['first']['what'])} · "
                     f"repro `{first['repro']}`")
        L.append(line)
        if p == "sim_sva":
            lost = sim_cov_lost((base_parts.get("sim_sva") or {}).get("cov"), d.get("cov"))
            if lost is not None and lost[0]:
                L.append(f"  - Coverage hit on rtl-v1 but never here ({lost[1]} passing runs merged): "
                         + ", ".join(code(x) for x in lost[0]))
    fm = parts.get("formal")
    if fm:
        for task, r in fm.items():
            line = f"- **formal {task}:** {r['verdict']} ({r['seconds']} s)"
            if r["failed"]:
                fails = sorted(r["failed"], key=lambda lab: (r["failed_steps"].get(lab, 99), lab))
                line += "; failed: " + ", ".join(
                    f"{code(lab)} ({kinds.get(lab, 'invariant' if lab.startswith('inv_') else 'other')}"
                    + (f", step {r['failed_steps'][lab]}" if lab in r["failed_steps"] and task != "prove" else "") + ")"
                    for lab in fails)
            if task == "cover" and base_reached is not None:
                lost = sorted(set(base_reached) - set(r["reached"]))
                line += f"; {len(r['reached'])}/{max(len(r['reached']) + len(r['unreached']), len(base_reached))} reached" + \
                        (f", lost vs rtl-v1: {', '.join(code(x) for x in lost)}" if lost else "")
                if r["verdict"] == "TIMEOUT":
                    line += (f" (bounded: the search stopped at step {r.get('last_step', '?')} at the time limit, so a"
                             " lost cover may only be deeper than that)")
            if r["bad_warnings"]:
                line += f"; forbidden Yosys warnings: {len(r['bad_warnings'])}"
            L.append(line + f" · repro `{r['repro']}`")
    cells = actual_cells(parts, kinds, base_reached)
    diffs = differences(b, cells)
    if diffs:
        L += ["", "**Differences from the prediction**", ""]
        for c in diffs:
            txt = b.explain.get(c, "").strip()
            L.append(f"- {CELL_TITLE[c]}: predicted {fmt_val(b.predict[c])}, got {fmt_val(cells[c])}. "
                     + (txt if txt else "**UNEXPLAINED**"))
    L.append("")
    return L


# The committed page must not carry this machine's absolute paths: in a make command (VAR=path)
# the repository root becomes $PWD (the commands run from the root, which forwards to the
# block), anywhere else it is dropped (a path relative to the root).
def shorten(text: str, repo: Path) -> str:
    root = str(repo).rstrip("/") + "/"
    return re.sub(r"=" + re.escape(root), "=$PWD/", text).replace(root, "")


# A cell value in prose.
def fmt_val(v) -> str:
    if isinstance(v, list):
        return ", ".join(code(x) for x in v) if v else "none"
    return f"**{v}**"


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

# Load saved parts of every bug and note which are stale.
def load_results(out: Path, bugs: list[Bug], fps: dict[str, str]) -> tuple[dict, dict]:
    results, stale = {}, {}
    for b in bugs:
        for part in PARTS:
            p = out / b.id / f"{part}.json"
            if p.is_file():
                d = json.loads(p.read_text(encoding="utf-8"))
                results.setdefault(b.id, {})[part] = d["data"]
                if d["fingerprint"] != fps[b.id]:
                    stale.setdefault(b.id, []).append(part)
    return results, stale


# Problems that make the run fail: missing or stale results, a dirty baseline, unexplained
# differences, broken flows.
def problems(bugs: list[Bug], results: dict, stale: dict, kinds: dict[str, str]) -> list[str]:
    out = []
    base_reached = results.get(BASE_ID, {}).get("formal", {}).get("cover", {}).get("reached")
    for b in bugs:
        parts = results.get(b.id, {})
        missing = [p for p in PARTS if p not in parts]
        if missing:
            out.append(f"{b.id}: no result for {', '.join(missing)}")
        if stale.get(b.id):
            out.append(f"{b.id}: stale {', '.join(stale[b.id])}")
        cells = actual_cells(parts, kinds, base_reached)
        for c, v in cells.items():
            if v == "error":
                out.append(f"{b.id}: {c} flow error")
        for c in differences(b, cells):
            if b.id == BASE_ID:
                out.append(f"baseline is not clean: {c} = {cells[c]}")
            elif not b.explain.get(c, "").strip():
                out.append(f"{b.id}: {c} differs from the prediction and has no explanation in bugs.toml")
    return out


# Parse arguments, check the base RTL, run what was asked, write the page, report problems.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip-root", type=Path, required=True, help="the block directory (ip/async_fifo)")
    ap.add_argument("--out", type=Path, required=True, help="output directory for the bug runs (under out/)")
    ap.add_argument("--doc", type=Path, help="page to write (default <ip-root>/docs/bug_matrix.md)")
    ap.add_argument("--only", nargs="+", metavar="ID", help="run only these ids (base, B01, ...)")
    ap.add_argument("--methods", nargs="+", choices=PARTS, default=list(PARTS), help="run only these parts")
    ap.add_argument("--report-only", action="store_true", help="rebuild the page from saved results")
    ap.add_argument("--sim-vars", default="ASIZE=4 DSIZE=8", help="size variables for lint, synth and simulation")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--keep-builds", action="store_true", help="keep UVM build objects (about 0.9 GB each)")
    ap.add_argument("--repro", default="make bugs", help="the command that reproduces this run (printed)")
    args = ap.parse_args(argv)
    ip_root = args.ip_root.resolve()
    repo = Path(subprocess.run(["git", "-C", str(ip_root), "rev-parse", "--show-toplevel"], capture_output=True,
                               text=True, check=True).stdout.strip())
    try:
        matrix, bugs = load_bugs(ip_root / "bugs" / "bugs.toml")
        findings = load_findings(ip_root / "bugs" / "bugs.toml")
        kinds, vrows = load_vplan(ip_root / "docs" / "vplan.md")
        rel = (ip_root / RTL_REL).relative_to(repo).as_posix()
        base_text = subprocess.run(["git", "-C", str(repo), "show", f"{BASE_TAG}:{rel}"], capture_output=True,
                                   text=True, check=True).stdout
        if (ip_root / RTL_REL).read_text(encoding="utf-8") != base_text:
            raise ValueError(f"{RTL_REL} differs from tag {BASE_TAG}: the patches target {BASE_TAG}; "
                             "regenerate them for the new RTL (plan M8 pitfall)")
        if args.only and (unknown := set(args.only) - {b.id for b in bugs}):
            raise ValueError(f"--only: unknown ids {sorted(unknown)}")
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print(f"bug_matrix: {e}", file=sys.stderr)
        return 2
    files = env_files(repo, ip_root)
    fps = {b.id: fingerprint(files, base_text, matrix, ip_root / "bugs" / b.patch if b.patch else None) for b in bugs}
    sim_vars = dict(kv.split("=", 1) for kv in args.sim_vars.split())
    ctx = Ctx(repo, ip_root, args.out.resolve(), matrix, kinds, base_text, sim_vars, args.jobs, args.keep_builds)
    if not args.report_only:
        sel = [b for b in bugs if not args.only or b.id in args.only]
        t0 = time.monotonic()
        try:
            run_all(ctx, sel, args.methods, fps)
        except RuntimeError as e:
            print(f"bug_matrix: {e}", file=sys.stderr)
            return 2
        ctx.say(f"bug_matrix: ran {len(sel)} ids x {', '.join(args.methods)} in {(time.monotonic() - t0) / 60:.1f} min")
    results, stale = load_results(ctx.out, bugs, fps)
    doc = args.doc or ip_root / "docs" / "bug_matrix.md"
    page = render(bugs, results, stale, matrix, vrows, kinds, args.repro, findings)
    doc.write_text(shorten(page, repo), encoding="utf-8")
    probs = problems(bugs, results, stale, kinds)
    for p in probs:
        print(f"bug_matrix: {p}")
    print(f"bug_matrix {'PASS' if not probs else 'FAIL'}: {doc}" + (f" ({len(probs)} problems)" if probs else "")
          + f"   repro: {args.repro}")
    return 0 if not probs else 1


if __name__ == "__main__":
    sys.exit(main())
