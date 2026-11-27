#!/usr/bin/env python3
# mcy_task.py — the test runner MCY calls for one task (M9). DUT-agnostic: everything block-specific
# (make targets, simulation runs, .sby templates) comes from the project's flow.json, written by
# mcy_run.py. Python >= 3.11, standard library only.
"""Run one MCY task: a batch of mutations, each judged by simulation or by one formal test.

MCY runs each task in tasks/<uuid>/ with input.txt ("<idx> <mutate command>" per line; idx is the
mutsel value of that mutation in the batch's netlist) and the environment PRJDIR, SCRIPTS and
MUTATIONS (the database ids, in input.txt order). The task writes output.txt ("<idx> <result>").

  mcy_task.py sim    --flow $PRJDIR/flow.json
      One netlist with every mutation of the batch (create_mutated.sh -c), one UVM build of it
      (one build at a time across all tasks: a build needs several GB, toolchain M3 note), then
      every simulation run of flow.json for every mutant, in parallel, in subset order. A mutant
      stops at its first failing run. A run that times out is retried once with three times the
      limit; a second timeout is a hang and fails the mutant (DEC-014 D5). Result PASS or FAIL.
  mcy_task.py formal --flow $PRJDIR/flow.json --test <name>
      The batch's mutations as RTLIL, then one SymbiYosys job per mutant from the test's .sby
      template (@MUTSEL@ etc. filled in). Result PASS, FAIL or TIMEOUT; anything else is ERROR,
      which MCY rejects, so a broken harness stops the run.

Concurrency: every simulation run and every formal job holds one of flow.json's `slots` (file
locks under locks/), so the machine load is the same whatever `mcy run -j` is, and a run's timeout
is never caused by an overloaded host.
Details per mutant and test go to details/<test>/<mutation id>.json (and, for a failing
simulation, the first failing run's log), which mcy_run.py turns into the report.
Exit status 0 when output.txt was written (whatever the results), 2 on a setup error.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import contextlib
import fcntl
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

# formal_run.py and simlog.py (same directory) hold the SBY log parser and the simulation judge.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import formal_run  # noqa: E402
import simlog  # noqa: E402


# One mutation of the batch: its mutsel value, database id and mutate command.
@dataclass
class Mut:
    idx: int
    mid: int
    cmd: str
    result: str = ""
    detail: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------------------------
# Shared machinery
# ---------------------------------------------------------------------------------------------

# Read the batch: input.txt lines and the database ids MCY passes in MUTATIONS (same order).
# Without MUTATIONS (a manual run) the ids are 0.
def read_batch(path: Path) -> list[Mut]:
    ids = os.environ.get("MUTATIONS", "").split()
    muts = []
    for n, line in enumerate(path.read_text().splitlines()):
        idx, cmd = line.split(" ", 1)
        muts.append(Mut(idx=int(idx), mid=int(ids[n]) if n < len(ids) else 0, cmd=cmd))
    return muts


# Global slots: N lock files; a holder of one may run one simulation or formal job.
class Slots:
    def __init__(self, lock_dir: Path, n: int):
        self.files = [lock_dir / f"slot{i}.lock" for i in range(n)]
        lock_dir.mkdir(parents=True, exist_ok=True)

    # Block until a slot is free, hold it for the with-body.
    @contextlib.contextmanager
    def take(self):
        while True:
            for path in self.files:
                f = path.open("w")
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    f.close()
                    continue
                try:
                    yield
                finally:
                    fcntl.flock(f, fcntl.LOCK_UN)
                    f.close()
                return
            time.sleep(0.25)


# An exclusive lock for the with-body (one UVM build at a time across tasks).
@contextlib.contextmanager
def file_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


# Run a shell command in its own process group with a timeout; output to log. Returns the exit
# code, or None after a timeout (the whole group is killed: make, simulator, solver).
def run_cmd(cmd: str, cwd: Path, log: Path, timeout: float | None) -> int | None:
    with log.open("w") as out:
        p = subprocess.Popen(cmd, shell=True, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            return None


# The batch's mutated design, written by MCY's own script (all mutations behind a mutsel port).
# design: the project's database/design.il when the caller is not two levels below the project.
def create_mutated(out_name: str, design: Path | None = None) -> Path:
    scripts = os.environ.get("SCRIPTS")
    if not scripts:
        raise SystemExit("mcy_task: SCRIPTS is not set (run from mcy, or export it)")
    cmd = ["bash", f"{scripts}/create_mutated.sh", "-c", "-o", out_name] + (["-d", str(design)] if design else [])
    subprocess.run(cmd, check=True)
    return Path(out_name).resolve()


# Write output.txt for MCY and one details file per mutant.
def finish(muts: list[Mut], test: str, details: Path) -> None:
    (details / test).mkdir(parents=True, exist_ok=True)
    with open("output.txt", "w") as f:
        for m in muts:
            f.write(f"{m.idx} {m.result}\n")
            if m.mid:
                (details / test / f"{m.mid}.json").write_text(json.dumps(dict(m.detail, result=m.result, mutation=m.cmd), indent=1))


# ---------------------------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------------------------

# Simulate every mutant of the batch (see module docstring). Also used by mcy_run.py's gate with
# idx 0 (the original design) as the only "mutant".
def sim_batch(flow: dict, muts: list[Mut], netlist: Path, work: Path, slots: Slots) -> None:
    s = flow["sim"]
    rules = simlog.load_rules(Path(s["patterns"]))
    out = work / "out"
    # extra_vars (optional): more make variables, e.g. SVA=0 for a scoreboard-only probe.
    mvars = (f"SIM={s['simulator']} ASIZE={flow['asize']} DSIZE={flow['dsize']} MCY=1 "
             f"DUT_SRCS={netlist} OUT={out} {s.get('extra_vars', '')}").strip()
    make = f"make --no-print-directory -C {shlex.quote(flow['ip_root'])}"

    # One build of the netlist; builds of different tasks take turns.
    t0 = time.monotonic()
    with file_lock(Path(flow["lock_dir"]) / "build.lock"):
        tb = time.monotonic()
        rc = run_cmd(f"{make} sim-build {mvars}", work, work / "build.log", None)
    build_s = round(time.monotonic() - tb, 1)
    if rc != 0:
        tail = (work / "build.log").read_text(errors="replace").splitlines()[-15:]
        for m in muts:
            m.result, m.detail = "ERROR", {"error": "UVM build of the mutated netlist failed", "log_tail": tail}
        return

    # Per-mutant state, shared by the worker threads.
    lock = threading.Lock()
    state = {m.idx: {"runs": 0, "seconds": 0.0, "fail": None, "retried": []} for m in muts}

    # One run of one mutant; a timeout is retried once with three times the limit.
    def one(run: dict, m: Mut) -> None:
        with lock:
            if state[m.idx]["fail"]:
                return
        name = f"m{m.idx}_{run['id']}"
        plus = f"{run['plusargs']} +mutsel={m.idx}".strip()
        cmd = f"{make} sim TEST={run['test']} SEED={run['seed']} RUN={name} NO_BUILD=1 PLUSARGS='{plus}' {mvars}"
        run_dir = out / "run" / f"{name}_{run['seed']}"
        limit = float(s["timeout_s"])
        for attempt in (1, 2):
            start = time.monotonic()
            with slots.take():
                rc = run_cmd(cmd, work, work / f"{name}_{run['seed']}.make.log", limit)
            secs = time.monotonic() - start
            if rc is not None or attempt == 2:
                break
            with lock:
                state[m.idx]["retried"].append(f"{run['id']} seed {run['seed']}")
            limit *= 3
        text = (run_dir / "sim.log").read_text(errors="replace") if (run_dir / "sim.log").is_file() else ""
        if rc is None:
            ok, reasons = False, [f"hang: killed after {limit:g} s twice (timeout {s['timeout_s']} s, retry x3)"]
        else:
            ok, reasons = simlog.judge(text, rules, 0) if text else (False, ["no simulator log"])
            ok = ok and rc == 0
            if rc != 0 and not reasons:
                reasons = [f"make exit code {rc}"]
        repro = (f"make sim TEST={run['test']} SEED={run['seed']} RUN={name} PLUSARGS='{plus}' "
                 f"SIM={s['simulator']} ASIZE={flow['asize']} DSIZE={flow['dsize']} MCY=1 DUT_SRCS=<mutated.v>")
        with lock:
            st = state[m.idx]
            st["runs"] += 1
            st["seconds"] += secs
            if not ok and not st["fail"]:
                st["fail"] = {"id": run["id"], "test": run["test"], "seed": run["seed"], "reasons": reasons[:4],
                              "repro": repro, "log": text.splitlines()[-400:]}

    # Run-major order: every mutant's first run goes before anyone's second, so most mutants
    # stop after one run and the batch's slots stay busy.
    jobs = [(r, m) for r in s["runs"] for m in muts]
    with cf.ThreadPoolExecutor(max_workers=max(1, int(flow["slots"]))) as pool:
        for f in [pool.submit(one, r, m) for r, m in jobs]:
            f.result()

    # Verdict and details per mutant.
    for m in muts:
        st = state[m.idx]
        fail = st["fail"]
        m.result = "FAIL" if fail else "PASS"
        m.detail = {"runs_done": st["runs"], "runs_total": len(s["runs"]), "sim_seconds": round(st["seconds"], 1),
                    "build_seconds": build_s, "build_wait_seconds": round(tb - t0, 1), "retried": st["retried"]}
        if fail:
            m.detail["first_fail"] = {k: v for k, v in fail.items() if k != "log"}
            m.detail["log_tail"] = fail["log"][-60:]


# ---------------------------------------------------------------------------------------------
# Formal
# ---------------------------------------------------------------------------------------------

# Fill a formal test's .sby template for one mutant: sizes, mutsel, timeout, and [files] with
# absolute paths (the mutated RTLIL plus the test's sources).
def render_sby(test: dict, flow: dict, idx: int, il: Path) -> str:
    text = Path(test["sby"]).read_text()
    files = [str(il)] + [str(Path(p)) for p in test["files"]]
    for key, val in {"@MUTSEL@": idx, "@ASIZE@": flow["asize"], "@DSIZE@": flow["dsize"],
                     "@TIMEOUT@": test["timeout_s"], "@FILES@": "\n".join(files)}.items():
        text = text.replace(key, str(val))
    return text


# One SBY job: run, parse the log (formal_run.parse_log), map the verdict to an MCY result.
def formal_one(flow: dict, name: str, test: dict, m: Mut, il: Path, work: Path, slots: Slots) -> None:
    sby = work / f"{name}_{m.idx}.sby"
    sby.write_text(render_sby(test, flow, m.idx, il))
    wd = work / f"{name}_{m.idx}"
    start = time.monotonic()
    with slots.take():
        rc = run_cmd(f"sby -f -d {wd} {sby}", work, work / f"{name}_{m.idx}.log", float(test["timeout_s"]) + 300)
    secs = round(time.monotonic() - start, 1)
    run = formal_run.Run(task=name, asize=int(flow["asize"]))
    log = (work / f"{name}_{m.idx}.log").read_text(errors="replace")
    formal_run.parse_log(run, log)
    verdict = "TIMEOUT" if rc is None else run.verdict
    if run.bad_warnings:
        m.result = "ERROR"
    else:
        m.result = verdict if verdict in ("PASS", "FAIL", "TIMEOUT") else "ERROR"
    m.detail = {"verdict": verdict, "seconds": secs, "failed": run.failed, "failed_steps": run.failed_steps,
                "bad_warnings": run.bad_warnings}
    if m.result == "ERROR":
        m.detail["log_tail"] = log.splitlines()[-30:]


# Every mutant of the batch through one formal test, in parallel within the slots.
def formal_batch(flow: dict, name: str, muts: list[Mut], il: Path, work: Path, slots: Slots) -> None:
    test = flow["formal"][name]
    with cf.ThreadPoolExecutor(max_workers=max(1, len(muts))) as pool:
        for f in [pool.submit(formal_one, flow, name, test, m, il, work, slots) for m in muts]:
            f.result()


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

# Parse arguments, run the batch, write output.txt and the details.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kind", choices=["sim", "formal"])
    ap.add_argument("--flow", required=True, type=Path, help="the project's flow.json (mcy_run.py)")
    ap.add_argument("--test", help="formal: the test name, a key of flow.json 'formal'")
    a = ap.parse_args(argv)
    flow = json.loads(a.flow.read_text())
    muts = read_batch(Path("input.txt"))
    work = Path.cwd()
    slots = Slots(Path(flow["lock_dir"]), int(flow["slots"]))
    details = Path(flow["details_dir"])
    if a.kind == "sim":
        sim_batch(flow, muts, create_mutated("mutated.v"), work, slots)
        finish(muts, "test_sim", details)
    else:
        if a.test not in flow.get("formal", {}):
            print(f"mcy_task: unknown formal test {a.test!r}", file=sys.stderr)
            return 2
        formal_batch(flow, a.test, muts, create_mutated("mutated.il"), work, slots)
        finish(muts, a.test, details)
    for m in muts:
        print(f"{m.idx} {m.mid} {m.result} {json.dumps({k: v for k, v in m.detail.items() if k not in ('log_tail',)})[:300]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
