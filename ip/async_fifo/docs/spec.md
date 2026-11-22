# async_fifo — Behavioral specification

**Version** 1.0 · **Date** 2026-11-22 · **Status** APPROVED (owner, 2026-11-22) ·
**RTL** `rtl/async_fifo.sv`, baseline tag `rtl-v1` (written by Claude in FAST MODE, 2026-11-22; lint, synth and smoke clean)

This document is the contract every checker is written against: the scoreboard (M3), the
assertions (M6), the formal properties (M7), and the judgments on planted bugs and mutants
(M8–M9). If the RTL and this document disagree, one of them is wrong, and the disagreement is
settled explicitly. Checkers never silently follow the RTL.

Requirement IDs (`F01…`) are assigned in `docs/vplan.md` (M2). Assumption IDs (`A01…`) match
the draft ledger in plan M2. Paths are relative to `ip/async_fifo/`.

---

## 1. Overview

A dual-clock FIFO. Data is written in the `wclk` domain and read in the `rclk` domain. The two
clocks have no frequency or phase relationship.

The architecture is Cummings, SNUG 2002, style #1:
- Each domain keeps its own pointer in two forms, binary and gray.
- Only the gray pointers cross between domains, each through a two-flop synchronizer clocked
  and reset by the destination domain.
- Each flag is computed in its own domain from that domain's pointer and the synchronized
  pointer of the other domain. The synchronized pointer is always old, so the flags are
  conservative (§7).

## 2. Parameters

| Name | Legal values | RTL default | Meaning |
|---|---|---|---|
| `ASIZE` | ≥ 2 | 4 | Address bits |
| `DSIZE` | ≥ 1 | 8 | Data bits per entry |
| `DEPTH` | `1 << ASIZE` (derived `localparam`) | 16 | Number of entries; powers of two only |

- **Why ASIZE ≥ 2.** The standard full comparison inverts the two MSBs of the gray pointer and
  compares the remaining bits `[ASIZE-2:0]`. At ASIZE = 1 that slice is empty, and depth 2
  would need a special case.
- **Elaboration checks.** ASIZE < 2 and DSIZE < 1 must each stop elaboration with an error in
  both Verilator and Yosys. Without its guard, DSIZE = 0 would quietly build 2-bit `[-1:0]`
  vectors in Yosys. `make lint` (Verilator) and `make synth` (Yosys) check that ASIZE = 1 and
  DSIZE = 0 are rejected, each with its own guard's message.
- **Configurations used.** Simulation: ASIZE = 4, DSIZE = 8. Formal and MCY: ASIZE = 2..3,
  DSIZE = 4.

## 3. Ports

Ports are connected by name; their order is not specified.

| Port | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `wclk` | in | 1 | — | Write clock |
| `wrst_n` | in | 1 | async assert, release synchronous to `wclk` | Write-domain reset, active low |
| `winc` | in | 1 | `wclk` | Write request |
| `wdata` | in | DSIZE | `wclk` | Write data, sampled together with `winc` |
| `wfull` | out | 1 | `wclk`, registered | Full flag (§7) |
| `rclk` | in | 1 | — | Read clock |
| `rrst_n` | in | 1 | async assert, release synchronous to `rclk` | Read-domain reset, active low |
| `rinc` | in | 1 | `rclk` | Read request (pop) |
| `rdata` | out | DSIZE | `rclk`, combinational from memory | Show-ahead head entry (§6) |
| `rempty` | out | 1 | `rclk`, registered | Empty flag (§7) |

Inputs are synchronous to their own domain's clock and meet setup and hold there. The FIFO does
not synchronize its inputs.

## 4. Clocks

- `wclk` and `rclk` may have any frequency ratio and any phase, including edges that
  coincide.
- Simulation sweeps wclk:rclk from 1:4 to 4:1 at random phase.
- Formal leaves the clocks unconstrained (A04): any interleaving of edges, simultaneous ones
  included.
- No minimum throughput is required. The only liveness requirement is bounded pessimism
  (§7.4).

## 5. Definitions

Signal values "at an edge" are the values present just before that edge, which is what a
flip-flop clocked by that edge samples.

- **Accepted write.** A `posedge wclk` at which `wrst_n = 1`, `winc = 1` and `wfull = 0`. It
  stores the `wdata` present at that edge.
- **Blocked write.** A `posedge wclk` at which `wrst_n = 1`, `winc = 1` and `wfull = 1`.
- **Accepted read.** A `posedge rclk` at which `rrst_n = 1`, `rinc = 1` and `rempty = 0`. It
  pops the entry that `rdata` presents at that edge.
- **Blocked read.** A `posedge rclk` at which `rrst_n = 1`, `rinc = 1` and `rempty = 1`.
- **Fill** (true fill). Accepted writes minus accepted reads since reset, computed by a
  reference model. It is never derived from the DUT's flags.
- **Coincident edges.** When an edge of one clock is evaluated, events at the *same instant* on
  the other clock are **not** counted, unless a rule says otherwise. This gives the strongest
  form of the safety rules in §7.2: the design may never rely on an event in the other domain
  at the same instant.

## 6. Write and read behavior

### 6.1 Write

- **W1.** An accepted write stores `wdata` as the newest entry and increases fill by 1.
- **W2.** A blocked write is ignored. Nothing is stored, no stored entry changes, and the
  write-side state does not change.
- **W3.** `winc` is ignored while `wrst_n = 0`.
- **W4.** At most one write per `wclk` edge. Writes may be accepted on every edge while
  `wfull = 0`.
- **W5 — capacity.** Starting from an empty FIFO with no reads, exactly DEPTH writes are
  accepted. The next attempt is blocked.

### 6.2 Read (show-ahead)

- **R1.** While `rempty = 0`, `rdata` presents the oldest unread entry: the `wdata` of the
  earliest accepted write that has not been popped.
- **R2.** An accepted read pops that entry. The value read is the `rdata` present at that
  edge. Immediately after the edge, if `rempty = 0`, `rdata` presents the next entry.
- **R3 — stability.** While `rempty = 0` and no read is accepted, `rdata` does not change.
  Write-side activity never disturbs it.
- **R4.** A blocked read is ignored. The read-side state does not change.
- **R5.** `rinc` is ignored while `rrst_n = 0`.
- **R6.** `rdata` is don't-care while `rempty = 1`. It may show stale data or data being
  written, and checkers must not compare it then.
- **R7.** `rdata` is a combinational read of the memory; there is no output register. A
  monitor samples `rdata` at the same `rclk` edge at which it sees `rinc && !rempty` (M3).

Together W1–W2 and R1–R4 give integrity and order. Every accepted write is read exactly once,
unmodified, in first-in, first-out order.

## 7. Flags

### 7.1 Form

`wfull` is a flip-flop in the `wclk` domain and `rempty` a flip-flop in the `rclk` domain. No
combinational path runs from any input to a flag.

### 7.2 Never optimistic (safety)

- **Full side.** At every `posedge wclk` with `wrst_n = 1`, if `wfull = 0` then fill < DEPTH.
  Here fill counts writes at earlier `wclk` edges and reads at strictly earlier `rclk` edges
  (§5). Consequence: fill never exceeds DEPTH (no overflow), and no unread entry is ever
  overwritten.
- **Empty side.** At every `posedge rclk` with `rrst_n = 1`, if `rempty = 0` then fill ≥ 1.
  Here fill counts reads at earlier `rclk` edges and writes at strictly earlier `wclk` edges.
  Consequence: no underflow, and a popped value is always real data.

A flag must reflect its own side's operation at once. A write that fills the FIFO, as the
write side sees it, sets `wfull` at that same edge. A read that empties the FIFO sets `rempty`
at that same edge. Otherwise the next edge could accept an operation that breaks the rules
above.

### 7.3 Pessimism is allowed

`wfull` may stay 1 after reads have freed space. `rempty` may stay 1 after writes have added
data. Checkers must not treat this as an error, except beyond the bound in §7.4.

### 7.4 Bounded pessimism

**K = 3** for `rtl/async_fifo.sv`. It is derived below and measured by `make smoke`.

Derivation, full side (the empty side mirrors it):
1. A read accepted at `rclk` edge t_r loads the new `rptr` at t_r.
2. The 1st `wclk` edge strictly after t_r copies it into `wq1_rptr`.
3. The 2nd copies it into `wq2_rptr`.
4. The 3rd loads `wfull` from `wfull_next`, which now compares against the new pointer.

A `wclk` edge that coincides with t_r samples the old `rptr` and does not count (§5).
K = two synchronizer stages + one flag register = 3. Changing either the synchronizer depth or
the flag register changes K.

- **Full side.** Let t_r be the most recent accepted read. Suppose t is the K-th or a later
  `posedge wclk` strictly after t_r, and no read is accepted in (t_r, t]. Then just after t,
  `wfull = 1` if and only if fill = DEPTH. That fill includes the write accepted at t, if any.
  If no read has been accepted since reset, `wfull` is exact after every `wclk` edge.
- **Empty side.** Let t_w be the most recent accepted write. Suppose t is the K-th or a later
  `posedge rclk` strictly after t_w, and no write is accepted in (t_w, t]. Then just after t,
  `rempty = 1` if and only if fill = 0. That fill includes the read accepted at t, if any.
- Both bounds apply only while both resets are released.
- K holds in RTL simulation and in formal, where nothing models metastability. In silicon, a
  first synchronizer stage that goes metastable may resolve to the old value, which adds one
  destination edge (K + 1). Because the pointer is gray, it always resolves to the old pointer
  or the new one, never to some other value.

## 8. Reset

- Both resets are active low, with asynchronous assertion.
- **A02.** Each reset is released synchronously to its own clock. The reset synchronizers are
  outside the FIFO and are the integrator's responsibility.
- **A01.** Both resets are asserted together at time 0 (power-up). After that they may be
  released at different times, in either order. A side that is out of reset sees the other
  side's pointer as zero, which is correct, because that pointer is zero.

Register values while each reset is asserted:

| Reset | Registers cleared to 0 | Flag value |
|---|---|---|
| `wrst_n = 0` | `wbin`, `wptr`, `wq1_rptr`, `wq2_rptr` | `wfull = 0` |
| `rrst_n = 0` | `rbin`, `rptr`, `rq1_wptr`, `rq2_wptr` | `rempty = 1` |

- **Memory.** The memory is not reset, and its contents after reset are unspecified. Nobody
  can observe them, because `rempty = 1` until an entry has been written.
- **Out of scope.** Asserting either reset on its own after time 0, i.e. independent resets
  in the middle of operation (roadmap E4). Behavior is undefined.

## 9. CDC structure

- **C1. What crosses.** Exactly two signal groups cross: the gray write pointer into the read
  domain, and the gray read pointer into the write domain. Nothing else crosses: no binary
  pointer, no flag, no reset.
- **C2. Synchronizers.** Each pointer passes through exactly two flip-flops, clocked by the
  destination clock and reset by the destination reset: `wptr → rq1_wptr → rq2_wptr`
  (`rclk`, `rrst_n`) and `rptr → wq1_rptr → wq2_rptr` (`wclk`, `wrst_n`). The destination
  logic uses only the second stage.
- **C3. Crossing nets.** The first synchronizer stage is driven only by a named wire,
  `wptr_cdc` or `rptr_cdc`. That wire is driven directly by the source gray pointer register
  (`wptr` or `rptr`), with no logic in between. So each crossing net changes only at
  source-clock edges and never glitches.
- **C4. Gray property.** Each crossing net changes in at most one bit per source-clock edge,
  and only on an edge with an accepted operation.
- **C5. Memory data path.** The memory is written on `wclk` and read combinationally in the
  `rclk` domain. This path is safe by protocol:
  - An entry is written at the same `wclk` edge that advances `wptr`.
  - The read side can see that entry only after the new pointer has passed through its
    synchronizer.
  - So whenever `rdata` is valid it is already stable.

  A structural CDC tool will report this path; this protocol is the justification.
- **C6.** All four synchronizer registers carry `(* ASYNC_REG = "TRUE" *)`.

## 10. Implementation requirements

Later modules depend on these structural choices.

- **One module, `async_fifo`, with no sub-module instances.** Open-source Yosys cannot
  reference signals inside sub-modules, and the white-box properties and induction invariants
  (M6–M7) need the pointers and synchronizer flops.
- **Language subset.** Synthesizable SystemVerilog accepted by both `yosys read_verilog -sv`
  and `verilator --lint-only`: `logic`, `always_ff`/`always_comb`, `localparam`. No
  interfaces, structs or packages on the ports.
- **Pointers.** All pointers are ASIZE+1 bits wide. They wrap modulo 2·DEPTH, and the extra
  MSB tells full apart from empty. Behavior must not depend on how many times the pointers
  have wrapped.
- **Gray invariant.** Out of reset, `wptr == gray(wbin)` and `rptr == gray(rbin)` at all
  times, where `gray(x) = (x >> 1) ^ x`.
- **Memory.** DEPTH × DSIZE. It is written at `wbin[ASIZE-1:0]` on an accepted write only, so
  the write enable is gated by `!wfull`. It is read combinationally at `rbin[ASIZE-1:0]`. The
  array's name is free; `mem` is suggested.
- **Internal names.** Properties refer to these internal names, so the names are fixed:

| Signal | Width | Clock / reset | Kind | Purpose |
|---|---|---|---|---|
| `wbin` | ASIZE+1 | `wclk` / `wrst_n` | reg | Binary write pointer; low ASIZE bits are the write address |
| `wptr` | ASIZE+1 | `wclk` / `wrst_n` | reg | Gray write pointer |
| `wptr_cdc` | ASIZE+1 | — | wire | `= wptr`; the only driver of `rq1_wptr` |
| `rq1_wptr` | ASIZE+1 | `rclk` / `rrst_n` | reg, ASYNC_REG | Synchronizer stage 1 |
| `rq2_wptr` | ASIZE+1 | `rclk` / `rrst_n` | reg, ASYNC_REG | Stage 2; the only write-pointer value the read logic uses |
| `rbin` | ASIZE+1 | `rclk` / `rrst_n` | reg | Binary read pointer; low ASIZE bits are the read address |
| `rptr` | ASIZE+1 | `rclk` / `rrst_n` | reg | Gray read pointer |
| `rptr_cdc` | ASIZE+1 | — | wire | `= rptr`; the only driver of `wq1_rptr` |
| `wq1_rptr` | ASIZE+1 | `wclk` / `wrst_n` | reg, ASYNC_REG | Synchronizer stage 1 |
| `wq2_rptr` | ASIZE+1 | `wclk` / `wrst_n` | reg, ASYNC_REG | Stage 2; the only read-pointer value the write logic uses |
| `wfull` | 1 | `wclk` / `wrst_n` | reg | Full flag (port) |
| `rempty` | 1 | `rclk` / `rrst_n` | reg | Empty flag (port) |

- **Flop count.** Expect `8·(ASIZE+1) + 2` flip-flops outside the memory as written: 26 at
  ASIZE = 2, 34 at ASIZE = 3, 42 at ASIZE = 4 (counted after `proc`, before optimization).
  After `synth`, Yosys shows two fewer, `8·(ASIZE+1)`. The gray MSB always equals the binary
  MSB, so it folds `wptr[ASIZE]` into `wbin[ASIZE]` and `rptr[ASIZE]` into `rbin[ASIZE]`
  (`docs/toolchain.md`). `make synth` checks the pre-optimization count.
- **Verification hook.** There is exactly one, just before `endmodule`:

  ```systemverilog
  `ifdef ASYNC_FIFO_PROPS
    `include "async_fifo_props.svh"   // white-box properties (M6/M7); absent from normal builds
  `endif
  ```

## 11. Implementation notes (outside the RTL)

- **Synthesis attributes.** `ASYNC_REG` keeps each synchronizer pair together in one slice
  and tells the tools these flops may go metastable. It also excludes them from
  shift-register extraction.
- **Timing constraints (M10, `constraints/async_fifo.xdc`).** The gray pointer paths
  `wptr → rq1_wptr` and `rptr → wq1_rptr` need `set_max_delay -datapath_only` and/or
  `set_bus_skew`. They keep all bits of one pointer update arriving within one destination
  period of each other, so the destination never samples a mix of two non-adjacent pointer
  values. M10 chooses the values.

## 12. Out of scope (backlog, plan §7)

- Almost-full or almost-empty flags, programmable thresholds, fill-level outputs.
- Depths that are not a power of two; depth 2 (ASIZE = 1).
- A registered read port (`rdata` from a flip-flop, with one cycle of read latency).
- Independent or mid-operation resets (roadmap E4).
- Reset synchronizers. They are the integrator's job; see A02.
- Inputs that violate setup or hold in their own domain, and X on inputs.
- A configurable number of synchronizer stages.

## 13. Open items (all closed)

- [x] K = 3 (§7.4), derived from the RTL. `make smoke` measures exactly 3 edges in both
      directions at ratios 1:3, 3:1, 1:1, 2:3, 4:1 and 1:4, at ASIZE 2, 3 and 4.
- [x] The coincident-edge convention (§5): **confirmed by the owner, 2026-11-22.** Evidence:
  - In the RTL, a synchronizer flop clocked at the same instant as the source pointer update
    samples the old pointer (non-blocking semantics).
  - `make smoke` at integer ratios puts every slow-clock edge on a fast-clock edge, and the
    latency there is still exactly K.
- [x] The wording of W5 (capacity) and R3 (`rdata` stability): **confirmed by the owner,
      2026-11-22.** Both become vplan rows (plan M2: F12, F14).
  - W5: `make smoke` checks `wfull` is exact at every edge of a fill and rises with the
    DEPTH-th write.
  - R3: `rdata` is checked against the model head at every `rclk` negedge, including while the
    write side is filling.

## Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-11-22 | Claude | First draft (M1 step 2) |
| 0.2 | 2026-11-22 | Claude | K = 3 with derivation (§7.4); flop count before/after optimization (§10); open items updated with smoke evidence |
| 0.3 | 2026-11-22 | Claude | DSIZE < 1 elaboration check added to §2 (M1 step 7, review finding) |
| 1.0 | 2026-11-22 | Owner | Approved: §5 coincident-edge convention and §6 W5/R3 wording confirmed; §13 closed |

## Reference

C. E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design",
SNUG San Jose 2002 (style #1).
