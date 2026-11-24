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
| T7 | *(M1, 2026-11-22)* elaboration-time parameter guard: `if (ASIZE < 2) begin : g $error("..."); end` | Verilator, Yosys native | **PASS, with a caveat** | Yosys (`chparam` and `hierarchy -chparam`): `ERROR: ...`, exit 1. Verilator: only **warning** `USERERROR`; exit 1 only because warnings are fatal by default — `-Wno-fatal` lets ASIZE=1 through (exit 0). `-Werror-USERERROR` makes it a hard error even with `-Wno-fatal`. `$fatal` is no better (warning `USERFATAL`). Yosys prints `%0d` format specs verbatim, so the message carries no value. |
| T8 | *(M3, 2026-11-24)* clocking blocks as the UVM agents use them: `default input #1step` sampling, `default output #0` drives, a combinational gate `inc = req & ~(gate & full)` on a registered DUT output, class access through a virtual interface, clock process owned by the interface and started by a class call | Verilator `--timing` | **PASS** | `#1step` gives the pre-edge value at every edge; a drive executed right after `@(cb)` changes the signal in that edge's time step and is first sampled at the next edge; the gate falls in the same time step as `full` rises, and the DUT still accepts that edge's push (exactly 2 accepted, 0 blocked with the gate on, 4 blocked with it off). Negative check: with `input #0` the monitor sees post-edge values (count off by one at 10 edges), so the test is sensitive. |
| T9 | *(M3, 2026-11-24)* reset asserted at time 0 with random register init (`--x-initial unique`, `+verilator+rand+reset+2`) | Verilator `--timing` | **PASS** | Style A (`logic r = 1; initial r = 0;`) and style B (same, `initial #0 r = 0;`) fire the async reset on all 6 seeds. Style C (no initializer, `initial r = 0;`) misses it on 3 of 6 seeds: random init sometimes starts `r` at 0, so there is no negedge. Random init differs per seed. |
| T10 | *(M3, 2026-11-24)* constrained-random distributions for `fifo_env_cfg`: `dist` weights, period-ratio constraints, inline `randomize() with` | Verilator (external SMT solver) | **PASS, with a caveat** | `dist` weights are honored (bucket 19–21% each, integer share 19%, gap classes on target over 2000 draws) and `with {}` works. **Values without a `dist` are not spread evenly** when other constraints involve them: the first run, with `b inside {[0:4]}` and no `dist`, gave buckets 72/12/2/0/14%; T_wclk lands below its midpoint 34% of the time instead of 50%, even with `dist {[lo:hi] :/ 1}`. About 20 ms per `randomize()`. |

## Findings that affect later modules

- **Build once, run many (M3/M5).** A UVM build takes minutes; a run takes about a second.
  `regress.py` must build once per configuration and fan out seeds.
- **UVM build memory (M3).** Verilator groups the generated C++ into unity files
  (`*_vm_classes_*.cpp`); for the full FIFO testbench each one takes ~45 s and peaks at 1.2 GB.
  Eight compile jobs need ~9 GB on this 8 GB host: the first M3 build swapped and took 96 min
  (4 h of system time). `common/sim/verilator.mk` therefore sets `--build-jobs` from free memory
  (1.5 GB per job, at most `J`) and keeps `--verilate-jobs $(J)`. T1's bare UVM build was small
  enough that `-j 8` happened to fit.
- **Make variables leak into Verilator's build (M3).** A command-line variable such as `DEPS=`
  reaches Verilator's generated makefile through `MAKEFLAGS`; `verilated.mk` uses `DEPS`
  internally (the `.d` files it includes), so the build died with "missing separator" in a `.sv`
  file. The sim layer runs Verilator under `env -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS`.
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
- **Parameter guard (M1+, T7).** Every Verilator command that builds the RTL (lint, smoke, UVM,
  MCY sim) must pass `-Werror-USERERROR`; otherwise a flow that uses `-Wno-fatal` would silently
  elaborate ASIZE=1. Yosys stops on its own.
- **Comments that start with "verilator" are pragmas.** `// Verilator reports ...` fails lint
  with `%Error-BADVLTPRAGMA: Unknown verilator comment` (seen in M1). Don't begin a comment
  with the word *verilator* unless it is a real `verilator lint_off/...` pragma.
- **Flop count after `synth` (M1).** Yosys folds each gray pointer MSB into the binary MSB
  (`assign wptr[ASIZE] = wbin[ASIZE]`; gray MSB = binary MSB), so `synth; stat` shows
  `8·(ASIZE+1)` async-reset flops, not the plan's `8·(ASIZE+1)+2`. The `+2` count holds
  before optimization (`proc` only: 42 bits at ASIZE=4). `make synth` checks the pre-opt count.
- **No FST tracing on this host (M1).** `--trace-fst` builds fail: Verilator's FST writer
  (`fstcpp_writer.cpp`) needs `lz4.h`. Only the runtime `liblz4-1` is installed, not the
  `liblz4-dev` headers. Flows use VCD (`--trace`); convert with the suite's `vcd2fst` if
  needed. Installing `liblz4-dev` would re-enable FST (a system package, so the owner decides).
- **ZERODLY on run-time delays (M1).** `#(UNIT * wmul)` with a variable multiplier raises
  `%Warning-ZERODLY` under `-Wall`. `tb_smoke.sv` waives it with a scoped
  `/* verilator lint_off ZERODLY */` block, justified in a comment (multipliers are checked
  >= 1). Other simulators ignore the comment.
- **`-Wall` catches a dead synchronizer stage (M1 self-test).** An RTL variant whose flag used
  `wq1_rptr` (one-stage synchronizer) failed the smoke build with `UNUSEDSIGNAL 'wq2_rptr'`.
  With that warning waived, smoke *passes* it (wfull latency 2 < K = 3 is legal), so lint is
  the only M1 check that sees this bug. This is useful for M8's detection matrix.
- **Clocking blocks (M3, T8).** `default input #1step output #0` behaves as IEEE 1800 says:
  monitors see the values the DUT sampled, and a drive executed right after `@(cb)` reaches the
  DUT one edge later. A continuous `assign` gating a TB request with a registered DUT output
  (`winc = req & ~(wfull & ...)`) is race-free. `input #0` would sample post-edge values instead.
  Under `-Wall` every clocking-block signal is reported UNDRIVEN/UNUSEDSIGNAL (false positives),
  so the UVM build uses Verilator's default warning set (still fatal), like T1; the RTL keeps its
  own `-Wall` lint in `make lint`.
- **ZERODLY is a default warning (M3, T8).** A run-time delay such as `#(period / 2)` fails the
  build even without `-Wall`. Clock generators waive it locally (`lint_off ZERODLY`) with a
  comment saying why the delay is never 0, as in M1.
- **Power-up reset at time 0 (M3, T9).** Declare the reset with initializer 1 and drive it to 0
  at time 0 (`initial #0 rst_n = 1'b0;`). With random register init a reset that merely starts
  at 0 has no negedge, so async-reset flops keep their random values until the first clock edge
  (3 of 6 seeds in T9). `#0` also avoids the time-0 race in event-driven simulators.
- **Randomization (M3, T10).** Use `dist` for every categorical choice whose share matters, and
  draw numbers that must be uniform inside a range procedurally (`$urandom_range`) after the
  categories are fixed. No simulator would give the plan's distribution otherwise: IEEE 1800 asks
  solvers to spread over all legal *combinations*, which favors buckets with more legal periods,
  and Verilator's solver is also uneven inside a range (T10).
- **Quiet runs.** `+verilator+quiet` suppresses Verilator's end-of-run report (wall time, speed),
  the only part of a run log that differs between two identical runs.
