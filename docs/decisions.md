# Decisions

One entry per decision: date · options · choice · reason · consequences.
IDs are `DEC-NNN`; cite them from code comments and other docs.

---

## DEC-001 — Simulator

- **Date:** 2026-11-21
- **Status:** APPROVED (owner, 2026-11-21)
- **Options:**
  1. Questa / Xcelium / VCS via university license — *not available* (no commercial access).
  2. Verilator ≥ 5.054 (OSS CAD Suite) — free, CI-friendly; UVM 2020 support is weeks old.
  3. Vivado XSim — free; UVM 1.2, `xcrg` coverage merge; no multiclock SVA, no concurrent
     assertions in procedural code; large install.
  4. Questa–Altera FPGA Starter (via Quartus) — free; plan §3 R1 reports `randomize()` and
     covergroups blocked without a paid license. Owner asked for it to be tried **only if needed**.
  5. EDA Playground — spot checks and portability only (short per-run limits).
- **Choice:** Verilator 5.055-devel (rev v5.054-350-gabfb70971, OSS CAD Suite 2026-11-21) with
  UVM 2020-3.2 (`chipsalliance/uvm-verilator` tag `uvm-2020-3.2`). Testbench stays portable.
- **Reason:** T1 (UVM + constrained random + seeds), T2 (covergroups, cross, `ignore_bins`,
  cross-run merge) and T3 (immediate, concurrent, `bind`, failure detection) all PASS — see
  `docs/toolchain.md`. It is free, scriptable and runs in public CI. Since Verilator passed,
  the Questa–Altera fallback was **not needed** and was not installed.
- **Consequences:**
  - UVM builds take ~4 min / ~0.9 GB: the flow builds once per configuration and runs many seeds.
  - Use `get_inst_coverage()` on coverpoints/crosses (`get_coverage()` there is unsupported);
    sample covergroups explicitly.
  - Coverage closure (SO-1) uses `verilator_coverage --write` and parses `.dat` records.
  - The Verilator build is a nightly (devel) snapshot: the OSS CAD Suite date pins it, and
    `make tools-smoke` must pass before any toolchain upgrade is accepted.
  - Keep SystemVerilog to the subset common with UVM 1.2/XSim (plan M0 pitfalls) so a
    commercial simulator or XSim can be added later via `common/sim/<sim>.mk`.

## DEC-002 — Formal frontend and SVA style

- **Date:** 2026-11-21
- **Status:** APPROVED (owner, 2026-11-21)
- **Options:**
  1. Open-source Yosys/SBY: clocked immediate assertions; white-box properties included inside
     the RTL module under `ifdef`; port-only end-to-end checker module (plan §3 R5).
  2. Tabby CAD Suite evaluation license (Verific): concurrent SVA and `bind` in formal.
- **Choice:** Option 1, open-source Yosys/SBY with the portable property style.
- **Reason:** T4 PASS — `multiclock on`, a `(* gclk *)` global clock, labeled immediate
  asserts/covers, k-induction prove, cover traces, and failures reported by label. T6 confirms
  concurrent SVA is rejected by both the native reader and the bundled yosys-slang plugin, so
  without Verific this style is the only one that works in formal. It also runs in public CI
  with no license.
- **Consequences:**
  - Properties used by formal are immediate `assert`/`assume`/`cover` in `always @(posedge <clk>)`
    or `always @(posedge gclk)` blocks, labeled `ast_/asm_/cov_<ID>_*`.
  - White-box properties live in `rtl/async_fifo_props.svh`, included under `ifdef`; the RTL
    stays one module (plan R5/R7). End-to-end properties go in a port-only checker.
  - Concurrent SVA may still be written for simulation only (Verilator supports it, T3), but
    nothing in sign-off SO-3 may depend on it.
  - Upgrade path: Tabby CAD evaluation license; T6 flags if open-source support appears.

## DEC-003 — Plan amendments from M0 findings

- **Date:** 2026-11-21
- **Status:** APPROVED (owner, 2026-11-21) — applied to `docs/PROJECT_PLAN.md` v1.1
- **Options:** amend the plan to match measured tool behavior, or leave it and diverge silently
  (not allowed by the working agreement).
- **Choice:** three edits:
  1. M0 step 2: OSS CAD Suite has no UVM library; fetch UVM 2020-3.2 from
     `chipsalliance/uvm-verilator` tag `uvm-2020-3.2` and pin it in `docs/toolchain.md`.
  2. §3 R5: the bundled yosys-slang plugin also rejects concurrent SVA (T6).
  3. M9 pitfalls: without the fixed `seed` (already required by M9 step 2) the mutation score
     moves between runs (bitcnt 94.25% vs 93.43% in T5); quote the seed with every score.
- **Reason:** each is backed by a recorded experiment in `docs/toolchain.md`.
- **Consequences:** a fresh setup following the plan gets the right UVM source; DEC-002's
  rationale is visible in the plan; M9 scores are reproducible.

## DEC-004 — Every code block carries a short purpose comment

- **Date:** 2026-11-21
- **Status:** APPROVED (owner request, 2026-11-21) — added to `docs/PROJECT_PLAN.md` §2 and §4
  and to `CLAUDE.md` Conventions
- **Options:** comments only where code is non-obvious (common practice), or a short purpose
  comment on every block.
- **Choice:** every block (module, class, function/task, always/initial block, property group,
  Make rule, script step, config section) gets 1–2 lines above it stating its purpose. In
  [YOU] files the owner writes them and Claude flags gaps in review. Vendored files stay
  unmodified and are described in a `SOURCE.txt`.
- **Reason:** the owner is learning this flow and clears context between sessions; a new
  session (and the owner) must be able to follow any file from its comments alone.
- **Consequences:** M0 step 4's "≤ 40 lines" limit for `tools_smoke/` experiments now counts
  code lines only, so required comments don't push experiments over it. Existing M0 files were
  commented retroactively on 2026-11-21 and `make tools-smoke` rerun.

## DEC-005 — Block-level docs live in `ip/async_fifo/docs/`

- **Date:** 2026-11-22
- **Status:** APPROVED (owner, 2026-11-22, M1 kickoff: "your defaults") — applied to `CLAUDE.md`
  Conventions and `docs/PROJECT_PLAN.md` §2 and §4 (plan v1.2)
- **Options:**
  1. Read the path rule literally: `docs/spec.md`, `docs/vplan.md`, … at repo level.
  2. Follow the §4 layout tree: block docs in `ip/async_fifo/docs/`; repo-level `docs/` holds
     only `PROJECT_PLAN.md`, `progress.md`, `decisions.md`, `toolchain.md`.
- **Choice:** option 2.
- **Reason:** the §4 tree already puts spec, vplan, vplan_status, coverage_closure, formal_notes,
  bug_matrix, mutation_report, results and interview_notes under `ip/async_fifo/docs/`; the old
  wording of the path rule contradicted it. Block docs should travel with the block when a
  second `ip/<name>/` is added.
- **Consequences:** a plan path `docs/<x>.md` means `ip/async_fifo/docs/<x>.md` unless `<x>` is
  one of the four repo-level docs. Scripts (`vplan_check.py`, `bug_matrix.py`,
  `make_results.py`) write there. The integrity rule's "docs/vplan.md" is
  `ip/async_fifo/docs/vplan.md`.

## DEC-006 — Every plan step is owned by Claude Code

- **Date:** 2026-11-22
- **Status:** APPROVED (owner request, 2026-11-22, after M1) — applied to `docs/PROJECT_PLAN.md`
  §0, §2 and §6 (plan v1.3) and to `CLAUDE.md` "How we work" and Conventions
- **Options:**
  1. Keep the [YOU] / [CLAUDE] / [PAIR] split, with learning mode on.
  2. Reassign every [YOU] step to Claude Code. Milestones, steps, deliverables and Done-when
     checks stay the same.
- **Choice:** option 2.
- **Reason:** owner's decision.
- **Consequences:**
  - The 14 former [YOU] steps in M0–M11 are now [CLAUDE], and prose that gave a task to the
    owner ("written by you", "you write the covergroups", …) names Claude instead.
    `CLAUDE.md` no longer has the LEARNING MODE / FAST MODE clause, and Claude writes the
    DEC-004 purpose comments in every file.
  - [PAIR] steps are unchanged: Claude drafts, the owner decides. The integrity rules are
    unchanged. In particular, a suspected RTL bug is still reported first, and the RTL is
    fixed only after the owner's OK (plan M7 step 4 now says so).
  - M11 now compares single-shot LLM-drafted properties with the M6/M7 set, which Claude Code
    also writes, iteratively and with formal feedback, rather than with a human-written set.
    `ai_sva/REPORT.md` must list this under threats to validity.

## DEC-007 — Power-up is the only reset

- **Date:** 2026-11-22
- **Status:** APPROVED (owner, 2026-11-22, M2 kickoff) — applied to `ip/async_fifo/docs/spec.md`
  v1.1 (§8, §12), `ip/async_fifo/docs/vplan.md` (ledger A05) and `docs/PROJECT_PLAN.md` M4/M7
  (plan v1.4)
- **Options:**
  1. Power-up only: both resets asserted at time 0, each released on its own clock, never
     asserted again. Formal assumes it (A05) and simulation asserts it.
  2. Also allow a later reset of both sides together, mid-traffic. This is the stronger claim,
     but formal then needs an assumption that both resets fall together plus a checker flush,
     and M3/M4 need a scoreboard and monitor flush and a reset sequence.
- **Choice:** option 1.
- **Reason:** owner's decision. It matches the approved spec §8 (A01 at power-up) and the plan's
  M7 reset model, and keeps the formal environment and the scoreboard simple.
- **Consequences:**
  - New ledger entry A05 (`asm_A05_wrst_stays_released`, `asm_A05_rrst_stays_released`): an
    `assume` in formal and an `assert` on the testbench in simulation.
  - Spec v1.1: any reset after power-up, on one side or both, is out of scope (roadmap E4).
  - Plan M4's optional `vseq_global_reset` is dropped. The scoreboard needs no reset flush.
  - The M7 assumption audit drops A05 and records the expected failure.

## DEC-008 — How the testbench drives `winc`/`rinc` and treats the flags

- **Date:** 2026-11-24
- **Status:** APPROVED (owner, 2026-11-24, M3 kickoff, as part of the `fifo_env_cfg` knobs) — noted
  in `docs/PROJECT_PLAN.md` M3 step 2 (plan v1.5)
- **Options:**
  1. Drivers decide from the flag value in the class: read `wfull` right after the edge and
     drive through a clocking block. Reading a DUT output from a class in the edge's own time
     step is a race (old or new value), so `respect_full = 1` could not promise zero blocked
     writes.
  2. Drive on the falling edge (plan M3 step 2 fallback). Race-free, but inputs then change
     between rising edges, so the simulation check for ledger A03 could never be enabled.
  3. Clocking-block drives at the rising edge, plus a combinational stage in each interface:
     `winc = !wrst_n ? noise : req & ~(wfull & ~ignore_full)` (and the mirror for `rinc`).
- **Choice:** option 3.
- **Reason:** it models real producer/consumer logic (`winc = want & ~wfull`), is race-free
  (toolchain T8), keeps every input change in the time step of its own rising edge (A03-sim
  stays possible), and stops the in-reset noise (vplan S3) exactly at the release edge.
- **Consequences:**
  - `respect_full = 1` means no blocked write is ever presented; `respect_full = 0` lets each
    attempt ignore `wfull` with probability `blocked_attempt_pct` (same for reads). A gated
    attempt is reported as `OP_GATED` and is not a DUT event.
  - Monitors sample through `#1step` clocking blocks: exactly the values the DUT saw (spec §5).
  - `fifo_env_cfg` draws categories with `dist` and numbers procedurally (toolchain T10); the
    approved distributions are unchanged.

## DEC-009 — M4 stimulus parameters and stimulus self-checks

- **Date:** 2026-11-24
- **Status:** APPROVED (owner, 2026-11-24: D1–D3 at the M4 kickoff; the thrash divisor and
  length revised the same day after measurement) — recorded in `ip/async_fifo/docs/vplan.md`
  §2.2 (v0.2)
- **Options and choices:**
  1. **D1, integer-ratio share in the thrash tests.** Keep the approved 20% everywhere, or use
     50% in `thrash_full_test` and `thrash_empty_test` only. *Choice: 50% in the thrash tests.*
     Coincident edges, needed for F16 (accepted write and read in the same time step at fill 1
     and DEPTH−1), exist only at integer ratios with aligned phase. It is implemented as a
     `+KIND`-style override (`fifo_env_cfg.int_pct`), so the solver needs nothing new.
  2. **D2, sequence parameters.** k (blocked attempts before stopping) uniform 2–4; 4–6 rounds
     for fill-to-full and drain-to-empty (the boundary half at 100% with the flag ignored, the
     other half at the cfg's rate and flag policy); `random_rates` 4–8 phases of 2·DEPTH to
     8·DEPTH slower-clock cycles, per-side rate 0% (weight 25), 100% (25), [10, 90]% (50), then
     top-up phases until S5 is met; `random_mix` 4–8 short-form picks, then more until S5.
     Thrash: the slow side's effective rate is 1/d of the fast side's full rate.
     *Approved first as d ∈ [K+1, 2K+2] = [4, 8] and 4·DEPTH operations; revised to
     **d ∈ [2K+1, 2K+4] = [7, 10]** and **max(4·DEPTH, 64) operations**.*
  3. **D3, stimulus self-checks that fail a run.** `F12_CAPACITY`, `DRAIN_COUNT`, `THRASH_WEAK`
     (fewer than 20 crossings in the thrash window), `S5_SHORT` (fewer than 4·DEPTH accepted
     reads, all tests but `smoke_test`). *Choice: all four.* They add checks; none is relaxed.
- **Reason for the revision:** at an aligned 4:1 ratio (thrash_full; 1:4 for thrash_empty) the
  refill lands exactly one slow-clock edge after each slow-side operation, so a crossing needs
  a gap of at least two slow edges, and the expected count is 2·n_ops·(1 − (K+1)/d). Measured
  over 200 seeds each in that configuration: d = 4 gave 2–3 crossings (always THRASH_WEAK),
  d = 5 failed 13–19% of runs, d = 6 failed 0–1%, d = 7 and 8 never failed (minimum 27 and
  33; means within 2.5% of the formula). The configuration is ~5% of thrash runs, so [4, 8]
  would have failed 1–2 sign-off runs per thrash test on stimulus alone. The 64-operation
  floor keeps the same margin when M9 builds smaller FIFOs (DEPTH = 8 would give only 32).
- **Consequences:**
  - At DEPTH = 16 nothing changes but d. A `+THRASH_D=<d>` plusarg forces d for directed
    closure and reproduction.
  - Aligned integer runs still put an accepted write and read in the same step at the boundary
    in about (K+1)/d ≈ 40–57% of slow-side operations, which is the F16 stimulus.

## DEC-010 — M6 assertion decisions

- **Date:** 2026-11-24
- **Status:** APPROVED (owner, 2026-11-24, M6 kickoff: "go with recommendations") — recorded in
  `ip/async_fifo/docs/vplan.md` v0.4 (§1.2, §4 "As built (M6)", §5 A01)
- **Options and choices:**
  1. **D1, showing each assertion can fail.** A force-based negative-test bench now, or wait for
     M8's planted bugs. *Choice: now* (`tb/sva_neg/`, `make sva-neg`, `common/scripts/sva_neg.py`).
     The twelve M8 bugs don't reach every assertion (the reset-value checks, for example).
  2. **D2, optional concurrent SVA.** *Choice: yes, simulation only:* the eight e2e assertions
     restated with implication, `[*K+1]`, `##1` and `disable iff` in
     `sva/async_fifo_sva_concurrent.sv`, bound into the e2e checker, labeled `cast_<FID>_<name>`.
     They run in the regression and in the negative tests. Formal keeps the immediate versions
     (open-source formal rejects concurrent SVA, toolchain T6).
  3. **D3, cover list (plan M6 step 3, [PAIR]).** *Choice: no additions.* The vplan's 15
     simulation and 7 formal-only covers stand. The F16 covers stay formal-only; in simulation,
     `cg_concurrent` covers the same events.
  4. **D4, A01 simulation wording.** "Both resets low at the first rising edge of *each* clock"
     fails on a legal testbench whose `rrst_n` is released before `wclk` first rises. *Choice:* at
     the first rising edge of *either* clock, both resets are 0 (the true initial state).
  5. **D5, A06.** `asm_A06_*` (inputs never X) can't fire in a two-state simulator. *Choice:*
     record it as not demonstrable in Verilator (no second simulator).
- **Consequences:**
  - Every simulation assertion has a demonstrated failure (25 of 27; A06's two are documented in
    `docs/sva_negative_tests.md`). M8 still records which planted bug trips which assertion.
  - Concurrent twins use a distinct prefix so a twin can never hide its immediate twin in a
    failure report; `sva_neg.py --twins` checks each twin fires in its twin's case.
  - The vplan intents, bins, checks and ledger rows are unchanged apart from A01's simulation
    wording.

---

## DEC-011 — M7 formal environment decisions

- **Date:** 2026-11-24
- **Status:** APPROVED (owner, 2026-11-24, M7 kickoff: "go with recommendations")
- **Options and choices:**
  1. **D1, clock model.** Unconstrained clocks (A04: `wclk` and `rclk` are free inputs sampled
     every formal step, any interleaving, coincident edges included) or ZipCPU's `anyconst` step
     counters (fixed rates). *Choice: unconstrained.* Strictly more general; enough for safety
     properties.
  2. **D2, A03 (inputs change only right after their own clock's edge).** *Choice: not adopted.*
     Its formal form is written behind a define that is off by default; Claude returns to the
     owner only if a proof cannot close without it.
  3. **D3, formal wording of A02 (reset release).** The vplan says a reset rises "only together
     with a rising edge" of its clock. In the formal step model a release in the same step as the
     edge may let async-reset flops capture at that edge, which simulation never does. *Choice:
     settle it with toolchain experiment T17 first; if it conflicts, the owner decides a new
     wording on the evidence.*
  4. **D4, ASIZE = 4 (stretch).** *Choice: attempt, capped at 30 minutes per task;* record the
     result or the timeout.
  5. **D5, cover-trace figures.** *Choice: a standard-library script `common/scripts/vcd2svg.py`
     renders the VCD traces to SVG; the SVGs are committed under `ip/async_fifo/docs/figures/`.*
- **Consequences:** no assumption is added; A03 stays optional in the ledger. Any change to A02's
  formal wording comes back to the owner with the T17 evidence.

---

## DEC-012 — A02 after the M7 audit

- **Date:** 2026-11-24
- **Status:** PROPOSED (awaiting the owner)
- **Finding:** with A02 dropped (a reset may rise in any formal step, not only with its own
  clock's rising edge), k-induction still proves every property at ASIZE 2 and 3
  (`make formal TASK=audit_a02 ASIZE=<n>`). The RTL logic tolerates any release timing. The
  vplan §5 audit rule says an unnecessary assumption "is retired". Physically A02 is still
  required: an asynchronous release near an edge is a recovery/removal violation and can go
  metastable, which no RTL model represents (plan R11).
- **Options:**
  1. **Drop it from formal, keep it as a requirement (recommended).** Remove the formal
     `assume`, so the SO-3 proof rests on A01 and A05 only. Keep the simulation `asm_A02_*` checks,
     which hold the testbench to spec §8, and the ledger row with "Formal: n/a: not needed (M7
     audit); physical requirement (R11)". Costs a vplan row edit (Runs/Clock of the two labels)
     and one `make formal-signoff` rerun.
  2. **Retire A02 completely.** Also delete the simulation checks; A02 moves to "Retired IDs".
     Loses the testbench check of a real integration rule.
  3. **Keep A02 as is,** with the audit result documented. No work; the proof keeps an
     assumption it does not need.
- **Consequences:** recorded once the owner chooses.
