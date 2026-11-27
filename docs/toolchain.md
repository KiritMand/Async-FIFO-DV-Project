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
| T11 | *(M5, 2026-11-24)* covergroup constructs for `fifo_coverage`: covergroup embedded in a class in a package, `sample()` with arguments, range bins, `iff`, 3-value transition bins `(15 => 16 => 15)`, a cross of a transition coverpoint, `ignore_bins` on a cross (`!binsof(..) intersect {..}` and `binsof(..) && binsof(cp.bin)`), `option.per_instance = 0`, two instances | Verilator `--coverage-user` | **PASS** | All 39 records (37 live, 2 ignore) have exactly the hand-computed counts. Records are named by covergroup **type** (`t11_pkg::cov_c::cg.cp_f.full`), never by instance, and two sampled instances add into one record, so runs merge. Cross bins are named `<binA,binB>`; an `ignore_bins` is one record with `Bt=ignore` (its count = hits of ignored combinations), and no live cross bin is created for it. Record keys include source file, line and column, so merge only databases from the same build; key on the `h` field when comparing. **`cg.get_coverage()` is not the item average** (50.42% where the items average ~82%): report numbers from the `.dat`, never from that call. |
| T12 | *(M5, 2026-11-24)* code coverage scoped to the design with a `.vlt` file: `--coverage-line --coverage-branch --coverage-toggle --coverage-user` | Verilator | **PASS, with a caveat** | `coverage_off -file "*/t12_tb.sv"` removes every line, branch and toggle point of that file (class methods and module signals) and keeps its covergroup. `*` matches across `/`. **A global `coverage_off` followed by `coverage_on -file "<dut>"` records no code coverage at all** (only the covergroup survives), silently, so list the files to exclude instead. Branch coverage is its own option in 5.055 (`v_branch` records); an untaken `else` shows as a 0-count branch point. |
| T13 | *(M5, 2026-11-24)* per-test reseeding: `process::self().srandom($urandom ^ hash(+NAME))`, then `$urandom` and `randomize()` of an object created afterwards | Verilator | **PASS** | Same `+verilator+seed` and name: identical values (repeatable). Same seed, other name: both the object's `randomize()` result and `$urandom` change, so an object created after the reseed follows it. Used by `fifo_base_test` to decorrelate tests that share a seed (M5 closure, `docs/coverage_closure.md` H01). |
| T14 | *(M6, 2026-11-24)* immediate assertions and covers as the FIFO property files use them: labeled `assert` with an `else $error` action, a keyword macro as the verb, a labeled immediate `cover`, `$past` inside an `if` that skips edges, `--no-assert`, `+verilator+error+limit`, `coverage_off -file` on the cover's own file | Verilator | **PASS** | Assertions and covers are **on by default** in 5.055 (`--assert` not needed); `--no-assert` removes the assertions and leaves cover records at count 0. A failure prints `[t] %Error: f.sv:l: Assertion failed in <scope>.<label>: <message>`, then `$stop`, exit 1. `+verilator+error+limit+N` keeps running and **exits 0** despite the errors, so tools must judge the log, not the exit code. A cover is a `t=user` record whose `o` field is its label; `coverage_off -file` on its file keeps it and its count. `$past` keeps history at every edge even when its statement is skipped. A declaration initializer gives no time-0 edge. |
| T15 | *(M6, 2026-11-24)* the same style in open-source SBY (`read -formal`, `multiclock on`): action blocks, keyword macro (`assume`), `$past` in a block clocked by a design clock, async-reset flops, labeled covers, two clocks | SBY + Yosys + yices | **PASS, with two findings** | **Yosys rejects `else` on an immediate assertion** (`syntax error, unexpected TOK_ELSE`); a macro that expands to the action block only outside `FORMAL` works. bmc clean, both covers reached, the BREAK build fails by label; `$past` keeps history at every edge in Yosys too. **k-induction of a `$past` on a design clock is not inductive by itself:** the induction step fails, because a free clock can stay idle for the whole window (recorded, not judged; M7 needs invariants or gclk-based history). |
| T16 | *(M6, 2026-11-24)* concurrent SVA for the optional simulation-only file: checker bound with `.*` into a module (reaching its internal nets), `[*N]` with a parameter count, `##1` antecedent, `$stable`/`$past`, two-term `disable iff`, bind parameters taken from the target's scope | Verilator | **PASS** | The clean build passes; BREAK fails on `cast_hold` only and BREAK2 on `cast_step` only, each with exit 1 and the same message format as immediate assertions (the `assertion` pattern parses both). A first BREAK that stepped the counter outside every 3-idle window passed, rightly: check that a negative test actually reaches the antecedent. |
| T17 | *(M7, 2026-11-24)* async-reset release in the same formal step as a rising clock edge (`multiclock on`): an RTL-style counter (reset outside the data path) and a checker-style counter (accept term includes the reset) under three release rules: SAME (only with a clock rise, the vplan's A02 wording), LATE (only without one), free | SBY + Yosys + yices | **PASS** | The coincident release with `inc` high is reachable (`cov_edge_inc`, step 1) and the flop **still acts as in reset at that edge**, as in simulation (`ast_release_holds`); the two counters agree under all three rules (bmc 16), LATE also covers and proves. So the vplan's A02 formal wording (DEC-011 D3) needs no change, and a free release did not break this toy (the A02 audit in M7 checks the FIFO). Config finding: a `.sby` line prefix naming several tasks (`a b: ...`) is rejected (`Unused option: a`); use tags on the `[tasks]` lines. |
| T18 | *(M7, 2026-11-24)* harness structure: `(* gclk *)` in two modules of one design, `$rose`/`$changed` of a design clock in a gclk block, `abc pdr` with an assumption under `multiclock on`, a hierarchical reference into an instance | SBY + Yosys + yices / abc | **PASS, with a finding** | Two gclk declarations work (the submodule's gclk assertion fails by its label `t18_top.u.ast_sub_on_edge` under BREAK); k-induction and `abc pdr` prove with the assumption, and `abc pdr` fails without it, so pdr honors assumptions. **A hierarchical reference is not resolved: Yosys declares an implicit, undriven wire named `\u.c` (warnings only) that the solver treats as free**, so an assertion through it fails and an assumption through it would silently constrain nothing. `` `default_nettype none `` makes it an error. Export signals through ports instead; `make formal` fails on "implicitly declared" and "has no driver" warnings. |
| T19 | *(M8, 2026-11-25)* SBY `mode cover` on a design whose assertion fails: a counter, an assertion broken at cnt = 3, one cover before and one after that point | SBY + Yosys + yices | **PASS** | Cover mode **ignores assertions** (neither checked nor assumed; the `cover_assert` option is off by default): verdict PASS, both covers reached (the later one at step 6, past the failure), the assertion is not named in the log. So a `cover` run reports pure reachability, also on a broken design: the M8 bug matrix reads lost covers from it, and the M7 "22/22 covers" was never evidence that assertions hold (that is `prove`'s job). |
| T20 | *(M9, 2026-11-26)* Verilator on the netlist an MCY test script gets: Yosys `prep` at ASIZE=2/DSIZE=4, `mutate -ctrl mutsel 8 1 <mutation>`, `write_verilog -norename` (as MCY's `create_mutated.sh` does), driven by a small testbench | Yosys + Verilator `--timing` | **PASS, with a caveat** | The netlist has an `input [7:0] mutsel` port and **no parameters** (sizes are fixed by `chparam`), so `tb_top` instantiates it without overrides (`ifdef MCY`). Verilator's default warnings, fatal in the UVM flow, **reject it on WIDTHEXPAND** only: Yosys writes the gray conversion as `x[2:1] ^ x`. A `.vlt` with `lint_off -rule WIDTHEXPAND -file "*mutated.v"` fixes it without touching the RTL or testbench warning set (`ip/async_fifo/mcy/verilator_netlist.vlt`). mutsel=0 returns every word intact; mutsel=1 (a `wdata` bit inverted) corrupts all 4. |
| T21 | *(M9, 2026-11-26)* the MCY equivalence harness `ip/async_fifo/mcy/test_eq/` as is: `chformal` scoped to the checker module, `fmcombine` on the two-clock netlist, ABC PDR under `multiclock on` | Yosys + SBY + ABC | **PASS** | `chformal -assert -cover -remove *async_fifo_e2e_props*` matches the derived `$paramod...` module and leaves exactly its 5 `asm_` cells plus the miter's 3 asserts (Yosys 0.71 keeps immediate properties as **`$check` cells** until lowered; `select t:$assert` finds none, chformal acts on `$check` by flavor). `fmcombine` accepts async-reset flops and a `$mem_v2`. PDR proves two identical copies equal with **no depth bound** (13 s) and finds the T20 mutation as an `mcy_eq_rdata` difference. Without the ledger assumptions two identical copies *differ* (a mid-run reset re-assertion exposes uninitialized memory): the miter needs A01/A02/A05 (DEC-014 D1). |

## Findings that affect later modules

- **Build once, run many (M3/M5).** A UVM build takes minutes; a run takes about a second.
  `regress.py` must build once per configuration and fan out seeds.
- **UVM build memory (M3).** Verilator groups the generated C++ into unity files
  (`*_vm_classes_*.cpp`); for the full FIFO testbench each one takes ~45 s and peaks at 1.2 GB.
  Eight compile jobs need ~9 GB on this 8 GB host: the first M3 build swapped and took 96 min
  (4 h of system time). `common/sim/verilator.mk` therefore sets `--build-jobs` from free memory
  (1.5 GB per job, at most `J`) and keeps `--verilate-jobs $(J)`. T1's bare UVM build was small
  enough that `-j 8` happened to fit.
- **Coverage always on (M5, decision D1).** The UVM build adds `--coverage-user
  --coverage-line --coverage-branch --coverage-toggle`, with code coverage limited to the RTL
  by a generated `cov_scope.vlt` (T12). Measured on this host: build 292 s vs 247 s without
  coverage (it varies with free memory). Run time unchanged: 12 runs took 2.54 s vs 2.58 s.
  The database is ~120 KB per run, 172 covergroup records. So `make sim` and `make regress`
  share one binary.
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
- **Assertions in sim (M6, T14).** On by default; the first failure stops the run (exit 1) and
  the log line names the label, which `common/sim/verilator.patterns` catches (`Assertion failed
  in`). Its `assertion` pattern (groups `time`, `label`) lets `sva_neg.py` list every label that
  failed at the first failing time; negative tests raise `+verilator+error+limit` for that, and
  judge the log because the exit code is then 0. `--no-assert` is the switch for M8's
  scoreboard-only column.
- **Cover statements (M6, T14).** `regress.py` reads them from the merged database (`t=user`
  records, label in `o`) into `functional.json` `covers`; `vplan_check --annotate` checks SO-1
  from it. Code coverage excludes `sva/*` and `rtl/async_fifo_props.svh` without losing them.
- **Lint of property code (M6).** `-Wall` reports SYNCASYNCNET wherever a property samples a reset
  level at a clock edge (F01), at the RTL's reset port, so `make lint` and the smoke build pass
  `-Wno-SYNCASYNCNET` with the property define (never for the RTL alone). PROCASSINIT (variables
  with initializers written by processes) is waived in place in the simulation-only bookkeeping.
  A `force` counts as a second writer (MULTIDRIVEN), so the negative-test bench uses the default
  warning set plus `-Wno-MULTIDRIVEN`; a force applied in the time step of a clock edge can race
  that edge's flops, so faults are applied between edges.
- **Lint-clean idiom.** Write `if (obj.randomize() != 1)` — `!obj.randomize()` raises WIDTHTRUNC.
- **Formal style (M6/M7).** Labeled immediate assertions/covers inside `always @(posedge gclk)`
  with `multiclock on` work, and SBY reports failures by label. Concurrent SVA is not available
  in open-source formal (T6), so plan §3 R5's portable style is required, not optional. Action
  blocks must sit behind a macro that is empty under `FORMAL` (T15). Read with
  `read_verilog -sv -formal` (without `-sv`, `parameter int` is a syntax error); recent Yosys
  represents every assert/assume/cover as a `$check` cell with a FLAVOR. Properties with
  `$past` on a design clock need induction help (T15). M7's answer is named history registers
  (`x_q <= x` at the same edge, which is what `$past` keeps), so invariants can constrain them.
- **Formal flow (M7).** `common/scripts/formal_run.py` (behind `make formal*`) holds what the M7
  runs taught:
  - **No variables in a `.sby`.** SBY expands environment variables in `[files]` paths only,
    never in `[script]`, so the runner writes a per-size copy (sizes in the `chparam` line,
    absolute sources, so `RTL_DIR`/`DUT_SRCS` reach formal).
  - **Task tags.** A line prefix naming several tasks (`a b: ...`) is rejected (T17); shared
    lines use tags from the `[tasks]` lines.
  - **Verdicts.** A failed induction step is `UNKNOWN` (rc 4), not `FAIL`; so is a broken proof
    whose bug lies deeper than the base case (planted B05). Expect `nopass` for "this must not
    prove".
  - **bmc with invariants loaded** reports an invariant before the spec property it protects
    (B05: `inv_rempty_safe` instead of `ast_F14_rdata_stable_gclk`), because SBY stops at the
    first failure. `bmc_spec` and the A01/A05 audits read with `FORMAL_NO_INV`. But on a correct
    design bmc **without** invariants is slow: smtbmc assumes the assertions already checked at
    earlier steps, so the invariants prune the search (depth 40 in 48 s at ASIZE=3 with them; more
    than 5 min for step 21 alone at ASIZE=2 without). The sign-off `bmc` keeps them.
  - **`smtbmc --keep-going`** lists every failing assertion but is slow: the A05 audit took
    604 s at ASIZE=3 against 4 s for A01.
  - **Traces.** yosys-smtbmc writes formal step k at `#10k` (plus a half step at `#10k+5`); the
    full cover-to-trace map is in `<workdir>/PASS`, while the log lists only the first few.
    `common/scripts/vcd2svg.py --step 10` gives one row or column per step (`--table` for
    debugging, `--svg` for figures).
  - **Solver time is not monotonic in size.** cover took 14 s at ASIZE=3 but 342 s at ASIZE=2
    (the latter with the regression loading all cores; see `docs/results.md` for clean numbers).
- **MCY reproducibility (M9).** `mcy init` picks a random mutation set unless the config pins it:
  two runs of the same example scored 94.25% and 93.43%. M9's `config.mcy` must set `seed` in
  `[options]` and the report must quote it. ~0.5 s per mutant at `-j4` with Icarus — a UVM
  testbench will need `maxbatchsize`/`mutsel` batching (plan R8).
- **Formal engines for MCY (M9, DEC-014).** Plain BMC of the two-copy miter at ASIZE=2 grows
  exponentially: steps 15/16/17/18 took 6/15/33/92 s and step 19 more than 5 min, so the planned
  depth 64 (two pointer wraps) is out of reach. ABC PDR on the same miter: identical copies proven
  equal in 13 s, unbounded; on a 49-mutant sample 48 differences found in 1.3–10.6 s (mean 3.0 s)
  and 1 equivalence proven in 26 s. For the formal test (mutant + e2e checker, no `inv_`) PDR found
  the failing property in 1.2–17.5 s where `bmc_bugs`-style BMC (`--keep-going`, depth 20) took
  4–170 s; the unmutated netlist is proven in 358 s (M7 `pdr_noinv`: 303 s). Both MCY formal tests
  use PDR, so NOCHANGE is a proof and the formal column has no depth bound.
- **MCY test scripts (M9).** MCY passes a batch as `input.txt` lines `<idx> <mutate command>`;
  `idx` is the mutsel value inside the batch's netlist (not the database id, which is in
  `$MUTATIONS`); the script answers in `output.txt`. A result outside the test's `expect` list
  stops `mcy run`. Test commands inherit the environment of MCY's bundled interpreter
  (`tabbypy3` exports `PYTHONHOME`, `PYTHONEXECUTABLE`, `PYTHONNOUSERSITE`), so a system `python3`
  started from a test dies with "Failed to import encodings module"; config.mcy's `run` lines
  start with `env -u PYTHONHOME -u PYTHONEXECUTABLE -u PYTHONNOUSERSITE`.
  Comment lines (`#`) are skipped in every config.mcy section, `[logic]` included,
  but a **blank line before the first section** is a syntax error (`mcy init`: "Syntax error in
  line N").
- **MCY and memories (M9, T20).** After `prep` the FIFO memory is one `$mem_v2` cell, and
  `mutate -list` also mutates its unused read-port controls. For the asynchronous read port,
  `mutate ... -cell mem -port RD_SRST` makes `write_verilog` abort with ``Assert `port.srst ==
  State::S0' failed`` (kernel/mem.cc:493), for const0 as well as const1. Seen in the M9 pilot: the
  first batch contained one. Such a mutation has no circuit meaning, so config.mcy runs
  `memory_map; opt_clean` before mutating: storage flops, write decoder and read mux become
  ordinary cells. memory_map's cells carry no `src` attribute; the report places them by cell name
  (flow.toml `[report.cells]`).
- **MCY and Verilator (M9).** A batch netlist holds up to 32 mutations at once. A `cnot` mutation
  drives one bit of a vector from another bit of the same vector (pilot: `wbin[1]` from
  `wbin[0]`), which Verilator reports as `UNOPTFLAT` (circular logic at vector granularity; the
  bits are acyclic), fatal under default warnings. It is a performance warning, so
  `mcy/verilator_netlist.vlt` waives it for `*mutated.v` only, beside WIDTHEXPAND (T20). Evidence
  that behavior is unchanged: the MCY gate's logs with every mutation inactive must equal the
  RTL's, line for line.
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
