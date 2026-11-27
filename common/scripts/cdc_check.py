#!/usr/bin/env python3
"""cdc_check.py — a small structural clock-domain-crossing checker (M8 step 5, `make cdc`).

Yosys elaborates the RTL (`prep; flatten; write_json`); this script builds the flop graph from
the netlist and checks every crossing against three rules:

  R1  A crossing starts at a flop and reaches the first destination flop with no logic between
      them (logic on a crossing can glitch, and a multi-bit cone can mix old and new bits).
  R2  The first destination flop (synchronizer stage 1) feeds nothing but flops of its own
      domain (stage 2): its possibly metastable output gets a full clock period to settle.
  R3  Every flop's asynchronous reset is the reset of its own clock domain (so the synchronizer
      stages use the destination reset).

Plus R4 (information only): a multi-bit synchronizer is safe only if its source changes at most
one bit per source clock (gray code). Structure cannot show that; the white-box assertions
ast_F09_*_cdc_one_bit do.

The block's config (TOML) names each clock domain's reset, the domain of each data port (outputs
are checked as destinations, inputs are sources) and waivers, each with a rule, destination,
source and reason. Exit status: 0 no unwaived violation, 1 violations, 2 setup error.
Python >= 3.11, standard library only.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

# Yosys flip-flop cell types and their clock / async-reset / data-input ports.
FF_TYPES = {"$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce", "$dffsr", "$dffsre", "$aldff", "$aldffe"}
FF_DATA_PORTS = ("D", "EN", "SRST")
MEM_TYPES = {"$mem", "$mem_v2"}


# One flop (or memory write port, or checked output port): a destination with a domain.
@dataclass
class Node:
    name: str
    kind: str                      # flop | memory | output | input
    domain: str | None
    reset: str | None = None
    ins: list = field(default_factory=list)     # data input bits (traced backwards)
    outs: list = field(default_factory=list)    # output bits (Q, RD_DATA, or the input port's bits)


# One source reached by a backwards trace: what it is and whether logic was crossed on the way.
@dataclass(frozen=True)
class Source:
    name: str
    kind: str
    domain: str | None
    logic: bool


# One rule violation (or R4 note), printable and matchable against waivers.
@dataclass
class Finding:
    rule: str
    dest: str
    source: str
    msg: str
    waived_by: str = ""


# The netlist as graphs: who drives each bit, who reads it, and every node with a domain.
class Netlist:
    # Parse the module of a Yosys JSON netlist.
    def __init__(self, data: dict, top: str, cfg: dict):
        m = data["modules"][top]
        self.cells = m["cells"]
        self.domains = cfg.get("domains", {})
        self.port_dom = cfg.get("ports", {})
        self.names = {n: nn["bits"] for n, nn in m["netnames"].items() if not n.startswith("$")}
        self.bitname = {}
        for n in sorted(self.names):
            for i, b in enumerate(self.names[n]):
                if isinstance(b, int):
                    self.bitname.setdefault(b, (n, i, len(self.names[n])))
        self.driver: dict[int, tuple] = {}
        self.readers: dict[int, list] = {}
        for pname, p in m["ports"].items():
            for b in p["bits"]:
                if not isinstance(b, int):
                    continue
                if p["direction"] == "input":
                    self.driver[b] = ("input", pname, "")
                else:
                    self.readers.setdefault(b, []).append(("output", pname, ""))
        for cname, c in self.cells.items():
            for port, bits in c["connections"].items():
                d = c.get("port_directions", {}).get(port, "input")
                for b in bits:
                    if not isinstance(b, int):
                        continue
                    if d == "output":
                        self.driver[b] = ("cell", cname, port)
                    else:
                        self.readers.setdefault(b, []).append(("cell", cname, port))
        self.nodes = self._nodes(m)

    # Readable name of a group of bits: the net whose bits they are, else net[i] of the first bit.
    def label(self, bits: list) -> str:
        ints = [b for b in bits if isinstance(b, int)]
        for n, nb in sorted(self.names.items()):
            if nb == bits:
                return n
        if not ints:
            return "const"
        n, i, w = self.bitname.get(ints[0], (f"bit{ints[0]}", 0, 1))
        return n if w == 1 else f"{n}[{i}]" + ("..." if len(ints) > 1 else "")

    # Name of the net that drives a single bit (a clock or reset).
    def net(self, bits: list) -> str | None:
        return self.bitname.get(bits[0], (None,))[0] if bits and isinstance(bits[0], int) else None

    # Every destination: flops, memory write ports, data ports with a configured domain.
    def _nodes(self, m: dict) -> dict[str, Node]:
        nodes = {}
        for cname, c in self.cells.items():
            con = c["connections"]
            if c["type"] in FF_TYPES:
                dom = self.net(con["CLK"]) if "CLK" in con else None
                rst = self.net(con["ARST"]) if "ARST" in con else None
                name = self.label(con["Q"])
                nodes[cname] = Node(name, "flop", dom, rst, [b for p in FF_DATA_PORTS for b in con.get(p, [])], con["Q"])
            elif c["type"] in MEM_TYPES:
                wclk = self.net(con.get("WR_CLK", []))
                ins = [b for p in ("WR_DATA", "WR_ADDR", "WR_EN") for b in con.get(p, [])]
                nodes[cname] = Node(c["parameters"].get("MEMID", cname).lstrip("\\"), "memory", wclk, None, ins,
                                    con.get("RD_DATA", []))
        for pname, p in m["ports"].items():
            if p["direction"] == "output":
                nodes[f"port:{pname}"] = Node(pname, "output", self.port_dom.get(pname), None, p["bits"], [])
        return nodes

    # All sources of a set of bits, walking back through logic to flops, memories and inputs.
    def trace(self, bits: list) -> set[Source]:
        out: set[Source] = set()
        seen: set[tuple[int, bool]] = set()
        stack = [(b, False) for b in bits if isinstance(b, int)]
        while stack:
            b, logic = stack.pop()
            if (b, logic) in seen:
                continue
            seen.add((b, logic))
            drv = self.driver.get(b)
            if drv is None:
                continue
            kind, name, port = drv
            if kind == "input":
                if name not in self.domains and name not in self.domains.values():   # clocks and resets are not data
                    out.add(Source(name, "input", self.port_dom.get(name), logic))
                continue
            c = self.cells[name]
            if c["type"] in FF_TYPES:
                n = self.nodes[name]
                out.add(Source(n.name, "flop", n.domain, logic))
            elif c["type"] in MEM_TYPES:
                n = self.nodes[name]
                out.add(Source(n.name, "memory", n.domain, True))       # the read mux is logic
                stack += [(x, True) for x in c["connections"].get("RD_ADDR", []) if isinstance(x, int)]
            else:
                for p, pb in c["connections"].items():
                    if c.get("port_directions", {}).get(p, "input") == "input":
                        stack += [(x, True) for x in pb if isinstance(x, int)]
        return out


# Apply R1-R4 to the netlist; returns (violations, notes) with waivers applied.
def check(nl: Netlist, cfg: dict) -> tuple[list[Finding], list[Finding]]:
    viol, notes, stage1 = [], [], {}
    for key, n in nl.nodes.items():
        if n.domain is None:
            continue
        for s in sorted(nl.trace(n.ins), key=lambda s: (s.name, s.logic)):
            if s.domain is None or s.domain == n.domain:
                continue
            if s.kind != "flop" or s.logic:
                why = "logic between source and destination" if s.logic else f"source is a {s.kind}, not a flop"
                viol.append(Finding("R1", n.name, s.name, f"{s.kind} {s.name} ({s.domain}) -> {n.kind} {n.name} "
                                                         f"({n.domain}): {why}"))
            elif n.kind == "flop":
                stage1[key] = (n, s)
    for key, (n, s) in sorted(stage1.items(), key=lambda kv: kv[1][0].name):
        bad = []
        for b in n.outs:
            for kind, name, port in nl.readers.get(b, []):
                ok = kind == "cell" and nl.cells[name]["type"] in FF_TYPES and port == "D" and nl.nodes[name].domain == n.domain
                if not ok:
                    bad.append(f"output {name}" if kind == "output" else f"{nl.cells[name]['type']} ({port})")
        if not any(nl.readers.get(b) for b in n.outs):
            bad.append("nothing (no second stage)")
        if bad:
            viol.append(Finding("R2", n.name, s.name, f"synchronizer stage 1 {n.name} ({n.domain}) feeds "
                                                      f"{', '.join(sorted(set(bad)))}, not only a second stage"))
        if len([b for b in n.outs if isinstance(b, int)]) > 1:
            notes.append(Finding("R4", n.name, s.name, f"{len(n.outs)}-bit synchronizer {s.name} -> {n.name}: safe only "
                                                       "if the source changes at most one bit per source edge (not checked "
                                                       "structurally)"))
    for n in nl.nodes.values():
        if n.kind == "flop" and n.reset is not None and n.domain in nl.domains and nl.domains[n.domain] != n.reset:
            viol.append(Finding("R3", n.name, n.reset, f"flop {n.name} on {n.domain} is reset by {n.reset}, "
                                                      f"not by its domain's reset {nl.domains[n.domain]}"))
    for f in viol:
        for w in cfg.get("waiver", []):
            if w.get("rule") == f.rule and w.get("dest") == f.dest and w.get("source") == f.source:
                f.waived_by = w.get("reason", "")
    return viol, notes


# Elaborate the RTL with Yosys and return its JSON netlist.
def elaborate(rtl: list[Path], top: str, params: list[str], workdir: Path) -> dict:
    workdir.mkdir(parents=True, exist_ok=True)
    js = workdir / "netlist.json"
    chp = " ".join(f"-set {p.replace('=', ' ', 1)}" for p in params)
    script = (f"read_verilog -sv {' '.join(str(p) for p in rtl)}; " + (f"chparam {chp} {top}; " if chp else "")
              + f"prep -top {top}; flatten; write_json {js}")
    print(f"+ yosys -q -p '{script}'")
    p = subprocess.run(["yosys", "-q", "-l", str(workdir / "yosys.log"), "-p", script], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"yosys failed, see {workdir / 'yosys.log'}")
    return json.loads(js.read_text(encoding="utf-8"))


# Command line: elaborate, check, print findings, write JSON, exit by the verdict.
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rtl", type=Path, nargs="+", required=True)
    ap.add_argument("--config", type=Path, required=True, help="domains, port domains, waivers (TOML)")
    ap.add_argument("--param", action="append", default=[], metavar="NAME=VALUE")
    ap.add_argument("--out", type=Path, required=True, help="work directory (netlist, report.json)")
    ap.add_argument("--repro", default="", help="reproduction command to print")
    args = ap.parse_args(argv)
    try:
        with args.config.open("rb") as f:
            cfg = tomllib.load(f)
        top = cfg["top"]
        nl = Netlist(elaborate(args.rtl, top, args.param, args.out), top, cfg)
    except (OSError, KeyError, RuntimeError, tomllib.TOMLDecodeError) as e:
        print(f"cdc_check: {e}", file=sys.stderr)
        return 2
    viol, notes = check(nl, cfg)
    open_v = [v for v in viol if not v.waived_by]
    for v in viol:
        print(f"  {v.rule} {'WAIVED' if v.waived_by else 'VIOLATION'}: {v.msg}" + (f"  [waiver: {v.waived_by}]" if v.waived_by else ""))
    for n in notes:
        print(f"  {n.rule} note: {n.msg}")
    used = {(v.rule, v.dest, v.source) for v in viol if v.waived_by}
    for w in cfg.get("waiver", []):
        if (w.get("rule"), w.get("dest"), w.get("source")) not in used:
            print(f"  warning: waiver {w.get('rule')} {w.get('source')} -> {w.get('dest')} matched nothing")
    nsync = len([n for n in notes if n.rule == "R4"])
    (args.out / "report.json").write_text(json.dumps({"violations": [vars(v) for v in viol], "notes": [vars(n) for n in notes]},
                                                     indent=1) + "\n", encoding="utf-8")
    print(f"cdc {'PASS' if not open_v else 'FAIL'}: {len(open_v)} violations, {len(viol) - len(open_v)} waived, "
          f"{nsync} multi-bit synchronizers" + (f"   repro: {args.repro}" if args.repro else ""))
    return 0 if not open_v else 1


if __name__ == "__main__":
    sys.exit(main())
