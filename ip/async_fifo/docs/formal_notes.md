# async_fifo — formal verification notes (M7)

How the two-clock proof of `rtl/async_fifo.sv` is built, why it closes, what it does not cover,
and how it compares with ZipCPU's published proof of the same design style. The plan rows are
vplan §4 (properties) and §5 (assumptions). The decisions are DEC-002 (immediate assertions
only) and DEC-011 (this module's environment choices). The toolchain findings are T15, T17 and
T18 in `docs/toolchain.md`.

Reproduce everything with `make formal-signoff` (ASIZE 2 and 3, DSIZE 4), or one job with
`make formal TASK=<bmc|prove|cover|pdr|...> ASIZE=<n>`.

---

## 1. Model

**Tool flow.** Open-source SymbiYosys 0.71 with `multiclock on` and yosys-smtbmc + yices, plus
ABC PDR as a second engine. Concurrent SVA is not available here (T6), so every property is a
labeled immediate `assert`/`assume`/`cover` in a block clocked by `wclk`, `rclk` or the global
formal clock (`(* gclk *)`, one tick per solver step).

**Formal top.** `async_fifo` itself, read with `ASYNC_FIFO_PROPS` and `FORMAL`. The RTL
includes `rtl/async_fifo_props.svh`, and under `FORMAL` that file instantiates the port-only e2e
checker (`sva/async_fifo_e2e_props.sv`). This puts the white-box properties, the end-to-end
properties and the invariants that tie them together in one flattened design. The checker
exports its internal state through `f_` output ports that exist only under `FORMAL`.
Open-source Yosys does not resolve hierarchical references. Worse, it accepts them without
complaint as implicit, undriven wires that the solver treats as free inputs (T18). An assumption
written that way would constrain nothing. Both source files use `` `default_nettype none ``,
which turns such a name into an error, and `make formal` also fails on Yosys's "implicitly
declared" and "has no driver" warnings.

**Clocks (A04, DEC-011 D1).** `wclk` and `rclk` are free inputs, sampled every step. Any
interleaving is possible: coincident rising edges, a clock idle for any number of steps, any
ratio. The covers `cov_F15_same_step_edges`, `cov_F15_wclk_burst` and `cov_F15_rclk_burst` show
the freedom is real. With `multiclock on`, a flop clocked by `wclk` loads at the step where `wclk`
rises, with its D input as it was in the previous step. A block clocked by `wclk` therefore sees
every signal "just before the edge", the same view the simulation properties have (vplan §4, As
built M6). That is the spec's coincident-edge rule.

**Resets.**
- **A01.** Both resets are 0 in the initial state (`initial assume`).
- **A02.** A reset rises only in a step where its own clock rises (`always @(posedge gclk)` with
  `$rose`). The worry was that at such a step an async-reset flop might load its D input as if
  the reset were already gone, which simulation never does. T17 shows it does not: the flop still
  acts as in reset at that edge, and an RTL-style counter (reset outside the data path) and a
  checker-style counter (reset inside the accept term) never disagree.
- **A05.** Once released, a reset never falls (DEC-007).
- **A03 (inputs change only right after their clock's edge)** was not needed and is not adopted.
  Its formal form exists behind `FORMAL_A03` (DEC-011 D2).

## 2. Properties added for formal

| Label(s) | Clock | How |
|---|---|---|
| `ast_F02_tracked_word`, `cov_F02_tracked_word_read` | rclk | `(* anyconst *)` index `f_idx` modulo 2·DEPTH, compared with the checker's own write and read counts. The data of every accepted write with that index is captured (`f_d1`), and the read with the same index must return it. Every write in every lap is a candidate. |
| `ast_F03_tracked_pair_order`, `cov_F03_tracked_pair_read` | rclk | Two-value technique: the write with index `f_idx+1` is captured (`f_d2`) only when it follows a captured `f_idx`, so the pair is two consecutive writes. The read of `f_idx+1` must return `f_d2`, and the read just before it (index `f_idx`) must have returned `f_d1` (`f_first_ok`). |
| `ast_F09_*_cdc_stable_off_edge` | gclk | `$changed(wptr_cdc)` ⇒ `$rose(wclk)` (and the read mirror). |
| `ast_F11_wsync_on_wclk`, `ast_F11_rsync_on_rclk` | gclk | A synchronizer stage changes only in a step where its destination clock rises. |
| `ast_F14_rdata_stable_gclk` | gclk | With `rempty = 0`, `rdata` changes only in a step where `rclk` rises. |
| `cov_F15_*`, `cov_F16_rw_at_one`, `cov_F16_rw_at_depth_m1` | gclk | Coincident edges, five-edge bursts of one clock, and an accepted write and read in the same step at fill 1 and DEPTH−1. |

Every simulation property (Runs = both) also runs in formal unchanged.

## 3. Why k-induction closes: the invariants

k-induction assumes the assertions hold for k steps from an *arbitrary* state and asks whether
they hold one step later. With free clocks the window can contain no clock edge at all (T15), so
a deeper window does not help. The fix is to describe the reachable states directly, at every
step, with asserted invariants (`inv_` labels; asserted, never assumed). There are 25. With them,
the proof closes at depth 6 at every size tried. Without them (`prove_noinv`), induction fails on
`ast_F06_wfull_not_optimistic`.

**Notation.** W = `wbin`, R = `rbin` (ASIZE+1 bits, arithmetic modulo 2·DEPTH). rs1/rs2 are the
binary values of `wq1_rptr`/`wq2_rptr` (the read pointer as the write side sees it), and ws1/ws2
are those of `rq1_wptr`/`rq2_wptr`. "a ≤ b from x" compares the modular distances b−x and a−x.

| Invariant | Statement | Why it holds |
|---|---|---|
| `inv_wbin_is_wr_cnt`, `inv_rbin_is_rd_cnt` | W = checker write count, R = read count | Both count accepted operations; T17 shows they agree even at a release edge. This ties every e2e property to the pointers. |
| `inv_wptr_gray`, `inv_rptr_gray` | `wptr` = gray(W), `rptr` = gray(R) at every step | Loaded together from the same `*_next`. |
| `inv_wq1_is_sampled_rd_cnt`, `inv_rq1_is_sampled_wr_cnt` | rs1 = the read count the checker sampled at the latest `wclk` edge (mirror for ws1) | Stage 1 samples `rptr_cdc` at the same edge, in the same view, as the checker's `rd_cnt_at_w`. |
| `inv_w_chain` | rs2 ≤ rs1 ≤ R ≤ W from rs2, and W − rs2 ≤ DEPTH | Each stage holds an older copy of the read pointer, which only moves forward. The writer never gets more than DEPTH ahead of what it has seen. |
| `inv_r_chain` | R ≤ ws2 ≤ ws1 ≤ W from R, and W − R ≤ DEPTH | Mirror: each copy of the write pointer is an older W, never behind R. |
| `inv_wfull_safe` | `wfull` = 0 ⇒ W − rs2 < DEPTH | `wfull` was computed from an older rs2 that is no newer than the current one. This, with the chain, is F06: fill = W − R ≤ W − rs2 < DEPTH. ZipCPU needed "lookahead" flag implications for this; stating safety against the synchronized pointer avoids them. |
| `inv_rempty_safe` | `rempty` = 0 ⇒ ws2 ≠ R | Mirror, and with the chain it is F07. |
| `inv_wq2_settled`, `inv_rq2_settled` | no read for ≥ 2 `wclk` edges ⇒ `wq2_rptr` = `wq1_rptr` (mirror) | Stage 2 copies stage 1, which has not changed. Uses the checker's edge counter `w_after_rd_q`. |
| `inv_wfull_exact`, `inv_rempty_exact` | no read for ≥ 3 `wclk` edges ⇒ `wfull` = (W − rs2 = DEPTH) (mirror) | The flag register was computed from a settled stage 2. This is F08 (K = 3): two synchronizer stages plus the flag register. |
| `inv_no_read_yet` | no read since reset ⇒ both stages are 0 and `wfull` = (W = DEPTH) | Gives F12 (capacity) at every edge. |
| `inv_w_history`, `inv_r_history` | W = (W before the latest edge) + (its accept bit), and the history registers agree with gray coding | The named history registers replace `$past`, so F04, F05 and F09 compare against a constrained value. |
| `inv_tracked_word_in_mem` | tracked index in flight ⇒ it was written, and `mem[idx]` = `f_d1` | Nothing overwrites an unread entry while the FIFO is not optimistic (the chain and flag invariants). |
| `inv_tracked_pair_in_mem` | pair armed and `f_idx+1` in flight ⇒ `mem` = `f_d2` | Same, for the second value. |
| `inv_e2e_edge_counters` | the checker's edge counters stay in 1..K+1 | Saturating counters: values outside are unreachable. |
| `inv_e2e_rd_total` | the saturating read total agrees with the read count until it saturates | Same register update. |
| `inv_e2e_no_read_yet` | no read yet ⇒ the write side sampled read count 0 | No read count other than 0 has ever existed. |
| `inv_e2e_head_held` | `rempty` = 0 and no read at the latest `rclk` edge ⇒ `rdata` = its value at that edge | F14 between edges: the head entry cannot be written while the FIFO is not full. |
| `inv_e2e_pair_after_first` | pair armed ⇒ first value captured | The pair arms only after its first write. **The one invariant added after a failed induction.** At ASIZE 3, `ast_F03_tracked_pair_order` failed from a state with the pair armed and no first value (index 15, pair 15→0). |
| `inv_e2e_first_ok` | first value captured and R = `f_idx`+1 ⇒ the first read came back intact | R reaches `f_idx`+1 only by reading `f_idx`, after it was written. |

Most of these were written from the argument above before the first `prove` run. The induction
counterexample asked for only one more. Reading it needed a trace viewer, so
`common/scripts/vcd2svg.py --table` prints any VCD signals as a step-by-step table.

## 4. Cross-checks

- **PDR.** ABC's PDR proves the same design (invariants included) at ASIZE 2 (102 s) and 3
  (522 s). The plan's test is whether PDR proves something k-induction cannot: it does not, since
  k-induction proves everything. The stronger test is PDR without our invariants (`pdr_noinv`),
  which must build its own. At ASIZE=2 it proves every spec property (303 s), an independent
  confirmation that the result does not depend on the hand-written invariants. At ASIZE=3 it
  timed out at the 30-minute cap, as did plain `pdr` at ASIZE=4. k-induction with the invariants
  takes seconds at every size.
- **Assumption audit (vplan §5).** Dropping A01 or A05 (bmc, spec properties only,
  `--keep-going`) makes many spec assertions fail, F06 and F07 among them, as the plan predicted.
  With A02 dropped, k-induction still passes: **A02 is not needed for any property**. Physically
  it is still required, because an asynchronous release near a clock edge is a recovery/removal
  violation and can go metastable, which neither RTL simulation nor this formal model represents
  (plan R11). Whether the formal assumption is retired is the owner's decision (see vplan §5).
- **Planted bug (preview of M8).** B05 (`rempty_next` from the current instead of the next read
  pointer) fails `bmc` on `ast_F14_rdata_stable_gclk`. The FIFO claims data one edge early, and a
  write lands on the exposed entry between `rclk` edges. `prove` no longer passes. Lesson for M8:
  use `bmc_spec` (no invariants), or an invariant (here `inv_rempty_safe`) is reported instead of
  a spec label. Without the invariants bmc is slow on a correct design: smtbmc assumes the
  assertions already checked at earlier steps, so the invariants prune the search. With them,
  depth 40 takes under a minute at ASIZE=3. Without them, step 21 alone took more than 5 minutes
  at ASIZE=2. Bugs fail early (B05 at step 11), so `bmc_spec` stays at depth 20.

## 5. Comparison with ZipCPU's proof

ZipCPU's "Crossing clock domains with an asynchronous FIFO" (zipcpu.com, 2018-07-06) proves
Cummings' FIFO with the same open-source tools. This section was written after this project's
proof closed, as the plan required.

| Topic | ZipCPU | This project |
|---|---|---|
| Clocks | Each clock is the MSB of a counter that adds an `anyconst` step each formal step: fixed rates, jittery edges | Free clocks (A04): any interleaving, including coincident edges, long gaps and changing ratios. Strictly more general; fine for safety properties. |
| Resets | May start released (`initial assume(wrst_n == rrst_n)`); may be re-asserted later, both together; released on the own clock | Power-up only (A01, A05, DEC-007); release on the own clock (A02), which the audit shows is not needed |
| Inputs | Assumed stable except at the own clock's rising edge (our A03) | Unconstrained; A03 not needed |
| Design | Cummings' modules merged into one file, for induction | Already one module since M1 (plan R7) |
| Flag safety | `f_fill` bounds plus "lookahead" implications (fill = full−1 ⇒ `wfull_next` or no write or `wfull`) | Safety against the synchronized pointer (`inv_wfull_safe`, chains): no lookahead terms |
| Flag exactness | Fill 0 ⇒ `rempty`, fill full ⇒ `wfull` (true state forces the flag) | Also F08: after K = 3 quiet edges the flag is exact, and F12 capacity. This rules out a FIFO with stuck flags. |
| Data | `anyconst` address and two `anyconst` data values; a four-state machine over "first/second in FIFO" | `anyconst` index only; real `wdata` captured, every lap; ordering from "second read follows an intact first" |
| Outputs between edges | Asserts `wfull`, `rempty` stable and `rdata` stable (when not empty) except at the own clock's edge | `rdata` (F14 gclk), crossing nets (F09b) and synchronizer stages (F11); **not** the flags themselves |
| Covers | Two shown (empty rising, full falling) | 22 (vplan §4), all reached |
| Results reported | No depth, engine or runtime given | §6 |

**What this proof missed.** ZipCPU asserts that `wfull` and `rempty` change only at their own
clock's rising edge. This project checks that for the crossing nets, the synchronizer stages and
`rdata`, but not for the flags or the binary pointers. A flag register clocked by the wrong clock
would probably still fail F06, F07 or F08 at some interleaving, but only indirectly. A direct
"flags change only on their own clock" property is a cheap addition (one gclk assertion per
flag). It would need a new vplan row, so it is listed as a proposal, not added.

**What to keep from this project's approach.** Free clocks instead of step counters. Invariants
stated against the synchronized pointers, which are fewer and easier to explain than lookahead
implications. Index-based tracking with captured data instead of `anyconst` data. Spec
properties checked by bmc without the invariants, so failures name a spec label.

**Not covered by either.** Metastability (an ideal flop always resolves). Liveness: neither proof
says a write is eventually accepted. F08's bounded pessimism is this project's substitute: once
the other side is quiet for K edges, the flag is exact.

## 6. Results

See `docs/results.md` for the run table (verdicts and runtimes per size and task).
