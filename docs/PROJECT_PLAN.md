# Async FIFO Design-Verification Project — Module Plan for Claude Code

**Version** 1.0 · **Date** 2026-11-19 · **Status** ready to start M0

Project 1 of a DV portfolio: a parameterized Cummings-style asynchronous FIFO, verified with UVM (write and read agents on separate clocks, randomized clock ratio), functional coverage, SVA, SymbiYosys formal (two clocks, k-induction), planted bugs, and MCY mutation coverage — plus an optional, measured experiment with AI-drafted SVA. Tool facts in §3 were checked on the date above; Module 0 re-checks them on your machine.

---

## 0. Quick start

**You (human):**

1. `mkdir async_fifo && cd async_fifo && git init && mkdir docs`
2. Save this file as `docs/PROJECT_PLAN.md`.
3. Start Claude Code in `async_fifo/` and send: **"Read docs/PROJECT_PLAN.md sections 0–5, then start M0."**
4. For each later module, send **"Start M<n>."** When a module's Done-when checks pass, review the diff and approve the commit.

**Claude Code (operating rules — M0 also copies these into `CLAUDE.md`):**

- This file is the source of truth for scope, order and acceptance criteria. If something here is wrong, or a tool behaves differently than described, say so, propose an edit to this file, and log the change in `docs/decisions.md`. Don't silently diverge.
- One module at a time. On "Start M<n>": read §2 and that module; restate its Objective and Done-when; list the steps you will do and the steps I own; wait for my OK.
- Ownership tags: **[YOU]** = I do it (you explain, hint and review, but don't write it). **[CLAUDE]** = you do it. **[PAIR]** = you draft, I decide and edit. **[STRETCH]** = optional within a core module.
- End each module by running its Done-when checks, updating `docs/progress.md`, and proposing a commit message `M<n>: <summary>`. Ask before committing.

---

## 1. Goal, deliverables, sign-off

**Goal.** Build and verify a parameterized async FIFO in the style of Cummings' SNUG 2002 paper (gray-code pointers, two-flop synchronizers, registered full/empty), and package the evidence so a reviewer can check it in five minutes.

**Sign-off** (your brief, made measurable):

| ID | Criterion | Evidence |
|---|---|---|
| SO-1 | 100% functional coverage of the vplan coverage model, merged across all seeds and clock ratios | merged coverage report (M5) |
| SO-2 | Zero failures over N seeds per test, with scoreboard and all assertions enabled | sign-off regression summary (M5 + M6) |
| SO-3 | All formal assertions proven unbounded (k-induction) and all formal covers reached, for ASIZE ∈ {2, 3} | SBY prove/cover logs (M7) |
| Q-1 | (reported) Detection matrix for ~10 planted bugs: simulation vs. SVA vs. formal | `docs/bug_matrix.md` (M8) |
| Q-2 | (reported) MCY mutation score per method, every surviving mutant explained | `docs/mutation_report.md` (M9) |

**Choosing N.** If a bug shows up in a fraction *p* of random runs, N runs all miss it with probability (1 − p)^N.

| N per test | Catches, with ≥ 95% confidence, any bug that appears in at least… |
|---|---|
| 100 | 3% of runs |
| 200 | 1.5% of runs |
| 500 | 0.6% of runs |

Default: **N = 200 per test** (about 1,200 runs for six tests; each run takes seconds, so the whole sign-off fits in minutes when run in parallel). Record your final N and the reason in the vplan.

---

## 2. Working agreement (M0 writes this to `CLAUDE.md`)

Claude Code loads `CLAUDE.md` into every session, and Anthropic's guidance is to keep it under about 200 lines; `@path` imports load the imported file in full, so this plan is deliberately **not** imported — Claude reads the relevant module on demand.

~~~markdown
# CLAUDE.md — async_fifo

## Project
Design-verification portfolio. Current block: `ip/async_fifo` — Cummings-style async FIFO
verified with UVM, functional coverage, SVA, SymbiYosys (multiclock, k-induction),
planted bugs and MCY. The full plan is `docs/PROJECT_PLAN.md`. Don't load it whole every
session: read its §2 and the section for the module we're working on.

## How we work
- One module at a time. On "Start M<n>": read that module, restate Objective and
  Done-when, list your steps vs. mine, wait for my OK.
- Ownership: [YOU] = I do it (you explain, hint, review — don't write it);
  [CLAUDE] = you do it; [PAIR] = you draft, I decide; [STRETCH] = optional.
- LEARNING MODE is ON: don't write or rewrite `ip/*/rtl/*`, first drafts of
  properties or invariants, the scoreboard, the covergroups, or any other [YOU] item.
  "FAST MODE for <task>" lifts this for that task only.
- At module end: run the Done-when checks, append to `docs/progress.md`
  (date · module · what changed · open issues), propose a commit `M<n>: <summary>`,
  and ask before committing.

## Integrity rules (non-negotiable)
- Never weaken a check to get a pass: no deleting or relaxing assertions, scoreboard
  checks or coverage bins, no new formal assumptions, no waivers — unless I approve
  and it is logged in docs/vplan.md (assumption ledger or exclusions) with a reason.
- Suspected RTL bug: stop and report the command, seed, failing label or first
  mismatch, and the waveform/trace path. Don't fix the RTL.
- Don't guess whether a tool supports a construct: write a ≤ 20-line experiment in
  `tools_smoke/`, run it, and record the result in `docs/toolchain.md`.
- Every run prints a one-line reproduction command. Generated output goes to `out/`.
- Don't install system packages or change global config without asking.

## Conventions
- Plan paths are relative to `ip/async_fifo/` unless they start with `common/`,
  `docs/` or `tools_smoke/`.
- Parameters: ASIZE (address bits, >= 2), DSIZE, DEPTH = 1 << ASIZE.
  Simulation default ASIZE=4, DSIZE=8. Formal and MCY: ASIZE=2..3, DSIZE=4.
- Ports: wclk wrst_n winc wdata wfull rclk rrst_n rinc rdata rempty.
  Internals: wbin wptr rbin rptr wq1_rptr wq2_rptr rq1_wptr rq2_wptr.
  Crossing nets (drive the first synchronizer stage): wptr_cdc rptr_cdc.
- Labels: ast_<FID>_*, asm_<AID>_*, cov_<FID>_* (IDs from docs/vplan.md).
- Every flow accepts RTL_DIR= and DUT_SRCS= overrides (used by the bug matrix and MCY).
- Testbench code stays simulator-neutral; workarounds go behind `ifdef <SIM>` with a
  line in docs/toolchain.md.
- Python >= 3.11, standard library only (tomllib for config files).

## Commands
make help | lint | synth | smoke | sim TEST=<t> SEED=<s> SIM=<sim> | regress | cov
| formal TASK=<bmc|prove|cover|pdr> ASIZE=<n> | bugs | mcy | results | clean

## Toolchain
Versions and the feature-by-tool support table live in docs/toolchain.md (written in M0).
~~~

---

## 3. Research findings that change the plan

Your brief leaves several tool and methodology questions open. These findings decide how the modules below are built.

| # | Finding | What it changes |
|---|---|---|
| R1 | The free **Questa–Altera FPGA Starter Edition** refuses `randomize()` and covergroups without a paid "svverification" license (Altera forum threads from 2021 through a 2025 release report the same error). | Not usable for UVM. Don't plan around it. |
| R2 | **Verilator** 5.050 (Jul 2026) added covergroups, coverpoints and bins; 5.052 (Sep 2026) says "Verilator now supports UVM 2020-3.2" with limitations tracked in issue #1538; 5.054 (Nov 2026) added cross-bin features and fixed coverage-merge bugs. Antmicro showed upstream UVM 2017 elaborating unpatched in Oct 2025. | A fully open-source UVM + coverage flow is now plausible, but it is weeks old. Require Verilator ≥ 5.054, smoke-test it in M0, and keep the testbench portable. |
| R3 | **Vivado simulator (XSim)**, free: UVM 1.2 is precompiled (`-L uvm`); functional coverage is supported and `xcrg` merges databases across runs. Its SVA support excludes multiclock properties and concurrent assertions embedded in procedural code. Windows and Linux only; large install. | A solid free fallback. Write single-clock assertions; keep concurrent assertions at module level. |
| R4 | **EDA Playground** gives free access to commercial simulators (VCS, Xcelium and Questa need a validated account; Riviera-PRO doesn't), with short per-run limits listed in its FAQ. | Good for spot checks and portability tests, not for regressions of hundreds of seeds. |
| R5 | **Open-source Yosys/SBY** (OSS CAD Suite): immediate `assert`/`assume`/`cover` inside `always @(*)` or clocked blocks; `$past`, `$stable`, `$rose`, `$fell`, `$changed` only in clocked blocks; `(* anyconst *)`/`(* anyseq *)`; `(* gclk *)` with `multiclock on` for designs with several clocks; `read -formal` defines `FORMAL` and accepts `-D` macros. Concurrent SVA (sequences, implication operators), `bind`, and hierarchical references need the commercial **Tabby CAD Suite** (Verific frontend); YosysHQ offers evaluation licenses. | Portable property style = clocked immediate assertions. Keep the RTL in **one module**, put white-box properties *inside* it through an `ifdef` include, and write end-to-end properties as a port-only checker module. Tabby CAD is an optional upgrade path. |
| R6 | Even with Verific, SBY doesn't support properties that span several clock domains. | Every property is written against exactly one clock (or the formal global clock). |
| R7 | **ZipCPU's proof of Cummings' FIFO**: clocks modeled with `anyconst` step counters; both resets asserted together and released on their own clock; Cummings' sub-modules merged into one file to make induction work; flag "lookahead" implications needed to pass induction; FIFO order proven with two arbitrary consecutive values. | Expect to write induction invariants. Use the two-value ordering technique after your own attempt (your brief says to read the post after writing your properties). |
| R8 | **MCY** tags mutations COVERED / UNCOVERED / NOCHANGE / EQGAP (optionally FMONLY); score = COVERED / (COVERED + UNCOVERED). `select` restricts which logic is mutated; `maxbatchsize` plus a `mutsel` input let one compiled testbench run many mutants. AppNote 400's equivalence test is for a combinational design and uses BMC depth 1. | Build a sequential two-clock equivalence miter; batch mutants so UVM compile time is paid once per batch; run MCY at small parameters. |
| R9 | The cross "behavior × clock-ratio bucket" can't close in a single run, because the ratio is fixed for the duration of a run. | Coverage must be merged across seeds, and ratio buckets must be randomized uniformly. |
| R10 | Gray-code safety is a **source-side** guarantee: the pointer changes at most one bit per *source* clock. The synchronized copy can jump several codes between destination edges when the source clock is faster. | The one-bit property goes on the crossing net, per source clock — not on the synchronized pointer, where it would fail on a correct design. |
| R11 | Neither RTL simulation nor formal on RTL models metastability; Cummings notes that RTL simulation treats even binary pointers ideally (all bits change at once). | "Delete a synchronizer stage" passes simulation, SVA and formal. It is caught structurally and argued with MTBF — M8 builds that story. |
| R12 | Gray-coded CDC buses need `set_max_delay -datapath_only` (source clock period) and/or `set_bus_skew`, and synchronizer flops get `ASYNC_REG` (AMD UG949/UG903). | Ship an example constraints file (M10): verification-complete isn't implementation-complete. |
| R13 | LLM-to-SVA work has public benchmarks: FVEval (NVIDIA, 2024), AssertLLM (2024), AssertLLM2 (2026), measuring syntax validity, functional correctness and bug detection. | M11 uses the same metric families so the results are credible. |
| R14 | **Claude Code**: `claude -p` runs non-interactively; `--output-format json` with `--json-schema` returns schema-conforming output in a `structured_output` field. | M11 can generate properties from a script, reproducibly. |

---

## 4. Repository layout and conventions

The layout separates reusable infrastructure (`common/`) from the block (`ip/async_fifo/`), so later projects drop in as `ip/<name>/`. Paths in §6 are relative to `ip/async_fifo/` unless they start with `common/`, `docs/` or `tools_smoke/`. (If you'd rather have one repo per project, keep the same tree and vendor `common/`.)

```text
async_fifo/
├── CLAUDE.md
├── README.md
├── Makefile                       # delegates to ip/*/Makefile
├── common/                        # DUT-agnostic, reused by future blocks
│   ├── scripts/                   # regress.py, vplan_check.py, bug_matrix.py,
│   │                              # make_results.py, mtbf.py, cdc_check.py
│   ├── sim/                       # verilator.mk, xsim.mk, questa.mk … + <sim>.patterns
│   └── uvm/                       # clk_rst_if.sv, base classes, report helpers
├── docs/                          # PROJECT_PLAN.md, progress.md, decisions.md, toolchain.md
├── ip/
│   └── async_fifo/
│       ├── Makefile
│       ├── rtl/                   # async_fifo.sv, async_fifo_props.svh
│       ├── docs/                  # spec, vplan, vplan_status, coverage_closure, formal_notes,
│       │                          # bug_matrix, mutation_report, results, interview_notes
│       ├── tb/smoke/              # tb_smoke.sv (directed, no UVM)
│       ├── tb/uvm/                # pkg/ if/ agents/wr/ agents/rd/ env/ seq/ tests/ top/
│       ├── sva/                   # async_fifo_e2e_props.sv (+ optional concurrent SVA)
│       ├── formal/                # async_fifo.sby
│       ├── regress/               # tests.toml
│       ├── bugs/                  # Bxx_<name>.patch
│       ├── mcy/                   # config.mcy, test_eq/, test_sim/, test_fm/
│       ├── constraints/           # async_fifo.xdc (example)
│       └── ai_sva/                # optional, M11
├── tools_smoke/                   # M0 capability experiments
├── out/                           # all generated output (gitignored)
└── .github/workflows/ci.yml
```

**Conventions**

- **Names.** Parameters `ASIZE`, `DSIZE`, `DEPTH = 1 << ASIZE`. Ports use Cummings' names: `wclk, wrst_n, winc, wdata, wfull, rclk, rrst_n, rinc, rdata, rempty`. Internals: `wbin`, `wptr` (gray), `rbin`, `rptr` (gray), `wq1_rptr`, `wq2_rptr` (read pointer synchronized into wclk), `rq1_wptr`, `rq2_wptr`; crossing nets `wptr_cdc`, `rptr_cdc`.
- **Traceability IDs.** Features `F01…`, assumptions `A01…`, bugs `B01…`, decisions `DEC-001…`. Property labels embed them: `ast_F06_wfull_not_optimistic`, `asm_A02_wrst_release`, `cov_F12_full_reached`.
- **Covergroups.** `cg_fill`, `cg_flags`, `cg_attempts`, `cg_cfg`.
- **Make targets** (each prints the underlying command): `help`, `lint`, `synth`, `smoke`, `sim`, `regress`, `cov`, `formal`, `bugs`, `mcy`, `results`, `clean`. All accept `RTL_DIR=` and `DUT_SRCS=` so M8/M9 can point every flow at patched or mutated RTL.
- **Output.** Everything generated goes to `out/` (gitignored). Commit summaries, never databases.
- **Scripts.** Python ≥ 3.11, standard library only (`tomllib` reads `tests.toml`), so CI needs no `pip install`.

---

## 5. Schedule

Your brief says "~2 weekends". With Claude Code doing the scaffolding, M0–M7 fit two weekends; M8–M10 usually need a third weekend or several evenings.

| Slot | Modules | Hours |
|---|---|---|
| Weekend 1, Saturday | M0 toolchain, M1 spec + RTL | 5–9 |
| Weekend 1, Sunday | M2 vplan, M3 UVM env | 6–9 |
| Evenings | finish M3, M4 stimulus | 3–4 |
| Weekend 2, Saturday | M5 coverage + regression, M6 SVA | 7–10 |
| Weekend 2, Sunday | M7 formal | 5–8 |
| Weekend 3 or evenings | M8 bugs, M9 MCY, M10 packaging | 9–14 |
| Optional | M11 AI-SVA, [STRETCH] items | 4–10 |

If you fall behind, cut in this order: M8 [STRETCH] items → MCY's `test_fm` → CI nightly jobs. Don't cut M2 (vplan) or M7 (formal); they carry the project.

---

## 6. Modules

Each module lists: **Objective** (what exists at the end) · **Why it matters** (how it moves the project toward sign-off, plus the interview angle) · **Steps** · **Deliverables** · **Done when** · **Pitfalls** · **Extension hooks** (how later work builds on it).

---

### M0 — Toolchain, repo skeleton, capability smoke tests

*Core · ~2–4 h*

**Objective.** A version-pinned toolchain; a repo skeleton where `make help` works; two recorded decisions — the simulator (DEC-001) and the formal frontend and SVA style (DEC-002) — each backed by a small passing experiment.

**Why it matters.** Every later module depends on features that free tools support unevenly: UVM, covergroups with crosses and cross-run merging, SVA, two-clock formal, mutation tooling. These decisions also fix how you write SVA (M6) and how you structure the RTL (M1). An hour of smoke tests here prevents a rewrite on day three. *Interview angle:* qualifying a toolchain before building on it is a senior habit.

**Steps**

1. [CLAUDE] Inventory: OS and architecture; versions of `yosys`, `sby`, `mcy`, `eqy`, `verilator`, `iverilog`, `gtkwave` or `surfer`, `python3`, and any of `vsim`, `xrun`, `vcs`, `xvlog`. Write them to `docs/toolchain.md`.
2. [YOU] Install the latest **OSS CAD Suite** release (from `YosysHQ/oss-cad-suite-build`; extract; source its `environment` script or add `oss-cad-suite/bin` to PATH). Claude supplies the exact commands for your OS. It bundles Yosys, SBY, MCY, EQY, the SMT solvers, Verilator, Icarus, GTKWave, cocotb and the yosys-slang plugin.
   - If the bundled Verilator is older than 5.054 and you want the open-source UVM path, [CLAUDE] scripts a source build of the latest Verilator release tag.
3. [PAIR] **DEC-001 simulator**, using this matrix and the T1–T3 results:

   | Option | Cost | UVM | Covergroups + cross-run merge | SVA | Usable in public CI | Notes |
   |---|---|---|---|---|---|---|
   | Questa / Xcelium / VCS via university license | license | full | full | full | no | most robust |
   | Verilator ≥ 5.054 | free | UVM 2020 (new, known limitations) | yes (new) | improving fast | yes | bleeding edge; slow UVM compile |
   | Vivado XSim | free | UVM 1.2 | yes (`xcrg` merge) | single-clock; none in procedural code | impractical | Windows/Linux, large install |
   | EDA Playground | free | yes (commercial sims) | yes | yes | no | short per-run limits |
   | Questa–Altera Starter | free | no | no | — | — | randomize/covergroups blocked |

   Default: a commercial simulator if you have university access; otherwise Verilator if T1–T3 pass; otherwise XSim. Either way, keep the testbench portable.
4. [CLAUDE] Capability experiments in `tools_smoke/` (each ≤ 40 lines with a `run.sh`):
   - **T1 UVM:** randomize an item with a constraint and print it; two seeds give different values; the UVM report summary parses.
   - **T2 Coverage merge:** a covergroup with two coverpoints, a cross and `ignore_bins`; seed A hits half the bins, seed B the other half; merge both databases; the merged report shows the union. SO-1 depends on this working.
   - **T3 SVA in simulation:** (a) an immediate `assert` in `always @(posedge clk)` using `$past`; (b) a concurrent `assert property` with `disable iff` and an implication; (c) a `bind`; plus a deliberately failing variant, confirming that the failure is reported and detectable as a test failure.
   - **T4 Two-clock formal:** a toy design (a toggle crossing a 2-FF synchronizer) with `multiclock on`, a `(* gclk *)` register, one *labeled* assert and one cover; `sby -f` tasks `prove` and `cover` pass; the cover trace opens in GTKWave.
   - **T5 MCY:** run YosysHQ's `bitcnt` example from AppNote 400 end to end (`mcy init`, `mcy run -j4`, `mcy status`).

   Record a feature × tool table (PASS/FAIL + notes) in `docs/toolchain.md`.
5. [PAIR] **DEC-002 formal frontend and SVA style.** Default with OSS CAD Suite: clocked immediate assertions; white-box properties included inside the RTL module under `ifdef`; a port-only end-to-end checker module (details in M6). Upgrade path: a Tabby CAD Suite evaluation license for concurrent SVA and `bind` in formal.
6. [CLAUDE] Skeleton per §4: directories; `.gitignore` (`out/`, `obj_dir/`, `xsim.dir/`, `*.vcd`, `*.fst`, SBY task directories, MCY `database/` and `tasks/`); root and IP Makefiles with stub targets and `make help`; `docs/progress.md`; `docs/decisions.md` (one entry per decision: date, options, choice, reason, consequences).
7. [CLAUDE] Write `CLAUDE.md` from §2, then fill its Toolchain line.

**Deliverables.** `CLAUDE.md`, Makefiles, `docs/toolchain.md`, `docs/decisions.md` (DEC-001, DEC-002), `tools_smoke/T1…T5`.

**Done when.** `make help` lists every target; T1–T5 results are recorded (a FAIL is acceptable only if the decisions avoid that feature); both decisions are recorded with reasons; tool versions are pinned.

**Pitfalls**

- Verilator + UVM compile times are long: design the flow as "build once per configuration, run many seeds".
- XSim ships UVM 1.2 and Verilator targets IEEE 1800.2-2020. Write to their common subset: use `get_starting_phase()` rather than the deprecated `starting_phase` field, and raise objections in tests or virtual sequences.
- XSim lacks multiclock SVA and concurrent assertions inside procedural blocks — another reason for the portable style.
- On Windows, run the open-source flow under WSL2 (Ubuntu); on macOS, OSS CAD Suite and Verilator work but Vivado doesn't exist.

**Extension hooks.** `tools_smoke/` becomes the regression you rerun whenever you upgrade a tool. `common/sim/<sim>.mk` is how you add a simulator later (for example, Verilator in CI and a commercial simulator locally).

---

### M1 — Specification and RTL

*Core · ~3–5 h*

**Objective.** `docs/spec.md` (the behavioral contract every checker is written against) and `rtl/async_fifo.sv`, written by you: lint-clean, synthesizable by Yosys, passing a directed smoke test, tagged `rtl-v1`.

**Why it matters.** Every checker you build — scoreboard, assertions, formal — encodes the spec, so ambiguities here (show-ahead `rdata`, flag latency, reset rules) turn into false passes or false failures later. Writing the RTL yourself is what lets you plant meaningful bugs in M8 and explain every mutant in M9. *Interview angle:* you can draw this FIFO from memory and explain why gray code plus a two-flop synchronizer is safe.

**Steps**

1. [YOU] Read Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design" (SNUG 2002, style #1): gray counters, full/empty generation, synchronizers, reset. Optional: his SNUG 2008 CDC paper, multi-bit CDC section.
2. [CLAUDE] Draft `docs/spec.md` for you to edit:
   - **Parameters.** `DSIZE ≥ 1`; `ASIZE ≥ 2` (keeps the standard full-flag expression legal — it slices `[ASIZE-2:0]` below the two inverted MSBs; a depth-2 FIFO would need a special case); `DEPTH = 2^ASIZE` (powers of two only).
   - **Ports.** Table using the §4 names.
   - **Write.** Accepted iff `winc && !wfull` at `posedge wclk`; a write while full is ignored and changes nothing.
   - **Read.** Accepted iff `rinc && !rempty` at `posedge rclk`; a read while empty is ignored. `rdata` is *show-ahead*: whenever `!rempty` it presents the oldest entry; an accepted read pops it, and the next entry appears after that `rclk` edge. `rdata` is don't-care while empty.
   - **Flags.** Registered and conservative: `wfull` may stay high after space frees and `rempty` may stay high after data arrives (pessimistic), but `!wfull` always guarantees space and `!rempty` always guarantees data (never optimistic). Pessimism is bounded: once the opposite side has been idle for K destination-clock edges the flag is exact. Fill in K after writing the RTL.
   - **Reset.** Active-low, asynchronous assertion; each reset is released synchronously to its own clock (reset synchronizers live outside the FIFO). A01: both resets are asserted together at power-up. Independent mid-operation resets are out of scope (roadmap E4).
   - **CDC structure.** Only gray-coded pointers cross, each through two flops clocked and reset by the destination domain, with no combinational logic between the source pointer register and the first synchronizer flop.
   - **Implementation notes.** `ASYNC_REG` on synchronizer flops; gray pointer crossings constrained with `set_max_delay -datapath_only` and/or `set_bus_skew` (M10).
   - **Out of scope.** Almost-full/empty, non-power-of-two depth, registered read port, independent resets.
3. [YOU] Write `rtl/async_fifo.sv`. Later modules depend on these requirements:
   - **One module, no sub-modules.** Open-source Yosys can't reference signals inside sub-modules, and white-box properties and induction invariants need the pointers and synchronizer flops (ZipCPU merged Cummings' sub-modules into one file for the same reason).
   - Synthesizable SystemVerilog that both `yosys read_verilog -sv` and `verilator --lint-only` accept: `logic`, `always_ff`/`always_comb`, `localparam`; no interfaces, structs or packages on the ports.
   - §4 internal names; synchronizer registers marked `(* ASYNC_REG = "TRUE" *)`.
   - **Explicit crossing nets.** Drive each first synchronizer stage only from a named wire (`wptr_cdc`, `rptr_cdc`). M6 attaches the one-bit-change property there, which is what lets it catch a "binary pointer sent across" bug.
   - An elaboration-time check that `ASIZE >= 2`.
   - Exactly one verification hook, just before `endmodule`:

     ```systemverilog
     `ifdef ASYNC_FIFO_PROPS
       `include "async_fifo_props.svh"   // white-box properties (M6/M7); absent from normal builds
     `endif
     ```

   - About 150 lines including comments. Learning mode: Claude doesn't write this file.
4. [CLAUDE] Static checks — report findings, don't fix the RTL: `verilator --lint-only -Wall`; `verible-verilog-lint` if installed; `yosys -p "read_verilog -sv rtl/async_fifo.sv; prep -top async_fifo; check -assert"`; then `synth -top async_fifo; stat`. Sanity check: with Cummings' binary-plus-gray pointer registers, expect `8·(ASIZE+1) + 2` flip-flops outside the memory.
5. [CLAUDE] Directed smoke testbench `tb/smoke/tb_smoke.sv` (plain SystemVerilog, no UVM): two clocks at a fixed ratio; reset; write until `wfull` and check that exactly DEPTH writes were accepted; read until `rempty` and check order and count. `make smoke RATIO=1:3` and `RATIO=3:1`. This stays your ten-second "did I break it?" check.
6. [CLAUDE] Review the RTL against the spec and the paper. Deliver review comments (line, issue, why), not patches.
7. [YOU] Fix, rerun steps 4–5, then `git tag rtl-v1`. M8 patches and M9 mutations are relative to this tag.

**Deliverables.** `docs/spec.md`, `rtl/async_fifo.sv`, `tb/smoke/tb_smoke.sv`, Make targets `lint`, `synth`, `smoke`.

**Done when.** Lint is clean (each waiver justified in a comment); Yosys `check -assert` passes; smoke passes at 1:3 and 3:1; `rtl-v1` is tagged.

**Pitfalls**

- Gray conversion is `(bin >> 1) ^ bin`.
- Full: the next gray write pointer equals the synchronized read pointer with its **two** MSBs inverted. Empty: the next gray read pointer equals the synchronized write pointer.
- Gate the memory write enable with `!wfull`, and each pointer increment with its own flag.
- Synchronizer flops use the destination clock **and** the destination reset.
- Keep the memory read combinational (show-ahead) unless you change the spec; the read monitor in M3 depends on it.

**Extension hooks.** Parameter-clean RTL enables sweeps (simulation at ASIZE=4, formal and MCY at 2–3). The single `ifdef` hook keeps verification code out of synthesis. The spec's out-of-scope list is your backlog (§7).

---

### M2 — Verification plan (`docs/vplan.md`)

*Core · ~2–3 h*

**Objective.** A verification plan that maps every feature to stimulus, checker, coverage item and formal property, with an assumption ledger and sign-off criteria, in a format a script can check for traceability.

**Why it matters.** The vplan turns "I wrote a testbench" into "I can show when I'm done". It orders M3–M9, defines the coverage you must close, and is the first thing a DV interviewer asks about. Stable IDs let scripts prove nothing was dropped.

**Steps**

1. [CLAUDE] Create the template: Scope · Features · Coverage model · Property list · Assumption ledger · Planted-bug plan (→ M8) · Sign-off · Out of scope · Revision history.
2. [PAIR] Feature table with columns `ID | Requirement | Stimulus | Checker | Coverage | Formal | Notes`. Start from this list and edit it:
   - **F01** Reset state: `rempty = 1`, `wfull = 0`, pointers zero in both domains.
   - **F02** Integrity: every accepted write is read exactly once, unmodified.
   - **F03** Order: first in, first out.
   - **F04** No overflow: a write while full is ignored and no stored entry is overwritten.
   - **F05** No underflow: a read while empty is ignored and the read pointer doesn't move.
   - **F06** `wfull` never optimistic: `!wfull` ⇒ true fill < DEPTH.
   - **F07** `rempty` never optimistic: `!rempty` ⇒ true fill > 0.
   - **F08** Bounded pessimism: once the opposite side has been idle for K destination-clock edges, the flag is exact (`wfull ⇔ fill = DEPTH`, `rempty ⇔ fill = 0`). Derive K from your RTL.
   - **F09** CDC safety of the crossing nets: (a) each changes at most one bit per **source** clock edge; (b) each changes only at source clock edges (registered, glitch-free source; formal only).
   - **F10** Gray/binary pointer consistency in each domain.
   - **F11** Synchronizer structure: two stages, destination clock and reset, no logic before stage 1. Structural; checked in M8 [STRETCH].
   - **F12** Full capacity: exactly DEPTH entries can be stored.
   - **F13** Wrap-around: correct across at least two pointer wraps.
   - **F14** Show-ahead stability: while `!rempty` and no read is accepted, `rdata` holds its value.
   - **F15** Clock robustness: F02–F10 hold for wclk:rclk from 1:4 to 4:1 at any phase (simulation) and for any interleaving of the two clocks (formal).
   - **F16** Boundary concurrency: simultaneous accepted read and write at fill 0/1 and at DEPTH−1/DEPTH.
3. [CLAUDE] Coverage model, precise enough to implement in M5:
   - **True fill** = accepted writes − accepted reads, from the scoreboard model (never from the DUT's flags). Bins: `zero`, `one`, `mid = [2:DEPTH-2]`, `almost_full = DEPTH-1`, `full = DEPTH`. Transitions: `DEPTH-1 ⇒ DEPTH ⇒ DEPTH-1` and `1 ⇒ 0 ⇒ 1`.
   - **Flag transitions:** `wfull` rise and fall; `rempty` rise and fall.
   - **Blocked attempts:** write while `wfull`; read while `rempty` (outside reset).
   - **Ratio bucket** on ρ = f_wclk / f_rclk: `B0 [0.25, 0.5)`, `B1 [0.5, 0.95)`, `B2 [0.95, 1.05]`, `B3 (1.05, 2.0]`, `B4 (2.0, 4.0]`. For B2, also a phase class: edges aligned within 5% of a period, or not.
   - **Crosses:** fill × bucket, flag transitions × bucket, blocked attempts × bucket.
4. [PAIR] Property list: for each F-ID, the intended properties, each marked **e2e** (ports only) or **white-box** (internal signals), and simulation, formal, or both. You write them in M6–M7.
5. [PAIR] Assumption ledger (ID, statement, why it's realistic, where it's enforced):
   - **A01** Both resets asserted together at time 0.
   - **A02** Each reset released synchronously to its own clock.
   - **A03** (formal, optional) Inputs change only just after their own clock's rising edge.
   - **A04** (formal) Clocks are unconstrained: any interleaving of edges, including simultaneous ones.

   Rule: in simulation, every formal assumption is checked as an assertion on the testbench's own behavior.
6. [CLAUDE] Sign-off section: SO-1…SO-3 and Q-1, Q-2 from §1, the (1 − p)^N table, and your chosen N.
7. [CLAUDE] `common/scripts/vplan_check.py`: parses the feature table; checks that each F-ID has a stimulus, a checker, and coverage or formal (or an explicit `n/a: <reason>`); later greps the code for every referenced label, test and covergroup and flags missing or orphaned ones; in M5, writes `docs/vplan_status.md` with coverage and proof status per row.

**Deliverables.** `docs/vplan.md`, `common/scripts/vplan_check.py`.

**Done when.** `vplan_check.py --structure` passes; every F-ID has a checker plus coverage or formal; the ledger is complete; N is chosen.

**Pitfalls**

- Sample fill coverage from the model, not from `wfull`/`rempty` — otherwise a buggy flag can fake coverage.
- Don't count blocked attempts during reset.
- Never reuse or renumber IDs.

**Extension hooks.** The format and the checker script are DUT-agnostic; reuse them for every future block. M11 feeds the property list to the LLM. Back-annotation mirrors what commercial vplan tools do.

---

### M3 — UVM environment: clocks, agents, scoreboard

*Core · ~4–6 h*

**Objective.** A running UVM environment: write and read agents on their own clocks, a randomized clock configuration, a queue-based scoreboard, and a smoke test that passes — and that demonstrably fails when it should.

**Why it matters.** This is the backbone for SO-1 and SO-2, the bug matrix, and MCY's simulation test. Getting clocking, show-ahead sampling and accepted-versus-attempted semantics right here prevents false passes everywhere downstream. *Interview angle:* a two-clock UVM environment with a clock-ratio config and a multi-domain scoreboard.

**Steps**

1. [CLAUDE] `tb/uvm/pkg/fifo_params_pkg.sv`: `ASIZE`, `DSIZE`, `DEPTH` from compile-time defines, so M7 and M9 can build small configurations.
2. [CLAUDE] Interfaces `fifo_wr_if` (`wclk, wrst_n, winc, wdata, wfull`) and `fifo_rd_if` (`rclk, rrst_n, rinc, rdata, rempty`), each with driver and monitor clocking blocks. If your simulator mishandles clocking-block drives, drive on the inactive edge instead and log the workaround in `docs/toolchain.md`.
3. [CLAUDE] `common/uvm/clk_rst_if.sv`: a reusable clock/reset generator interface with `start_clock(period_ps, phase_ps)`, `assert_reset()` and `release_reset_sync()` (releases on its own clock's edge). One instance per domain in `tb_top`; tests control them through virtual interfaces. 1 ps time resolution.
4. [PAIR] `fifo_env_cfg` (you own the constraints):
   - Randomize the ratio bucket first (uniform over B0–B4), then periods inside it: `wclk_period_ps ∈ [2000, 20000]`, `rclk_period_ps` chosen to satisfy the bucket; about 20% of runs use exact integer ratios (1:4, 1:2, 1:1, 2:1, 4:1), the rest arbitrary ones; `rclk_phase_ps ∈ [0, rclk_period_ps)`.
   - Traffic knobs: `wr_rate_pct`, `rd_rate_pct` (0–100), `respect_full`, `respect_empty`, `blocked_attempt_pct`.
   - A `ratio_bucket()` helper for coverage, and plusarg overrides (`+WCLK_PS=`, `+RCLK_PS=`, `+RPHASE_PS=`, `+BUCKET=`) for reproduction and directed closure.
5. [CLAUDE] Agents `wr_agent` and `rd_agent` (item, sequencer, driver, monitor):
   - The driver follows the cfg policy; with `respect_full = 0` it sometimes asserts `winc` while `wfull` (blocked attempts are part of the stimulus).
   - The write monitor publishes an accepted write when `winc && !wfull` at the edge, and a separate blocked-attempt event otherwise. The read monitor publishes an accepted read with `rdata` sampled **at the same edge** (show-ahead). Both publish flag samples for coverage.
6. [YOU] `fifo_scoreboard` (two `uvm_analysis_imp_decl` ports, a SystemVerilog queue as the reference model):
   - On an accepted write: error if the model already holds DEPTH entries (an overflow got through: F04/F06); push.
   - On an accepted read: error if the model is empty (F05/F07); pop and compare; flag X/Z on `rdata`.
   - **Same-timestamp rule.** Both domains can produce events at the same simulation time. Check overflow and underflow against the fill at the *start* of that time step, then apply the events — otherwise process order hides a same-instant overflow or underflow.
   - `report_phase`: writes, reads, mismatches, max/min fill, leftover entries. Expose `fill()` for coverage.
   - Self-test hook: `+SB_INJECT_ERROR` flips one expected bit.
7. [CLAUDE] `fifo_env` (agents, scoreboard, coverage stub, virtual sequencer); `fifo_base_test` (randomize cfg → config_db → start clocks → reset → print cfg on one line); `smoke_test` (write DEPTH+2 with two blocked attempts, then read to empty with blocked reads).
8. [CLAUDE] `common/sim/<sim>.mk` and `make sim TEST= SEED= SIM=`: build once per configuration into `out/build/…`; run into `out/run/<test>_<seed>/`; decide pass/fail from the log (UVM_ERROR/UVM_FATAL counts, assertion-failure patterns, a missing end-of-test marker); print the exact rerun command.

**Deliverables.** `tb/uvm/**`, `common/uvm/clk_rst_if.sv`, `common/sim/*.mk`.

**Done when.** `smoke_test` passes on three seeds with three different printed clock configs; with `+SB_INJECT_ERROR` it fails with a non-zero exit; rerunning a printed command reproduces the same log.

**Pitfalls**

- Generate clocks in modules or interfaces, not classes.
- Never drive DUT inputs with blocking assignments at the sampling edge.
- Release each reset on its own clock (A02).
- Allow a drain time of several slow-clock periods so the last reads get checked.
- Use simulator macros (`ifdef VERILATOR`, …) only for logged workarounds.

**Extension hooks.** The agents and `clk_rst_if` serve any FIFO-like or multi-clock block; parameterized widths let an AXI-Stream variant reuse them; the sim layer adds simulators without testbench changes.

---

### M4 — Stimulus: virtual sequences and tests

*Core · ~3–4 h*

**Objective.** Virtual sequences for fill-to-full, drain-to-empty, thrash at full, thrash at empty and random rates (plus a random mix), and a test list that runs them under randomized clock configurations.

**Why it matters.** Async FIFO bugs live at the full and empty boundaries, with simultaneous traffic, at particular clock ratios. Virtual sequences coordinate both agents to put the FIFO exactly there; M5's coverage then measures whether they did.

**Steps**

1. [CLAUDE] Agent sequences: `wr_burst_seq(n, rate)`, `rd_burst_seq(n, rate)`, `wr_until_blocked_seq(k)` (stops after k blocked attempts), `rd_until_blocked_seq(k)`.
2. [PAIR] Virtual sequences on `fifo_vsequencer` (you write the two thrash sequences):
   - `vseq_fill_to_full`: write at 100%, no reads, until k blocked writes.
   - `vseq_drain_to_empty`: from full, read at 100% until k blocked reads.
   - `vseq_thrash_full`: reach DEPTH−1, then write faster than you read so the fill oscillates between DEPTH−1 and DEPTH for T cycles.
   - `vseq_thrash_empty`: the mirror image around 0 and 1.
   - `vseq_random_rates`: 4–8 phases; each phase re-randomizes both rates with `dist` weight on 0%, 100% and the middle.
   - `vseq_random_mix`: a random series of the above.
   - Optional: `vseq_global_reset` asserts both resets mid-traffic (compatible with A01). It requires the scoreboard and monitors to flush on reset; skip it if time is short.
3. [CLAUDE] One test per virtual sequence plus `random_mix_test`; `regress/tests.toml` (test, seed count, plusargs, timeout).
4. [CLAUDE] Sanity: three seeds per test; the scoreboard prints min/max fill and the number of boundary crossings.

**Deliverables.** `tb/uvm/seq/*`, `tb/uvm/tests/*`, `regress/tests.toml`.

**Done when.** All tests pass on three seeds; fill-to-full reaches DEPTH; drain-to-empty reaches 0; each thrash test shows at least 20 boundary crossings; blocked attempts appear in the logs.

**Pitfalls**

- "Faster" means effective rate = rate % × clock frequency. Compute it from the cfg periods, or the thrash sequences silently fail at some ratios.
- Don't treat the DUT's flags as truth inside sequences — they're pessimistic. Use the scoreboard's fill, or tolerate the lag.

**Extension hooks.** The sequence library feeds MCY's test subset (M9), CI smoke (M10) and future variants (almost-full thresholds, reset in traffic, AXI-Stream wrapper).

---

### M5 — Functional coverage, regression, closure

*Core · ~4–6 h*

**Objective.** The vplan coverage model implemented; a regression runner that executes N seeds per test in parallel and merges coverage across runs; coverage closed to 100%; an archived sign-off run (SO-1, SO-2).

**Why it matters.** The cross of behavior × clock-ratio bucket can only close across many runs, because each run has one clock ratio — so merging is mandatory, not a nicety. The closure log is interview gold: it shows you reasoned about holes instead of cranking seeds.

**Steps**

1. [PAIR] `fifo_coverage` — a subscriber to the monitors and to the scoreboard's fill. You write the covergroups; Claude wires the sampling:
   - `cg_fill`: fill bins and transitions, × bucket.
   - `cg_flags`: `wfull`/`rempty` rise and fall, × bucket.
   - `cg_attempts`: blocked writes and reads, × bucket.
   - `cg_cfg`: bucket × phase class.

   Use type-level coverage so merged runs combine bins.
2. [CLAUDE] `common/scripts/regress.py`: reads `tests.toml`; builds once; runs in parallel (`-j`) with recorded seeds and timeouts; classifies pass/fail via `common/sim/<sim>.patterns`; writes `results.json`, a Markdown summary and JUnit XML; prints failing seeds with their rerun commands; merges coverage with the simulator's tool (`verilator_coverage --write`, `xcrg`, `vcover merge`, `urg` or `imc`) and writes the report to `out/cov/`.
3. [CLAUDE] `vplan_check.py --annotate` → `docs/vplan_status.md` (coverage per vplan row).
4. [PAIR] Closure loop: regress (for example, 50 seeds per test) → inspect holes → fix constraints or add directed knobs (for example, `+BUCKET=B4`) → repeat. Log every hole, its root cause and the fix in `docs/coverage_closure.md`.
5. [CLAUDE] Sign-off run: N seeds per test with every checker on. After M6, rerun with assertions enabled — SO-2 counts only that final run. Archive `out/signoff/<date>/summary.md` and commit the summary, not the databases.
6. [CLAUDE] Also collect code coverage (line, branch, toggle) as secondary evidence; sign-off is on functional coverage.

**Deliverables.** `tb/uvm/env/fifo_coverage.sv`, `common/scripts/regress.py`, `docs/coverage_closure.md`, `docs/vplan_status.md`, sign-off summary.

**Done when.** Merged functional coverage is 100% (exclusions only with a vplan justification); zero failures over N seeds per test; a randomly chosen rerun command reproduces its log.

**Pitfalls**

- Verilator's covergroup support is new (5.050+, with cross and merge fixes in 5.054): cross-check merged numbers against T2.
- The `mid` bin is trivial; the valuable bins are the boundary transitions.
- Make sure the randomization is uniform over buckets, not over periods.

**Extension hooks.** `regress.py` is DUT-agnostic (driven by `tests.toml`); its JUnit output feeds CI; merged databases enable trend tracking; coverage holes become inputs to AI-assisted closure (§7, E10).

---

### M6 — SVA in simulation

*Core · ~3–4 h*

**Objective.** A labeled property set — end-to-end (ports only) and white-box (internal signals) — written by you from the vplan, active in every simulation, with cover properties, and with each assertion shown to fire on a violation.

**Why it matters.** Assertions check intent on every cycle and point at the root cause; the same text is reused by formal in M7. The split between e2e and white-box exists because of R5: open-source Yosys has no `bind` and no hierarchical references, so port-only properties can attach anywhere (UVM top, formal harness, MCY's mutated netlist), while white-box ones ride inside the RTL through the M1 hook.

**Property architecture**

- **`sva/async_fifo_e2e_props.sv`** — a module whose inputs are only the DUT's ports. It keeps its own counts of accepted writes and reads (the true fill) and exports them as outputs, so M7 can link them to the internal pointers. Covers F01, F04–F08, F12–F14 and F16. Formal-only parts (arbitrary tracked data, M7) go under `ifdef FORMAL`.
- **`rtl/async_fifo_props.svh`** — included inside the RTL module when `ASYNC_FIFO_PROPS` is defined: F09 on `wptr_cdc`/`rptr_cdc`, F10, internal fill bounds, flag/pointer relations. M7 adds induction invariants here under `ifdef FORMAL`.
- **Portable style.** Clocked immediate assertions, shaped like `always @(posedge <clk>) if (<domain out of reset> && <past valid>) ast_<FID>_<name>: assert (<expr>);`. Open-source SBY and simulators both accept this (M0's T3 and T4 confirm it on your tools). Each property names exactly one clock.
- **Optional `sva/async_fifo_sva_concurrent.sv`** — the same intents as concurrent SVA (implication, `##[1:K]`, `disable iff`), attached with `bind` in simulation only (or in formal too, if you get Tabby CAD). It shows fluency in the syntax interviewers expect.

**Steps**

1. [YOU] Write each property's intent as one English sentence in the vplan, then code the properties yourself — before reading ZipCPU's FIFO post. Claude explains syntax and reviews, but doesn't draft.
2. [CLAUDE] Wiring: instantiate the e2e checker in `tb_top`; build with `+define+ASYNC_FIFO_PROPS`; make every assertion failure fail the test (action blocks call `$error` with the label; `common/sim/<sim>.patterns` catches them).
3. [PAIR] Cover properties, which double as formal non-vacuity checks in M7: full reached; empty after full; at least two pointer wraps; blocked write; blocked read; simultaneous accepted read and write at fill 1 and at DEPTH−1.
4. [CLAUDE] Show that each assertion can fail: a short negative test per assertion (using `force` on an internal signal), or defer to M8 and record which bug trips which assertion.
5. [CLAUDE] Full regression with assertions on — this is the SO-2 run. Add assertion and cover hit counts to the summary if your simulator reports them.

**Deliverables.** `sva/async_fifo_e2e_props.sv`, `rtl/async_fifo_props.svh`, optional concurrent file and bind, updated vplan.

**Done when.** Every vplan property exists with its label; the regression with assertions passes; every cover is hit; every assertion has a demonstrated (or scheduled-in-M8) failure.

**Pitfalls**

- **Safety alone accepts a dead FIFO.** A design whose `wfull` and `rempty` are stuck high never overflows, never underflows, is never optimistic, and loses no data. F08 (bounded pessimism) and the covers are what rule it out — say this in interviews.
- F09 is a source-side property (R10), and it must sit on the crossing net, or a "send the binary pointer" bug slips past.
- Guard `$past` with per-domain past-valid flags and reset; the first edge after reset is special.
- F06/F07 use the true fill (accepted operations), not the DUT's synchronized pointers.
- No multi-clock properties (R3, R6).
- A property that restates the RTL (`wfull == <the same expression>`) passes whenever the RTL agrees with itself. Keep such properties as induction invariants (M7), but count the e2e properties as the real spec checks.

**Extension hooks.** The e2e checker is a reusable FIFO protocol checker. M11 benchmarks LLM properties against this human-written set. The concurrent file is ready for Tabby CAD or a commercial formal tool.

---

### M7 — Formal: SymbiYosys, two clocks, k-induction

*Core · ~5–8 h*

**Objective.** Every assertion proven unbounded by k-induction for ASIZE ∈ {2, 3} (stretch: 4), every cover reached, a minimal and justified assumption set — then a written comparison with ZipCPU's proof.

**Why it matters.** Simulation samples behaviors; formal covers every input sequence and every interleaving of the two clocks, not only ratios from 1:4 to 4:1. Two-clock formal — global-clock modeling and induction invariants — is uncommon, which makes it a strong differentiator. This module delivers SO-3.

**Steps**

1. [YOU] Read SBY's "Formal extensions to Verilog" page (immediate assertions, the `$past` family, `anyconst`/`anyseq`, `(* gclk *)` with `multiclock on`) and ZipCPU's asynchronous-reset and clock-switch posts, which teach the two-clock setup. Hold off on ZipCPU's async FIFO post until step 8.
2. [PAIR] Environment model; record every item in the assumption ledger:
   - `(* gclk *) reg f_gclk;` defines the formal time step, with `multiclock on`.
   - **Clocks.** Start with unconstrained `wclk` and `rclk`: any interleaving of edges, including simultaneous edges and arbitrarily long gaps. ZipCPU instead uses `anyconst` step counters for fixed-rate clocks. Unconstrained clocks are more general and sufficient for safety properties.
   - **Resets.** Both asserted initially (A01); each released on its own clock (A02).
   - **Optional A03.** `winc`/`wdata` change only just after a `wclk` rising edge (likewise for the read side): smaller traces, no loss of generality for a design that registers its inputs.
   - **Data integrity and order.** In the e2e checker under `ifdef FORMAL`, pick one arbitrary write (an `anyconst` index) and assert it reads back intact; then extend to two consecutive items to prove order.
   - **Visibility on open-source Yosys.** Instantiate the e2e checker *inside* the RTL include under `ifdef FORMAL`, so the formal top is `async_fifo` itself, and link the checker's exported counters to the internal pointers with invariants.
3. [CLAUDE] `formal/async_fifo.sby` — a sketch; verify every command against the installed Yosys (`yosys -h read`, `yosys -h chparam`) before relying on it:

   ```ini
   [tasks]
   bmc
   prove
   cover
   pdr

   [options]
   bmc:   mode bmc
   bmc:   depth 60
   prove: mode prove
   prove: depth 30
   cover: mode cover
   cover: depth 120
   pdr:   mode prove
   multiclock on

   [engines]
   bmc:   smtbmc
   prove: smtbmc
   cover: smtbmc
   pdr:   abc pdr

   [script]
   read -formal -DASYNC_FIFO_PROPS async_fifo_e2e_props.sv async_fifo.sv
   chparam -set ASIZE 2 -set DSIZE 4 async_fifo
   prep -top async_fifo

   [files]
   ../sva/async_fifo_e2e_props.sv
   ../rtl/async_fifo.sv
   ../rtl/async_fifo_props.svh
   ```

   Add `make formal TASK=<task> ASIZE=<n>`.
4. [PAIR] BMC first. Debug counterexamples in the VCD (GTKWave or Surfer), fixing properties or assumptions. If the RTL really is wrong, that's a genuine find: log it in `docs/progress.md` — you fix the RTL, not Claude.
5. [YOU] Prove. Expect "induction failed": the solver starts from an unreachable state. Add **asserted** (never assumed) invariants until it closes. Typical ones: gray = bin2gray(bin) in both domains; each synchronizer stage holds a recent value of its source pointer; 0 ≤ wbin − rbin ≤ DEPTH; registered flags agree with the pointer values they were computed from; the checker's counters equal the pointers (mod 2^(ASIZE+1)). Claude helps you read induction traces: which step failed, and which state was unreachable.
6. [CLAUDE] Covers: all reached. Save two traces (fill → full → drain; pointer wrap) as figures for the README.
7. [CLAUDE] Cross-checks:
   - `abc pdr` finds invariants on its own. If PDR proves a property that k-induction can't, your invariants are incomplete.
   - Parameter sweep ASIZE = 2, 3 (4), with runtimes recorded in `docs/results.md`.
   - Assumption audit: drop each assumption in turn and confirm the expected failure — evidence that none of them over-constrains.
   - Sanity: one planted bug (a preview of M8) breaks the proof.
8. [YOU] Now read ZipCPU's async FIFO post. Write `docs/formal_notes.md`: clock model, reset assumptions, invariants, the two-value ordering technique; what you missed, and what you'd keep from your own approach.

**Deliverables.** `formal/async_fifo.sby`, the formal parts of `async_fifo_props.svh` and the e2e checker, `docs/formal_notes.md`, a proof summary in `docs/results.md`.

**Done when.** `prove` passes for ASIZE 2 and 3; `cover` passes; `pdr` passes (or its timeout is documented); the ledger has been reviewed with the assumption audit; the notes are written.

**Pitfalls**

- Depth counts formal time steps, not clock cycles. Strengthen invariants rather than raising depth.
- Over-constrained assumptions make proofs vacuous; covers are your guard.
- Be explicit about which clock each `$past` samples.
- Concurrent SVA (implication, `##`) needs Verific. Translate it into immediate assertions plus small counters or state machines.
- Metastability isn't modeled, so a missing synchronizer stage still proves (M8).

**Extension hooks.** E3 (metastability-aware model); E4 (drop A01 and study the counterexample); liveness with clock fairness; EQY equivalence checks for an optimized variant.

---

### M8 — Planted bugs and the detection matrix

*Core · ~3–5 h (+2–4 h [STRETCH])*

**Objective.** About ten realistic bugs as patches against `rtl-v1`; a script that runs each one through (a) simulation with the scoreboard only, (b) simulation with SVA and (c) formal; and a generated table of what each method caught and why — including "delete a synchronizer stage" and your metastability narrative.

**Why it matters.** A passing testbench proves nothing until it fails on real bugs. The matrix quantifies each method's blind spots; it is the most interview-ready artifact in the project.

**Candidate bugs.** Predict each cell before running — the misses are the lesson. "Stim" means caught only if the stimulus creates that scenario.

| ID | Bug | Sim (scoreboard) | Sim + SVA | Formal | Notes |
|---|---|---|---|---|---|
| B01 | Full test inverts only the MSB | ✓ | ✓ | ✓ | full asserts at the wrong fill |
| B02 | Full test without inversion (empty-style compare) | ✓ | ✓ | ✓ | never really full → overflow |
| B03 | Memory write enable ignores `wfull` | stim | stim | ✓ | needs blocked writes; overwrites the oldest entry |
| B04 | Read pointer advances while empty | stim | stim | ✓ | needs blocked reads |
| B05 | `rempty` computed from the current, not the next, read pointer | stim | stim | ✓ | one cycle optimistic; needs back-to-back reads to empty |
| B06 | Wrong gray conversion: `bin ^ (bin << 1)` | stim | ✓ | ✓ | F09/F10 fire on the first increments |
| B07 | Binary pointer sent across, converted to gray after the synchronizer | ✗ | ✓ | ✓* | *only with white-box F09; e2e-only formal passes |
| B08 | One synchronizer stage deleted | ✗ | ✗ | ✗ | structural check or MTBF analysis only |
| B09 | Synchronizer clocked by the source clock | ✗ | ✗ | ✗* | *caught by a white-box formal assertion that `rq*_wptr` changes only on `rclk` edges, or structurally |
| B10 | Memory addressed with gray bits instead of binary | ✓ | ✓ | ✓ | slots collide at the half-wrap |
| B11 | `wfull` asserts at DEPTH−1 | ✗ | ✓ (F08) | ✓ | "safe but wrong": also a coverage hole (fill = DEPTH never hit) |
| B12 | `rempty` resets to 0 | stim | ✓ (F01) | ✓ | needs a read right at reset release |

**Steps**

1. [YOU] Choose about ten (or all twelve), write your predictions, and implement each as `bugs/Bxx_<name>.patch` (`git diff rtl-v1 -- rtl/async_fifo.sv`), with a header comment explaining the bug.
2. [CLAUDE] `common/scripts/bug_matrix.py`: for each patch, copy the RTL into `out/bugs/<ID>/`, `git apply`, then run with `RTL_DIR` pointing there: (a) a fixed-seed subset of the regression without `ASYNC_FIFO_PROPS` and without the e2e checker (scoreboard only); (b) the same subset with every assertion enabled; (c) SBY `prove` and `cover` at ASIZE = 2. Record the first failing test and seed, the failing label, the formal result and runtimes. Emit `docs/bug_matrix.md` with prediction versus actual.
3. [PAIR] Explain every cell that differs from your prediction. If a bug escapes a method that should have caught it, improve the testbench or properties and rerun the whole matrix, recording the change.
4. [YOU] The B08 narrative, in the metastability section of `docs/interview_notes.md`:
   - RTL simulation is zero-delay and two-valued at the flop, so it can't show metastability; formal analyzes the same RTL semantics, so it can't either. Deleting a stage only changes latency, and the flags stay conservative.
   - What does catch it: structural CDC analysis (synchronizer recognition rules), MTBF analysis, and timing constraints.
   - Quantify it with `common/scripts/mtbf.py`: MTBF = e^(t_res/τ) / (T_w · f_clk · f_data) for one, two and three stages. Take τ and T_w from a vendor characterization, or use clearly labeled textbook values.
   - Note: an exact-latency assertion would fail on B08 — but it detects the latency change, not the CDC risk.
5. [STRETCH][CLAUDE] `common/scripts/cdc_check.py`, a mini structural CDC checker: Yosys `prep; flatten; write_json` → a flop graph with clock and reset nets → rules: **R1** the crossing source is a flop with no logic before the first destination flop; **R2** the first destination flop feeds only a second flop in the same domain (at least two stages); **R3** synchronizer flops use the destination reset; plus an explicit waiver for the memory read path (data qualified by the pointers). The baseline passes; B08 and B09 fail. Add a column.
6. [STRETCH][PAIR] CDC-jitter simulation: wrap each first-stage capture in a macro that is the identity normally and, under `SIM_CDC_JITTER`, lets each bit that changed at the most recent source edge resolve to its old value at random — never mixing in older history. The baseline still passes (gray code tolerates one-code uncertainty); B07 now fails in plain simulation. Add a column.

**Deliverables.** `bugs/*.patch`, `common/scripts/bug_matrix.py`, `docs/bug_matrix.md`, the metastability section, `common/scripts/mtbf.py`, optional `cdc_check.py`.

**Done when.** The matrix is generated by the script from a clean checkout; every bug has results and an explanation; predictions and actuals are compared; the B08 narrative is written.

**Pitfalls**

- Patches target `rtl-v1`; regenerate them if the RTL changes.
- Use the sign-off property set in runs (b) and (c).
- Record whether an e2e or a white-box property made the catch; e2e catches are stronger evidence.
- Fixed seeds keep the matrix reproducible.

**Extension hooks.** `bug_matrix.py` plus the patches form a regression for the verification environment itself — rerun it after any testbench change to confirm detection hasn't regressed. M9 and M11 reuse it. `cdc_check.py` can grow into a CDC lint for future multi-clock blocks.

---

### M9 — Mutation coverage with MCY

*Core · ~4–6 h*

**Objective.** An MCY project that generates 200–500 mutations, discards those that don't change behavior using an equivalence check, runs your simulation and formal flows on the rest, and reports a mutation score per method, with every surviving mutant explained.

**Why it matters.** Ten planted bugs measure what you thought of; MCY measures what you didn't. Because the equivalence check throws out mutations that don't change behavior, the score is meaningful.

**Steps**

1. [YOU] Read the MCY documentation and AppNote 400 (the `bitcnt` walkthrough).
2. [CLAUDE] `mcy/config.mcy`:
   - `[options]`: `size 50` at first, then 300; a fixed `seed`; `tags COVERED UNCOVERED NOCHANGE EQGAP FMONLY`; an optional `select` to focus mutations (for example on the flag logic).
   - `[script]`: read `rtl/async_fifo.sv` **without** `ASYNC_FIFO_PROPS` (so properties are never mutated), `chparam -set ASIZE 2 -set DSIZE 4 async_fifo`, `prep -top async_fifo`.
   - `[test test_eq]`: a sequential two-clock miter (`mcy/test_eq/miter.sv`) instantiating the mutated module twice (`mutsel = 0` versus the mutation) with shared inputs, asserting equal `wfull`/`rempty` always and equal `rdata` whenever not empty; SBY BMC with `multiclock on` and enough depth for at least two pointer wraps at ASIZE = 2. PASS means no observable difference within the bound.
   - `[test test_sim]`: the UVM testbench compiled against `mutated.v`, with a `mutsel` port driven from `+mutsel=`; a fixed seed subset chosen to hit every ratio bucket and boundary scenario (use M5's coverage to pick it); `maxbatchsize` 16–32 so one compile serves many mutants. Only the e2e checker and the scoreboard can run here, because white-box properties don't exist in the mutated netlist.
   - `[test test_fm]`: SBY BMC on the mutated netlist plus the e2e checker.
   - `[logic]`: as in AppNote 400, plus FMONLY when simulation misses a mutant that formal catches. `[report]`: counts and scores for simulation, formal, and combined, each COVERED / (COVERED + UNCOVERED).
3. [CLAUDE] Testbench support: `ifdef MCY` in `tb_top` for the `mutsel` port; `make mcy`.
4. [PAIR] `mcy init && mcy run -j<cores>`. Require EQGAP = 0; otherwise fix the miter (depth, reset alignment, compared outputs).
5. [PAIR] For each UNCOVERED mutant: reproduce it (`mcy task -v test_sim <id>`), classify it — stimulus gap, checker gap, difference beyond the equivalence bound, or truly benign — fix and rerun. Log everything in `docs/mutation_report.md`.

**Deliverables.** `mcy/**`, `docs/mutation_report.md`, scores in `docs/results.md`.

**Done when.** EQGAP = 0; scores reported; every UNCOVERED mutant has a disposition; at least one testbench or property improvement driven by MCY is documented.

**Pitfalls**

- AppNote 400's equivalence check uses BMC depth 1 for a combinational design; yours needs a sequential, two-clock miter.
- Comparing `rdata` while empty creates fake differences.
- Bounded equivalence can label a deep difference NOCHANGE; say so in the report.
- Make sure your simulator compiles Yosys-written Verilog.

**Extension hooks.** The config is a template for future blocks; MCY can run nightly in CI; M11 compares human and LLM property sets by mutation score; the same machinery supports fault-injection studies (useful for safety-oriented roles).

---

### M10 — Results, CI, portfolio packaging

*Core · ~2–3 h*

**Objective.** A repository a reviewer can trust in five minutes: generated results, a README, CI, a constraints example, interview notes, and a release tag.

**Why it matters.** The project only helps you if someone can see and reproduce it quickly. CI proves reproducibility; the notes turn the work into answers.

**Steps**

1. [CLAUDE] `common/scripts/make_results.py` → `docs/results.md`, built only from generated artifacts (sign-off summary, coverage, proofs, bug matrix, MCY scores, tool versions). No hand-typed numbers.
2. [CLAUDE] README: what and why; an architecture diagram (Mermaid: DUT, agents, scoreboard, coverage, e2e checker, white-box properties, formal top, MCY harness); one command per flow; the results table; limitations (metastability not modeled, A01, formal at small parameters); next steps (§7).
3. [CLAUDE] `.github/workflows/ci.yml` using YosysHQ's `setup-oss-cad-suite` GitHub Action: jobs `lint`, `smoke`, `formal` (prove + cover at ASIZE = 2) and `vplan_check`; a UVM smoke job on Verilator if DEC-001 chose it; optionally a nightly regression subset and a small MCY run.
4. [CLAUDE] `constraints/async_fifo.xdc` example: `ASYNC_REG` on the synchronizer flops; `set_max_delay -datapath_only` (source clock period) and `set_bus_skew` on the gray pointer crossings, with comments citing AMD UG949/UG903.
5. [YOU] `docs/interview_notes.md`: a 60-second pitch; the metastability answer (B08, MTBF, constraints); "how did you know you were done?"; the two-clock formal and induction story; the dead-FIFO insight (M6); one MCY surprise; the AI experiment result if you did M11. Rehearse each aloud in under two minutes.
6. [CLAUDE] Tag `v1.0`.

**Done when.** A fresh clone plus the documented setup passes `make lint smoke formal`; CI is green; README numbers match `docs/results.md`.

**Extension hooks.** The results generator and CI jobs serve every future block under `ip/`.

---

### M11 (optional) — AI-drafted SVA, judged by formal

*Optional · ~4–6 h*

**Objective.** A reproducible experiment: an LLM drafts properties from your spec and vplan, the formal tool judges each one, and a report measures how many held, how many were wrong and why, and how they compare with your hand-written set.

**Why it matters.** The roles you're targeting mention AI-assisted test generation, debug and closure. Measured results — not a demo — show judgment about where LLMs help and where formal has to police them.

**Steps**

1. [PAIR] Pre-register `ai_sva/PROTOCOL.md` before any run:
   - Inputs: condition A = spec + vplan features; condition B = A + RTL.
   - Required output: the portable immediate-assertion style, the label scheme, the allowed signal names, and **no assumptions**.
   - Model ID, settings, at least five samples per condition, and versioned prompt files.
2. [CLAUDE] `ai_sva/generate.py`: headless Claude Code (`claude -p … --output-format json --json-schema …`, which returns `structured_output`) or the Anthropic API. Save raw outputs with metadata (model ID, date, prompt hash, cost).
3. [CLAUDE] `ai_sva/evaluate.py`, for each property in turn:
   1. Does it elaborate in Yosys?
   2. On the clean RTL, does it hold (prove), fail with a counterexample (a false property), or stay unknown?
   3. Is it non-vacuous (cover its precondition)?
   4. Is it a tautology (does it still hold when every signal it references is replaced by an unconstrained input)?
   5. Which bugs does it kill (M8 patches, optionally MCY mutants)?

   Reject any generated `assume`.
4. [PAIR] Error taxonomy with examples: wrong clock or domain; needs multi-clock semantics; off-by-one latency; assumes exact (non-pessimistic) flag timing; unsupported syntax; vacuous; tautology; restates the RTL. Optional repair loop: feed the counterexample back up to two times and measure the fix rate.
5. [CLAUDE] `ai_sva/REPORT.md`: per condition — generated, elaborated %, holds %, false %, vacuous %, bugs killed versus the human set, unique kills — plus threats to validity (one design, small N, prompt sensitivity, model version).
6. [YOU] A one-paragraph takeaway for the README and the interview notes.

**Deliverables.** `ai_sva/{PROTOCOL.md, prompts/, generate.py, evaluate.py, runs/, REPORT.md}`.

**Done when.** The scripts reproduce the numbers; the report and takeaway are written.

**Pitfalls**

- Don't show the model your own properties (contamination).
- "Holds" isn't "useful": measure vacuity and bug kills.
- Keep API keys out of git.

**Related work to cite.** FVEval (NVIDIA, 2024); AssertLLM (2024); AssertLLM2 (2026).

---

## 7. Roadmap: building on this project

Already built for reuse: `common/` (scripts, simulator layer, clock/reset interface), the vplan format and checker, `tests.toml`, the bug-matrix framework, the MCY template, and the CI jobs. A new block is a new `ip/<name>/` with the same layout.

| ID | Extension | Builds on | Why it's worth doing |
|---|---|---|---|
| E1 | Turn `cdc_check.py` into a general CDC lint | M8 | completes the metastability story; reusable |
| E2 | CDC-jitter simulation model | M8 | catches multi-bit CDC bugs in plain simulation |
| E3 | Metastability-aware formal: nondeterministic first-stage capture; then per-fanout nondeterminism (divergence) for one cycle | M7 | proves gray-code tolerance; the divergence model is the one that can flag a missing stage |
| E4 | Reset-domain crossing: drop A01, study the counterexample, design and verify a fix (reset handshake or flush) | M7 | ZipCPU's proof assumes the resets assert together — what happens when they don't? A strong RDC talking point |
| E5 | FIFO variants: almost-full/empty thresholds, registered read (block RAM), FWFT wrapper, non-power-of-two depth, width conversion | M1–M9 | exercises reuse of agents, scoreboard and coverage |
| E6 | AXI-Stream async FIFO with reusable AXI-S agents and protocol properties | M3, M6 | industry-standard interface |
| E7 | FPGA bring-up: two PLL clocks, XDC constraints, logic-analyzer capture | M10 | lab credibility |
| E8 | CDC library (pulse, toggle, handshake, MCP synchronizers) in the same flow | all | a natural second portfolio project |
| E9 | cocotb + pyuvm port; multi-simulator CI matrix | M3–M5 | Python-based flows |
| E10 | AI-assisted coverage closure: an LLM proposes constraints or sequences for holes; measure coverage gain per run | M5, M11 | AI in DV, with measurements |
| E11 | Gate-level simulation on the Yosys netlist; EQY RTL-versus-netlist equivalence | M3, M7 | implementation-aware verification |

---

## 8. References

**Design and CDC**

- C. E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design," SNUG San Jose 2002 — http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf
- C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using SystemVerilog," SNUG Boston 2008 — http://www.sunburst-design.com/papers/CummingsSNUG2008Boston_CDC.pdf
- Mentor/Siemens, "Addressing Asynchronous FIFO Verification Challenge" (DVCon) — https://dvcon-proceedings.org/wp-content/uploads/Addressing-Asynchronous-FIFO-Verification-Challenge.pdf
- AMD UG949, constraints on individual CDC paths — https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Constraints-on-Individual-CDC-Paths
- AMD UG903, `set_bus_skew` example for a gray-coded bus — https://docs.amd.com/r/2022.1-English/ug903-vivado-using-constraints/set_bus_skew-Example-Two
- Altera AN 42, "Metastability in Altera Devices" (MTBF background) — https://cdrdv2-public.intel.com/653636/an042.pdf

**Formal**

- ZipCPU, "Crossing clock domains with an Asynchronous FIFO" (read at M7 step 8, after your own proof) — https://zipcpu.com/blog/2018/07/06/afifo.html
- ZipCPU, asynchronous reset properties — https://zipcpu.com/formal/2018/04/12/areset.html
- ZipCPU, clock switch (two-clock formal) — https://zipcpu.com/formal/2018/05/31/clkswitch.html
- SBY, "Formal extensions to Verilog" — https://yosyshq.readthedocs.io/projects/sby/en/latest/verilog.html
- SBY, "SystemVerilog, VHDL, SVA" (Tabby CAD/Verific) — https://yosyshq.readthedocs.io/projects/sby/en/latest/verific.html
- SBY issue #202 (hierarchical access requires Verific) — https://github.com/YosysHQ/sby/issues/202
- OSS CAD Suite — https://github.com/YosysHQ/oss-cad-suite-build

**Mutation coverage**

- MCY documentation — https://mcy.readthedocs.io/
- YosysHQ AppNote 400, "Introduction to Mutation Coverage with Yosys (MCY)" — https://yosyshq.readthedocs.io/projects/ap400/en/latest/

**Simulators**

- Verilator revision history (UVM in 5.052, covergroups in 5.050, cross/merge in 5.054) — https://verilator.org/guide/latest/changes.html
- Antmicro, "Support for upstream UVM 2017 in Verilator" — https://antmicro.com/blog/2025/10/support-for-upstream-uvm-2017-in-verilator
- Antmicro, Verilator UVM example — https://github.com/antmicro/verilator-uvm-example
- AMD UG900, UVM support in the Vivado simulator — https://docs.amd.com/r/en-US/ug900-vivado-logic-simulation/Universal-Verification-Methodology-UVM-Support
- AMD UG900, coverage support and `xcrg` — https://docs.amd.com/r/2025.2-English/ug900-vivado-logic-simulation/Code-Coverage-Support
- AMD UG900, test-bench feature support (SVA table) — https://docs.amd.com/r/2025.1-English/ug900-vivado-logic-simulation/Test-Bench-Feature
- Altera forum: Starter Edition and the verification license — https://community.altera.com/discussions/quartus-prime/questa-intel-fpga-starter-edition-failed-to-checkout-license-for-randomize-funct/254702
- EDA Playground FAQ — https://eda-playground.readthedocs.io/en/latest/faq.html

**AI-assisted verification**

- FVEval (NVIDIA, 2024) — https://arxiv.org/abs/2410.23299
- AssertLLM (2024) — https://arxiv.org/abs/2402.00386
- AssertLLM2 (2026) — https://arxiv.org/abs/2605.27472

**Claude Code**

- CLAUDE.md and memory — https://code.claude.com/docs/en/memory
- Headless mode (`claude -p`, structured output) — https://code.claude.com/docs/en/headless
