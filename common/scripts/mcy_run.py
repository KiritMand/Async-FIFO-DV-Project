#!/usr/bin/env python3
# mcy_run.py — drive an MCY mutation-coverage run for a block and write its report (M9; `make mcy`).
# DUT-agnostic: the block supplies config.mcy (template), flow.toml (tests, files, timeouts),
# the simulation run list and triage.toml (dispositions). Python >= 3.11, standard library only.
"""Prepare, gate, run and report an MCY project.

Phases (each prints what it runs; the last line is the reproduction command):

  1. setup   out/<ip>/mcy/a<A>_d<D>_n<size>_s<seed>/: config.mcy from the template (sizes, paths,
             size and seed), the DUT copied as <top>.sv, flow.json for mcy_task.py. A previous
             project of the same name is removed (unless --resume or --report-only).
  2. init    `mcy init`: the design, the mutation list and the database. The list must have
             exactly `size` entries.
  3. gate    Before any mutant is judged, the harness must be right on the original design: a
             netlist with the first batch of mutations, all inactive (mutsel = 0), must pass every
             simulation run, and each run's log must equal the baseline regression's log for the
             same test and seed (the netlist is the RTL); test_eq with mutsel 0 against itself
             must PASS (the miter has no spurious difference); test_fm with mutsel 0 must PASS
             (the original netlist meets every e2e property). Any failure stops here.
  4. run     `mcy run -j <J>` (progress every minute), then `mcy status`.
  5. report  From the MCY database and mcy_task.py's details: summary.json and report.md in the
             project; with --doc, also the block's mutation report page. Each mutant that some
             method missed (UNCOVERED, FMONLY, SIMONLY, EQGAP, *TIMEOUT) needs a disposition in
             triage.toml whose `mutation` text matches; otherwise the page says so and the exit
             status is 1.

Exit 0: run complete, EQGAP = 0, every required disposition present and current. 1: otherwise
(gate failure, EQGAP, missing or stale disposition, a test ERROR). 2: setup or usage error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import tomllib
from pathlib import Path

# mcy_task.py (same directory) holds the batch runners the gate reuses; bug_matrix.py the
# classifier of a failing simulation log line.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bug_matrix  # noqa: E402
import mcy_task  # noqa: E402
import provenance  # noqa: E402

PRIMARY = ("COVERED", "UNCOVERED", "NOCHANGE", "EQGAP")
NEEDS_DISPOSITION = ("UNCOVERED", "FMONLY", "SIMONLY", "EQGAP", "EQTIMEOUT", "FMTIMEOUT")
TESTS = ("test_sim", "test_eq", "test_fm")


class SetupError(Exception):
    """Bad arguments or block files: exit 2."""


# Run a command in a directory, output to a log file; print the command. Returns the exit code.
def sh(cmd: list[str], cwd: Path, log: Path) -> int:
    print(f"+ (cd {cwd} && {' '.join(cmd)}) > {log}", flush=True)
    with log.open("w") as f:
        return subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).returncode


# Directory of MCY's helper scripts (create_mutated.sh), next to the installed mcy.
def mcy_scripts() -> Path:
    mcy = shutil.which("mcy")
    if not mcy:
        raise SetupError("mcy not on PATH (run through make, which adds the OSS CAD Suite)")
    p = Path(mcy).resolve().parent.parent / "share" / "mcy" / "scripts"
    if not (p / "create_mutated.sh").is_file():
        raise SetupError(f"no create_mutated.sh under {p}")
    return p


# ---------------------------------------------------------------------------------------------
# 1. Setup
# ---------------------------------------------------------------------------------------------

# Block settings (flow.toml) with paths made absolute, and the simulation run list.
def load_block(flow_cfg: Path) -> dict:
    base = flow_cfg.parent
    with flow_cfg.open("rb") as f:
        cfg = tomllib.load(f)
    sim = dict(cfg["sim"])
    sim["patterns"] = str((base / sim["patterns"]).resolve())
    runs_file = base / sim.pop("runs")
    if not runs_file.is_file():
        raise SetupError(f"no simulation run list {runs_file}: run `make mcy-pick` first")
    with runs_file.open("rb") as f:
        sim["runs"] = [{k: r[k] for k in ("id", "test", "seed", "plusargs")} for r in tomllib.load(f)["run"]]
    sim["runs_file"] = str(runs_file)
    formal = {}
    for name, t in cfg["formal"].items():
        formal[name] = {"sby": str((base / t["sby"]).resolve()), "timeout_s": int(t["timeout_s"]),
                        "files": [str((base / p).resolve()) for p in t["files"]]}
    report = {k: (v if k == "cells" else str((base / v).resolve())) for k, v in cfg["report"].items()}
    return {"sim": sim, "formal": formal, "report": report}


# Fill the config.mcy template: placeholders, then the size and seed option lines.
def render_config(template: Path, asize: int, dsize: int, size: int, seed: int) -> str:
    text = template.read_text()
    for key, val in {"@ASIZE@": asize, "@DSIZE@": dsize, "@COMMON@": HERE.parent}.items():
        text = text.replace(key, str(val))
    text, n1 = re.subn(r"(?m)^size\s+\d+\s*$", f"size {size}", text)
    text, n2 = re.subn(r"(?m)^seed\s+\d+\s*$", f"seed {seed}", text)
    if n1 != 1 or n2 != 1:
        raise SetupError(f"{template}: needs exactly one 'size' and one 'seed' line in [options]")
    if "@" in re.sub(r"(?m)^#.*$", "", text):
        raise SetupError(f"{template}: unfilled placeholder left: {re.findall(r'@[A-Z_]+@', text)}")
    return text


# Create the project directory: config.mcy, the DUT, flow.json.
def setup(a: argparse.Namespace, block: dict, proj: Path) -> dict:
    if proj.exists():
        shutil.rmtree(proj)
    proj.mkdir(parents=True)
    (proj / "config.mcy").write_text(render_config(a.config, a.asize, a.dsize, a.size, a.seed))
    shutil.copyfile(a.dut, proj / f"{a.top}.sv")
    flow = {"ip_root": str(a.ip_root), "asize": a.asize, "dsize": a.dsize, "slots": a.slots,
            "lock_dir": str(a.out / "mcy" / "locks"), "details_dir": str(proj / "details"),
            "sim": {k: v for k, v in block["sim"].items() if k not in ("baseline", "runs_file")},
            "formal": block["formal"]}
    (proj / "flow.json").write_text(json.dumps(flow, indent=1))
    return flow


# ---------------------------------------------------------------------------------------------
# 3. Gate
# ---------------------------------------------------------------------------------------------

# A simulation log as compared with the baseline: the MCY build prints one extra line.
def log_lines(path: Path) -> list[str]:
    return [ln for ln in path.read_text(errors="replace").splitlines() if not ln.startswith("MCY mutsel=")]


# The gate (see module docstring). Returns a dict of check -> {ok, ...}; ok overall if all ok.
def gate(proj: Path, flow: dict, block: dict, base_out: Path, batch: int) -> dict:
    work = proj / "gate" / "run"  # two levels below the project, like an MCY task
    work.mkdir(parents=True)
    muts = (proj / "database" / "mutations.txt").read_text().splitlines()[:batch]
    (work / "input.txt").write_text("".join(f"{i} {m}\n" for i, m in enumerate(muts, 1)))
    os.environ["SCRIPTS"] = str(mcy_scripts())
    os.environ.pop("MUTATIONS", None)
    cwd = os.getcwd()
    os.chdir(work)
    try:
        netlist = mcy_task.create_mutated("mutated.v")
        il = mcy_task.create_mutated("mutated.il")
    finally:
        os.chdir(cwd)
    slots = mcy_task.Slots(Path(flow["lock_dir"]), int(flow["slots"]))
    results: dict[str, dict] = {}

    # Formal gates in a background thread while the simulation gate builds and runs.
    def formal_gates() -> None:
        for name in flow["formal"]:
            m = mcy_task.Mut(idx=0, mid=0, cmd="original design")
            mcy_task.formal_one(flow, name, flow["formal"][name], m, il, work, slots)
            results[name] = {"ok": m.result == "PASS", "result": m.result, **m.detail}
            print(f"  gate {name} mutsel=0: {m.result} ({m.detail.get('seconds')} s)", flush=True)
    th = threading.Thread(target=formal_gates)
    th.start()

    # Simulation gate: every run passes with mutsel = 0 ...
    m = mcy_task.Mut(idx=0, mid=0, cmd="original design")
    print(f"  gate test_sim mutsel=0: build + {len(flow['sim']['runs'])} runs", flush=True)
    mcy_task.sim_batch(flow, [m], netlist, work, slots)
    sim = {"ok": m.result == "PASS", "result": m.result, **{k: v for k, v in m.detail.items() if k != "log_tail"}}
    # ... and matches the baseline log of the same test and seed, line for line.
    diffs = []
    if sim["ok"]:
        for r in flow["sim"]["runs"]:
            mine = work / "out" / "run" / f"m0_{r['id']}_{r['seed']}" / "sim.log"
            ref = base_out / "run" / f"{r['id']}_{r['seed']}" / "sim.log"
            if not ref.is_file():
                diffs.append(f"{r['id']} seed {r['seed']}: no baseline log {ref}")
                continue
            a, b = log_lines(mine), log_lines(ref)
            if a != b:
                n = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
                diffs.append(f"{r['id']} seed {r['seed']}: line {n + 1}: netlist {a[n] if n < len(a) else '<end>'!r} "
                             f"vs RTL {b[n] if n < len(b) else '<end>'!r}")
    sim["log_diffs"] = diffs
    sim["ok"] = sim["ok"] and not diffs
    results["test_sim"] = sim
    if m.result == "PASS":
        print(f"  gate test_sim mutsel=0: PASS, {len(flow['sim']['runs']) - len(diffs)}/{len(flow['sim']['runs'])} "
              f"logs identical to the RTL baseline", flush=True)
    else:
        print(f"  gate test_sim mutsel=0: {m.result} ({m.detail.get('error') or m.detail.get('first_fail', {}).get('reasons')}); "
              f"see {work}", flush=True)
    for d in diffs[:5]:
        print(f"    {d}")
    th.join()
    return results


# ---------------------------------------------------------------------------------------------
# 4. Run
# ---------------------------------------------------------------------------------------------

# mcy run in the background; print the number of classified mutants once a minute.
def run_mcy(proj: Path, jobs: int, size: int) -> int:
    log = proj / "mcy_run.log"
    print(f"+ (cd {proj} && mcy run -j{jobs}) > {log}", flush=True)
    start = time.monotonic()
    with log.open("w") as f:
        p = subprocess.Popen(["mcy", "run", f"-j{jobs}"], cwd=proj, stdout=f, stderr=subprocess.STDOUT)
        while p.poll() is None:
            time.sleep(60)
            try:
                db = sqlite3.connect(f"file:{proj / 'database' / 'db.sqlite3'}?mode=ro", uri=True, timeout=30)
                n, = db.execute("SELECT COUNT(DISTINCT mutation_id) FROM tags").fetchone()
                res = dict(db.execute("SELECT test, COUNT(*) FROM results GROUP BY test").fetchall())
                db.close()
                print(f"  [{(time.monotonic() - start) / 60:.0f} min] classified {n}/{size}; results "
                      + ", ".join(f"{t} {res.get(t, 0)}" for t in TESTS), flush=True)
            except sqlite3.Error:
                pass
    sh(["mcy", "status"], proj, proj / "mcy_status.log")
    return p.returncode


# ---------------------------------------------------------------------------------------------
# 5. Report
# ---------------------------------------------------------------------------------------------

# A mutate command's options as a dict; -src may repeat (kept as a list).
def parse_mutation(cmd: str) -> dict:
    toks = cmd.split()
    out: dict = {"src": []}
    for i, t in enumerate(toks[:-1]):
        if t.startswith("-") and not toks[i + 1].startswith("-"):
            if t == "-src":
                out["src"].append(toks[i + 1])
            else:
                out[t[1:]] = toks[i + 1]
    return out


# Short, stable description: mode, the signal bit it acts on (if the net has a name) and the cell
# port where it is applied (the same net feeds several cells, so the port tells them apart).
def short(m: dict) -> str:
    mode = m.get("mode", "?")
    kind = re.sub(r"\$\d+$", "", m.get("cell", "?")).rsplit("$", 1)[-1]
    at = f"{kind}.{m.get('port', '?')}[{m.get('portbit', 0)}]"
    what = f"{m['wire']}[{m.get('wirebit', 0)}] at {at}" if "wire" in m else at
    extra = f" ctrlbit {m['ctrlbit']}" if "ctrlbit" in m else ""
    return f"{mode} {what}{extra}"


# The RTL statement a mutation's cell comes from: (line number, text). A cell without a source
# location (memory_map's) has only its wire's declaration in -src, so the first `cells` entry
# (cell-name fragment -> regex on the RTL text) matching its name wins; otherwise the last -src
# (the cell's own). An `always` header gets the comment line above it, which says what the block
# holds. The "none" mutation is the original design.
def statement(m: dict, rtl: list[str], cells: dict[str, str] | None = None) -> tuple[int, str]:
    if m.get("mode") == "none":
        return 0, "(none: the original design)"
    n = 0
    for frag, rx in (cells or {}).items():
        if frag in m.get("cell", ""):
            n = next((i for i, ln in enumerate(rtl, 1) if re.search(rx, ln)), 0)
            break
    if not n:
        n = next((int(mm.group(1)) for src in reversed(m["src"]) if (mm := re.search(r":(\d+)\.\d+-", src))), 0)
    if not 0 < n <= len(rtl):
        return 0, "?"
    text = rtl[n - 1].strip()
    if text.startswith("always"):
        i = n - 2
        while i >= 0 and not rtl[i].strip().startswith("//"):
            i -= 1
        while i > 0 and rtl[i - 1].strip().startswith("//"):
            i -= 1
        above = rtl[i].strip().lstrip("/ ").split(". ")[0].split(": ")[0].rstrip(".") if i >= 0 else ""
        text = f"{text} … ({above[:70]})" if above else text
    return n, text


# Everything the report needs, from the database, the details files and triage.toml (only the
# entries for this run's seed and size; an entry without them is for seed 1, size 300).
def collect(proj: Path, triage_file: Path, top: str, cells: dict[str, str] | None = None,
            seed: int = 1, size: int = 300) -> dict:
    db = sqlite3.connect(proj / "database" / "db.sqlite3")
    muts = dict(db.execute("SELECT mutation_id, mutation FROM mutations").fetchall())
    results: dict[int, dict] = {i: {} for i in muts}
    for mid, test, res in db.execute("SELECT mutation_id, test, result FROM results"):
        results[mid][test] = res
    tags: dict[int, set] = {i: set() for i in muts}
    for mid, tag in db.execute("SELECT mutation_id, tag FROM tags"):
        tags[mid].add(tag)
    db.close()
    rtl = (proj / f"{top}.sv").read_text().splitlines()
    triage = {}
    if triage_file.is_file():
        with triage_file.open("rb") as f:
            for d in tomllib.load(f).get("disposition", []):
                if int(d.get("seed", 1)) == seed and int(d.get("size", 300)) == size:
                    triage[int(d["id"])] = d
    rows = []
    for mid, cmd in sorted(muts.items()):
        pm = parse_mutation(cmd)
        line, text = statement(pm, rtl, cells)
        det = {}
        for t in TESTS:
            p = proj / "details" / t / f"{mid}.json"
            det[t] = json.loads(p.read_text()) if p.is_file() else {}
        rows.append({"id": mid, "mutation": cmd, "short": short(pm) if pm.get("mode") != "none" else "none",
                     "line": line, "stmt": text, "results": results[mid], "tags": sorted(tags[mid]),
                     "details": det, "triage": triage.get(mid)})
    return {"rows": rows, "triage_ids": set(triage)}


# Scores and counts. sim detects = COVERED - FMONLY; formal detects = COVERED - SIMONLY.
def scores(rows: list[dict]) -> dict:
    count = {t: sum(t in r["tags"] for r in rows) for t in PRIMARY + NEEDS_DISPOSITION[1:]}
    n = count["COVERED"] + count["UNCOVERED"]
    det = {"simulation": count["COVERED"] - count["FMONLY"], "formal": count["COVERED"] - count["SIMONLY"],
           "combined": count["COVERED"]}
    return {"counts": count, "denominator": n, "detected": det,
            "score": {k: (round(100.0 * v / n, 2) if n else None) for k, v in det.items()}}


# The first failing check of a mutant simulation detected, as "<category>: <label or id>" using
# the M8 bug matrix's classifier of a failing log line (assertion, scoreboard, test check, ...).
def caught_by(r: dict) -> str:
    reasons = r["details"]["test_sim"].get("first_fail", {}).get("reasons", [])
    if any(x.startswith("hang:") for x in reasons):
        return "hang: run timeout"
    line = next((x.removeprefix("first failure: ") for x in reasons if x.startswith("first failure: ")), "")
    if not line:
        return "run ended early: " + (reasons[0][:60] if reasons else "?")
    c = bug_matrix.classify(line, {})
    if c["cat"] in ("assertion", "e2e"):
        # A mutated netlist has no white-box properties: every assertion is the e2e checker's, and
        # an immediate (ast_) and its concurrent twin (cast_) are one property.
        return f"e2e: {re.sub(r'^c?ast_', '', c['what'])}"
    return f"{c['cat']}: {c['what']}"


# Problems that make the run not done: missing/stale dispositions, EQGAP, ERRORs, missing results.
def problems(rows: list[dict]) -> list[str]:
    out = []
    for r in rows:
        if len(r["results"]) != len(TESTS) or not set(r["tags"]) & set(PRIMARY):
            out.append(f"mutant {r['id']}: incomplete (results {r['results']}, tags {r['tags']})")
        if any(v == "ERROR" for v in r["results"].values()):
            out.append(f"mutant {r['id']}: a test returned ERROR")
        if "EQGAP" in r["tags"]:
            out.append(f"mutant {r['id']}: EQGAP (proven equivalent, yet a test failed it)")
        need = [t for t in r["tags"] if t in NEEDS_DISPOSITION]
        d = r["triage"]
        if need and not d:
            out.append(f"mutant {r['id']} ({r['short']}, tags {' '.join(need)}): no disposition in triage.toml")
        elif d and d.get("mutation") != r["short"]:
            out.append(f"mutant {r['id']}: stale disposition (triage says {d.get('mutation')!r}, run has {r['short']!r})")
    return out


# Markdown table helper.
def table(head: list[str], rows: list[list]) -> list[str]:
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(str(c).replace("|", "\\|") for c in row) + " |" for row in rows]
    return out


# Render the report page (Markdown). No absolute paths: everything relative to the repo root.
def render(meta: dict, data: dict, sc: dict, probs: list[str], rel) -> str:
    rows = data["rows"]
    c = sc["counts"]
    L = [f"# {meta['ip']} — mutation coverage (MCY)", "",
         "Generated by `common/scripts/mcy_run.py` from the MCY database; do not edit. Dispositions "
         "live in `ip/" + meta["ip"] + "/mcy/triage.toml`.", "",
         f"Reproduce: `{meta['repro']}` (project `{rel(meta['proj'])}`, {meta['finished']}).", ""]

    # Setup.
    L += ["## Setup", ""]
    L += table(["Item", "Value"], [
        ["Design", f"`{rel(meta['dut'])}` at ASIZE = {meta['asize']}, DSIZE = {meta['dsize']}, without properties"],
        ["Mutations", f"{meta['size']} drawn by Yosys `mutate -list` with **seed {meta['seed']}** (the score is "
                      f"for this set: another seed draws other mutations)"],
        ["Tools", meta["tools"]],
        ["test_sim", f"UVM testbench on the mutated netlist (`MCY=1` build), {meta['sim_runs']} runs per mutant "
                     f"from `{rel(meta['sim_runs_file'])}`; checks: scoreboard, test checks, e2e checker; "
                     f"a mutant stops at its first failing run; run limit {meta['sim_timeout']} s, "
                     f"a timeout retried at 3x, then counted as a hang"],
        ["test_eq", "miter of the original and the mutant (`mcy/test_eq/`), environment = ledger assumptions "
                    "A01, A05 via the e2e checker's assumptions (A02 off, DEC-012); ABC PDR: PASS is a proof (no depth bound)"],
        ["test_fm", "mutant + e2e checker, spec properties only (no `inv_`), ledger assumptions; ABC PDR "
                    "(no depth bound); the white-box properties do not exist in a mutated netlist"],
    ])

    # Gate.
    g = meta.get("gate", {})
    if g:
        L += ["", "## Gate (original design, mutsel = 0)", ""]
        L += table(["Test", "Result", "Note"], [
            [k, "PASS" if v.get("ok") else "**FAIL**",
             (f"{len(v.get('log_diffs') or [])} log differences vs the RTL regression"
              if k == "test_sim" else f"{v.get('seconds', '?')} s")] for k, v in g.items()])

    # Scores.
    n = sc["denominator"]
    L += ["", "## Scores", "",
          f"Score = mutants detected by the method / (COVERED + UNCOVERED) = detected / {n}; NOCHANGE "
          f"mutants (proven equivalent) are excluded. Seed {meta['seed']}, size {meta['size']}.", ""]
    L += table(["Method", "Detected", "Missed", "Score"], [
        [k, sc["detected"][k], n - sc["detected"][k], f"**{sc['score'][k]:.2f}%**" if n else "n/a"]
        for k in ("simulation", "formal", "combined")])
    L += ["", "Tags: " + ", ".join(f"{t} {c[t]}" for t in c) + ".", ""]

    # Survivors and dispositions.
    need = [r for r in rows if set(r["tags"]) & set(NEEDS_DISPOSITION)]
    L += ["## Mutants a method missed, with dispositions", ""]
    if need:
        L += table(["Id", "Mutation", "RTL line", "Tags", "Missed by", "Class", "Disposition"], [
            [r["id"], f"`{r['short']}`", f"{r['line']}: `{r['stmt']}`", " ".join(t for t in r["tags"] if t != "COVERED"),
             "both" if "UNCOVERED" in r["tags"] else ("simulation" if "FMONLY" in r["tags"] else
                                                       "formal" if "SIMONLY" in r["tags"] else "-"),
             (r["triage"] or {}).get("class", "**none**"), (r["triage"] or {}).get("note", "**missing**")]
            for r in need])
    else:
        L += ["None: every non-equivalent mutant was detected by both methods."]
    fixed = [r for r in rows if r["triage"] and r["triage"].get("fixed") and not set(r["tags"]) & set(NEEDS_DISPOSITION)]
    if fixed:
        L += ["", "### Improvements driven by MCY (now detected by both methods)", ""]
        L += table(["Id", "Mutation", "Was", "Fix"], [[r["id"], f"`{r['short']}`", r["triage"].get("was", "?"),
                                                      r["triage"]["fixed"]] for r in fixed])

    # By RTL statement.
    by: dict[int, dict] = {}
    for r in rows:
        b = by.setdefault(r["line"], {"stmt": r["stmt"], "n": 0, "noc": 0, "sim": 0, "fm": 0, "miss": 0})
        b["n"] += 1
        b["noc"] += "NOCHANGE" in r["tags"]
        b["sim"] += "COVERED" in r["tags"] and "FMONLY" not in r["tags"]
        b["fm"] += "COVERED" in r["tags"] and "SIMONLY" not in r["tags"]
        b["miss"] += "UNCOVERED" in r["tags"]
    L += ["", "## By RTL statement", "",
          "The mutated cell's source line (`-src` of the mutation); one statement can hold several cells.", ""]
    L += table(["Line", "Statement", "Mutants", "NOCHANGE", "Sim detects", "Formal detects", "UNCOVERED"], [
        [ln, f"`{b['stmt']}`", b["n"], b["noc"], b["sim"], b["fm"], b["miss"]] for ln, b in sorted(by.items())])

    # What caught the detected mutants.
    simc: dict[str, int] = {}
    fmc: dict[str, int] = {}
    for r in rows:
        if r["results"].get("test_sim") == "FAIL":
            s = caught_by(r)
            simc[s] = simc.get(s, 0) + 1
        for lab in r["details"]["test_fm"].get("failed", []) if r["results"].get("test_fm") == "FAIL" else []:
            lab = re.sub(r"^ast_", "", lab)
            fmc[lab] = fmc.get(lab, 0) + 1
    L += ["", "## What detected them", "", "Simulation: the first failing check of each detected mutant.", ""]
    L += table(["First failing check", "Mutants"], sorted(([k or "?", v] for k, v in simc.items()), key=lambda x: -x[1]))
    L += ["", "Formal: the properties PDR reported failing (a mutant can fail several; PDR stops at the first "
              "counterexample it finds, so this is not every property the mutant breaks).", ""]
    L += table(["Property", "Mutants"], sorted(([k, v] for k, v in fmc.items()), key=lambda x: -x[1]))

    # Other seeds (robustness of the score) and probes (ablations), from their own result files.
    ex = meta.get("extras", {})
    if ex.get("seeds") or ex.get("probes"):
        L += ["", "## Other mutation sets and probes", ""]
    if ex.get("seeds"):
        L += ["Independent mutation sets of the same size (another seed draws other mutations); each is a "
              "full run with the same gate and tests.", ""]
        L += table(["Seed", "Mutants", "Simulation", "Formal", "Combined", "UNCOVERED", "NOCHANGE", "EQGAP", "Status", "Repro"], [
            [s["seed"], s["size"], f"{s['score']['simulation']}%", f"{s['score']['formal']}%", f"{s['score']['combined']}%",
             s["counts"]["UNCOVERED"], s["counts"]["NOCHANGE"], s["counts"]["EQGAP"],
             "complete" if not s["problems"] else f"{len(s['problems'])} open", f"`{s['repro']}`"] for s in ex["seeds"]])
    for p in ex.get("probes", []):
        c = p["counts"]
        L += ["", f"Probe `{p['name']}`: every mutant re-simulated with `{p['extra_vars']}` (same runs), against this "
                  f"run's simulation. Detected by both {c['both']}, by this run only {c['project_only']}, by the probe "
                  f"only {c['probe_only']}, by neither {c['neither']}, errors {c['error']}. Repro: `{p['repro']}`.", ""]
        only = [r for r in p["mutants"] if r["class"] == "project_only"]
        byid = {r["id"]: r for r in rows}
        if only:
            L += table(["Id", "Mutation", "RTL line", "Caught here by"], [
                [r["id"], f"`{byid[r['id']]['short']}`", f"{byid[r['id']]['line']}: `{byid[r['id']]['stmt']}`",
                 caught_by(byid[r["id"]])] for r in only])

    # Cost.
    tot = meta["cost"]
    L += ["", "## Cost", ""]
    L += table(["Part", "Value"], [[k, v] for k, v in tot.items()])

    # Problems.
    L += ["", "## Status", ""]
    L += ([f"- {p}" for p in probs] if probs else ["Complete: EQGAP = 0, no ERROR, every survivor has a current disposition."])
    L += ["", f"Repro: `{meta['repro']}`", ""]
    return "\n".join(L)


# Run-time totals from the details files.
def cost(rows: list[dict], wall_s: float | None) -> dict:
    sim_runs = sum(r["details"]["test_sim"].get("runs_done", 0) for r in rows)
    sim_s = sum(r["details"]["test_sim"].get("sim_seconds", 0) for r in rows)
    eq_s = sum(r["details"]["test_eq"].get("seconds", 0) for r in rows)
    fm_s = sum(r["details"]["test_fm"].get("seconds", 0) for r in rows)
    builds = {}
    for r in rows:
        b = r["details"]["test_sim"].get("build_seconds")
        if b is not None:
            builds[b] = 1
    out = {"simulation runs": f"{sim_runs} ({sim_s / 3600:.2f} h of slot time)",
           "equivalence (test_eq)": f"{eq_s / 3600:.2f} h of slot time",
           "formal (test_fm)": f"{fm_s / 3600:.2f} h of slot time"}
    if wall_s is not None:
        out["wall clock (mcy run)"] = f"{wall_s / 3600:.2f} h"
    return out


# Finished sibling projects (same sizes and mutation count, other seeds) and this project's probes,
# read from their own summary.json / probe.json, for the report's robustness section.
def extras(proj: Path, a: argparse.Namespace) -> dict:
    seeds = []
    for p in sorted(proj.parent.glob(f"a{a.asize}_d{a.dsize}_n{a.size}_s*/summary.json")):
        if p.parent != proj:
            s = json.loads(p.read_text())
            if s.get("denominator"):
                seeds.append(s)
    probes = [json.loads(p.read_text()) for p in sorted((proj / "probe").glob("*/probe.json"))]
    return {"seeds": sorted(seeds, key=lambda s: s["seed"]), "probes": probes}


# Tool versions for the report.
def tool_versions() -> str:
    y = subprocess.run(["yosys", "-V"], capture_output=True, text=True).stdout.strip()
    v = subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip()
    return f"{y}; {v}; MCY and SBY from the same OSS CAD Suite"


# ---------------------------------------------------------------------------------------------
# Probe: re-simulate a finished project's mutants with other make variables
# ---------------------------------------------------------------------------------------------

# Re-simulate every mutant of a finished project with extra make variables (e.g. SVA=0: the
# scoreboard and test checks without any assertion) in batches of up to `batch` mutations (one
# build each), then compare with the project's own test_sim results. A mutant the probe catches
# but the project missed would mean nondeterminism (removing checks cannot add detections), so it
# fails the probe. Writes <project>/probe/<name>/probe.json and probe.md; returns the exit status.
def probe(proj: Path, name: str, extra_vars: str, batch: int, slots_n: int, lock_dir: Path, repro: str) -> int:
    pdir = proj / "probe" / name
    if pdir.exists():
        shutil.rmtree(pdir)
    pdir.mkdir(parents=True)
    prov = provenance.record(proj.parent)   # the tree and tools this probe runs on
    flow = json.loads((proj / "flow.json").read_text())
    flow["sim"]["extra_vars"] = extra_vars
    flow["lock_dir"], flow["slots"], flow["details_dir"] = str(lock_dir), slots_n, str(pdir / "details")
    db = sqlite3.connect(proj / "database" / "db.sqlite3")
    muts = db.execute("SELECT mutation_id, mutation FROM mutations ORDER BY mutation_id").fetchall()
    main_res = dict(db.execute("SELECT mutation_id, result FROM results WHERE test = 'test_sim'").fetchall())
    db.close()
    os.environ["SCRIPTS"] = str(mcy_scripts())

    # Netlists first (create_mutated works in the current directory), then the batches in threads,
    # which share the build lock and the run slots.
    jobs = []
    cwd = os.getcwd()
    for k in range(0, len(muts), batch):
        work = pdir / f"b{k // batch}"
        work.mkdir()
        chunk = [mcy_task.Mut(idx=i + 1, mid=mid, cmd=cmd) for i, (mid, cmd) in enumerate(muts[k:k + batch])]
        (work / "input.txt").write_text("".join(f"{m.idx} {m.cmd}\n" for m in chunk))
        os.chdir(work)
        try:
            netlist = mcy_task.create_mutated("mutated.v", design=proj / "database" / "design.il")
        finally:
            os.chdir(cwd)
        jobs.append((chunk, netlist, work))
    print(f"probe {name}: {len(muts)} mutants in {len(jobs)} batches, make variables '{extra_vars}'", flush=True)
    slots = mcy_task.Slots(lock_dir, slots_n)
    threads = [threading.Thread(target=mcy_task.sim_batch, args=(flow, c, n, w, slots)) for c, n, w in jobs]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # Compare with the project, write the results.
    rows, counts = [], {"both": 0, "project_only": 0, "probe_only": 0, "neither": 0, "error": 0}
    for chunk, _, _ in jobs:
        for m in chunk:
            p, q = main_res.get(m.mid), m.result
            key = ("error" if q == "ERROR" else "both" if p == q == "FAIL" else "project_only" if p == "FAIL"
                   else "probe_only" if q == "FAIL" else "neither")
            counts[key] += 1
            rows.append({"id": m.mid, "mutation": m.cmd, "project": p, "probe": q, "class": key,
                         "probe_first_fail": m.detail.get("first_fail", {}).get("reasons", [])[:1]})
    (pdir / "probe.json").write_text(json.dumps({"name": name, "extra_vars": extra_vars, "counts": counts,
                                                 "repro": repro, "mutants": rows, "provenance": prov}, indent=1))
    lines = [f"# MCY probe `{name}` ({extra_vars}) of `{proj.name}`", "", f"Repro: `{repro}`", "",
             "| Class | Mutants |", "|---|---|"] + [f"| {k} | {v} |" for k, v in counts.items()]
    lines += ["", "Mutants the project's simulation caught but the probe did not:", ""]
    lines += [f"- {r['id']}: `{short(parse_mutation(r['mutation']))}`" for r in rows if r["class"] == "project_only"] or ["- none"]
    (pdir / "probe.md").write_text("\n".join(lines) + "\n")
    ok = counts["probe_only"] == 0 and counts["error"] == 0
    print(f"probe {name} {'PASS' if ok else 'FAIL'}: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    print(f"  report: {pdir / 'probe.md'}\n  repro: {repro}")
    return 0 if ok else 1


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

# Arguments, then the phases.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip-root", required=True, type=Path)
    ap.add_argument("--config", required=True, type=Path, help="config.mcy template")
    ap.add_argument("--flow-cfg", required=True, type=Path, help="the block's mcy/flow.toml")
    ap.add_argument("--dut", required=True, type=Path, help="the one RTL file to mutate")
    ap.add_argument("--top", default="async_fifo")
    ap.add_argument("--asize", type=int, required=True)
    ap.add_argument("--dsize", type=int, required=True)
    ap.add_argument("--size", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True, type=Path, help="block output dir (projects go to <out>/mcy/)")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4, help="mcy run -j")
    ap.add_argument("--slots", type=int, default=max(1, (os.cpu_count() or 4) - 2), help="concurrent runs/jobs")
    ap.add_argument("--resume", action="store_true", help="keep the project; mcy reset + run, then report")
    ap.add_argument("--report-only", action="store_true", help="only rebuild the report from the project")
    ap.add_argument("--doc", action="store_true", help="also write the block's report page (flow.toml [report] page)")
    ap.add_argument("--probe", default="", help="re-simulate the finished project's mutants: probe name")
    ap.add_argument("--probe-vars", default="", help="make variables for the probe build, e.g. SVA=0")
    ap.add_argument("--probe-batch", type=int, default=150, help="mutations per probe netlist (<= 255)")
    ap.add_argument("--repro", default="")
    a = ap.parse_args(argv)
    a.ip_root, a.config, a.flow_cfg, a.dut, a.out = (p.resolve() for p in (a.ip_root, a.config, a.flow_cfg, a.dut, a.out))
    repo = a.ip_root.parent.parent
    try:
        block = load_block(a.flow_cfg)
    except (SetupError, KeyError, FileNotFoundError) as e:
        print(f"mcy_run: {e}", file=sys.stderr)
        return 2
    proj = a.out / "mcy" / f"a{a.asize}_d{a.dsize}_n{a.size}_s{a.seed}"
    meta_path = proj / "meta.json"
    if a.probe:
        if not (proj / "database" / "db.sqlite3").is_file():
            print(f"mcy_run: no finished project {proj} to probe", file=sys.stderr)
            return 2
        return probe(proj, a.probe, a.probe_vars, min(a.probe_batch, 255), a.slots, a.out / "mcy" / "locks", a.repro)

    # Phases 1-4 (skipped with --report-only).
    meta: dict = {}
    if not a.report_only:
        try:
            if not a.resume:
                prov = provenance.record(a.ip_root)   # the tree and tools, before setup copies anything
                flow = setup(a, block, proj)
                if sh(["mcy", "init"], proj, proj / "mcy_init.log") != 0:
                    print(f"mcy_run FAIL: mcy init, see {proj / 'mcy_init.log'}", file=sys.stderr)
                    return 1
                n = len((proj / "database" / "mutations.txt").read_text().splitlines())
                if n != a.size:
                    print(f"mcy_run FAIL: {n} mutations, expected {a.size}", file=sys.stderr)
                    return 1
                print(f"gate: harness on the original design (mutsel = 0)", flush=True)
                g = gate(proj, flow, block, a.out / block["sim"]["baseline"], batch=32)
                meta["gate"] = g
                meta["provenance"] = prov
                meta_path.write_text(json.dumps(meta, indent=1))
                if not all(v["ok"] for v in g.values()):
                    print(f"mcy_run FAIL: gate ({', '.join(k for k, v in g.items() if not v['ok'])}); details in "
                          f"{meta_path}\n  repro: {a.repro}", file=sys.stderr)
                    return 1
            else:
                meta = json.loads(meta_path.read_text()) if meta_path.is_file() else {}
                # A resumed run records the tree again; the results page checks every record.
                meta.setdefault("provenance_resumes", []).append(provenance.record(a.ip_root))
                sh(["mcy", "reset"], proj, proj / "mcy_reset.log")
            start = time.monotonic()
            rc = run_mcy(proj, a.jobs, a.size)
            meta["wall_s"] = round(time.monotonic() - start, 1) + meta.get("wall_s", 0) if a.resume else round(time.monotonic() - start, 1)
            meta["finished"] = datetime.datetime.now().isoformat(timespec="seconds")
            meta_path.write_text(json.dumps(meta, indent=1))
            if rc != 0:
                print(f"mcy_run: mcy run exited {rc}, see {proj / 'mcy_run.log'}", file=sys.stderr)
        except SetupError as e:
            print(f"mcy_run: {e}", file=sys.stderr)
            return 2
    elif meta_path.is_file():
        meta = json.loads(meta_path.read_text())

    # Phase 5: report.
    data = collect(proj, Path(block["report"]["triage"]), a.top, block["report"].get("cells"), a.seed, a.size)
    sc = scores(data["rows"])
    probs = problems(data["rows"])
    if meta.get("gate") and not all(v["ok"] for v in meta["gate"].values()):
        probs.insert(0, "gate failed")
    rel = lambda p: os.path.relpath(p, repo)  # noqa: E731
    info = {"ip": a.ip_root.name, "proj": str(proj), "dut": str(a.dut), "asize": a.asize, "dsize": a.dsize,
            "size": a.size, "seed": a.seed, "tools": tool_versions(), "sim_runs": len(block["sim"]["runs"]),
            "sim_runs_file": block["sim"]["runs_file"], "sim_timeout": block["sim"]["timeout_s"],
            "gate": meta.get("gate", {}), "finished": meta.get("finished", "?"), "repro": a.repro,
            "cost": cost(data["rows"], meta.get("wall_s")), "extras": extras(proj, a)}
    page = render(info, data, sc, probs, rel)
    (proj / "report.md").write_text(page)
    summary = {"size": a.size, "seed": a.seed, "asize": a.asize, "dsize": a.dsize, **sc, "problems": probs,
               "finished": info["finished"], "repro": a.repro,
               "provenance": meta.get("provenance"), "provenance_resumes": meta.get("provenance_resumes", []),
               "mutants": [{k: r[k] for k in ("id", "short", "line", "results", "tags")} for r in data["rows"]]}
    (proj / "summary.json").write_text(json.dumps(summary, indent=1))
    if a.doc:
        Path(block["report"]["page"]).write_text(page)
        print(f"  wrote {rel(block['report']['page'])}")
    s = sc["score"]
    print(f"mcy {'PASS' if not probs else 'FAIL'}: seed {a.seed}, {a.size} mutants: " + ", ".join(f"{t} {v}" for t, v in sc["counts"].items())
          + (f"; scores sim {s['simulation']}%, formal {s['formal']}%, combined {s['combined']}%" if sc["denominator"] else ""))
    for p in probs[:20]:
        print(f"  {p}")
    if len(probs) > 20:
        print(f"  ... {len(probs) - 20} more in {proj / 'report.md'}")
    print(f"  report: {rel(proj / 'report.md')}")
    print(f"  repro: {a.repro}")
    return 0 if not probs else 1


if __name__ == "__main__":
    sys.exit(main())
