# async_fifo — Verification plan

**Version** 0.2 · **Date** 2026-11-24 · **Status** DRAFT: owner decisions applied (feature-table
edits, power-up-only resets, N = 200); full text awaiting owner review ·
**Spec** [`spec.md`](spec.md) v1.1 · **RTL** `rtl/async_fifo.sv`, tag `rtl-v1`

This plan maps every requirement of the spec to the stimulus that exercises it, the checkers
that judge it, the coverage that proves it was exercised, and the formal properties that prove
it for all inputs. It also lists the assumptions those results rest on and the criteria for
sign-off. `common/scripts/vplan_check.py` reads it (`make vplan`), so the tables follow fixed
rules (§1.3). Paths are relative to `ip/async_fifo/`.

---

## 1. Scope

### 1.1 Design and configurations

- **DUT.** `async_fifo` (Cummings style #1): gray pointers, two-flop synchronizers, registered
  flags, show-ahead read. The spec is the contract; checkers never follow the RTL silently.
- **Configurations.** Simulation: ASIZE = 4, DSIZE = 8 (DEPTH = 16). Formal: ASIZE = 2 and 3,
  DSIZE = 4. MCY: ASIZE = 2, DSIZE = 4.
- **K = 3** (spec §7.4): two synchronizer stages plus the flag register.

### 1.2 Methods

| Method | Code | Module | Evidence |
|---|---|---|---|
| UVM simulation, Verilator (DEC-001) | `tb/uvm/` | M3–M5 | regression summary, merged functional coverage |
| Assertions in simulation | `sva/async_fifo_e2e_props.sv`, `rtl/async_fifo_props.svh` | M6 | regression with every assertion enabled |
| Formal: SBY, two clocks, k-induction (DEC-002) | `formal/async_fifo.sby` | M7 | prove and cover logs |
| Planted bugs | `bugs/` | M8 | `docs/bug_matrix.md` |
| Mutation testing, MCY | `mcy/` | M9 | `docs/mutation_report.md` |

### 1.3 How to read and edit this plan

- **Terms** come from spec §5. *Fill* is the true fill (accepted writes − accepted reads), taken
  from a reference model, never from the DUT's flags. *Accepted* and *blocked* operations are
  defined there too, along with the coincident-edge rule: an event at the same instant on the
  other clock does not count.
- **Clock ratio.** ρ = f_wclk / f_rclk = T_rclk / T_wclk. Buckets: B0 [0.25, 0.5),
  B1 [0.5, 0.95), B2 [0.95, 1.05], B3 (1.05, 2.0], B4 (2.0, 4.0].
- **Tables are parsed by their header row.** Don't rename columns or put `|` inside a cell.
- **Cells.** Items in one cell are separated by `<br>`. Names in backticks are references:
  property labels (`ast_`, `asm_`, `cov_`), coverage items (`cg_…`), tests (`…_test`), make
  targets (`make …`) and other code names. A cell that doesn't apply says `n/a: <reason>`.
  A Checker cell may never be `n/a`. An item marked [STRETCH] is optional.
- **IDs** (F, A, B) are never reused or renumbered. A dropped ID moves to the line below.

Retired IDs: none.

---

## 2. Features

### 2.1 Feature table

| ID | Requirement | Stimulus | Checker | Coverage | Formal | Notes |
|---|---|---|---|---|---|---|
| F01 | **Reset state.** While `wrst_n = 0`: `wfull = 0`, and `wbin`, `wptr`, `wq1_rptr`, `wq2_rptr` are 0. While `rrst_n = 0`: `rempty = 1`, and `rbin`, `rptr`, `rq1_wptr`, `rq2_wptr` are 0. `winc` and `rinc` are ignored while their own reset is asserted (spec §8, W3, R5). | Every test (power-up reset, A01)<br>Drivers toggle `winc`/`rinc` at random during reset (S3) | `ast_F01_wfull_low_in_reset`<br>`ast_F01_rempty_high_in_reset`<br>`ast_F01_wside_regs_zero`<br>`ast_F01_rside_regs_zero`<br>`ast_F07_rempty_not_optimistic` (a write counted during reset makes `rempty` fall with fill 0) | `cg_reset.cp_winc_in_reset`<br>`cg_reset.cp_rinc_in_reset`<br>`cov_F01_winc_in_reset`<br>`cov_F01_rinc_in_reset` | All F01 properties (Runs = both), from the formal reset model (A01, A02, A05) | B12 |
| F02 | **Integrity.** Every accepted write is read exactly once, with its data unchanged (spec W1, R1, R2). | Every test<br>Every test ends with a drain (S6) | `fifo_scoreboard` (pop and compare; X/Z on `rdata` is an error; entries left after the final drain are an error)<br>`ast_F02_tracked_word` | `cg_fill.x_fill_bucket`<br>`cov_F02_tracked_word_read` | `ast_F02_tracked_word` (one arbitrary write index, `anyconst`; the read with the same index must return its data)<br>`cov_F02_tracked_word_read` | B03, B10. Data-bit toggling is in code coverage (M5 step 6). |
| F03 | **Order.** Entries are read in the order they were written. | Every test | `fifo_scoreboard` (compares against the head of the model queue)<br>`ast_F03_tracked_pair_order` | `cg_fill.x_fill_bucket`<br>`cov_F03_tracked_pair_read` | `ast_F03_tracked_pair_order` (two arbitrary consecutive writes come out in order, the two-value technique)<br>`cov_F03_tracked_pair_read` | B10 |
| F04 | **No overflow.** A blocked write (`winc` while `wfull`) is ignored: nothing is stored, no stored entry changes, and the write pointer does not move (spec W2). | `smoke_test`<br>`fill_to_full_test`<br>`thrash_full_test`<br>`random_mix_test` (`respect_full = 0`, S4) | `fifo_scoreboard` (an accepted write while the model holds DEPTH is an overflow; an overwritten entry shows up as a mismatch)<br>`ast_F04_blocked_write_holds_wptr`<br>`ast_F14_rdata_stable` (overwriting the oldest entry changes `rdata` while no read is accepted) | `cg_attempts.x_blocked_bucket`<br>`cov_F04_blocked_write_at_full` | `ast_F04_blocked_write_holds_wptr`<br>`ast_F02_tracked_word`<br>`cov_F04_blocked_write_at_full` | B03. Only a blocked write at true full (fill = DEPTH) can overwrite an unread entry, hence the split bins in `cg_attempts`. |
| F05 | **No underflow.** A blocked read (`rinc` while `rempty`) is ignored: nothing is popped and the read pointer does not move (spec R4). | `smoke_test`<br>`drain_to_empty_test`<br>`thrash_empty_test`<br>`random_mix_test` (`respect_empty = 0`, S4) | `fifo_scoreboard` (an accepted read while the model is empty is an underflow)<br>`ast_F05_blocked_read_holds_rptr`<br>`ast_F07_rempty_not_optimistic` | `cg_attempts.x_blocked_bucket`<br>`cov_F05_blocked_read_at_empty` | `ast_F05_blocked_read_holds_rptr`<br>`cov_F05_blocked_read_at_empty` | B04 |
| F06 | **`wfull` never optimistic.** At every rising `wclk` edge with `wrst_n = 1`, `wfull = 0` ⇒ fill < DEPTH. Fill counts writes at earlier `wclk` edges and reads at strictly earlier `rclk` edges (spec §5, §7.2). | `fill_to_full_test`<br>`thrash_full_test` | `ast_F06_wfull_not_optimistic`<br>`fifo_scoreboard` (overflow check, same-timestamp rule) | `cg_fill.x_fill_bucket`<br>`cg_flags.x_flag_bucket` | `ast_F06_wfull_not_optimistic` | B01, B02 |
| F07 | **`rempty` never optimistic.** At every rising `rclk` edge with `rrst_n = 1`, `rempty = 0` ⇒ fill ≥ 1. Fill counts reads at earlier `rclk` edges and writes at strictly earlier `wclk` edges (spec §5, §7.2). | `drain_to_empty_test`<br>`thrash_empty_test` | `ast_F07_rempty_not_optimistic`<br>`fifo_scoreboard` (underflow check, same-timestamp rule) | `cg_fill.x_fill_bucket`<br>`cg_flags.x_flag_bucket` | `ast_F07_rempty_not_optimistic` | B04, B05, B12 |
| F08 | **Bounded pessimism, K = 3.** Once no read has been accepted for K rising `wclk` edges, `wfull = 1` exactly when fill = DEPTH. Once no write has been accepted for K rising `rclk` edges, `rempty = 1` exactly when fill = 0 (spec §7.4). This rules out a FIFO with stuck flags, which passes every safety check. | `thrash_full_test`<br>`thrash_empty_test`<br>`random_rates_test` (0% phases leave the other side idle) | `ast_F08_wfull_exact`<br>`ast_F08_rempty_exact` | `cg_flags.x_flag_bucket` (lag bins)<br>`cov_F08_wfull_lag`<br>`cov_F08_rempty_lag`<br>`cov_F08_wfull_lag_k_minus_1`<br>`cov_F08_rempty_lag_k_minus_1` | All F08 properties (Runs = both) | B02, B11. The `_k_minus_1` covers show that K is tight. Under B08 they become unreachable: a latency change, not the CDC risk. |
| F09 | **CDC safety of the crossing nets.** (a) At each rising edge of its source clock, `wptr_cdc` (`rptr_cdc`) has changed in at most one bit since the previous edge, and only if that previous edge accepted a write (read) (spec C4). (b) It changes only at rising edges of its source clock, never between them (spec C3; formal only). This is a source-side property (plan R10). On the synchronized copy it would fail on a correct design. | Every test (every accepted operation moves a pointer) | `ast_F09_wptr_cdc_one_bit`<br>`ast_F09_rptr_cdc_one_bit`<br>`ast_F09_wptr_cdc_moves_on_write`<br>`ast_F09_rptr_cdc_moves_on_read` | n/a: every accepted operation moves a pointer; pointer wraps are covered by F13 | The four (a) properties (Runs = both)<br>`ast_F09_wptr_cdc_stable_off_edge`<br>`ast_F09_rptr_cdc_stable_off_edge` | B06, B07 |
| F10 | **Gray/binary consistency.** Out of reset, `wptr == (wbin >> 1) ^ wbin` and `rptr == (rbin >> 1) ^ rbin` (spec §10). | Every test | `ast_F10_wptr_is_gray_of_wbin`<br>`ast_F10_rptr_is_gray_of_rbin` | n/a: holds at every edge; pointer wraps are covered by F13 | Both F10 properties (Runs = both); also induction invariants in M7 | B06. These restate the RTL (plan M6 pitfall): they serve as invariants, and the e2e checks carry the spec. |
| F11 | **Synchronizer structure.** Each gray pointer crosses through exactly two flops, clocked and reset by the destination domain, with no logic between the crossing net and the first stage. All four carry `ASYNC_REG` (spec C1–C3, C6). | n/a: structural; checked on the netlist and in formal | `make synth` (8·(ASIZE+1)+2 async-reset flops before optimization; a deleted stage changes the count)<br>`ast_F01_rside_regs_zero`<br>`ast_F01_wside_regs_zero` (a stage on the wrong reset leaves reset early when the other side is released first, F17)<br>`cdc_check.py` [STRETCH, M8] | n/a: structural, nothing to exercise | `ast_F11_wsync_on_wclk`<br>`ast_F11_rsync_on_rclk` (synchronizer flops change only in a formal step where their destination clock rises) | B08, B09. Without the [STRETCH] script, `ASYNC_REG` and "no logic before stage 1" are checked by review only. Metastability is not modeled (plan R11). |
| F12 | **Full capacity.** Starting empty with no reads, exactly DEPTH writes are accepted and the next attempt is blocked (spec W5). | `fill_to_full_test` | `ast_F12_capacity`<br>`fill_to_full_test` end check: the scoreboard's maximum fill equals DEPTH | `cg_fill.x_fill_bucket` (full bin)<br>`cov_F12_full_reached`<br>`cov_F12_empty_after_full` | All F12 properties (Runs = both) | B11 is safe but wrong: only F08, F12 and coverage see it. Also B02. |
| F13 | **Wrap-around.** Correct across at least two wraps of each (ASIZE+1)-bit pointer (≥ 4·DEPTH accepted reads), with full and empty each reached in both pointer laps. Behavior must not depend on the wrap count (spec §10). | Every test except `smoke_test` makes ≥ 4·DEPTH accepted reads (S5) | `fifo_scoreboard`<br>`ast_F10_wptr_is_gray_of_wbin`<br>`ast_F10_rptr_is_gray_of_rbin`<br>`ast_F06_wfull_not_optimistic`<br>`ast_F07_rempty_not_optimistic` | `cg_fill.cp_lap`<br>`cov_F13_two_wraps` | `cov_F13_two_wraps`; the unbounded proofs hold for any wrap count | B01, B10 |
| F14 | **Show-ahead stability.** While `rempty = 0` and no read is accepted, `rdata` holds its value. Write-side activity never disturbs it (spec R3). | `random_rates_test` (0% read phases while writing)<br>`fill_to_full_test` | `ast_F14_rdata_stable`<br>`fifo_scoreboard` (value popped) | `cov_F14_hold_while_writing` | `ast_F14_rdata_stable`<br>`ast_F14_rdata_stable_gclk` (every formal step, so a transient overwrite between `rclk` edges is caught too)<br>`cov_F14_hold_while_writing` | B03 (overwrite at full) |
| F15 | **Clock robustness.** F02–F10 hold for wclk:rclk from 1:4 to 4:1 at any phase (simulation), and for any interleaving of the two clocks, coincident edges included (formal, A04). | Every test: `fifo_env_cfg` picks the ratio bucket first (S1) | `fifo_scoreboard` and the F02–F10 assertions, active at every ratio; no checker is disabled or relaxed by ratio | `cg_cfg.x_bucket_kind`<br>`cg_cfg.x_b2_phase`<br>Every × bucket cross in `cg_fill`, `cg_concurrent`, `cg_flags`, `cg_attempts` | Every formal property runs under A04<br>`cov_F15_same_step_edges`<br>`cov_F15_wclk_burst`<br>`cov_F15_rclk_burst` | Plan R9: the ratio is fixed within a run, so the × bucket crosses close only in merged coverage. |
| F16 | **Boundary concurrency.** An accepted write and an accepted read at the same instant are handled correctly at the boundaries. This is possible only at fill 1 and fill DEPTH−1 (fill at the start of that instant). At fill 0 the read, and at DEPTH the write, would be an underflow or overflow, which F05–F07 forbid. | `thrash_full_test`<br>`thrash_empty_test` at integer ratios with aligned phase (S1) | `fifo_scoreboard` same-timestamp rule (overflow and underflow judged on the fill at the start of the time step)<br>`ast_F06_wfull_not_optimistic`<br>`ast_F07_rempty_not_optimistic` | `cg_concurrent.x_concurrent_bucket` | `cov_F16_rw_at_one`<br>`cov_F16_rw_at_depth_m1`; the safety proofs include coincident edges (A04) | B05. "Same instant" means the same simulation timestamp, or the same formal step. |
| F17 | **Reset release order.** Both resets start asserted (A01) and are released in either order, any time apart, each on its own clock (A02). Writes accepted while the read side is still in reset are read back intact after its release, and the side still in reset keeps its reset values (F01; spec §8). | Every test: `fifo_env_cfg` randomizes the release order and the gap between releases (S2) | `fifo_scoreboard`<br>`ast_F01_rside_regs_zero`<br>`ast_F01_wside_regs_zero`<br>`ast_F07_rempty_not_optimistic` | `cg_reset.x_order_writes`<br>`cov_F17_write_during_rd_reset`<br>`cov_F17_rd_released_first`<br>`cov_F17_full_before_rd_release` | All F17 covers (Runs = both); the formal model releases each reset independently (A01, A02, A05) | B12; a synchronizer on the wrong reset (F11) |

### 2.2 Tests

M3 and M4 implement these names. `regress/tests.toml` lists them with their seed counts.
Parameter values are the owner's M4 decisions (DEC-009). Every test except `smoke_test` fails
with `S5_SHORT` if it makes fewer than 4·DEPTH accepted reads.

| Test | Sequence | Module | Purpose |
|---|---|---|---|
| `smoke_test` | directed | M3 | DEPTH+2 writes, two of them blocked; then read to empty, with blocked reads |
| `fill_to_full_test` | `vseq_fill_to_full` | M4 | 4–6 rounds: write at 100% with no reads, `wfull` ignored, until k ∈ [2, 4] blocked writes; then drain at the cfg's read rate. Each round checks F12 (`F12_CAPACITY`); the run checks max fill = DEPTH |
| `drain_to_empty_test` | `vseq_drain_to_empty` | M4 | 4–6 rounds: fill to DEPTH at the cfg's write rate; then read at 100%, `rempty` ignored, until k ∈ [2, 4] blocked reads. Each round checks the drain count (`DRAIN_COUNT`) |
| `thrash_full_test` | `vseq_thrash_full` | M4 | From DEPTH−1, write at 100% while reading at 1/d of the write side's full rate, d ∈ [7, 10], for max(4·DEPTH, 64) accepted reads; the fill bounces between DEPTH−1 and DEPTH, ≥ 20 crossings (`THRASH_WEAK`). 50% integer ratios (DEC-009) |
| `thrash_empty_test` | `vseq_thrash_empty` | M4 | Mirror of `thrash_full_test` around 0 and 1: from fill 1, read at 100% while writing at 1/d of the read side's full rate, for max(4·DEPTH, 64) accepted writes, ≥ 20 crossings. 50% integer ratios |
| `random_rates_test` | `vseq_random_rates` | M4 | 4–8 phases of 2·DEPTH to 8·DEPTH slower-clock cycles; each side's rate is 0% (weight 25), 100% (25) or [10, 90]% (50); then top-up phases until S5 is met |
| `random_mix_test` | `vseq_random_mix` | M4 | 4–8 picks among the five sequences above in short form (one round, DEPTH thrash operations without the crossing check, 1–2 rate phases), then more picks until S5 is met |

### 2.3 Stimulus obligations

The coverage model can close only if M3 and M4 provide the following.

- **S1 — Clock configuration** (`fifo_env_cfg`, M3).
  - Pick the bucket uniformly over B0–B4, then the periods inside it (uniform over buckets, not
    over periods).
  - About 20% of runs use an exact integer ratio (1:4, 1:2, 1:1, 2:1, 4:1). Each bucket holds
    exactly one of them.
  - In half of the integer-ratio runs, the `rclk` phase makes rising edges coincide. Otherwise
    the phase is random in [0, T_rclk).
  - Coincident edges are needed for F16 and for the coincident-edge rule (spec §5).
- **S2 — Reset release** (M3).
  - Both resets are asserted at time 0.
  - The release order is uniform: write side first or read side first.
  - The gap between the two releases is random in [0, 3·DEPTH] cycles of the clock released
    first.
  - Traffic on each side starts at its own release, so writes can happen during the gap (F17).
- **S3 — Inputs during reset.** Drivers drive random `winc`/`rinc` while their reset is
  asserted (F01).
- **S4 — Blocked attempts.** Some runs ignore the flags (`respect_full = 0`,
  `respect_empty = 0`), so writes at true full and reads at true empty happen (F04, F05).
- **S5 — Run length.** Every test except `smoke_test` makes at least 4·DEPTH accepted reads
  (F13).
- **S6 — Drain.** Every test ends by reading until the model is empty, then waits several
  slow-clock periods. Entries left over after that are an error (F02).

---

## 3. Coverage model

All bins are sampled from the testbench's reference model and its monitors, never from the
DUT's flags alone. A buggy flag must not be able to fake coverage. Blocked attempts are never
counted while that side's reset is asserted. The bucket comes from `fifo_env_cfg`.

| Item | Sampled | Bins | Purpose |
|---|---|---|---|
| `cg_cfg.cp_bucket` | Once per run, after `fifo_env_cfg` is randomized | B0, B1, B2, B3, B4 (§1.3) | Every ratio range is run |
| `cg_cfg.cp_kind` | as above | integer (1:4, 1:2, 1:1, 2:1, 4:1), arbitrary | Exact ratios put edges in fixed relations |
| `cg_cfg.cp_phase` | as above | aligned (the first rising `rclk` edge within 5% of T_wclk of a rising `wclk` edge), unaligned | Coincident vs. offset edges |
| `cg_cfg.x_bucket_kind` | as above | cp_bucket × cp_kind (10) | Each bucket at its integer ratio and at arbitrary ratios |
| `cg_cfg.x_b2_phase` | as above | B2 × cp_phase (2; other buckets ignored) | Near-equal clocks, aligned and drifting |
| `cg_reset.cp_order` | Once per run, when the second reset is released | w_first, r_first | Both release orders (F17) |
| `cg_reset.cp_writes_before_rd_release` | as above | none [0], some [1:DEPTH−1], full [DEPTH]: accepted writes before `rrst_n` rose | Writes waiting on a read side in reset (F17) |
| `cg_reset.x_order_writes` | as above | w_first × {none, some, full}, r_first × none (4; r_first × some/full is impossible and ignored) | F17 scenarios, including a FIFO full before the read side is released |
| `cg_reset.cp_winc_in_reset` | as above | seen: `winc = 1` at a rising `wclk` edge while `wrst_n = 0` | Writes ignored in reset (F01) |
| `cg_reset.cp_rinc_in_reset` | as above | seen: `rinc = 1` at a rising `rclk` edge while `rrst_n = 0` | Reads ignored in reset (F01) |
| `cg_fill.cp_fill` | At the end of each simulation time step in which the model fill changed (net), after the scoreboard has applied that step's operations | zero [0], one [1], mid [2:DEPTH−2], almost_full [DEPTH−1], full [DEPTH] | Every fill level; zero counts only after a read empties the FIFO |
| `cg_fill.cp_fill_trans` | as above | full_bounce (DEPTH−1 ⇒ DEPTH ⇒ DEPTH−1), empty_bounce (1 ⇒ 0 ⇒ 1) | The boundary transitions, the valuable bins (plan M5) |
| `cg_fill.cp_lap` | as above, only when fill is 0 or DEPTH | full_msb0, full_msb1, empty_msb0, empty_msb1: bit ASIZE of the model's write count, which is the write pointer's lap | Full and empty in both pointer laps (F13) |
| `cg_fill.x_fill_bucket` | as above | cp_fill × cp_bucket (25) | Every fill level at every ratio |
| `cg_fill.x_trans_bucket` | as above | cp_fill_trans × cp_bucket (10) | Boundary transitions at every ratio |
| `cg_concurrent.cp_start_fill` | At the end of each time step with both an accepted write and an accepted read; the value is the fill at the start of the step | at_one [1], at_depth_m1 [DEPTH−1]. No bins for 0 or DEPTH: there the pair is an underflow or overflow, which the scoreboard reports as an error | Boundary concurrency (F16) |
| `cg_concurrent.x_concurrent_bucket` | as above | cp_start_fill × cp_bucket (10) | F16 at every ratio |
| `cg_flags.cp_flag_event` | At each rising edge of the flag's own clock while its reset is released. Rise and fall compare with the previous edge; fill is taken at the start of the time step | wfull_rise, wfull_fall, rempty_rise, rempty_fall, wfull_lag (`wfull = 1`, fill < DEPTH), rempty_lag (`rempty = 1`, fill > 0) | Flag edges, and the lag window that F08 checks |
| `cg_flags.x_flag_bucket` | as above | cp_flag_event × cp_bucket (30) | Flag behavior at every ratio |
| `cg_attempts.cp_blocked` | At each blocked write or read (spec §5), outside reset; fill at the start of the time step | write_at_full (fill = DEPTH), write_lag (fill < DEPTH), read_at_empty (fill = 0), read_lag (fill > 0) | Blocked attempts. Only write_at_full can expose an overwrite (B03) |
| `cg_attempts.x_blocked_bucket` | as above | cp_blocked × cp_bucket (20) | Blocked attempts at every ratio |

**Totals.** 6 covergroups, 21 items, 150 bins. SO-1 requires all of them plus every simulation
cover property (§4).

**Implementation rules for M5.**
- Use type-level coverage (`option.per_instance = 0`), merged across runs with
  `verilator_coverage --write`. Read coverpoints and crosses with `get_inst_coverage()`
  (DEC-001).
- Before relying on crosses of transition bins (`x_trans_bucket`) or `ignore_bins` on a cross
  (`x_b2_phase`, `x_order_writes`), run a `tools_smoke/` experiment. If a construct is missing,
  implement the same bins another way (for example, a small tracker that feeds a plain
  coverpoint). The bins themselves don't change.
- Bucket and phase come from `fifo_env_cfg`'s `ratio_bucket()` helper (plan M3 step 4).

---

## 4. Property list

**Kind.** *e2e* properties use ports only and live in `sva/async_fifo_e2e_props.sv`, a checker
module that keeps its own counts of accepted writes and reads (the true fill). *white-box*
properties use the internal names of spec §10 and live in `rtl/async_fifo_props.svh`, which is
included inside the RTL when `ASYNC_FIFO_PROPS` is defined. Formal-only parts sit under
`ifdef FORMAL`.

**Runs.** `sim`, `formal` or `both`. **Clock.**
- `wclk` / `rclk`: sampled at that clock's rising edge, using values from just before the edge.
- `gclk`: every formal step. A `both` property on `gclk` runs in simulation as an event-driven
  check, because simulation has no global clock.
- `init`: the initial state.

Each property names exactly one clock (plan R6). Style: labeled, clocked immediate assertions
(DEC-002). `asm_` labels are `assume` under `FORMAL` and `assert` in simulation (one macro).
That is how the simulation checks every formal assumption on the testbench's own behavior.

| Label | Kind | Runs | Clock | Intent |
|---|---|---|---|---|
| `ast_F01_wfull_low_in_reset` | e2e | both | wclk | At every rising `wclk` edge while `wrst_n = 0`, `wfull` is 0. |
| `ast_F01_rempty_high_in_reset` | e2e | both | rclk | At every rising `rclk` edge while `rrst_n = 0`, `rempty` is 1. |
| `ast_F01_wside_regs_zero` | white-box | both | wclk | At every rising `wclk` edge while `wrst_n = 0`, `wbin`, `wptr`, `wq1_rptr` and `wq2_rptr` are 0. |
| `ast_F01_rside_regs_zero` | white-box | both | rclk | At every rising `rclk` edge while `rrst_n = 0`, `rbin`, `rptr`, `rq1_wptr` and `rq2_wptr` are 0. |
| `cov_F01_winc_in_reset` | e2e | both | wclk | `winc = 1` at a rising `wclk` edge while `wrst_n = 0`. |
| `cov_F01_rinc_in_reset` | e2e | both | rclk | `rinc = 1` at a rising `rclk` edge while `rrst_n = 0`. |
| `ast_F02_tracked_word` | e2e | formal | rclk | For one arbitrary accepted write (an `anyconst` write index), the accepted read with the same index returns its data. |
| `cov_F02_tracked_word_read` | e2e | formal | rclk | The tracked write is read back. |
| `ast_F03_tracked_pair_order` | e2e | formal | rclk | Of two arbitrary consecutive accepted writes, the first is read before the second, and both come back intact. |
| `cov_F03_tracked_pair_read` | e2e | formal | rclk | Both tracked writes are read back. |
| `ast_F04_blocked_write_holds_wptr` | white-box | both | wclk | A blocked write leaves `wbin` and `wptr` unchanged. |
| `cov_F04_blocked_write_at_full` | e2e | both | wclk | A write is attempted while `wfull = 1` and fill = DEPTH (true full). |
| `ast_F05_blocked_read_holds_rptr` | white-box | both | rclk | A blocked read leaves `rbin` and `rptr` unchanged. |
| `cov_F05_blocked_read_at_empty` | e2e | both | rclk | A read is attempted while `rempty = 1` and fill = 0 (true empty), out of reset. |
| `ast_F06_wfull_not_optimistic` | e2e | both | wclk | At every rising `wclk` edge out of reset, `wfull = 0` implies fill < DEPTH. |
| `ast_F07_rempty_not_optimistic` | e2e | both | rclk | At every rising `rclk` edge out of reset, `rempty = 0` implies fill ≥ 1. |
| `ast_F08_wfull_exact` | e2e | both | wclk | Once no read has been accepted for K = 3 rising `wclk` edges (or none since reset), `wfull` is 1 exactly when fill = DEPTH. |
| `ast_F08_rempty_exact` | e2e | both | rclk | Once no write has been accepted for K = 3 rising `rclk` edges (or none since reset), `rempty` is 1 exactly when fill = 0. |
| `cov_F08_wfull_lag` | e2e | both | wclk | `wfull = 1` while fill < DEPTH: the flag lags a read. |
| `cov_F08_rempty_lag` | e2e | both | rclk | `rempty = 1` while fill > 0: the flag lags a write. |
| `cov_F08_wfull_lag_k_minus_1` | e2e | both | wclk | `wfull` still lags at the (K−1)-th rising `wclk` edge after the most recent read, so the bound K is tight. |
| `cov_F08_rempty_lag_k_minus_1` | e2e | both | rclk | `rempty` still lags at the (K−1)-th rising `rclk` edge after the most recent write, so the bound K is tight. |
| `ast_F09_wptr_cdc_one_bit` | white-box | both | wclk | Between consecutive rising `wclk` edges, `wptr_cdc` changes in at most one bit. |
| `ast_F09_rptr_cdc_one_bit` | white-box | both | rclk | Between consecutive rising `rclk` edges, `rptr_cdc` changes in at most one bit. |
| `ast_F09_wptr_cdc_moves_on_write` | white-box | both | wclk | `wptr_cdc` changes only after a `wclk` edge that accepted a write. |
| `ast_F09_rptr_cdc_moves_on_read` | white-box | both | rclk | `rptr_cdc` changes only after an `rclk` edge that accepted a read. |
| `ast_F09_wptr_cdc_stable_off_edge` | white-box | formal | gclk | `wptr_cdc` changes only in a formal step where `wclk` rises. |
| `ast_F09_rptr_cdc_stable_off_edge` | white-box | formal | gclk | `rptr_cdc` changes only in a formal step where `rclk` rises. |
| `ast_F10_wptr_is_gray_of_wbin` | white-box | both | wclk | `wptr` equals the gray code of `wbin`. |
| `ast_F10_rptr_is_gray_of_rbin` | white-box | both | rclk | `rptr` equals the gray code of `rbin`. |
| `ast_F11_wsync_on_wclk` | white-box | formal | gclk | `wq1_rptr` and `wq2_rptr` change only in a formal step where `wclk` rises. |
| `ast_F11_rsync_on_rclk` | white-box | formal | gclk | `rq1_wptr` and `rq2_wptr` change only in a formal step where `rclk` rises. |
| `ast_F12_capacity` | e2e | both | wclk | While no read has been accepted since reset, `wfull` is 1 exactly when fill = DEPTH. |
| `cov_F12_full_reached` | e2e | both | wclk | Fill reaches DEPTH with `wfull = 1`. |
| `cov_F12_empty_after_full` | e2e | both | rclk | After fill has reached DEPTH, it returns to 0 with `rempty = 1`. |
| `cov_F13_two_wraps` | e2e | both | rclk | At least 4·DEPTH reads have been accepted, so both pointers have wrapped twice. |
| `ast_F14_rdata_stable` | e2e | both | rclk | If `rempty = 0` and no read was accepted at the previous rising `rclk` edge, `rdata` is unchanged since that edge. |
| `ast_F14_rdata_stable_gclk` | e2e | formal | gclk | While `rempty = 0`, `rdata` changes only in a formal step where `rclk` rises. |
| `cov_F14_hold_while_writing` | e2e | both | rclk | `rdata` is held (`rempty = 0`, no read accepted) across an `rclk` edge while a write was accepted since the previous one. |
| `cov_F15_same_step_edges` | e2e | formal | gclk | `wclk` and `rclk` rise in the same formal step while both resets are released. |
| `cov_F15_wclk_burst` | e2e | formal | gclk | Five rising `wclk` edges occur with no rising `rclk` edge between them, beyond the 4:1 that simulation reaches. |
| `cov_F15_rclk_burst` | e2e | formal | gclk | Five rising `rclk` edges occur with no rising `wclk` edge between them. |
| `cov_F16_rw_at_one` | e2e | formal | gclk | An accepted write and an accepted read occur in the same formal step at fill 1. |
| `cov_F16_rw_at_depth_m1` | e2e | formal | gclk | An accepted write and an accepted read occur in the same formal step at fill DEPTH−1. |
| `cov_F17_write_during_rd_reset` | e2e | both | wclk | A write is accepted while `rrst_n = 0`. |
| `cov_F17_rd_released_first` | e2e | both | rclk | `rrst_n = 1` while `wrst_n = 0`. |
| `cov_F17_full_before_rd_release` | e2e | both | wclk | Fill reaches DEPTH while `rrst_n = 0`. |
| `asm_A01_resets_low_at_start` | e2e | both | init | Both resets are 0 in the initial state (simulation: at the first rising edge of each clock). |
| `asm_A02_wrst_release_on_wclk` | e2e | both | gclk | `wrst_n` rises only together with a rising `wclk` edge. |
| `asm_A02_rrst_release_on_rclk` | e2e | both | gclk | `rrst_n` rises only together with a rising `rclk` edge. |
| `asm_A03_w_inputs_after_wclk` | e2e | both | gclk | `winc` and `wdata` change only in the step right after a rising `wclk` edge. |
| `asm_A03_r_inputs_after_rclk` | e2e | both | gclk | `rinc` changes only in the step right after a rising `rclk` edge. |
| `asm_A05_wrst_stays_released` | e2e | both | gclk | Once `wrst_n` is 1, it stays 1. |
| `asm_A05_rrst_stays_released` | e2e | both | gclk | Once `rrst_n` is 1, it stays 1. |
| `asm_A06_w_inputs_known` | e2e | sim | wclk | While `wrst_n = 1`, `winc` is 0 or 1, and `wdata` is known whenever `winc = 1`. |
| `asm_A06_r_inputs_known` | e2e | sim | rclk | While `rrst_n = 1`, `rinc` is 0 or 1. |

**Count.** 47 `ast_`/`cov_` properties (25 assertions, 22 covers) and 9 `asm_`. Every
property must exist under its label by the end of M6 (simulation) or M7 (formal). M6 step 4 or
M8 shows each assertion failing at least once. M7 adds induction invariants (white-box,
`ifdef FORMAL`) on top of this list. Those are proof aids, not spec checks, and need no vplan
row.

---

## 5. Assumption ledger

An assumption narrows what formal explores or what the testbench may do. Each one needs a
reason it holds in a real system, and each formal assumption is also checked in simulation as
an assertion on the testbench (§4, `asm_`). Adding or changing a row needs the owner's approval
(integrity rule).

| ID | Assumption | Why it is realistic | Formal | Simulation | Status |
|---|---|---|---|---|---|
| A01 | Both resets are asserted (0) together at time 0 (power-up). | One power-on reset source feeds both reset synchronizers (spec §8). | `asm_A01_resets_low_at_start` (initial state) | `asm_A01_resets_low_at_start`, asserted at the first rising edge of each clock | active |
| A02 | Each reset is released synchronously to its own clock: `wrst_n` rises only with a rising `wclk` edge, `rrst_n` only with a rising `rclk` edge. | Reset synchronizers (asynchronous assert, synchronous release) are the integrator's job (spec §8). | `asm_A02_wrst_release_on_wclk`<br>`asm_A02_rrst_release_on_rclk` | `asm_A02_wrst_release_on_wclk`<br>`asm_A02_rrst_release_on_rclk`: each rising reset edge must fall in the time step of a rising edge of its clock | active |
| A03 | `winc`/`wdata` change only in the formal step right after a rising `wclk` edge; `rinc` likewise for `rclk`. | Inputs come from flops on their own clock (spec §3). The DUT samples them only at rising edges and has no combinational path from input to output, so changes between edges are invisible to it. The assumption only shrinks traces. | `asm_A03_w_inputs_after_wclk`<br>`asm_A03_r_inputs_after_rclk` (adopted only if M7 needs it) | `asm_A03_w_inputs_after_wclk`<br>`asm_A03_r_inputs_after_rclk`: inputs change only in the time step of a rising edge of their own clock (requires drivers that drive at that edge, M3) | optional |
| A04 | Clocks are unconstrained: any interleaving of rising edges, including coincident edges and arbitrarily long gaps. | Strictly more general than any real pair of clocks, and enough for safety properties (no fairness needed). | n/a: no constraint; `wclk` and `rclk` are free inputs sampled every formal step. The F15 covers show the freedom is real. | n/a: simulated clocks (1:4 to 4:1) are a subset | modeling |
| A05 | No reset after power-up: once `wrst_n` (`rrst_n`) has risen, it stays 1. | Owner decision DEC-007: mid-operation resets are out of scope (spec §8, v1.1). | `asm_A05_wrst_stays_released`<br>`asm_A05_rrst_stays_released` | `asm_A05_wrst_stays_released`<br>`asm_A05_rrst_stays_released` | active |
| A06 | Inputs are known (0 or 1) whenever their side is out of reset, and they meet setup and hold on their own clock. | X on inputs and timing violations are out of scope (spec §3, §12). | n/a: formal is two-valued and samples inputs exactly at the edge | `asm_A06_w_inputs_known`<br>`asm_A06_r_inputs_known` (Verilator is two-state, so these can only fire in a four-state simulator) | active |

**Assumption audit (M7).** Drop each active formal assumption in turn and rerun. Expected
results:
- **A01:** registers start arbitrary, so F01, F06 and F07 fail.
- **A02:** a reset released between clock edges. Record whether anything fails; if nothing
  does, the assumption is unnecessary and is retired.
- **A05:** a reset re-asserted on one side only. F06 and F07 fail because the checker's counts
  and the DUT disagree.

M7 records the actual results here.

---

## 6. Planted-bug plan (→ M8)

These patches go against `rtl-v1`. M8 writes the per-method predictions, runs the matrix and
explains every difference. The last two columns say which feature each bug breaks and which
checks this plan expects to catch it.

| ID | Bug | Violates | Expected catch | Notes |
|---|---|---|---|---|
| B01 | Full compare inverts only the MSB | F06, F12 | `fifo_scoreboard`<br>`ast_F06_wfull_not_optimistic`<br>`ast_F12_capacity` | Full asserts at a fill that depends on the read pointer |
| B02 | Full compare without inversion (empty-style) | F06, F08, F12 | `ast_F12_capacity`<br>`ast_F08_wfull_exact`<br>`ast_F06_wfull_not_optimistic` | `wfull` can rise with fill 0 (dead FIFO), or a lap is missed (overflow) |
| B03 | Memory write enable ignores `wfull` | F04, F02 | `ast_F14_rdata_stable`<br>`fifo_scoreboard`<br>`ast_F02_tracked_word` | Needs a blocked write at true full (`cg_attempts.cp_blocked`, write_at_full) |
| B04 | Read pointer advances while empty | F05, F07 | `ast_F05_blocked_read_holds_rptr`<br>`ast_F07_rempty_not_optimistic`<br>`fifo_scoreboard` | Needs a blocked read |
| B05 | `rempty` computed from the current, not the next, read pointer | F07 | `ast_F07_rempty_not_optimistic`<br>`fifo_scoreboard` | One edge optimistic. Needs back-to-back reads down to empty (`drain_to_empty_test`) |
| B06 | Gray conversion `bin ^ (bin << 1)` | F09, F10 | `ast_F10_wptr_is_gray_of_wbin`<br>`ast_F09_wptr_cdc_one_bit` | The flags then compare wrong codes; whether e2e checks see it depends on stimulus |
| B07 | Binary pointer crosses; converted to gray after the synchronizer | F09 | `ast_F09_wptr_cdc_one_bit` | Invisible to e2e checks in RTL simulation (plan R11). The M8 [STRETCH] jitter simulation shows it end to end |
| B08 | One synchronizer stage deleted | F11 | `make synth`<br>`cov_F08_wfull_lag_k_minus_1` (or its `rempty` twin) becomes unreachable | Metastability is not modeled. The cover sees the latency change, not the CDC risk. M8 MTBF narrative |
| B09 | Synchronizer clocked by the source clock | F11 | `ast_F11_rsync_on_rclk`<br>`cdc_check.py` [STRETCH] | Formal only. In simulation `ast_F08_rempty_exact` may fire when the source clock is the slower one (B0, B1) |
| B10 | Memory addressed with gray bits instead of binary | F02, F03 | `fifo_scoreboard`<br>`ast_F02_tracked_word` | Slots collide across the half-wrap |
| B11 | `wfull` asserts at DEPTH−1 | F08, F12 | `ast_F12_capacity`<br>`ast_F08_wfull_exact` | Safe but wrong: the scoreboard sees no error, and `cg_fill.cp_fill` full stays a hole |
| B12 | `rempty` resets to 0 | F01, F07 | `ast_F01_rempty_high_in_reset`<br>`ast_F07_rempty_not_optimistic` | Fires at the first `rclk` edge in reset |

---

## 7. Sign-off

| ID | Criterion | Evidence |
|---|---|---|
| SO-1 | 100% of the coverage model (§3), merged across all seeds and clock ratios, and every simulation cover property (`cov_`, Runs = sim or both) hit at least once. Exclusions only through §8. | Merged coverage report (M5), `docs/vplan_status.md` |
| SO-2 | Zero failures over N seeds per test, for every test in `regress/tests.toml`. Scoreboard, all assertions (`ASYNC_FIFO_PROPS` plus the e2e checker) and the simulated assumptions (`asm_`) are enabled. | Sign-off regression summary (M5 + M6) |
| SO-3 | Every formal assertion (Runs = formal or both) proven unbounded by k-induction, and every formal cover reached, at ASIZE = 2 and 3 (DSIZE = 4). Assumption audit done. | SBY prove and cover logs (M7) |
| Q-1 | Reported: the detection matrix for the planted bugs (§6), comparing scoreboard-only simulation, simulation with SVA, and formal. | `docs/bug_matrix.md` (M8) |
| Q-2 | Reported: the MCY mutation score per method, with its seed, and an explanation for every surviving mutant. | `docs/mutation_report.md` (M9) |

**Choosing N.** If a bug shows up in a fraction *p* of random runs, all N runs miss it with
probability (1 − p)^N. For 95% confidence, p ≥ 1 − 0.05^(1/N) ≈ 3/N.

| N per test | Catches, with ≥ 95% confidence, any bug that shows up in at least… | …or, for a bug that appears in one ratio bucket only (≈ N/5 runs), in at least… |
|---|---|---|
| 100 | 3.0% of runs | 14% of that bucket's runs |
| 200 | 1.5% of runs | 7.2% of that bucket's runs |
| 500 | 0.6% of runs | 3.0% of that bucket's runs |

**N = 200** seeds per test. This was the owner's decision on 2026-11-22.
- Seven tests (§2.2) make about 1,400 runs: roughly 9 minutes on 8 cores, assuming about 3 s
  per run.
- M5 measures the real run time. Raising N later strengthens the result and needs no
  approval; lowering it does.
- Seeds are recorded per run, so any failure can be reproduced from the summary.

---

## 8. Exclusions

A coverage bin, cover property or check may be excluded only with a reason and the owner's
approval (integrity rule). Every exclusion is listed here.

| Item | Reason | Approved by | Date |
|---|---|---|---|

None.

---

## 9. Out of scope

From spec §12, plus limits of the methods used:

- Almost-full and almost-empty flags, programmable thresholds, fill-level outputs.
- Depths that are not a power of two, and depth 2 (ASIZE = 1). The elaboration guards reject
  ASIZE < 2 (`make lint`, `make synth`).
- A registered read port.
- Any reset after power-up, on one side or both (A05, DEC-007; roadmap E4).
- Reset synchronizers (the integrator's job, A02).
- X on inputs and setup or hold violations (A06).
- A configurable number of synchronizer stages.
- **Metastability.** Neither RTL simulation nor formal models it (plan R11). M8 covers it with
  structure checks, MTBF analysis and timing constraints.
- Formal at ASIZE ≥ 4 ([STRETCH] in M7). Gate-level simulation. Timing closure: M10 only
  ships an example constraints file.

---

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-11-22 | Claude | First draft (M2). Owner decisions applied: F01 adds W3/R5; F09(a) adds spec C4; F11 gets formal and `make synth` checks; F16 restricted to fill 1 and DEPTH−1; F17 added (reset release order); power-up-only resets (A05, DEC-007); N = 200. |
| 0.2 | 2026-11-24 | Claude | M4: §2.2 test rows carry the approved stimulus parameters and their stimulus self-checks (DEC-009: 50% integer ratios in the thrash tests, thrash divisor d ∈ [7, 10] after measurement, thrash length max(4·DEPTH, 64), `S5_SHORT`). No feature, coverage or property change. |
