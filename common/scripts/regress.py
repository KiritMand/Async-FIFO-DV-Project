#!/usr/bin/env python3
# regress.py — parallel regression and coverage merge (plan M5 step 2).
# DUT-agnostic: what to build and run comes from the block's regress/tests.toml ([flow] and
# [[test]]); pass/fail rules from common/sim/<sim>.patterns (simlog.judge); the coverage merge
# from a per-simulator class below. Python >= 3.11, standard library only.
"""Run a block's regression: build once, run every test x seed in parallel, judge each log,
merge the coverage of the passing runs, and write the reports.

Outputs (under --out):
  regress/results.json   one record per run: status, reasons, seconds, repro command, cfg line
  regress/summary.md     per-test table, failing runs with rerun commands, coverage summary
  regress/junit.xml      JUnit XML for CI (one testsuite per tests.toml entry)
  regress/logs/          make's output for each run (the simulator log stays in the run dir)
  cov/                   merged database, functional.{json,md}, code.{json,md}, annotated source

Exit status: 0 every run passed and the merge checked out; 1 a run failed, the merge disagreed
with the per-run sum, or a recheck log differed; 2 usage, configuration or build error.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass, field
from pathlib import Path

import provenance

# simlog.py (same directory) holds the log judge and the [CFG] line pattern.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import simlog  # noqa: E402

COMMON = HERE.parent
REPRO_LINE = re.compile(r"^\s*repro:\s*(.+?)\s*$")


class ConfigError(Exception):
    """A malformed tests.toml or command line: exit 2, never a silent partial run."""


# ---------------------------------------------------------------------------------------------
# Configuration: tests.toml
# ---------------------------------------------------------------------------------------------

FLOW_KEYS = {"dir", "build", "run", "run_dir"}
TEST_KEYS = {"name", "id", "seeds", "timeout_s", "plusargs"}


# One [[test]] entry after defaults are applied. id names the run directory and the report row.
@dataclass
class Entry:
    id: str
    name: str
    seeds: int
    timeout_s: float
    plusargs: str


# Read tests.toml: the [flow] commands (dir resolved against the file) and the entries, with
# [defaults] applied, the optional id filter, and the optional seed override. The override
# replaces the default seed count (the vplan's N); entries with their own `seeds` keep it.
def load_config(path: Path, seeds: int | None = None, only: list[str] | None = None) -> tuple[dict, list[Entry]]:
    with path.open("rb") as f:
        raw = tomllib.load(f)
    unknown = set(raw) - {"flow", "defaults", "test"}
    if unknown:
        raise ConfigError(f"{path}: unknown sections {sorted(unknown)}")
    flow = raw.get("flow", {})
    if set(flow) != FLOW_KEYS:
        raise ConfigError(f"{path}: [flow] needs exactly {sorted(FLOW_KEYS)}, has {sorted(flow)}")
    flow = dict(flow, dir=str((path.parent / flow["dir"]).resolve()))
    defaults = dict(raw.get("defaults", {}))
    if seeds is not None:
        if seeds < 1:
            raise ConfigError("--seeds must be >= 1")
        defaults["seeds"] = seeds
    if set(defaults) - (TEST_KEYS - {"name", "id"}):
        raise ConfigError(f"{path}: unknown keys in [defaults]: {sorted(set(defaults) - TEST_KEYS)}")
    entries: list[Entry] = []
    for t in raw.get("test", []):
        if "name" not in t or set(t) - TEST_KEYS:
            raise ConfigError(f"{path}: [[test]] needs a name and only {sorted(TEST_KEYS)}: {t}")
        merged = {**defaults, **t}
        e = Entry(id=merged.get("id", merged["name"]), name=merged["name"], seeds=int(merged.get("seeds", 1)),
                  timeout_s=float(merged.get("timeout_s", 60)), plusargs=str(merged.get("plusargs", "")))
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", e.id):
            raise ConfigError(f"{path}: id {e.id!r} must be a plain name (it names a directory)")
        if any(x.id == e.id for x in entries):
            raise ConfigError(f"{path}: duplicate id {e.id!r}")
        if "'" in e.plusargs:
            raise ConfigError(f"{path}: {e.id}: plusargs may not contain a single quote")
        entries.append(e)
    if only:
        missing = sorted(set(only) - {e.id for e in entries})
        if missing:
            raise ConfigError(f"--only: no entry with id {missing}")
        entries = [e for e in entries if e.id in only]
    if not entries:
        raise ConfigError(f"{path}: no tests to run")
    return flow, entries


# Fill a [flow] template; an unknown placeholder is a configuration error.
def fill(template: str, **values: object) -> str:
    try:
        return template.format_map({k: str(v) for k, v in values.items()})
    except KeyError as e:
        raise ConfigError(f"unknown placeholder {e} in [flow] template {template!r}") from None


# ---------------------------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------------------------

# One simulation run: what to execute and, once done, its verdict.
@dataclass
class Run:
    id: str
    test: str
    seed: int
    plusargs: str
    cmd: str
    run_dir: str
    timeout_s: float
    status: str = "NOTRUN"  # PASS, FAIL or TIMEOUT
    reasons: list[str] = field(default_factory=list)
    seconds: float = 0.0
    repro: str = ""
    cfg: str = ""


# Expand entries into runs, interleaved by seed (seed 1 of every test, then seed 2, ...), so a
# partial or interrupted regression still covers every test.
def plan_runs(flow: dict, entries: list[Entry], sim: str, out: str, vars_: str) -> list[Run]:
    runs = []
    for seed in range(1, max(e.seeds for e in entries) + 1):
        for e in entries:
            if seed > e.seeds:
                continue
            kw = dict(sim=sim, test=e.name, id=e.id, seed=seed, plusargs=e.plusargs, vars=vars_, out=out)
            runs.append(Run(id=e.id, test=e.name, seed=seed, plusargs=e.plusargs, cmd=fill(flow["run"], **kw),
                            run_dir=fill(flow["run_dir"], **kw), timeout_s=e.timeout_s))
    return runs


# Execute one run in its own process group (so a timeout kills make and the simulator alike),
# keep make's output in log_path, then judge the simulator log with the patterns.
def execute(run: Run, cwd: str, log_path: Path, rules: dict) -> Run:
    start = time.monotonic()
    with log_path.open("w") as log:
        p = subprocess.Popen(run.cmd, shell=True, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True)
        try:
            rc = p.wait(timeout=run.timeout_s)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            rc = None
    run.seconds = round(time.monotonic() - start, 3)
    made = log_path.read_text(errors="replace")
    run.repro = next((m.group(1) for ln in made.splitlines() if (m := REPRO_LINE.match(ln))), run.cmd)
    sim_log = Path(run.run_dir) / "sim.log"
    text = sim_log.read_text(errors="replace") if sim_log.is_file() else ""
    run.cfg = next((m.group(1).strip() for ln in text.splitlines() if (m := simlog.CFG_LINE.search(ln))), "")
    if rc is None:
        run.status, run.reasons = "TIMEOUT", [f"killed after {run.timeout_s:g} s (timeout_s)"]
        return run
    ok, reasons = simlog.judge(text, rules, 0) if text else (False, [f"no simulator log {sim_log}"])
    if rc != 0:
        reasons = [f"make exit code {rc} (see {log_path})"] + reasons
    run.status, run.reasons = ("PASS" if ok and rc == 0 else "FAIL"), reasons
    return run


# Run everything with j workers; print failures as they happen and progress every ~10%.
def run_all(runs: list[Run], cwd: str, logs: Path, rules: dict, jobs: int) -> None:
    done = fails = 0
    step = max(1, len(runs) // 10)
    with cf.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = [pool.submit(execute, r, cwd, logs / f"{r.id}_{r.seed}.txt", rules) for r in runs]
        for f in cf.as_completed(futs):
            r = f.result()
            done += 1
            if r.status != "PASS":
                fails += 1
                print(f"  {r.status}: {r.id} seed {r.seed}: {r.reasons[0] if r.reasons else ''}\n    rerun: {r.repro}",
                      flush=True)
            if done % step == 0 or done == len(runs):
                print(f"  [{done}/{len(runs)}] failures so far: {fails}", flush=True)


# ---------------------------------------------------------------------------------------------
# Coverage (one class per simulator; only Verilator exists on this host, DEC-001)
# ---------------------------------------------------------------------------------------------

class MergeMismatch(Exception):
    """The simulator's merged database disagrees with the per-run sum (plan M5 pitfall)."""


# Verilator coverage: per-run coverage.dat, merged with `verilator_coverage --write`.
class VerilatorCoverage:
    DB = "coverage.dat"
    CHUNK = 300  # databases per verilator_coverage call (keeps command lines short)

    # Read a .dat file into {key: count}. Keys are the raw record strings; the same key twice
    # in one file (two instances of one covergroup type) adds up.
    @staticmethod
    def read(path: Path) -> dict[str, int]:
        out: dict[str, int] = {}
        for line in path.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
            if line.startswith("C '"):
                key, count = line[3:].rsplit("' ", 1)
                out[key] = out.get(key, 0) + int(count)
        return out

    # Split a record key into its fields (\x01 between fields, \x02 between name and value).
    @staticmethod
    def fields(key: str) -> dict[str, str]:
        return dict(f.split("\x02", 1) for f in key.split("\x01") if "\x02" in f)

    # Merge the databases with the simulator's own tool (in chunks, then the chunk results), then
    # check the result against an independent sum in Python: they must agree record by record.
    def merge(self, dbs: list[Path], cov_dir: Path) -> dict[str, int]:
        tool = shutil.which("verilator_coverage")
        if not tool:
            raise ConfigError("verilator_coverage not on PATH (run through make, which adds the OSS CAD Suite)")
        parts = []
        for i in range(0, len(dbs), self.CHUNK):
            part = cov_dir / f"part{i // self.CHUNK}.dat"
            subprocess.run([tool, "--write", str(part), *map(str, dbs[i:i + self.CHUNK])], check=True)
            parts.append(part)
        merged = cov_dir / "merged.dat"
        subprocess.run([tool, "--write", str(merged), *map(str, parts)], check=True)
        for p in parts:
            p.unlink()
        expect: dict[str, int] = {}
        for db in dbs:
            for k, v in self.read(db).items():
                expect[k] = expect.get(k, 0) + v
        got = self.read(merged)
        bad = [k for k in expect.keys() | got.keys() if expect.get(k) != got.get(k)]
        if bad:
            first = sorted(bad)[:3]
            raise MergeMismatch(f"{len(bad)} records differ between merged.dat and the per-run sum, e.g. "
                                + "; ".join(f"{self.fields(k).get('h') or self.fields(k).get('o')}: merged "
                                            f"{got.get(k)} vs sum {expect.get(k)}" for k in first))
        # Annotated source is a reading aid, not evidence: a failure (e.g. a moved source file)
        # is reported but does not fail the regression.
        ann = subprocess.run([tool, "--annotate", str(cov_dir / "annotate"), "--annotate-all", "--annotate-min", "1", str(merged)],
                             capture_output=True, text=True)
        if ann.returncode != 0:
            print(f"  warning: no annotated source ({ann.stderr.strip().splitlines()[0] if ann.stderr.strip() else ann.returncode})")
        return got

    # Functional coverage from covergroup records: group -> item -> live bins and ignored bins.
    # The bin's hierarchical name is <covergroup type>.<item>.<bin>; illegal bins count as ignored.
    def functional(self, records: dict[str, int]) -> dict:
        groups: dict[str, dict] = {}
        for key, count in records.items():
            kv = self.fields(key)
            if kv.get("t") != "covergroup":
                continue
            cg_type = kv["page"].split("/", 1)[1]
            item, bin_ = kv["h"][len(cg_type) + 1:].split(".", 1)
            g = groups.setdefault(cg_type.split("::")[-1], {"items": {}})
            it = g["items"].setdefault(item, {"bins": {}, "ignored": {}})
            it["ignored" if kv.get("Bt") in ("ignore", "illegal") else "bins"][bin_] = count
        return groups

    # Cover statements (M6): every `t=user` record is one labeled cover; its `o` field is the
    # label (toolchain T14). Same label in several instances adds up: {label: hits}.
    def covers(self, records: dict[str, int]) -> dict[str, int]:
        out: dict[str, int] = {}
        for key, count in records.items():
            kv = self.fields(key)
            if kv.get("t") == "user":
                out[kv.get("o", "?")] = out.get(kv.get("o", "?"), 0) + count
        return dict(sorted(out.items()))

    # Code coverage per source file and kind (line, branch, toggle, ...): points and points hit.
    def code(self, records: dict[str, int]) -> dict:
        files: dict[str, dict] = {}
        for key, count in records.items():
            kv = self.fields(key)
            kind = kv.get("page", "").split("/", 1)[0].removeprefix("v_")
            if kind in ("covergroup", "user", ""):
                continue
            k = files.setdefault(kv.get("f", "?"), {}).setdefault(kind, {"points": 0, "hit": 0})
            k["points"] += 1
            k["hit"] += count > 0
        return files


SIMULATORS = {"verilator": VerilatorCoverage}


# Totals over the live bins of a functional model.
def func_totals(groups: dict) -> tuple[int, int]:
    live = hit = 0
    for g in groups.values():
        for it in g["items"].values():
            live += len(it["bins"])
            hit += sum(1 for c in it["bins"].values() if c > 0)
    return live, hit


# Percentage text that never rounds a hole up to 100.
def pct(hit: int, total: int) -> str:
    if total == 0:
        return "n/a"
    p = 100.0 * hit / total
    return f"{min(p, 99.9) if hit < total else 100.0:.1f}%"


# Merge the passing runs' databases and write cov/: merged database, functional and code
# coverage as JSON and Markdown. Returns the Markdown summary for summary.md.
def merge_coverage(sim: str, runs: list[Run], cov_dir: Path) -> str:
    cov = SIMULATORS[sim]()
    dbs = [Path(r.run_dir) / cov.DB for r in runs if r.status == "PASS"]
    missing = [str(d) for d in dbs if not d.is_file()]
    if missing:
        raise MergeMismatch(f"{len(missing)} passing runs left no coverage database, e.g. {missing[0]}")
    if cov_dir.exists():
        shutil.rmtree(cov_dir)
    cov_dir.mkdir(parents=True)
    records = cov.merge(dbs, cov_dir) if dbs else {}
    groups, files, covers = cov.functional(records), cov.code(records), cov.covers(records)
    live, hit = func_totals(groups)
    meta = {"sim": sim, "merged_runs": len(dbs), "generated": now()}
    (cov_dir / "functional.json").write_text(json.dumps({**meta, "live": live, "hit": hit, "groups": groups,
                                                         "covers": covers}, indent=1))
    (cov_dir / "code.json").write_text(json.dumps({**meta, "files": files}, indent=1))
    # Functional: one row per covergroup and item, then every hole by name.
    md = [f"### Functional coverage: {hit}/{live} live bins ({pct(hit, live)}), {len(dbs)} runs merged", "",
          "| Covergroup | Item | Live bins | Hit | Coverage |", "|---|---|---|---|---|"]
    holes = []
    for gname, g in sorted(groups.items()):
        for iname, it in sorted(g["items"].items()):
            n, h = len(it["bins"]), sum(1 for c in it["bins"].values() if c > 0)
            md.append(f"| `{gname}` | `{iname}` | {n} | {h} | {pct(h, n)} |")
            holes += [f"`{gname}.{iname}.{b}`" for b, c in sorted(it["bins"].items()) if c == 0]
    md += ["", f"**Holes ({len(holes)}):** " + (", ".join(holes) if holes else "none"), ""]
    # Cover statements: hits per label over all merged runs, then every one never hit.
    missed = [c for c, n in covers.items() if n == 0]
    md += [f"### Cover statements: {len(covers) - len(missed)}/{len(covers)} hit", "",
           "| Cover | Hits |", "|---|---|", *[f"| `{c}` | {n} |" for c, n in covers.items()], "",
           f"**Never hit ({len(missed)}):** " + (", ".join(f"`{c}`" for c in missed) if missed else "none"), ""]
    func_md = "\n".join(md)
    # Code coverage: one row per file and kind (secondary evidence, plan M5 step 6).
    cmd = ["### Code coverage (secondary evidence)", "", "| File | Kind | Points | Hit | Coverage |", "|---|---|---|---|---|"]
    for fname, kinds in sorted(files.items()):
        for kind, k in sorted(kinds.items()):
            cmd.append(f"| `{Path(fname).name}` | {kind} | {k['points']} | {k['hit']} | {pct(k['hit'], k['points'])} |")
    cmd += ["", f"Annotated source: `{cov_dir / 'annotate'}`", ""]
    code_md = "\n".join(cmd)
    (cov_dir / "functional.md").write_text(func_md)
    (cov_dir / "code.md").write_text(code_md)
    print(f"  functional coverage: {hit}/{live} live bins ({pct(hit, live)}); holes: {len(holes)}"
          + (f" — {', '.join(h.strip('`') for h in holes[:8])}{' ...' if len(holes) > 8 else ''}" if holes else ""))
    print(f"  cover statements: {len(covers) - len(missed)}/{len(covers)} hit"
          + (f" — never hit: {', '.join(missed)}" if missed else ""))
    return func_md + "\n" + code_md


# ---------------------------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------------------------

# Local time stamp for reports.
def now() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


# Source revision of the tree the regression ran on ("<hash>" or "<hash>-dirty").
def git_rev(where: str) -> str:
    try:
        rev = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=where, capture_output=True, text=True,
                             check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=where, capture_output=True, text=True).stdout.strip()
        return rev + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


# JUnit XML: one testsuite per entry, one testcase per seed; failures carry reasons and rerun.
def write_junit(runs: list[Run], path: Path) -> None:
    root = ET.Element("testsuites", name="regress")
    for rid in dict.fromkeys(r.id for r in runs):
        rs = [r for r in runs if r.id == rid]
        bad = [r for r in rs if r.status != "PASS"]
        suite = ET.SubElement(root, "testsuite", name=rid, tests=str(len(rs)), failures=str(len(bad)),
                              time=f"{sum(r.seconds for r in rs):.3f}")
        for r in rs:
            case = ET.SubElement(suite, "testcase", classname=rid, name=f"seed{r.seed}", time=f"{r.seconds:.3f}")
            if r.status != "PASS":
                fail_el = ET.SubElement(case, "failure", message=f"{r.status}: {r.reasons[0] if r.reasons else ''}")
                fail_el.text = "\n".join(r.reasons + [f"rerun: {r.repro}"])
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


# summary.md: header, per-entry table, failing runs with rerun commands, then coverage.
def write_summary(meta: dict, runs: list[Run], cov_md: str, path: Path) -> None:
    n_pass = sum(r.status == "PASS" for r in runs)
    lines = [f"# Regression summary — {meta['generated']}", "",
             f"- **Result:** {'PASS' if n_pass == len(runs) else 'FAIL'}: {n_pass}/{len(runs)} runs passed",
             f"- **Simulator:** {meta['sim']} · **Jobs:** {meta['jobs']} · **Wall time:** {meta['wall_s']:.0f} s",
             f"- **Source:** git {meta['git']} · **Tests file:** `{meta['tests']}`",
             f"- **Reproduce this regression:** `{meta['repro']}`", "",
             "| Entry | Test | Plusargs | Seeds | Pass | Fail | Timeout | Mean s | Max s |",
             "|---|---|---|---|---|---|---|---|---|"]
    for rid in dict.fromkeys(r.id for r in runs):
        rs = [r for r in runs if r.id == rid]
        secs = [r.seconds for r in rs]
        lines.append(f"| `{rid}` | `{rs[0].test}` | `{rs[0].plusargs or '-'}` | {len(rs)} | "
                     f"{sum(r.status == 'PASS' for r in rs)} | {sum(r.status == 'FAIL' for r in rs)} | "
                     f"{sum(r.status == 'TIMEOUT' for r in rs)} | {sum(secs) / len(secs):.2f} | {max(secs):.2f} |")
    bad = [r for r in runs if r.status != "PASS"]
    lines += ["", f"## Failing runs ({len(bad)})", ""]
    lines += [f"- `{r.id}` seed {r.seed}: {r.status}, {'; '.join(r.reasons)}  \n  rerun: `{r.repro}`" for r in bad] or ["None."]
    lines += ["", "## Coverage", "", cov_md or "Not merged."]
    path.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------------------------
# Recheck: rerun random runs from their printed commands and compare the logs
# ---------------------------------------------------------------------------------------------

# Pick k runs at random (the choice seed is printed), save each sim.log, rerun the run's repro
# command and require a byte-identical log (plan M5 Done-when). Returns the number of mismatches.
def recheck(runs: list[Run], k: int, cwd: str, out_dir: Path, choice_seed: int) -> int:
    pick = random.Random(choice_seed).sample(runs, min(k, len(runs)))
    out_dir.mkdir(parents=True, exist_ok=True)
    bad, rows = 0, []
    print(f"recheck: {len(pick)} random runs (choice seed {choice_seed})")
    for r in pick:
        log = Path(r.run_dir) / "sim.log"
        saved = out_dir / f"{r.id}_{r.seed}.orig.log"
        shutil.copyfile(log, saved)
        subprocess.run(r.repro, shell=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        same = log.is_file() and log.read_bytes() == saved.read_bytes()
        bad += not same
        rows.append({"repro": r.repro, "identical": same})
        print(f"  {'identical' if same else 'DIFFERENT'}: {r.repro}")
    # Saved for the results page (make_results.py): which runs were rerun and whether they matched.
    (out_dir / "recheck.json").write_text(json.dumps({"choice_seed": choice_seed, "runs": rows}, indent=1))
    return bad


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

# Refuse to write reports anywhere but an out/ tree (the report directory is wiped per run).
def report_dir(out: Path) -> Path:
    if "out" not in out.resolve().parts:
        raise ConfigError(f"--out must be inside an out/ directory (got {out})")
    return out / "regress"


# Command line: full regression, or --merge-only on the last results.json.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tests", type=Path, required=True, help="the block's regress/tests.toml")
    ap.add_argument("--sim", default="verilator", choices=sorted(SIMULATORS))
    ap.add_argument("--out", type=Path, required=True, help="the block's output directory (make's OUT)")
    ap.add_argument("--vars", default="", help="make variables appended to every command ({vars})")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--seeds", type=int, help="override the default seed count (entries with their own keep it)")
    ap.add_argument("--only", nargs="+", metavar="ID", help="run only these entry ids")
    ap.add_argument("--merge-only", action="store_true", help="re-merge coverage of the last results.json")
    ap.add_argument("--recheck", type=int, default=0, metavar="K", help="rerun K random runs and diff their logs")
    ap.add_argument("--repro", default="", help="the command that reproduces this regression (printed)")
    args = ap.parse_args(argv)
    try:
        return regress(args)
    except ConfigError as e:
        print(f"regress: {e}", file=sys.stderr)
        return 2


# The regression proper (see main); returns the exit status.
def regress(args: argparse.Namespace) -> int:
    flow, entries = load_config(args.tests, args.seeds, args.only)
    out = args.out.resolve()
    rep = report_dir(out)
    rules = simlog.load_rules(COMMON / "sim" / f"{args.sim}.patterns")
    results = rep / "results.json"
    if args.merge_only:
        # Re-merge: runs and metadata from the last regression; coverage and summary rewritten.
        if not results.is_file():
            raise ConfigError(f"no {results}: run `make regress` first")
        data = json.loads(results.read_text())
        runs = [Run(**r) for r in data["runs"]]
        meta = dict(data["meta"], repro=args.repro or data["meta"]["repro"])
    else:
        # Full regression: fresh report directory, one build, then every run in parallel.
        if rep.exists():
            shutil.rmtree(rep)
        (rep / "logs").mkdir(parents=True)
        prov = provenance.record(Path(flow["dir"]))   # the tree and tools this regression runs on
        build = fill(flow["build"], sim=args.sim, vars=args.vars, out=out)
        print(f"+ (cd {flow['dir']} && {build})", flush=True)
        t0 = time.monotonic()
        with (rep / "build.log").open("w") as bl:
            rc = subprocess.run(build, shell=True, cwd=flow["dir"], stdout=bl, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            print((rep / "build.log").read_text(errors="replace")[-3000:], file=sys.stderr)
            raise ConfigError(f"build failed (exit {rc}), see {rep / 'build.log'}")
        runs = plan_runs(flow, entries, args.sim, str(out), args.vars)
        print(f"regress: {len(runs)} runs ({len(entries)} entries) on {args.jobs} jobs", flush=True)
        run_all(runs, flow["dir"], rep / "logs", rules, args.jobs)
        meta = {"generated": now(), "sim": args.sim, "jobs": args.jobs, "wall_s": round(time.monotonic() - t0, 1),
                "git": git_rev(flow["dir"]), "tests": str(args.tests), "repro": args.repro, "provenance": prov}
        results.write_text(json.dumps({"meta": meta, "runs": [asdict(r) for r in runs]}, indent=1))
        write_junit(runs, rep / "junit.xml")
    # Coverage of the passing runs, then the summary (written even when the merge fails).
    status = 0 if all(r.status == "PASS" for r in runs) else 1
    try:
        cov_md = merge_coverage(args.sim, runs, out / "cov")
    except (MergeMismatch, subprocess.CalledProcessError) as e:
        print(f"regress: coverage merge FAILED: {e}", file=sys.stderr)
        cov_md, status = f"**Merge failed:** {e}", 1
    write_summary(meta, runs, cov_md, rep / "summary.md")
    if args.recheck and not args.merge_only:
        status |= recheck(runs, args.recheck, flow["dir"], rep / "recheck", int(time.time())) > 0
    # Final verdict, the failing runs again (last lines a reader sees), and the repro line.
    n_pass = sum(r.status == "PASS" for r in runs)
    for r in runs:
        if r.status != "PASS":
            print(f"  {r.status} {r.id} seed {r.seed}: rerun: {r.repro}")
    print(f"regress {'PASS' if status == 0 else 'FAIL'}: {n_pass}/{len(runs)} runs passed; "
          f"summary {rep / 'summary.md'}" + (f"   repro: {meta['repro']}" if meta.get("repro") else ""))
    return status


if __name__ == "__main__":
    sys.exit(main())
