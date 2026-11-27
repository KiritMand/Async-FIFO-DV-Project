# async_fifo — interview notes

Short answers to the questions this project gets asked, with the evidence for each. Paths are
relative to `ip/async_fifo/`.

---

## Metastability, and why nothing in RTL catches a deleted synchronizer stage (B08)

### The bug

B08 (`bugs/B08_one_sync_stage.patch`) makes the full compare read the first synchronizer stage,
`wq1_rptr`, instead of the second, `wq2_rptr`. The read pointer then crosses into the write domain
through one flop. That flop can go metastable when `rptr` changes close to a `wclk` edge, and its
output feeds the full-flag logic directly. A late-resolving value then has only part of a clock
period, minus the compare logic's delay, before `wfull` captures it. `wq2_rptr` is still in the
RTL, but nothing reads it.

### What the matrix measured

From `docs/bug_matrix.md` (`make bugs`). Simulation is seeds 1–20 of the seven UVM tests, 140 runs;
formal is ASIZE=2.

| Method | B08 result |
|---|---|
| Simulation, scoreboard and test checks only | 0 of 140 runs fail |
| Simulation with every assertion (white-box, e2e, `asm_`) | 0 of 140 runs fail |
| Formal bmc of the spec properties (depth 20) | no failure |
| Formal k-induction with the 25 invariants | **PASS** |
| Coverage | `cov_F08_wfull_lag_k_minus_1`: 1,866 hits on rtl-v1, **0** on B08, unreachable in formal |
| `make cdc` (structural rules) | **FAIL, rule R2**: stage 1 `wq1_rptr` feeds the compare logic |
| `make lint` / `make synth` | fail, but only because `wq2_rptr` is left unread (see below) |

I predicted that `prove` would fail on an invariant. It passes. `wfull`, computed from stage 1,
changes at the same edge where stage 2 copies stage 1, so every invariant written for the
two-stage design still holds. Formal proves the buggy design correct, because in its model it is.

### Why RTL simulation and RTL formal cannot see it

- **RTL simulation is zero-delay and two-valued at a flop.** At a clock edge a flop takes exactly
  the old or the new value of its input. There is no setup/hold window, no resolution time, no
  "in between". A synchronizer stage in RTL is just one clock of delay. Deleting it makes `wfull`
  fall one `wclk` edge sooner after a read. The flag stays conservative (it can still only lag a
  read, never lead it), so the scoreboard and every safety assertion keep passing.
- **Formal on RTL uses the same semantics.** SymbiYosys models each flop as a function of the values
  at the step before the edge. It explores every input sequence, including the clock ratios and
  phases no simulation reaches, but every one of them is metastability-free. B08 is not wrong in
  that model; it is only faster.
- **What does change is latency, and that is visible.** The flag lag bound K = 3 is no longer
  tight. The cover `cov_F08_wfull_lag_k_minus_1` (the flag still lags at the K-th `wclk` edge
  after a read) becomes unreachable. An exact-latency assertion would fail too. But that catches
  the latency change, not the CDC risk, so it is the wrong tool:
  - A safe design with an extra pipeline register after the flag logic has different latency and
    would fail the same check.
  - An unsafe single-stage design with a delay flop added after the compare keeps the latency and
    would pass.
- **Even the proof passes.** The induction invariants describe the two-stage design (for example
  `inv_wfull_safe`: wfull is safe against stage 2), yet B08 keeps them all true. Its `wfull` falls
  exactly when stage 2 catches up with stage 1. k-induction therefore proves B08 correct, and in
  the RTL model it is correct. The flaw exists only in silicon.

### What does catch it

1. **Structural CDC analysis.** Synchronizer-recognition rules on the netlist. `make cdc`
   (`common/scripts/cdc_check.py`) applies three:
   - R1: no logic on a crossing.
   - R2: stage 1 feeds only stage 2.
   - R3: each flop is reset by its own domain's reset.

   B08 breaks R2: `wq1_rptr` feeds the compare logic. Commercial CDC tools apply the same idea
   with many more rules (convergence, reconvergence, multi-bit encoding, reset crossings).
   `make lint` and `make synth` also fail on B08, but only incidentally: lint sees an unused
   signal (`wq2_rptr`), synth a lower flop count. A designer who deleted the flop completely,
   instead of leaving it unread, gets no lint warning. The flop count is specific to this design.
2. **MTBF analysis.** It turns "one stage" into a failure rate (next section).
3. **Timing constraints.** The synchronizer flops are marked `ASYNC_REG`, so the tools place each
   pair close together and leave the stage-to-stage path its full period. The gray bus gets
   `set_max_delay -datapath_only` (one source period) or `set_bus_skew`, so the bits arrive within
   one source period of each other (plan R12, the example constraints file in M10).

### MTBF: how much one stage costs

For one synchronizer, MTBF = e^(S/τ) / (T_W · f_clk · f_data):
- **S** is the settling time the metastable flop gets before its output is used.
- **τ** is the flop's resolution time constant.
- **T_W** is its metastability window.
- **f_data** is how often the synchronized signal changes. Here that is the pointer update rate,
  taken as one change per source edge, the worst case.

With one stage, the compare logic sits between the metastable flop and the next capture:
S = T_clk − t_pd − t_logic. With n ≥ 2 stages, each stage-to-stage path has no logic:
S = (n − 1)(T_clk − t_pd).

`python3 common/scripts/mtbf.py --markdown` with **illustrative** values (τ = 20 ps, T_W = 50 ps,
t_pd = 100 ps, t_logic = 600 ps; these are not a characterization of any library or FPGA):

| f_clk | 1 stage | 2 stages | 3 stages |
|---|---|---|---|
| 250 MHz | 1e58 years | 1e71 years | 1e155 years |
| 500 MHz | 1e14 years | 1e27 years | 1e68 years |
| 800 MHz | 7.61 h | 1e10 years | 1e35 years |
| 1000 MHz | 0.0654 s | 2.21e+04 years | 1e24 years |

Sensitivity at 800 MHz (`--fclk-mhz 800 --tau-ps <τ>`), as at a slow process, voltage or
temperature corner:

| τ | 1 stage | 2 stages | 3 stages |
|---|---|---|---|
| 10 ps | 1e9 years | 1e35 years | 1e85 years |
| 20 ps | 7.61 h | 1e10 years | 1e35 years |
| 40 ps | 0.0293 s | 26.6 h | 1e10 years |

How to read it:
- **MTBF is exponential in the slack.** At 250 MHz even one stage looks safe on paper. Near the
  clock's limit, the logic delay eats the settling time, and one stage fails every 65 ms at 1 GHz,
  while two stages last about 22,000 years.
- **Designs don't rely on the slow case.** τ grows at low voltage and temperature: doubling it
  turns two stages at 800 MHz from 10¹⁰ years into a day. A chip has many synchronizers, and the
  requirement is set by units shipped × lifetime, not by one part on a bench. The second stage
  buys margin across corners; a third is added at high clock rates or for long lifetimes.
- **Use real numbers before quoting one.** Replace τ and T_W with vendor characterization; FPGA
  tools report synchronizer MTBF from their own data.

### One-line answers

- *Why two flops?* Stage 1 may go metastable. Stage 2 gives it a full clock period, with no logic
  in between, to resolve before anything uses the value. MTBF grows exponentially with that time.
- *Why gray code?* A synchronizer captures each bit independently. When at most one bit changes
  per source edge, any capture is the old or the new pointer, never a mix. B07 sends the binary
  pointer instead: in RTL it passes every end-to-end check, and only the source-side one-bit
  assertion (`ast_F09_wptr_cdc_one_bit`) fails.
- *Why can't simulation find metastability bugs?* RTL flops have no timing window; every capture
  is clean. Metastability is a physical effect. It is handled by structure (CDC rules), statistics
  (MTBF) and constraints (timing), not by functional checks.
