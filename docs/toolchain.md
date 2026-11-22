# Toolchain

Pinned versions and the feature-by-tool support table. Rerun `tools_smoke/` after any upgrade
and update this file.

## Host

| Item | Value |
|---|---|
| OS | Ubuntu 26.04 LTS on WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2), x86_64 |
| CPU / RAM | 8 cores / 7 GB (WSL default limit; raise in `%UserProfile%\.wslconfig` if Verilator UVM builds run out of memory) |
| glibc | 2.43 |
| Python | 3.14.4 (system `/usr/bin/python3`; OSS CAD Suite does not put a `python3` on PATH) |
| Perl | 5.40.1 (Verilator front end) |
| make / g++ | GNU Make 4.4.1 / g++ 15.2.0 (`build-essential`, installed 2026-11-21) |

## OSS CAD Suite (pinned)

| Item | Value |
|---|---|
| Release | `2026-11-21` — `oss-cad-suite-linux-x64-20261121.tgz` |
| sha256 | `da62ff9cd16a69fc23607f3430459a3ca405561063e93910bf71d99012bb59e2` |
| Location | `~/tools/oss-cad-suite` (archive and `.sha256` kept beside it) |
| PATH | Make flows prepend `$(OSS_CAD_SUITE)/bin` via `common/tools.mk` (override `OSS_CAD_SUITE=`). Interactive shells: add `export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"` to `~/.bashrc`. |

| Tool | Version |
|---|---|
| Yosys | 0.71+77 (git 11d972c20) |
| SBY | v0.71-7-gb21f778 |
| EQY | v0.71-3-gd35005d |
| MCY | bundled with 20261121 (no `--version`; runs on bundled `tabbypy3` = Python 3.11.6) |
| Verilator | 5.055 devel, rev v5.054-350-gabfb70971 (≥ 5.054 ✓) |
| Icarus Verilog | 14.0 (devel) s20260301-1253-gc20d73fe3 |
| GTKWave | v4.0.0-prealpha (e40ba79) |
| Surfer | 0.7.0 (v0.7.0-122-gc2d17a64) |
| Yices | 2.8.0 |
| Z3 | 4.15.5 |
| Boolector | 3.2.4 |
| Bitwuzla | 0.9.1 |
| yosys-slang plugin | bundled (`share/yosys/plugins/slang.so`) |

## UVM library (pinned)

| Item | Value |
|---|---|
| Source | `chipsalliance/uvm-verilator`, tag `uvm-2020-3.2` (commit `1eab10a7995c7846dcad7305b995ddb265880433`, "UVM 2020-3.2 from Accellera.com") — the release Verilator 5.052+ names as supported |
| Location | `~/tools/uvm-2020-3.2` (`UVM_HOME=~/tools/uvm-2020-3.2/src`) |
| Build recipe | `verilator --binary --vpi +incdir+$UVM_HOME $UVM_HOME/uvm_pkg.sv $UVM_HOME/dpi/uvm_dpi.cc <tb>` (same as Verilator's own `t_uvm_hello_all_v2020_3_2_dpi` test) |
| Cost | T1 build ≈ 4 min (234–245 s at `-j 8`), peak RSS ≈ 0.9 GB; run < 0.5 s |

## Not available

| Tool | Status |
|---|---|
| Questa / Xcelium / VCS (commercial) | no access |
| Questa–Altera FPGA Starter | not installed; fallback only if Verilator fails T1–T3 (DEC-001) |
| Vivado XSim | not installed |

## Feature × tool results (tools_smoke/)

Rerun with `make tools-smoke` (or `make tools-smoke T="T1 T3"`); logs in `out/tools_smoke/`.
Run on 2026-11-21 with the pinned versions above: all PASS, 765 s total (T1 211 s, T5 493 s).

| Test | Feature | Tool | Result | Notes |
|---|---|---|---|---|
| T1 | UVM 2020-3.2: constrained `randomize()`, seeds differ, report summary parses | Verilator | **PASS** | 8 items/seed, constraints held, `+verilator+seed+N` changes values; summary lines `UVM_ERROR :    0` parse. Builds warning-clean with warnings fatal. |
| T2 | Covergroup: 2 coverpoints, cross, `ignore_bins`; merge two runs | Verilator + `verilator_coverage` | **PASS** | `--coverage-user`; run0 5 holes, run1 6 holes, merged 0 holes over 13 live bins. Ignored bin is recorded with type `ignore` and excluded. |
| T3a | Immediate assert with `$past` in a clocked block | Verilator | **PASS** | `--assert`; fails as `Assertion failed in t3_top.dut.ast_a_cnt_inc` |
| T3b | Concurrent `assert property` with `disable iff` + `\|=>` | Verilator | **PASS** | caught only by BREAK_B |
| T3c | `bind` of a checker module | Verilator | **PASS** | reported at `t3_top.dut.u_chk.ast_c_ack_has_req` |
| T3d | Deliberate failure is reported and fails the test | Verilator | **PASS** | first failure → `$stop`, exit code 1, `%Error: ... Assertion failed in <path>.<label>` |
| T4 | Two-clock formal: `multiclock on`, `(* gclk *)`, labeled assert + cover | SBY + Yosys (native reader) + yices | **PASS** | `prove`: k-induction succeeds; `cover`: `cov_T4_q2_rose_twice` reached at step 9, trace `out/tools_smoke/T4/cover/engine_0/trace0.vcd` (converts with `vcd2fst`; open by hand in GTKWave/Surfer); BREAK build fails as `ast_T4_q2_from_q1`. |
| T5 | MCY `bitcnt` example end to end (`init`, `run -j4`, `status`) | MCY + Icarus + SBY | **PASS** | 1000 mutations, ~8 min at `-j4`. Run A: COVERED 901 / UNCOVERED 55 / NOCHANGE 44 → 94.25%; run B: 896 / 63 / 41 → 93.43%. Example vendored unmodified (`tools_smoke/T5_mcy/bitcnt/SOURCE.txt`). |
| T6 | *(extra, for DEC-002)* concurrent SVA in formal | Yosys native / yosys-slang | **unsupported (as expected)** | native: `syntax error, unexpected '@'`; slang: `encountered unsupported SVA feature` — even for `a \|-> 1'b1`. T6 PASSes while this holds and FAILs if support appears. |

## Findings that affect later modules

- **Build once, run many (M3/M5).** A UVM build is ~4 min and ~0.9 GB; a run is under a second.
  `regress.py` must build once per configuration and fan out seeds. Memory is not the limit at `-j 8`.
- **Covergroups (M5).** `cg.get_coverage()` works; `cg.<coverpoint|cross>.get_coverage()` is
  *unsupported* in this Verilator — use `get_inst_coverage()` for per-point numbers. Sample
  covergroups explicitly with `sample()`: a clocked covergroup also samples reset/idle values,
  which skewed T2's first attempt.
- **Coverage merge (M5).** `verilator_coverage --write merged.dat a.dat b.dat` merges; covergroup
  bins are records with `t=covergroup`, a hierarchical bin name (`h`) and bin type (`Bt=ignore|illegal`).
  No covergroup-level text report exists, so `regress.py` parses `.dat` directly (T2 has a working
  20-line parser).
- **Assertions in sim (M6).** Verilator stops at the first failing assertion (exit 1). Pass/fail
  patterns for `common/sim/verilator.patterns`: `%Error:`, `Assertion failed in`.
- **Lint-clean idiom.** Write `if (obj.randomize() != 1)` — `!obj.randomize()` raises WIDTHTRUNC.
- **Formal style (M6/M7).** Labeled immediate assertions/covers inside `always @(posedge gclk)`
  with `multiclock on` work, and SBY reports failures by label. Concurrent SVA is not available
  in open-source formal (T6), so plan §3 R5's portable style is required, not optional.
- **MCY reproducibility (M9).** `mcy init` picks a random mutation set unless the config pins it:
  two runs of the same example scored 94.25% and 93.43%. M9's `config.mcy` must set `seed` in
  `[options]` and the report must quote it. ~0.5 s per mutant at `-j4` with Icarus — a UVM
  testbench will need `maxbatchsize`/`mutsel` batching (plan R8).
- **SBY config comments.** `#` comment lines are accepted in every `.sby` section, including
  `[script]` (verified by T4 after DEC-004 commenting).
