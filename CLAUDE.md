# CLAUDE.md — async_fifo

## Project
Design-verification portfolio. Current block: `ip/async_fifo` — Cummings-style async FIFO
verified with UVM, functional coverage, SVA, SymbiYosys (multiclock, k-induction),
planted bugs and MCY. The full plan is `docs/PROJECT_PLAN.md`. Don't load it whole every
session: read its §2 and the section for the module we're working on.

## How we work
- One module at a time. On "Start M<n>": read that module, restate Objective and
  Done-when, list your steps and any decisions that are mine, wait for my OK.
- Ownership: [CLAUDE] = you do it (every step since DEC-006, RTL included);
  [PAIR] = you draft, I decide; [STRETCH] = optional.
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
- Plan paths are relative to `ip/async_fifo/` unless they start with `common/` or
  `tools_smoke/`, or are a repo-level doc: docs/{PROJECT_PLAN,progress,decisions,toolchain}.md.
  Any other `docs/` path (spec, vplan, results, ...) means `ip/async_fifo/docs/` (DEC-005).
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
- Comment every code block, in every file, as it is written: 1–2 short lines above each
  module, class, function/task, always/initial block, property group, Make rule, script step
  or config section, saying what it is for (purpose, not a restatement of the code). A fresh
  session must be able to follow a file from these comments alone. You write them in every
  file you create or edit. Vendored third-party files stay unmodified;
  describe them in a SOURCE.txt beside them instead.

## Commands
make help | lint | synth | cdc | smoke | sva-neg | vplan | sim TEST=<t> SEED=<s> SIM=<sim> | regress | cov
| formal TASK=<bmc|prove|cover|pdr|...> ASIZE=<n> | formal-audit | formal-signoff
| formal-figures | bugs | mcy | results | clean
Repo level: make tools-smoke [T="T1 T3"] (rerun toolchain experiments) | clean-all

## Toolchain
Versions and the feature-by-tool support table live in docs/toolchain.md (written in M0).
Pinned: OSS CAD Suite 2026-11-21 in ~/tools/oss-cad-suite (Verilator 5.055-devel, Yosys/SBY 0.71)
and UVM 2020-3.2 in ~/tools/uvm-2020-3.2 (UVM_HOME=.../src). Make flows put the suite on PATH
via common/tools.mk. Simulator: Verilator (DEC-001). Formal: open-source SBY, labeled clocked
immediate assertions only, no concurrent SVA in formal (DEC-002). After any tool upgrade, run
`make tools-smoke`; it must pass before the upgrade is accepted.
