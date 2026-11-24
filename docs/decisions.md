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
