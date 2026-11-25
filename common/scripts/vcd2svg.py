#!/usr/bin/env python3
"""vcd2svg.py — read a VCD trace (SBY/smtbmc or simulator) and print it as a table or draw it as
an SVG waveform. Standard library only (DEC-011 D5: the README figures of M7's cover traces).

  vcd2svg.py TRACE.vcd --list                      # every signal, full hierarchical name
  vcd2svg.py TRACE.vcd --table wbin rbin wfull     # one row per timestamp (debugging)
  vcd2svg.py TRACE.vcd --svg out.svg wclk wbin ... [--title T] [--label sig=Text ...]

Signals are matched by full name or by a dot-separated suffix (`wbin` matches `async_fifo.wbin`,
`p_e2e.wr_cnt` matches `async_fifo.p_e2e.wr_cnt`); an ambiguous suffix is an error.
--step N keeps only timestamps divisible by N and labels them t/N: yosys-smtbmc writes formal
step k at #10k (plus a half-step #10k+5), so --step 10 gives one row or column per formal step.
"""
from __future__ import annotations

import argparse
import html
import sys
from dataclasses import dataclass, field
from pathlib import Path


# One VCD variable: its full name, width, and value changes as (time, value string) pairs.
# Values are kept as VCD writes them: binary digits (possibly x/z) without the 'b' prefix.
@dataclass
class Signal:
    name: str
    width: int
    changes: list[tuple[int, str]] = field(default_factory=list)

    # Value at time t (the latest change at or before t), or None before the first change.
    def at(self, t: int) -> str | None:
        val = None
        for ct, cv in self.changes:
            if ct > t:
                break
            val = cv
        return val


# Parsed trace: signals by full name and the sorted list of timestamps that appear.
@dataclass
class Trace:
    signals: dict[str, Signal]
    times: list[int]

    # Resolve a full name or a unique dot-separated suffix to a signal; raise on none or several.
    def find(self, pattern: str) -> Signal:
        if pattern in self.signals:
            return self.signals[pattern]
        hits = [s for n, s in self.signals.items() if n.endswith("." + pattern)]
        if len(hits) != 1:
            what = "no signal" if not hits else f"{len(hits)} signals ({', '.join(h.name for h in hits[:4])})"
            raise KeyError(f"'{pattern}' matches {what}")
        return hits[0]


# Parse VCD text. Handles $scope/$upscope, $var (several names may share one id code), #time,
# scalar changes (0!, 1!, x!) and vector changes (b0101 !, r1.5 !). Ignores everything else.
def parse_vcd(text: str) -> Trace:
    by_id: dict[str, list[Signal]] = {}
    signals: dict[str, Signal] = {}
    scope: list[str] = []
    times: list[int] = []
    t = 0
    toks = iter(text.split())
    for tok in toks:
        if tok == "$scope":
            next(toks)                          # scope kind (module, begin, ...)
            scope.append(next(toks))
            next(toks)                          # $end
        elif tok == "$upscope":
            scope.pop()
            next(toks)
        elif tok == "$var":
            _kind, width, code, ref = next(toks), int(next(toks)), next(toks), next(toks)
            rest = next(toks)
            if rest != "$end":                  # bit-select such as [3:0]: drop it
                while next(toks) != "$end":
                    pass
            name = ".".join(scope + [ref])
            sig = signals.setdefault(name, Signal(name, width))
            by_id.setdefault(code, []).append(sig)
        elif tok.startswith("$"):              # other sections ($date, $comment, ...): skip
            if tok not in ("$end", "$dumpvars", "$dumpall", "$dumpon", "$dumpoff"):
                while next(toks, "$end") != "$end":
                    pass
        elif tok.startswith("#"):
            t = int(tok[1:])
            if not times or times[-1] != t:
                times.append(t)
        elif tok[0] in "bBrR":
            val, code = tok[1:].lower(), next(toks)
            for sig in by_id.get(code, []):
                sig.changes.append((t, val))
        elif tok[0] in "01xXzZ":
            for sig in by_id.get(tok[1:], []):
                sig.changes.append((t, tok[0].lower()))
    return Trace(signals, times)


# Display form of a value: 1-bit as 0/1/x, vectors in hex (x if any bit is unknown).
def fmt(val: str | None, width: int) -> str:
    if val is None:
        return "-"
    if width == 1:
        return val[-1]
    if any(c in "xz" for c in val):
        return "x"
    return format(int(val, 2), "x")


# Text table: header of short names, one row per timestamp (labeled t // step).
def table(tr: Trace, sigs: list[Signal], step: int = 1) -> str:
    names = ["t"] + [s.name.split(".")[-1] if len(s.name.split(".")) < 3 else ".".join(s.name.split(".")[-2:])
                     for s in sigs]
    rows = [[str(t // step)] + [fmt(s.at(t), s.width) for s in sigs] for t in tr.times]
    widths = [max(len(r[i]) for r in [names] + rows) for i in range(len(names))]
    line = lambda r: "  ".join(c.rjust(w) for c, w in zip(r, widths))
    return "\n".join([line(names)] + [line(r) for r in rows])


# SVG waveform: one lane per signal, one column per timestamp. 1-bit signals are drawn as a
# line (high/low); vectors as value boxes whose label is the hex value, split where it changes.
# Fixed light palette with an explicit white background, so the figure reads the same anywhere.
def svg(tr: Trace, sigs: list[Signal], title: str, labels: dict[str, str], step: int = 1) -> str:
    col, lane, left, top = 26, 26, 150, 34 if title else 12
    n = len(tr.times)
    w, h = left + col * n + 12, top + lane * len(sigs) + 24
    w = max(w, 16 + int(len(title) * 7.8))          # room for the title (13 px bold monospace)
    ink, grid, fill_v = "#1f2933", "#d9dee5", "#e8f0fb"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
           f'font-family="ui-monospace, Menlo, Consolas, monospace" font-size="11">',
           f'<rect width="{w}" height="{h}" fill="#ffffff"/>']
    if title:
        out.append(f'<text x="8" y="20" font-size="13" font-weight="bold" fill="{ink}">{html.escape(title)}</text>')
    # Step grid and step numbers along the bottom.
    for i, t in enumerate(tr.times):
        x = left + i * col
        out.append(f'<line x1="{x}" y1="{top - 4}" x2="{x}" y2="{top + lane * len(sigs)}" stroke="{grid}"/>')
        if i % 2 == 0:
            out.append(f'<text x="{x + 2}" y="{h - 8}" fill="#6b7785" font-size="9">{t // step}</text>')
    # One lane per signal: name at the left, then the waveform.
    for k, s in enumerate(sigs):
        y0, y1 = top + k * lane + 4, top + (k + 1) * lane - 6
        name = labels.get(s.name, s.name.split(".")[-1])
        out.append(f'<text x="8" y="{y1 - 2}" fill="{ink}">{html.escape(name)}</text>')
        vals = [fmt(s.at(t), s.width) for t in tr.times]
        if s.width == 1:
            pts = []
            for i, v in enumerate(vals):
                y = y0 if v == "1" else y1
                x = left + i * col
                pts += [f"{x},{y}", f"{x + col},{y}"]
            out.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="#1d5fbf" stroke-width="1.6"/>')
        else:
            i = 0
            while i < n:
                j = i
                while j + 1 < n and vals[j + 1] == vals[i]:
                    j += 1
                x, xe = left + i * col + 1, left + (j + 1) * col - 1
                out.append(f'<rect x="{x}" y="{y0}" width="{xe - x}" height="{y1 - y0}" rx="3" '
                           f'fill="{fill_v}" stroke="#1d5fbf"/>')
                out.append(f'<text x="{(x + xe) / 2}" y="{y1 - 4}" text-anchor="middle" fill="{ink}">{vals[i]}</text>')
                i = j + 1
    out.append("</svg>")
    return "\n".join(out) + "\n"


# Command line: --list, --table or --svg (see the module docstring).
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd", type=Path)
    ap.add_argument("signals", nargs="*")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="list every signal")
    mode.add_argument("--table", action="store_true", help="print the signals as a table")
    mode.add_argument("--svg", type=Path, help="write the signals as an SVG waveform")
    ap.add_argument("--title", default="")
    ap.add_argument("--step", type=int, default=1, help="keep timestamps divisible by N, labeled t/N")
    ap.add_argument("--label", action="append", default=[], metavar="SIG=TEXT",
                    help="lane label for a signal (default: its last name component)")
    args = ap.parse_args(argv)
    tr = parse_vcd(args.vcd.read_text(encoding="utf-8", errors="replace"))
    tr.times = [t for t in tr.times if t % args.step == 0]
    if args.list:
        for n, s in sorted(tr.signals.items()):
            print(f"{s.width:4}  {n}")
        return 0
    try:
        sigs = [tr.find(p) for p in args.signals]
        labels = {tr.find(k).name: v for k, v in (lab.split("=", 1) for lab in args.label)}
    except KeyError as e:
        print(f"vcd2svg: {e.args[0]}", file=sys.stderr)
        return 2
    if args.table:
        print(table(tr, sigs, args.step))
    else:
        args.svg.write_text(svg(tr, sigs, args.title, labels, args.step), encoding="utf-8")
        print(f"vcd2svg: wrote {args.svg} ({len(sigs)} signals, {len(tr.times)} steps)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
