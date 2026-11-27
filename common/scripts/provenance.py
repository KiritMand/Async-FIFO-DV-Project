#!/usr/bin/env python3
"""provenance.py — which source tree and tools produced a result, and is that still the tree?

Every flow that saves a result (regress, formal_run, sva_neg, cdc_check, bug_matrix, mcy_run)
stores record() next to it: the git commit it ran at, the blob hash of every flow input that was
uncommitted at that moment, and the tool versions. make_results.py later calls check() on that
record: the result is CURRENT when every flow input has, in today's working tree, the same
content it had when the flow ran; otherwise STALE (with the files that changed); UNKNOWN when
nothing was recorded (results made before M10).

Flow inputs are every file of the repository except prose and generated documentation (*.md,
except the vplan, which the checkers read), figures and sign-off snapshots, CI and editor files,
the toolchain experiments, the example constraints, and the results generator itself. The rule
is deliberately broad: a change to any script, testbench or Makefile makes every result STALE.

Python >= 3.11, standard library only.
"""

from __future__ import annotations

import datetime
import os
import shutil
import subprocess
from pathlib import Path

# Paths that never change a result (prefixes, exact names, suffixes). Everything else is an input.
NOT_INPUT_PREFIXES = (".github/", ".claude/", "tools_smoke/", "common/scripts/tests/")
NOT_INPUT_NAMES = {".gitignore", "common/scripts/make_results.py", "common/scripts/provenance.py"}
NOT_INPUT_SUFFIXES = (".xdc",)
NOT_INPUT_PARTS = ("/docs/figures/", "/docs/signoff/")


# Is this repository path (POSIX, relative to the top) a flow input?
def is_input(path: str) -> bool:
    if path.startswith(NOT_INPUT_PREFIXES) or path in NOT_INPUT_NAMES or path.endswith(NOT_INPUT_SUFFIXES):
        return False
    if any(part in "/" + path for part in NOT_INPUT_PARTS):
        return False
    return not path.endswith(".md") or path.endswith("/vplan.md")


# Run git in the repository and return stdout ("" and no exception on failure when ok_fail).
def _git(repo: Path, *args: str, ok_fail: bool = False) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if r.returncode != 0 and not ok_fail:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout if r.returncode == 0 else ""


# Top of the repository that contains `where`.
def repo_top(where: Path) -> Path:
    return Path(_git(where, "rev-parse", "--show-toplevel").strip())


# Git blob hash of a working-tree file (None if it does not exist).
def blob_now(repo: Path, path: str) -> str | None:
    f = repo / path
    return _git(repo, "hash-object", "--", path).strip() if f.is_file() else None


# Git blob hash of a path at a commit (None if the path is not in that commit).
def blob_at(repo: Path, rev: str, path: str) -> str | None:
    return _git(repo, "rev-parse", "--verify", "--quiet", f"{rev}:{path}", ok_fail=True).strip() or None


# Input paths that differ from HEAD in the working tree: modified, deleted or untracked.
def dirty_inputs(repo: Path) -> list[str]:
    out = _git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
    paths = [e[3:] for e in out.split("\0") if len(e) > 3]
    return sorted(p for p in set(paths) if is_input(p))


# First line of a tool's version output, or "not found".
def _version(cmd: list[str]) -> str:
    if not shutil.which(cmd[0]):
        return "not found"
    r = subprocess.run(cmd, capture_output=True, text=True)
    lines = (r.stdout or r.stderr).strip().splitlines()
    return lines[0].strip() if lines else "unknown"


# Versions of the tools on PATH (the flows run under make, which puts the pinned suite first),
# the OSS CAD Suite release and the UVM library commit.
def tool_versions() -> dict[str, str]:
    tools = {"verilator": _version(["verilator", "--version"]), "yosys": _version(["yosys", "-V"]),
             "sby": _version(["sby", "--version"]), "yices": _version(["yices", "--version"])}
    yosys = shutil.which("yosys")
    ver = Path(yosys).resolve().parent.parent / "VERSION" if yosys else None
    tools["oss-cad-suite"] = ver.read_text().strip() if ver and ver.is_file() else "unknown"
    uvm = Path(os.environ.get("UVM_HOME", str(Path.home() / "tools/uvm-2020-3.2/src")))
    rev = _git(uvm.parent, "rev-parse", "HEAD", ok_fail=True).strip() if uvm.parent.is_dir() else ""
    tools["uvm"] = f"{uvm.parent.name} @ {rev[:12]}" if rev else "unknown"
    return tools


# What to store with a result: commit, uncommitted flow inputs (with their content hashes),
# time and tool versions. `where` is any directory inside the repository.
def record(where: Path) -> dict:
    try:
        repo = repo_top(where)
    except (RuntimeError, OSError) as e:   # not in a git checkout (script self-tests): say so
        return {"rev": None, "error": str(e), "dirty": {}, "tools": tool_versions()}
    return {"rev": _git(repo, "rev-parse", "HEAD").strip(),
            "dirty": {p: blob_now(repo, p) for p in dirty_inputs(repo)},
            "time": datetime.datetime.now().isoformat(timespec="seconds"),
            "tools": tool_versions()}


# Compare a stored record with today's working tree: ("CURRENT" | "STALE" | "UNKNOWN", detail).
def check(rec: dict | None, repo: Path) -> tuple[str, str]:
    if not rec or not rec.get("rev"):
        return "UNKNOWN", "no provenance recorded"
    rev, dirty = rec["rev"], rec.get("dirty", {})
    if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{rev}^{{commit}}"],
                      capture_output=True).returncode != 0:
        return "UNKNOWN", f"commit {rev[:10]} is not in this repository"
    # Candidates: inputs that differ between the commit and today, plus those dirty back then.
    changed = _git(repo, "diff", "--name-only", "-z", "--no-renames", rev).split("\0")
    untracked = _git(repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
    cands = {p for p in changed + untracked + list(dirty) if p and is_input(p)}
    stale = sorted(p for p in cands if (dirty[p] if p in dirty else blob_at(repo, rev, p)) != blob_now(repo, p))
    if stale:
        more = f" (+{len(stale) - 3} more)" if len(stale) > 3 else ""
        return "STALE", f"changed since the run: {', '.join(stale[:3])}{more}"
    note = f" + {len(dirty)} uncommitted input(s), unchanged since" if dirty else ""
    return "CURRENT", f"{rev[:10]}{note}"


# Short form of a record's commit for reports: "<hash>" or "<hash>+dirty".
def short(rec: dict | None) -> str:
    if not rec or not rec.get("rev"):
        return "unknown"
    return rec["rev"][:10] + ("+dirty" if rec.get("dirty") else "")
