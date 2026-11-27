#!/usr/bin/env python3
# vplan_check.py — traceability checks for a Markdown verification plan (plan M2 step 7).
# DUT-agnostic: it knows the vplan table format (ip/<block>/docs/vplan.md §1.3), not the block.
"""Check a verification plan for traceability.

Modes:
  --structure  the plan is complete and self-consistent: every feature has a stimulus, a
               checker, and coverage or formal; every label, coverage item and test is defined
               once and referenced from its home row; the ledger and sign-off are filled in.
  --trace      look for every planned label, covergroup, test and target in the code and
               report what exists. Report-only unless --strict (strict from M6 on). With
               --defer formal, labels whose Runs is `formal` are reported as deferred and are
               not required yet (M6: the formal-only labels arrive in M7).
  --annotate   write docs/vplan_status.md: the merged coverage of the last regression
               (functional.json from regress.py) per vplan coverage item and per feature, the
               regression result, the simulation cover properties (functional.json "covers"),
               and, with --formal (M7), the formal sign-off (formal_run.py's signoff.json):
               SO-3 and each feature's Formal column.
               With --strict it fails on any hole, any planned item missing from the coverage
               database, or a bin count that differs from the plan's stated total.

Python >= 3.11, standard library only. Exit status: 0 pass, 1 check failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------------------------
# Format of the plan. Each table is recognized by its exact header row (vplan §1.3).
# ---------------------------------------------------------------------------------------------

SCHEMAS = {
    "features": ["ID", "Requirement", "Stimulus", "Checker", "Coverage", "Formal", "Notes"],
    "tests": ["Test", "Sequence", "Module", "Purpose"],
    "coverage": ["Item", "Sampled", "Bins", "Purpose"],
    "properties": ["Label", "Kind", "Runs", "Clock", "Intent"],
    "ledger": ["ID", "Assumption", "Why it is realistic", "Formal", "Simulation", "Status"],
    "bugs": ["ID", "Bug", "Violates", "Expected catch", "Notes"],
    "exclusions": ["Item", "Reason", "Approved by", "Date"],
}

# Section headings the template requires, as "## <n>. <title>".
REQUIRED_SECTIONS = [
    "Scope", "Features", "Coverage model", "Property list", "Assumption ledger",
    "Planted-bug plan", "Sign-off", "Exclusions", "Out of scope", "Revision history",
]

# Allowed values in the property and ledger tables.
KINDS = {"e2e", "white-box"}
RUNS = {"sim", "formal", "both"}
CLOCKS = {"wclk", "rclk", "gclk", "init"}
STATUSES = {"active", "optional", "modeling"}

# Name patterns: IDs, property labels (which embed their home ID), coverage items, tests.
FID_RE = re.compile(r"^F\d{2}$")
AID_RE = re.compile(r"^A\d{2}$")
BID_RE = re.compile(r"^B\d{2}$")
LABEL_RE = re.compile(r"^(?:(?:ast|cov)_(F\d{2})|asm_(A\d{2}))_[a-z0-9_]+$")
COVITEM_RE = re.compile(r"^(cg_[a-z0-9_]+)\.(?:cp|x)_[a-z0-9_]+$")
COVGROUP_RE = re.compile(r"^cg_[a-z0-9_]+$")
TEST_RE = re.compile(r"^[a-z0-9_]+_test$")
CODE_RE = re.compile(r"^(?:fifo|vseq)_[a-z0-9_]+$")
SEP_RE = re.compile(r"^\|?(\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$|^\|?\s*:?-{3,}:?\s*\|?\s*$")


# One parsed table row: its 1-based line number and its cells keyed by column name.
@dataclass
class Row:
    line: int
    cells: dict[str, str]

    def __getitem__(self, col: str) -> str:
        return self.cells[col]


# One problem found by a check, printed as "<file>:<line>: <message>".
@dataclass
class Finding:
    line: int
    msg: str


# ---------------------------------------------------------------------------------------------
# Cell helpers
# ---------------------------------------------------------------------------------------------

# Split a Markdown table line into stripped cells (no pipes inside cells, by convention).
def split_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


# Items of a cell are separated by <br>; returns the non-empty ones.
def items(cell: str) -> list[str]:
    return [p.strip() for p in re.split(r"<br\s*/?>", cell) if p.strip()]


# Every `backticked` name in a piece of text.
def tokens(text: str) -> list[str]:
    return re.findall(r"`([^`]+)`", text)


# A cell that is missing: empty or a dash.
def is_blank(cell: str) -> bool:
    return cell.strip() in {"", "-", "—", "–"}


# A cell that says the column doesn't apply ("n/a", with or without a reason).
def is_na(cell: str) -> bool:
    return re.match(r"^n/a\b", cell.strip(), re.IGNORECASE) is not None


# An n/a cell must give its reason: "n/a: <reason>".
def na_has_reason(cell: str) -> bool:
    return re.match(r"^n/a:\s*\S", cell.strip(), re.IGNORECASE) is not None


# Sort a referenced name into the kind of thing it points to (None = not tracked).
def classify(tok: str) -> str | None:
    if tok.startswith(("ast_", "asm_", "cov_")):
        return "label"
    if tok.startswith("cg_"):
        return "coverage"
    if TEST_RE.match(tok):
        return "test"
    if tok.startswith("make "):
        return "make"
    if tok.endswith(".py"):
        return "script"
    if CODE_RE.match(tok):
        return "code"
    return None


# ---------------------------------------------------------------------------------------------
# Parsed plan
# ---------------------------------------------------------------------------------------------

# Reads the plan once: its section titles, its tables (by schema) and the free-text lines
# the checks need (N, Retired IDs). Parse problems become findings, not exceptions.
class Vplan:
    def __init__(self, path: Path):
        self.path = path
        self.lines = path.read_text(encoding="utf-8").splitlines()
        self.tables: dict[str, list[Row]] = {}
        self.table_line: dict[str, int] = {}
        self.sections: dict[str, int] = {}
        self.findings: list[Finding] = []
        self._parse()

    # Record a problem at a line.
    def err(self, line: int, msg: str) -> None:
        self.findings.append(Finding(line, msg))

    # Walk the file once: collect "## n. Title" headings and every table with a known header.
    def _parse(self) -> None:
        i = 0
        while i < len(self.lines):
            line = self.lines[i]
            m = re.match(r"^##\s+\d+\.\s+(.+?)\s*$", line)
            if m:
                self.sections.setdefault(m.group(1), i + 1)
            is_table = (line.lstrip().startswith("|") and i + 1 < len(self.lines)
                        and SEP_RE.match(self.lines[i + 1].strip()))
            if not is_table:
                i += 1
                continue
            header = split_row(line)
            j = i + 2
            raw = []
            while j < len(self.lines) and self.lines[j].lstrip().startswith("|"):
                raw.append((j + 1, split_row(self.lines[j])))
                j += 1
            kind = next((k for k, cols in SCHEMAS.items() if cols == header), None)
            if kind is not None:
                self._add_table(kind, i + 1, header, raw)
            i = j

    # Store one recognized table; a second table with the same header or a ragged row is an error.
    def _add_table(self, kind: str, line: int, header: list[str],
                   raw: list[tuple[int, list[str]]]) -> None:
        if kind in self.tables:
            self.err(line, f"second '{kind}' table (first at line {self.table_line[kind]})")
            return
        rows = []
        for ln, cells in raw:
            if len(cells) != len(header):
                self.err(ln, f"{kind} row has {len(cells)} cells, header has {len(header)}")
                continue
            rows.append(Row(ln, dict(zip(header, cells))))
        self.tables[kind] = rows
        self.table_line[kind] = line


# ---------------------------------------------------------------------------------------------
# --structure
# ---------------------------------------------------------------------------------------------

# Everything the structure checks learn about the plan, shared by the later trace step.
@dataclass
class Model:
    features: dict[str, Row] = field(default_factory=dict)
    ledger: dict[str, Row] = field(default_factory=dict)
    bugs: dict[str, Row] = field(default_factory=dict)
    props: dict[str, Row] = field(default_factory=dict)          # label -> row
    prop_home: dict[str, str] = field(default_factory=dict)      # label -> F/A ID
    cov_items: dict[str, Row] = field(default_factory=dict)      # cg_x.cp_y -> row
    covgroups: set[str] = field(default_factory=set)
    tests: dict[str, Row] = field(default_factory=dict)
    optional_tokens: set[str] = field(default_factory=set)       # [STRETCH] or optional rows
    other_refs: dict[str, int] = field(default_factory=dict)     # make/script/code -> line
    n_seeds: int | None = None


# Run every structure check; returns the model and fills vp.findings.
def check_structure(vp: Vplan) -> Model:
    mdl = Model()
    # A heading may carry a suffix after the required title, e.g. "Planted-bug plan (→ M8)".
    for title in REQUIRED_SECTIONS:
        if not any(s == title or s.startswith(title + " ") for s in vp.sections):
            vp.err(1, f"missing section '## <n>. {title}'")
    missing = [k for k in SCHEMAS if k not in vp.tables]
    for k in missing:
        vp.err(1, f"missing '{k}' table (header: | {' | '.join(SCHEMAS[k])} |)")
    if missing:
        return mdl
    _collect_ids(vp, mdl)
    _check_properties(vp, mdl)
    _check_coverage_table(vp, mdl)
    _check_tests_table(vp, mdl)
    _check_features(vp, mdl)
    _check_ledger(vp, mdl)
    _check_bugs(vp, mdl)
    _check_exclusions(vp, mdl)
    _check_references(vp, mdl)
    _check_signoff_and_retired(vp, mdl)
    return mdl


# Feature, assumption and bug IDs: well-formed and unique.
def _collect_ids(vp: Vplan, mdl: Model) -> None:
    for kind, rx, store in (("features", FID_RE, mdl.features),
                            ("ledger", AID_RE, mdl.ledger),
                            ("bugs", BID_RE, mdl.bugs)):
        for r in vp.tables[kind]:
            fid = r["ID"]
            if not rx.match(fid):
                vp.err(r.line, f"bad {kind} ID '{fid}' (expected {rx.pattern[1:-1]})")
            elif fid in store:
                vp.err(r.line, f"duplicate ID {fid} (first at line {store[fid].line})")
            else:
                store[fid] = r


# Property list: one label per row, well-formed, unique, home ID exists, legal kind/runs/clock.
def _check_properties(vp: Vplan, mdl: Model) -> None:
    for r in vp.tables["properties"]:
        toks = tokens(r["Label"])
        if len(toks) != 1:
            vp.err(r.line, "Label cell must hold exactly one `label`")
            continue
        lab = toks[0]
        m = LABEL_RE.match(lab)
        if not m:
            vp.err(r.line, f"malformed label '{lab}' (ast_/cov_<Fnn>_name or asm_<Ann>_name)")
            continue
        if lab in mdl.props:
            vp.err(r.line, f"duplicate label {lab} (first at line {mdl.props[lab].line})")
            continue
        home = m.group(1) or m.group(2)
        if home not in mdl.features and home not in mdl.ledger:
            vp.err(r.line, f"{lab}: home ID {home} is not in the feature table or ledger")
        if r["Kind"] not in KINDS:
            vp.err(r.line, f"{lab}: Kind '{r['Kind']}' not in {sorted(KINDS)}")
        if r["Runs"] not in RUNS:
            vp.err(r.line, f"{lab}: Runs '{r['Runs']}' not in {sorted(RUNS)}")
        if r["Clock"] not in CLOCKS:
            vp.err(r.line, f"{lab}: Clock '{r['Clock']}' not in {sorted(CLOCKS)}")
        if r["Clock"] == "gclk" and r["Runs"] == "sim":
            vp.err(r.line, f"{lab}: gclk exists only in formal, Runs cannot be 'sim'")
        if is_blank(r["Intent"]):
            vp.err(r.line, f"{lab}: Intent is empty")
        mdl.props[lab] = r
        mdl.prop_home[lab] = home


# Coverage model: item names cg_<group>.<cp_|x_><name>, unique, every column filled.
def _check_coverage_table(vp: Vplan, mdl: Model) -> None:
    for r in vp.tables["coverage"]:
        toks = tokens(r["Item"])
        m = COVITEM_RE.match(toks[0]) if len(toks) == 1 else None
        if not m:
            vp.err(r.line, f"Item must be one `cg_<group>.cp_<name>` or `.x_<name>`, got '{r['Item']}'")
            continue
        item = toks[0]
        if item in mdl.cov_items:
            vp.err(r.line, f"duplicate coverage item {item}")
            continue
        for col in ("Sampled", "Bins", "Purpose"):
            if is_blank(r[col]):
                vp.err(r.line, f"{item}: {col} is empty")
        mdl.cov_items[item] = r
        mdl.covgroups.add(m.group(1))


# Test list: one `<name>_test` per row, unique, every column filled.
def _check_tests_table(vp: Vplan, mdl: Model) -> None:
    for r in vp.tables["tests"]:
        toks = tokens(r["Test"])
        if len(toks) != 1 or not TEST_RE.match(toks[0]):
            vp.err(r.line, f"Test cell must be one `<name>_test`, got '{r['Test']}'")
            continue
        if toks[0] in mdl.tests:
            vp.err(r.line, f"duplicate test {toks[0]}")
            continue
        for col in ("Sequence", "Module", "Purpose"):
            if is_blank(r[col]):
                vp.err(r.line, f"{toks[0]}: {col} is empty")
        mdl.tests[toks[0]] = r


# Feature rows: stimulus, a real checker, coverage or formal; n/a always with a reason; the
# Formal cell agrees with whether any of the row's own properties run in formal.
def _check_features(vp: Vplan, mdl: Model) -> None:
    for fid, r in mdl.features.items():
        if is_blank(r["Requirement"]):
            vp.err(r.line, f"{fid}: Requirement is empty")
        for col in ("Stimulus", "Checker", "Coverage", "Formal"):
            cell = r[col]
            if is_blank(cell):
                vp.err(r.line, f"{fid}: {col} is empty (write the entry or 'n/a: <reason>')")
            elif is_na(cell) and col == "Checker":
                vp.err(r.line, f"{fid}: Checker cannot be n/a, every feature needs a checker")
            elif is_na(cell) and not na_has_reason(cell):
                vp.err(r.line, f"{fid}: {col} says n/a without a reason ('n/a: <reason>')")
        if is_na(r["Coverage"]) and is_na(r["Formal"]):
            vp.err(r.line, f"{fid}: needs coverage or formal, both are n/a")
        own_formal = [p for p, h in mdl.prop_home.items()
                      if h == fid and mdl.props[p]["Runs"] in ("formal", "both")]
        if not is_blank(r["Formal"]) and not is_na(r["Formal"]) and not own_formal:
            vp.err(r.line, f"{fid}: Formal cell is filled but no {fid} property runs in formal")
        if is_na(r["Formal"]) and own_formal:
            vp.err(r.line, f"{fid}: Formal is n/a but {own_formal[0]} runs in formal")
        cov_refs = [t for t in tokens(r["Coverage"])
                    if classify(t) == "coverage" or t.startswith("cov_")]
        if not is_blank(r["Coverage"]) and not is_na(r["Coverage"]) and not cov_refs:
            vp.err(r.line, f"{fid}: Coverage cell names no `cg_` item or `cov_` property")
        _note_optional(r, ("Stimulus", "Checker", "Coverage", "Formal"), mdl)


# Remember names that sit in a [STRETCH] item: --trace doesn't require them.
def _note_optional(r: Row, cols: tuple[str, ...], mdl: Model) -> None:
    for col in cols:
        for it in items(r[col]):
            if "[STRETCH]" in it:
                mdl.optional_tokens.update(tokens(it))


# Ledger rows: all columns filled, legal status, and every formal assumption also simulated:
# each asm_ label sits in the Formal and/or Simulation cell that matches its Runs value.
def _check_ledger(vp: Vplan, mdl: Model) -> None:
    for aid, r in mdl.ledger.items():
        for col in SCHEMAS["ledger"][1:]:
            if is_blank(r[col]):
                vp.err(r.line, f"{aid}: {col} is empty")
            elif is_na(r[col]) and not na_has_reason(r[col]):
                vp.err(r.line, f"{aid}: {col} says n/a without a reason")
        if r["Status"] not in STATUSES:
            vp.err(r.line, f"{aid}: Status '{r['Status']}' not in {sorted(STATUSES)}")
        own = [p for p, h in mdl.prop_home.items() if h == aid]
        if r["Status"] in ("active", "optional") and not own:
            vp.err(r.line, f"{aid}: an {r['Status']} assumption needs at least one asm_{aid}_ label")
        formal_toks, sim_toks = set(tokens(r["Formal"])), set(tokens(r["Simulation"]))
        for p in own:
            runs = mdl.props[p]["Runs"]
            if runs in ("formal", "both") and p not in formal_toks:
                vp.err(r.line, f"{aid}: {p} runs in formal but is missing from the Formal cell")
            if runs in ("sim", "both") and p not in sim_toks:
                vp.err(r.line, f"{aid}: {p} runs in simulation but is missing from the Simulation cell")
        if any(mdl.props[p]["Runs"] == "formal" for p in own):
            vp.err(r.line, f"{aid}: every formal assumption must also be checked in simulation (Runs = both)")
        if r["Status"] == "optional":
            mdl.optional_tokens.update(own)


# Planted bugs: each names the features it violates (which must exist) and an expected catch.
def _check_bugs(vp: Vplan, mdl: Model) -> None:
    for bid, r in mdl.bugs.items():
        if is_blank(r["Bug"]):
            vp.err(r.line, f"{bid}: Bug is empty")
        fids = re.findall(r"\bF\d{2}\b", r["Violates"])
        if not fids:
            vp.err(r.line, f"{bid}: Violates names no feature ID")
        for f in fids:
            if f not in mdl.features:
                vp.err(r.line, f"{bid}: violates unknown feature {f}")
        if is_blank(r["Expected catch"]):
            vp.err(r.line, f"{bid}: Expected catch is empty")
        _note_optional(r, ("Expected catch",), mdl)


# Exclusions: every column filled (owner approval and date are mandatory) and the excluded
# item exists in the plan.
def _check_exclusions(vp: Vplan, mdl: Model) -> None:
    for r in vp.tables["exclusions"]:
        for col in SCHEMAS["exclusions"]:
            if is_blank(r[col]):
                vp.err(r.line, f"exclusion: {col} is empty")
        toks = tokens(r["Item"])
        if not any(t in mdl.props or t in mdl.cov_items for t in toks):
            vp.err(r.line, f"exclusion: Item '{r['Item']}' is not a label or coverage item of this plan")


# Cross-references: every referenced label, coverage item and test is defined; every label is
# referenced from its home row; every covergroup and test is used by some feature.
def _check_references(vp: Vplan, mdl: Model) -> None:
    sources = ([(r, SCHEMAS["features"][1:]) for r in mdl.features.values()]
               + [(r, ["Formal", "Simulation"]) for r in mdl.ledger.values()]
               + [(r, ["Expected catch", "Notes"]) for r in mdl.bugs.values()])
    home_refs: dict[str, set[str]] = {}
    used_groups: set[str] = set()
    used_tests: set[str] = set()
    for r, cols in sources:
        rid = r["ID"]
        for col in cols:
            for t in tokens(r[col]):
                kind = classify(t)
                if kind == "label":
                    if not LABEL_RE.match(t):
                        vp.err(r.line, f"{rid}: malformed label `{t}`")
                    elif t not in mdl.props:
                        vp.err(r.line, f"{rid}: `{t}` is not defined in the property list")
                    home_refs.setdefault(rid, set()).add(t)
                elif kind == "coverage":
                    m = COVITEM_RE.match(t)
                    if m and t in mdl.cov_items:
                        group = m.group(1)
                    elif COVGROUP_RE.match(t) and t in mdl.covgroups:
                        group = t
                    else:
                        vp.err(r.line, f"{rid}: `{t}` is not defined in the coverage model")
                        continue
                    if rid in mdl.features:
                        used_groups.add(group)
                elif kind == "test":
                    if t not in mdl.tests:
                        vp.err(r.line, f"{rid}: test `{t}` is not in the test list")
                    elif rid in mdl.features:
                        used_tests.add(t)
                elif kind in ("make", "script", "code"):
                    mdl.other_refs.setdefault(t, r.line)
    for lab, home in mdl.prop_home.items():
        if lab not in home_refs.get(home, set()):
            vp.err(mdl.props[lab].line, f"{lab} is not referenced from its home row {home}")
    for g in sorted(mdl.covgroups - used_groups):
        vp.err(vp.table_line["coverage"], f"covergroup {g} is not referenced by any feature")
    for t in sorted(set(mdl.tests) - used_tests):
        vp.err(mdl.tests[t].line, f"test {t} is not referenced by any feature")


# Sign-off states N exactly once as "**N = <int>**"; retired IDs never come back.
def _check_signoff_and_retired(vp: Vplan, mdl: Model) -> None:
    n_hits = [(i + 1, int(m.group(1))) for i, ln in enumerate(vp.lines)
              for m in [re.search(r"\*\*N = (\d+)\*\*", ln)] if m]
    if len(n_hits) != 1:
        vp.err(vp.sections.get("Sign-off", 1),
               f"sign-off must state N once as '**N = <int>**' (found {len(n_hits)})")
    elif n_hits[0][1] < 1:
        vp.err(n_hits[0][0], "N must be at least 1")
    else:
        mdl.n_seeds = n_hits[0][1]
    retired = [(i + 1, ln) for i, ln in enumerate(vp.lines) if ln.startswith("Retired IDs:")]
    if len(retired) != 1:
        vp.err(1, f"need exactly one 'Retired IDs:' line (found {len(retired)})")
        return
    line, text = retired[0]
    defined = set(mdl.features) | set(mdl.ledger) | set(mdl.bugs)
    for rid in re.findall(r"\b[FAB]\d{2}\b", text):
        if rid in defined:
            vp.err(line, f"retired ID {rid} is in use again (IDs are never reused)")


# ---------------------------------------------------------------------------------------------
# --trace
# ---------------------------------------------------------------------------------------------

# Code files --trace searches: HDL, formal, regression and scripts, never docs/ or out/.
CODE_SUFFIXES = {".sv", ".svh", ".v", ".sby", ".toml", ".py", ".mk"}


# Read every code file under the search roots once.
def load_code(roots: list[Path]) -> dict[Path, str]:
    code = {}
    for root in roots:
        for p in sorted(root.rglob("*")):
            if not p.is_file() or {"docs", "out", ".git"} & set(p.relative_to(root).parts):
                continue
            if p.suffix in CODE_SUFFIXES or p.name == "Makefile":
                code[p] = p.read_text(encoding="utf-8", errors="replace")
    return code


# Does any loaded file match the regex?
def found(code: dict[Path, str], rx: str) -> bool:
    pat = re.compile(rx, re.MULTILINE)
    return any(pat.search(txt) for txt in code.values())


# A make target exists if the Makefile defines it and its recipe is not the "stub" placeholder.
def make_target_real(makefile: Path, target: str) -> bool:
    if not makefile.is_file():
        return False
    lines = makefile.read_text(encoding="utf-8").splitlines()
    for i, ln in enumerate(lines):
        if re.match(rf"^{re.escape(target)}:(?!=)", ln) and "##" in ln:
            recipe = []
            for nxt in lines[i + 1:]:
                if not nxt.startswith("\t"):
                    break
                recipe.append(nxt)
            return bool(recipe) and not any("call stub" in r for r in recipe)
    return False


# Look up every planned name in the code; print one summary line per category and, with
# --verbose, the missing names. Labels whose Runs value is in `defer` are not required yet.
# Returns the number of required-but-missing items and orphans.
def run_trace(mdl: Model, roots: list[Path], makefile: Path, verbose: bool, defer: set[str] = frozenset()) -> int:
    code = load_code(roots)
    checks: dict[str, list[tuple[str, bool]]] = {k: [] for k in
                                                ("labels", "coverage", "tests", "code", "make", "scripts")}
    for lab in mdl.props:
        checks["labels"].append((lab, found(code, rf"\b{re.escape(lab)}\s*:")))
    for item in mdl.cov_items:
        group, point = item.split(".")
        hit = any(re.search(rf"covergroup\s+{group}\b", t) and re.search(rf"\b{point}\s*:", t)
                  for t in code.values())
        checks["coverage"].append((item, hit))
    for test in mdl.tests:
        checks["tests"].append((test, found(code, rf"\bclass\s+{test}\b")))
    for tok in sorted(mdl.other_refs):
        kind = classify(tok)
        if kind == "make":
            checks["make"].append((tok, make_target_real(makefile, tok.split()[1])))
        elif kind == "script":
            hit = any(p.name == tok for p in code)
            checks["scripts"].append((tok, hit))
        else:
            checks["code"].append((tok, found(code, rf"\b(class|module|interface)\s+{tok}\b")))
    defined = set(mdl.props)
    orphans = sorted({m.group(1) for t in code.values()
                      for m in re.finditer(r"\b((?:ast|asm|cov)_[FA]\d{2}_[a-z0-9_]+)\s*:", t)}
                     - defined)
    deferred = {lab for lab, r in mdl.props.items() if r["Runs"] in defer}
    missing_required = 0
    parts = []
    for cat, rows in checks.items():
        hits = sum(ok for _, ok in rows)
        opt = sum(1 for n, ok in rows if not ok and n in mdl.optional_tokens)
        dfr = sum(1 for n, ok in rows if not ok and n in deferred and n not in mdl.optional_tokens)
        missing_required += len(rows) - hits - opt - dfr
        parts.append(f"{cat} {hits}/{len(rows)}" + (f" ({opt} optional missing)" if opt else "")
                     + (f" ({dfr} deferred: Runs = {'/'.join(sorted(defer))})" if dfr else ""))
    print("vplan_check --trace: " + ", ".join(parts) + f"; orphan labels in code: {len(orphans)}")
    if verbose:
        for cat, rows in checks.items():
            for name, ok in rows:
                if not ok:
                    tag = ("optional" if name in mdl.optional_tokens else
                           "deferred" if name in deferred else "missing")
                    print(f"  {tag:8} {cat:8} {name}")
    for o in orphans:
        print(f"  orphan   label    {o} (in code, not in the vplan)")
    return missing_required + len(orphans)


# ---------------------------------------------------------------------------------------------
# --annotate
# ---------------------------------------------------------------------------------------------

# Coverage numbers for one vplan item from functional.json: (live bins, hit, hole names), or
# None when the item is not in the database (planned but not implemented).
def item_status(groups: dict, item: str) -> tuple[int, int, list[str]] | None:
    group, point = item.split(".")
    it = groups.get(group, {}).get("items", {}).get(point)
    if it is None:
        return None
    bins = it["bins"]
    return len(bins), sum(1 for c in bins.values() if c > 0), sorted(b for b, c in bins.items() if c == 0)


# The plan's stated bin total ("**Totals.** ... <n> bins"), or None if it states none.
def stated_bins(vp: Vplan) -> int | None:
    for ln in vp.lines:
        m = re.search(r"\*\*Totals\.\*\*.*?(\d+)\s+bins", ln)
        if m:
            return int(m.group(1))
    return None


# Percentage text that never rounds a hole up to 100.
def pct(hit: int, total: int) -> str:
    if total == 0:
        return "n/a"
    return "100%" if hit == total else f"{min(99.9, 100.0 * hit / total):.1f}%"


# SO-1 numbers for the results page (make_results.py), counted the way --annotate counts them:
# planned bins and hits over the plan's items (excluded ones left out), the fewest hits of any
# planned bin, planned items missing from the database, the plan's stated total, and the
# simulation cover properties of the plan with their hits.
def so1_counts(vp: Vplan, mdl: Model, cov: dict) -> dict:
    groups, covers = cov["groups"], cov.get("covers") or {}
    excluded = {t for r in vp.tables["exclusions"] for t in tokens(r["Item"])}
    bins, missing = {}, []
    for item in mdl.cov_items:
        if item in excluded:
            continue
        group, point = item.split(".")
        it = groups.get(group, {}).get("items", {}).get(point)
        if it is None:
            missing.append(item)
        else:
            bins.update({f"{item}.{b}": c for b, c in it["bins"].items()})
    sim_covers = [p for p, r in mdl.props.items()
                  if p.startswith("cov_") and r["Runs"] in ("sim", "both") and p not in excluded]
    return {"bins": len(bins), "hit": sum(c > 0 for c in bins.values()), "thinnest": min(bins.values(), default=0),
            "missing": missing, "stated": stated_bins(vp), "covers": len(sim_covers),
            "covers_hit": sum(covers.get(c, 0) > 0 for c in sim_covers),
            "covers_thinnest": min((covers.get(c, 0) for c in sim_covers), default=0)}


# SO-3 (vplan §7) from formal_run.py's sign-off JSON: k-induction passes at ASIZE 2 and 3, every
# formal cover of the plan (Runs = formal or both, not excluded) is reached in each cover run,
# every run met its expectation (pdr, audit, cross-checks). Returns (SO-3 text, per-feature
# Formal text, number of problems).
SO3_SIZES = (2, 3)


def formal_status(mdl: Model, data: dict, excluded: set[str]) -> tuple[str, dict[str, str], int]:
    runs = data["runs"]
    by = lambda task: {r["asize"]: r for r in runs if r["task"] == task}
    prove, cover, pdr = by("prove"), by("cover"), by("pdr")
    fcov = [p for p, r in mdl.props.items() if p.startswith("cov_") and r["Runs"] in ("formal", "both")
            and p not in excluded]
    missed = {a: [c for c in fcov if c not in r["reached"]] for a, r in cover.items()}
    proven = [a for a in SO3_SIZES if a in prove and prove[a]["verdict"] == "PASS"]
    reached = [a for a in SO3_SIZES if a in cover and not missed[a]]
    bad_runs = [r for r in runs if not r["ok"]]
    problems = (len(SO3_SIZES) - len(proven)) + (len(SO3_SIZES) - len(reached)) + len(bad_runs)
    sizes = lambda xs: ", ".join(str(x) for x in xs) or "none"
    audit = ", ".join(f"{r['task'][-3:].upper()} dropped: {r['verdict']}" for r in runs
                      if r["task"].startswith("audit_") and r["asize"] == max(SO3_SIZES))
    text = (f"k-induction PASS at ASIZE {sizes(proven)} (required: {sizes(SO3_SIZES)}); "
            f"formal covers {len(fcov)}/{len(fcov)} reached at ASIZE {sizes(reached)}"
            + "".join(f" — **MISSED at {a}:** {', '.join(f'`{c}`' for c in m)}" for a, m in missed.items() if m)
            + f"; pdr {', '.join(f'{a}: {r['verdict']}' for a, r in sorted(pdr.items())) or 'not run'}"
            + (f"; audit at ASIZE {max(SO3_SIZES)}: {audit}" if audit else "")
            + (f"; **{len(bad_runs)} run(s) not as expected:** "
               + ", ".join(f"{r['task']}@{r['asize']} {r['verdict']}" for r in bad_runs) if bad_runs else "")
            + f"; {data['meta']['generated']}; reproduce with `{data['meta']['repro']}`.")
    per_feature = {}
    for fid in mdl.features:
        labs = [p for p, r in mdl.props.items() if r["Runs"] in ("formal", "both")
                and (m := LABEL_RE.match(p)) and m.group(1) == fid]
        asts = [p for p in labs if p.startswith("ast_")]
        covs = [p for p in labs if p.startswith("cov_") and p not in excluded]
        parts = []
        if asts:
            parts.append(f"{len(asts)} assertion(s) " + ("proven" if len(proven) == len(SO3_SIZES) else "**NOT PROVEN**"))
        if covs:
            hit = sum(all(c in cover[a]["reached"] for a in SO3_SIZES if a in cover) for c in covs)
            parts.append(f"{hit}/{len(covs)} cover(s) reached")
        per_feature[fid] = "; ".join(parts)
    return text, per_feature, problems


# Write the status page from the plan, the merged coverage and (optionally) the regression
# results and the formal sign-off. Returns the number of problems --strict fails on: holes,
# missing items, a bin count different from the plan's total, an SO-3 shortfall.
def run_annotate(vp: Vplan, mdl: Model, cov_path: Path, results_path: Path | None, out: Path,
                 formal_path: Path | None = None) -> int:
    cov = json.loads(cov_path.read_text())
    groups = cov["groups"]
    covers = cov.get("covers")  # cover-property hits {label: count}, once M6 adds them
    excluded = {t for r in vp.tables["exclusions"] for t in tokens(r["Item"])}
    problems = 0
    # Coverage model: one row per planned item, in plan order.
    rows, live_total, hit_total, missing = [], 0, 0, []
    for item in mdl.cov_items:
        st = item_status(groups, item)
        if item in excluded:
            rows.append(f"| `{item}` | — | — | excluded (vplan §8) | |")
        elif st is None:
            missing.append(item)
            rows.append(f"| `{item}` | — | — | **NOT IN DATABASE** | |")
        else:
            n, h, holes = st
            live_total += n
            hit_total += h
            rows.append(f"| `{item}` | {h}/{n} | {pct(h, n)} | {'covered' if h == n else '**HOLES**'} | "
                        f"{', '.join(f'`{b}`' for b in holes)} |")
    holes_total = live_total - hit_total
    planned = stated_bins(vp)
    count_ok = planned is None or planned == live_total + sum(
        (item_status(groups, i) or (0, 0, []))[0] for i in excluded if i in mdl.cov_items)
    problems += holes_total + len(missing) + (not count_ok)
    # Items in the database that the plan doesn't list (helper coverpoints for crosses).
    extra = sorted(f"{g}.{i}" for g, gd in groups.items() for i in gd["items"] if f"{g}.{i}" not in mdl.cov_items)
    # Formal sign-off (M7), if given.
    so3, formal_feat = "pending (M7)", {}
    if formal_path and formal_path.is_file():
        so3, formal_feat, fprob = formal_status(mdl, json.loads(formal_path.read_text()), excluded)
        problems += fprob
    # Per feature: its coverage items, its simulation cover properties, its formal column.
    feats = []
    for fid, r in mdl.features.items():
        cov_items = [t for t in tokens(r["Coverage"]) if t in mdl.cov_items]
        sim_covers = [t for t in tokens(r["Coverage"]) if t.startswith("cov_") and t in mdl.props
                      and mdl.props[t]["Runs"] in ("sim", "both")]
        if is_na(r["Coverage"]):
            cstat = "n/a"
        else:
            sts = [item_status(groups, i) for i in cov_items if i not in excluded]
            n = sum(s[0] for s in sts if s)
            h = sum(s[1] for s in sts if s)
            cstat = (f"{h}/{n} bins" + ("" if h == n and all(sts) else " — **HOLES**")) if cov_items else "—"
        if covers is None:
            pstat = f"{len(sim_covers)} pending (M6)" if sim_covers else "—"
        else:
            hit_c = sum(1 for c in sim_covers if covers.get(c, 0) > 0)
            pstat = f"{hit_c}/{len(sim_covers)} hit" + ("" if hit_c == len(sim_covers) else " — **MISSED**")
        formal = "n/a" if is_na(r["Formal"]) else (formal_feat.get(fid) or "—") if formal_feat else "pending (M7)"
        feats.append(f"| {fid} | {cstat} | {pstat} | {formal} |")
    # SO-1 cover properties: every simulation cover of the plan (Runs = sim or both), listed in a
    # feature or not, must be hit at least once (vplan §7). Excluded ones (vplan §8) don't count.
    all_covers = [p for p, r in mdl.props.items()
                  if p.startswith("cov_") and r["Runs"] in ("sim", "both") and p not in excluded]
    if covers is None:
        so1c = "pending (M6)"
    else:
        missed_c = [c for c in all_covers if covers.get(c, 0) == 0]
        problems += len(missed_c)
        so1c = (f"{len(all_covers) - len(missed_c)}/{len(all_covers)} simulation covers hit"
                + (f" — **MISSED:** {', '.join(f'`{c}`' for c in missed_c)}" if missed_c else ""))
    # Regression result, if given.
    reg = "No regression results given."
    if results_path and results_path.is_file():
        data = json.loads(results_path.read_text())
        runs, meta = data["runs"], data["meta"]
        n_pass = sum(r["status"] == "PASS" for r in runs)
        per = {}
        for r in runs:
            per.setdefault(r["id"], []).append(r["status"] == "PASS")
        reg = (f"{n_pass}/{len(runs)} runs passed ({len(per)} entries, "
               + ", ".join(f"`{k}` {sum(v)}/{len(v)}" for k, v in per.items())
               + f"); git {meta['git']}; {meta['generated']}; reproduce with `{meta['repro']}`.")
    # The page.
    so1 = (f"{hit_total}/{live_total} planned bins hit ({pct(hit_total, live_total)})"
           + (f", {len(missing)} item(s) missing" if missing else "")
           + ("" if count_ok else f", **bin count {live_total} differs from the plan's {planned}**"))
    lines = [
        f"# {vp.path.parent.parent.name} — verification plan status",
        "",
        f"Generated by `vplan_check.py --annotate` on {datetime.datetime.now().isoformat(timespec='seconds')} "
        f"from `{vp.path.name}` and the merged coverage of {cov['merged_runs']} passing runs "
        f"({cov['sim']}). Do not edit by hand: rerun `make cov` (or `make regress`).",
        "",
        "## Sign-off",
        "",
        "| ID | Status |",
        "|---|---|",
        f"| SO-1 coverage model | {so1} |",
        f"| SO-1 cover properties | {so1c} |",
        f"| SO-2 regression | {reg} |",
        f"| SO-3 formal | {so3} |",
        "",
        "## Coverage model (vplan §3)",
        "",
        "| Item | Hit/bins | Coverage | Status | Holes |",
        "|---|---|---|---|---|",
        *rows,
        "",
        f"Planned total: {planned if planned is not None else 'not stated'} bins; in the database: "
        f"{live_total} live bins in the planned items. Items in the database but not in the plan "
        f"(helpers, not counted): {', '.join(f'`{e}`' for e in extra) or 'none'}.",
        "",
        "## Features",
        "",
        "| ID | Coverage | Simulation covers | Formal |",
        "|---|---|---|---|",
        *feats,
        "",
    ]
    out.write_text("\n".join(lines))
    print(f"vplan_check --annotate: SO-1 coverage model {so1}; wrote {out}")
    return problems


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

# Parse arguments, run the requested modes, print findings and a one-line reproduction command.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vplan", required=True, type=Path, help="path to docs/vplan.md")
    ap.add_argument("--structure", action="store_true", help="check the plan itself")
    ap.add_argument("--trace", action="store_true", help="look for planned names in the code")
    ap.add_argument("--annotate", action="store_true", help="write vplan_status.md from merged coverage")
    ap.add_argument("--cov", type=Path, help="--annotate: functional.json written by regress.py")
    ap.add_argument("--results", type=Path, help="--annotate: results.json written by regress.py")
    ap.add_argument("--formal", type=Path, help="--annotate: signoff.json written by formal_run.py (M7)")
    ap.add_argument("--status-out", type=Path, help="--annotate: output (default: vplan_status.md next to the vplan)")
    ap.add_argument("--root", type=Path, action="append", default=[],
                    help="directory to search for code (repeatable; default: the block root, "
                         "two levels above the vplan)")
    ap.add_argument("--makefile", type=Path, help="Makefile for `make <target>` references "
                                                  "(default: <first root>/Makefile)")
    ap.add_argument("--strict", action="store_true", help="--trace fails on anything missing; "
                                                       "--annotate fails on any hole")
    ap.add_argument("--defer", action="append", default=[], choices=sorted(RUNS),
                    help="--trace: labels with this Runs value are not required yet (repeatable)")
    ap.add_argument("-v", "--verbose", action="store_true", help="list missing names")
    args = ap.parse_args(argv)
    raw = list(argv) if argv is not None else sys.argv[1:]
    repro = "repro: python3 " + shlex.join([sys.argv[0]] + raw)

    if not (args.structure or args.trace or args.annotate):
        ap.error("choose at least one of --structure, --trace, --annotate")
    if args.annotate and not (args.cov and args.cov.is_file()):
        print(f"vplan_check --annotate: need --cov <functional.json> (got {args.cov}); run `make regress`",
              file=sys.stderr)
        return 2
    if not args.vplan.is_file():
        print(f"vplan_check: no such file {args.vplan}", file=sys.stderr)
        return 2

    vp = Vplan(args.vplan)
    mdl = check_structure(vp)
    rc = 0
    if args.structure:
        for f in sorted(vp.findings, key=lambda f: f.line):
            print(f"{args.vplan}:{f.line}: {f.msg}")
        if vp.findings:
            print(f"vplan_check --structure: FAIL, {len(vp.findings)} problem(s)   {repro}")
            rc = 1
        else:
            print(f"vplan_check --structure: PASS ({len(mdl.features)} features, "
                  f"{len(mdl.props)} properties, {len(mdl.ledger)} assumptions, "
                  f"{len(mdl.cov_items)} coverage items in {len(mdl.covgroups)} covergroups, "
                  f"{len(mdl.tests)} tests, {len(mdl.bugs)} planted bugs, N = {mdl.n_seeds})")
    if args.trace:
        if vp.findings and not args.structure:
            print(f"vplan_check --trace: the plan has {len(vp.findings)} structure problem(s); "
                  "run --structure first", file=sys.stderr)
            return 1
        roots = args.root or [args.vplan.resolve().parent.parent]
        makefile = args.makefile or roots[0] / "Makefile"
        bad = run_trace(mdl, roots, makefile, args.verbose, set(args.defer))
        if args.strict and bad:
            print(f"vplan_check --trace --strict: FAIL, {bad} missing or orphan item(s)   {repro}")
            rc = 1
    if args.annotate:
        if vp.findings:
            print(f"vplan_check --annotate: the plan has {len(vp.findings)} structure problem(s); "
                  "run --structure first", file=sys.stderr)
            return 1
        out = args.status_out or args.vplan.parent / "vplan_status.md"
        bad = run_annotate(vp, mdl, args.cov, args.results, out, args.formal)
        if args.strict and bad:
            print(f"vplan_check --annotate --strict: FAIL, {bad} hole(s) or missing item(s)   {repro}")
            rc = 1
    if rc == 0:
        print(repro)
    return rc


if __name__ == "__main__":
    sys.exit(main())
