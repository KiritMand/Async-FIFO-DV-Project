// async_fifo_e2e_props.sv — end-to-end properties of the async FIFO (vplan §4, kind e2e).
// A checker module whose inputs are only the DUT's ports, so it attaches anywhere: the UVM top,
// the negative-test bench, the M7 formal harness and MCY's mutated netlists. It keeps its own
// counts of accepted writes and reads (the true fill, spec §5) and exports them, so M7 can tie
// them to the internal pointers.
//
// Style (DEC-002; toolchain T14, T15): labeled immediate assertions in blocks clocked by exactly
// one DUT clock. A block clocked by posedge X reads every signal as it was just before that edge
// (spec §5), because all registers here and in the DUT update with non-blocking assignments;
// a register of the other domain that changes at the same instant still shows its old value,
// which is the spec's coincident-edge rule.
// Under `ifdef FORMAL (M7): the formal forms of the asm_ assumptions (initial state and gclk),
// the formal-only properties (vplan Runs = formal), checker-only induction invariants (inv_
// labels), and f_ output ports that export checker state to the white-box invariants in
// rtl/async_fifo_props.svh, which instantiates this checker inside the DUT for formal.
// Formal switches (defines): FORMAL_A02 / FORMAL_A03 add the formal form of A02 / A03 (both off:
// DEC-012 option 1, DEC-011 D2); FORMAL_DROP_A01/A05 drop one assumption for the ledger audit
// (vplan §5).

`default_nettype none

// Action blocks exist only in simulation: Yosys rejects `else` on an immediate assertion (T15).
// asm_ labels are assumptions in formal and assertions on the testbench in simulation (vplan §5).
`ifdef FORMAL
  `define E2E_ELSE(msg)
  `define E2E_ASM assume
`else
  `define E2E_ELSE(msg) else $error msg
  `define E2E_ASM assert
`endif

// The checker. K is the flag pessimism bound of spec §7.4.
module async_fifo_e2e_props #(
  parameter int DSIZE = 8,
  parameter int ASIZE = 4,
  parameter int K     = 3
) (
  input  wire logic             wclk,
  input  wire logic             wrst_n,
  input  wire logic             winc,
  input  wire logic [DSIZE-1:0] wdata,
  input  wire logic             wfull,
  input  wire logic             rclk,
  input  wire logic             rrst_n,
  input  wire logic             rinc,
  input  wire logic [DSIZE-1:0] rdata,
  input  wire logic             rempty,
  output      logic [ASIZE:0]   wr_cnt,  // accepted writes since reset, mod 2*DEPTH (like wbin)
  output      logic [ASIZE:0]   rd_cnt   // accepted reads since reset, mod 2*DEPTH (like rbin)
`ifdef FORMAL
  // Formal-only exports (M7): checker state the white-box induction invariants tie to the DUT.
  ,
  output      logic [ASIZE:0]          f_rd_cnt_at_w,   // rd_cnt as the latest wclk edge sampled it
  output      logic [$clog2(K+2)-1:0]  f_w_after_rd_q,  // wclk edges since the latest read (sat.)
  output      logic [ASIZE:0]          f_wr_cnt_at_r,   // wr_cnt as the latest rclk edge sampled it
  output      logic [$clog2(K+2)-1:0]  f_r_after_wr_q,  // rclk edges since the latest write (sat.)
  output      logic [ASIZE+2:0]        f_rd_total,      // accepted reads, saturating at 4*DEPTH
  output      logic [ASIZE:0]          f_idx,           // tracked write index (anyconst, F02/F03)
  output      logic                    f_have1,         // write f_idx has been accepted
  output      logic [DSIZE-1:0]        f_d1,            // its data (latest lap)
  output      logic                    f_pair,          // write f_idx+1 followed it (F03 armed)
  output      logic [DSIZE-1:0]        f_d2             // data of write f_idx+1 (latest lap)
`endif
);

  // Constants at the width they are compared with (no width warnings, portable to Yosys).
  // FILL_FULL = DEPTH; SAT = K+1, where the edge counters below saturate; TWO_WRAPS = 4*DEPTH.
  localparam int              SW        = $clog2(K + 2);
  localparam logic [ASIZE:0]  FILL_FULL = {1'b1, {ASIZE{1'b0}}};
  localparam logic [SW-1:0]   SAT       = SW'(K + 1);
  localparam logic [SW-1:0]   KV        = SW'(K);
  localparam logic [ASIZE+2:0] TWO_WRAPS = {3'b100, {ASIZE{1'b0}}};

  // ---------------------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------------------

  // Accepted and blocked operations at an edge of their own clock (spec §5).
  wire w_acc = wrst_n && winc && !wfull;
  wire w_blk = wrst_n && winc &&  wfull;
  wire r_acc = rrst_n && rinc && !rempty;
  wire r_blk = rrst_n && rinc &&  rempty;

  // True fill. Read at a wclk edge it counts writes at earlier wclk edges and reads at strictly
  // earlier rclk edges; at an rclk edge, the mirror (spec §5, §7.2). Modulo 2*DEPTH: a correct
  // FIFO stays in [0, DEPTH], and the first overflow or underflow fails ast_F06 or ast_F07 at
  // the very edge where it is accepted, before the count can alias.
  wire [ASIZE:0] fill = wr_cnt - rd_cnt;

  // Accepted-write counter. Reset like the DUT (asynchronous assertion), so it starts at 0 with
  // the power-up reset (A01) and ignores winc while wrst_n = 0 (spec W3).
  always @(posedge wclk or negedge wrst_n)
    if (!wrst_n)    wr_cnt <= '0;
    else if (w_acc) wr_cnt <= wr_cnt + 1'b1;

  // Accepted-read counter, plus a total that saturates at 4*DEPTH (two laps of each pointer,
  // F13); rd_total == 0 also means "no read accepted since reset" (F12).
  logic [ASIZE+2:0] rd_total;
  always @(posedge rclk or negedge rrst_n)
    if (!rrst_n) begin
      rd_cnt   <= '0;
      rd_total <= '0;
    end else if (r_acc) begin
      rd_cnt   <= rd_cnt + 1'b1;
      if (rd_total != TWO_WRAPS) rd_total <= rd_total + 1'b1;
    end

  // Write side's view of the reads (F08). rd_cnt_at_w is rd_cnt at the previous wclk edge, so a
  // difference now means a read was accepted at an rclk edge in [previous wclk edge, this edge).
  // w_after_rd: this edge is the n-th wclk edge strictly after the most recent accepted read
  // (spec §7.4; a read at the same instant as an edge makes the next edge the first), saturating
  // at SAT = K+1, which also stands for "no read since reset".
  logic [ASIZE:0] rd_cnt_at_w;
  logic [SW-1:0]  w_after_rd_q;
  wire            rd_moved_w = (rd_cnt != rd_cnt_at_w);
  wire [SW-1:0]   w_after_rd = rd_moved_w ? SW'(1) : (w_after_rd_q == SAT) ? SAT : w_after_rd_q + 1'b1;
  always @(posedge wclk or negedge wrst_n)
    if (!wrst_n) begin
      rd_cnt_at_w  <= '0;
      w_after_rd_q <= SAT;
    end else begin
      rd_cnt_at_w  <= rd_cnt;
      w_after_rd_q <= w_after_rd;
    end

  // Read side's view of the writes: the mirror of the block above (F08, F14 cover).
  logic [ASIZE:0] wr_cnt_at_r;
  logic [SW-1:0]  r_after_wr_q;
  wire            wr_moved_r = (wr_cnt != wr_cnt_at_r);
  wire [SW-1:0]   r_after_wr = wr_moved_r ? SW'(1) : (r_after_wr_q == SAT) ? SAT : r_after_wr_q + 1'b1;
  always @(posedge rclk or negedge rrst_n)
    if (!rrst_n) begin
      wr_cnt_at_r  <= '0;
      r_after_wr_q <= SAT;
    end else begin
      wr_cnt_at_r  <= wr_cnt;
      r_after_wr_q <= r_after_wr;
    end

  // Read-side history: r_pv is 1 once the previous rclk edge was out of reset, so the history
  // registers hold a real, out-of-reset edge; r_seen_full records that fill has reached DEPTH
  // (F12 cover).
  logic r_pv, r_seen_full;
  always @(posedge rclk or negedge rrst_n)
    if (!rrst_n) begin
      r_pv        <= 1'b0;
      r_seen_full <= 1'b0;
    end else begin
      r_pv        <= 1'b1;
      if (fill == FILL_FULL) r_seen_full <= 1'b1;
    end

  // Edge-to-edge history for F14: what $past would return at the next rclk edge (r_acc and rdata
  // just before the previous edge). Named rather than $past so M7's invariants can constrain them.
  logic             r_acc_q;
  logic [DSIZE-1:0] r_rdata_q;
  always @(posedge rclk) begin
    r_acc_q   <= r_acc;
    r_rdata_q <= rdata;
  end

  // ---------------------------------------------------------------------------------------
  // Write-domain properties (posedge wclk)
  // ---------------------------------------------------------------------------------------

  // In reset: the flag value of spec §8 (F01), and the cover for inputs toggled during reset.
  // Out of reset: flag safety (F06), exactness (F08, F12), and the covers of the write side.
  always @(posedge wclk) begin
    if (!wrst_n) begin
      ast_F01_wfull_low_in_reset: assert (!wfull) `E2E_ELSE(("wfull=1 while wrst_n=0"));
      cov_F01_winc_in_reset: cover (winc);
    end else begin
      // Never optimistic: wfull = 0 implies fill < DEPTH.
      ast_F06_wfull_not_optimistic: assert (wfull || fill < FILL_FULL)
        `E2E_ELSE(("wfull=0 at fill=%0d (DEPTH=%0d)", fill, FILL_FULL));
      // Exact once no read for K edges: this block reads wfull as left by the previous edge, so
      // the check runs from the (K+1)-th edge after the read (state just after the K-th).
      // Spec §7.4 bounds hold while both resets are released.
      if (rrst_n && w_after_rd == SAT)
        ast_F08_wfull_exact: assert (wfull == (fill == FILL_FULL))
          `E2E_ELSE(("wfull=%0b at fill=%0d, no read for > K wclk edges", wfull, fill));
      // Capacity: with no read accepted since reset, wfull is exact at every edge (spec W5); a
      // read side still in reset keeps its pointer at 0, which is the truth (spec §8).
      if (rd_total == '0)
        ast_F12_capacity: assert (wfull == (fill == FILL_FULL))
          `E2E_ELSE(("wfull=%0b at fill=%0d with no read since reset", wfull, fill));

      // Covers: a blocked write at true full; flag lag, and lag still present just after the
      // (K-1)-th edge (K is tight); full reached; F17 writes and full while the reader is in reset.
      cov_F04_blocked_write_at_full: cover (w_blk && fill == FILL_FULL);
      cov_F08_wfull_lag: cover (wfull && fill < FILL_FULL);
      cov_F08_wfull_lag_k_minus_1: cover (rrst_n && w_after_rd == KV && wfull && fill < FILL_FULL);
      cov_F12_full_reached: cover (wfull && fill == FILL_FULL);
      cov_F17_write_during_rd_reset: cover (w_acc && !rrst_n);
      cov_F17_full_before_rd_release: cover (fill == FILL_FULL && !rrst_n);
`ifndef FORMAL
      // A06 (simulation only): inputs are known while out of reset. Two-state simulators
      // cannot produce X, so this can only fire in a four-state simulator (vplan §5).
      asm_A06_w_inputs_known: `E2E_ASM (!$isunknown(winc) && (!winc || !$isunknown(wdata)));
`endif
    end
  end

  // ---------------------------------------------------------------------------------------
  // Read-domain properties (posedge rclk)
  // ---------------------------------------------------------------------------------------

  // The mirror of the write domain, plus show-ahead stability (F14), the wrap cover (F13) and
  // the read-side F12/F17 covers.
  always @(posedge rclk) begin
    if (!rrst_n) begin
      ast_F01_rempty_high_in_reset: assert (rempty) `E2E_ELSE(("rempty=0 while rrst_n=0"));
      cov_F01_rinc_in_reset: cover (rinc);
    end else begin
      // Never optimistic: rempty = 0 implies fill >= 1.
      ast_F07_rempty_not_optimistic: assert (rempty || fill != '0)
        `E2E_ELSE(("rempty=0 at fill=0"));
      // Exact once no write for K edges (same window rule as ast_F08_wfull_exact).
      if (wrst_n && r_after_wr == SAT)
        ast_F08_rempty_exact: assert (rempty == (fill == '0))
          `E2E_ELSE(("rempty=%0b at fill=%0d, no write for > K rclk edges", rempty, fill));
      // Show-ahead: with data present and no read accepted at the previous edge, rdata has not
      // changed since that edge, whatever the write side did meanwhile (spec R3).
      if (r_pv && !rempty && !r_acc_q)
        ast_F14_rdata_stable: assert (rdata == r_rdata_q)
          `E2E_ELSE(("rdata changed from %0h to %0h with no read", r_rdata_q, rdata));

      // Covers: a blocked read at true empty; flag lag and its (K-1)-th-edge tightness; empty
      // again after full; two pointer wraps; rdata held while writes arrive; reader released first.
      cov_F05_blocked_read_at_empty: cover (r_blk && fill == '0);
      cov_F08_rempty_lag: cover (rempty && fill != '0);
      cov_F08_rempty_lag_k_minus_1: cover (wrst_n && r_after_wr == KV && rempty && fill != '0);
      cov_F12_empty_after_full: cover (r_seen_full && fill == '0 && rempty);
      cov_F13_two_wraps: cover (rd_total == TWO_WRAPS);
      cov_F14_hold_while_writing: cover (r_pv && !rempty && !r_acc_q && wr_moved_r && rdata == r_rdata_q);
      cov_F17_rd_released_first: cover (!wrst_n);
`ifndef FORMAL
      // A06 (simulation only), read side.
      asm_A06_r_inputs_known: `E2E_ASM (!$isunknown(rinc));
`endif
    end
  end

  // ---------------------------------------------------------------------------------------
  // Assumptions checked on the testbench (simulation forms; vplan §5)
  // ---------------------------------------------------------------------------------------
`ifndef FORMAL
  // Lint waiver (PROCASSINIT, a -Wall style warning): the bookkeeping below needs time-0 values
  // and has no reset of its own (A05 is about resets); declaration initializers give them.
  /* verilator lint_off PROCASSINIT */
  // Time of the latest rising edge of each clock (-1: none yet). Non-blocking, so it lands in
  // the same update batch as a reset release or input change made at that edge.
  realtime t_wclk_rise = -1.0, t_rclk_rise = -1.0;
  always @(posedge wclk) t_wclk_rise <= $realtime;
  always @(posedge rclk) t_rclk_rise <= $realtime;

  // A01: power-up. At the first rising edge of either clock, both resets are still 0.
  initial begin
    @(posedge wclk or posedge rclk);
    asm_A01_resets_low_at_start: `E2E_ASM (!wrst_n && !rrst_n);
  end

  // A02: each reset rises only in the time step of a rising edge of its own clock.
  always @(posedge wrst_n) asm_A02_wrst_release_on_wclk: `E2E_ASM ($realtime == t_wclk_rise);
  always @(posedge rrst_n) asm_A02_rrst_release_on_rclk: `E2E_ASM ($realtime == t_rclk_rise);

  // A03: from the first edge of their clock on, inputs change only in the time step of a rising
  // edge of that clock (the testbench drives at the edge, DEC-008).
  always @(winc or wdata) if (t_wclk_rise >= 0.0)
    asm_A03_w_inputs_after_wclk: `E2E_ASM ($realtime == t_wclk_rise);
  always @(rinc) if (t_rclk_rise >= 0.0)
    asm_A03_r_inputs_after_rclk: `E2E_ASM ($realtime == t_rclk_rise);

  // A05: once released, a reset never falls again (the flag is set by the release itself).
  logic w_released = 1'b0, r_released = 1'b0;
  always @(posedge wrst_n) w_released <= 1'b1;
  always @(posedge rrst_n) r_released <= 1'b1;
  always @(wrst_n) if (w_released) asm_A05_wrst_stays_released: `E2E_ASM (wrst_n);
  always @(rrst_n) if (r_released) asm_A05_rrst_stays_released: `E2E_ASM (rrst_n);
  /* verilator lint_on PROCASSINIT */
`else
  // =======================================================================================
  // Formal (M7): environment, formal-only properties, checker-only invariants, exports
  // =======================================================================================

  // Global formal step (multiclock on) and its past-valid flag for $past/$rose on step 0.
  (* gclk *) reg f_gclk;
  reg f_pv = 1'b0;
  always @(posedge f_gclk) f_pv <= 1'b1;

  // Environment (vplan §5). A01: both resets asserted in the initial state (power-up).
`ifndef FORMAL_DROP_A01
  initial asm_A01_resets_low_at_start: assume (!wrst_n && !rrst_n);
`endif

  // A02 (off by default, DEC-012 option 1: the M7 audit proved every property without it, so
  // the proof does not rely on it): a reset rises only in a step where its own clock rises, as a
  // reset synchronizer does (toolchain T17). It stays a physical requirement, checked in
  // simulation. A05: once released, a reset stays released (DEC-007).
  always @(posedge f_gclk) if (f_pv) begin
`ifdef FORMAL_A02
    if ($rose(wrst_n)) asm_A02_wrst_release_on_wclk: assume ($rose(wclk));
    if ($rose(rrst_n)) asm_A02_rrst_release_on_rclk: assume ($rose(rclk));
`endif
`ifndef FORMAL_DROP_A05
    if ($past(wrst_n)) asm_A05_wrst_stays_released: assume (wrst_n);
    if ($past(rrst_n)) asm_A05_rrst_stays_released: assume (rrst_n);
`endif
  end

  // A03 (optional, not adopted: DEC-011 D2): inputs change only in a step where their own clock
  // rises. That edge samples the previous step, so the new value is first seen at the next edge.
`ifdef FORMAL_A03
  always @(posedge f_gclk) if (f_pv) begin
    if ($changed(winc) || $changed(wdata)) asm_A03_w_inputs_after_wclk: assume ($rose(wclk));
    if ($changed(rinc)) asm_A03_r_inputs_after_rclk: assume ($rose(rclk));
  end
`endif

  // ---- Tracked writes (F02, F03; the two-value technique). f_idx_c is an arbitrary index
  // mod 2*DEPTH, so every write, in every lap, is a candidate. Write side: capture the data of
  // each accepted write with index f_idx_c (first) and f_idx_c+1 (second); the pair is armed
  // only once a first exists, so it is always two consecutive writes.
  (* anyconst *) reg [ASIZE:0] f_idx_c;
  wire [ASIZE:0]    f_idx2 = f_idx_c + 1'b1;
  logic             f_have1_r, f_pair_r, f_first_ok;
  logic [DSIZE-1:0] f_d1_r, f_d2_r;
  always @(posedge wclk or negedge wrst_n)
    if (!wrst_n) begin
      f_have1_r <= 1'b0;
      f_pair_r  <= 1'b0;
    end else if (w_acc) begin
      if (wr_cnt == f_idx_c)            f_have1_r <= 1'b1;
      if (wr_cnt == f_idx2 && f_have1_r) f_pair_r <= 1'b1;
    end
  always @(posedge wclk)
    if (w_acc) begin
      if (wr_cnt == f_idx_c)             f_d1_r <= wdata;
      if (wr_cnt == f_idx2 && f_have1_r) f_d2_r <= wdata;
    end

  // Read side: remember whether the read of the first tracked index returned its data intact.
  always @(posedge rclk or negedge rrst_n)
    if (!rrst_n)                          f_first_ok <= 1'b0;
    else if (r_acc && rd_cnt == f_idx_c) f_first_ok <= f_have1_r && rdata == f_d1_r;

  // F02: the read with the tracked index returns the tracked data. F03: the read of the second
  // index returns its data, right after the first came back intact (order). Covers: both reached.
  always @(posedge rclk) if (rrst_n) begin
    if (r_acc && rd_cnt == f_idx_c && f_have1_r)
      ast_F02_tracked_word: assert (rdata == f_d1_r);
    if (r_acc && rd_cnt == f_idx2 && f_pair_r)
      ast_F03_tracked_pair_order: assert (f_first_ok && rdata == f_d2_r);
    cov_F02_tracked_word_read: cover (r_acc && rd_cnt == f_idx_c && f_have1_r);
    cov_F03_tracked_pair_read: cover (r_acc && rd_cnt == f_idx2 && f_pair_r && f_first_ok);
  end

  // ---- Every-step properties and covers (clock gclk).
  // Rising-edge run lengths for the burst covers: rising edges of one clock since the latest
  // rising edge of the other, counted only while both resets are released (saturate at 5).
  reg [2:0] f_wburst = 3'd0, f_rburst = 3'd0;
  always @(posedge f_gclk) begin
    if (!wrst_n || !rrst_n || $rose(rclk)) f_wburst <= 3'd0;
    else if ($rose(wclk) && f_wburst != 3'd5) f_wburst <= f_wburst + 3'd1;
    if (!wrst_n || !rrst_n || $rose(wclk)) f_rburst <= 3'd0;
    else if ($rose(rclk) && f_rburst != 3'd5) f_rburst <= f_rburst + 3'd1;
  end

  // F14 every step: with data present, rdata changes only in a step where rclk rises (a write
  // landing on the head entry between rclk edges would show here). F15: coincident edges and
  // five-edge bursts. F16: an accepted write and an accepted read in the same step at fill 1 and
  // DEPTH-1 (the edge samples the previous step, hence $past).
  always @(posedge f_gclk) if (f_pv) begin
    if (!rempty && $changed(rdata)) ast_F14_rdata_stable_gclk: assert ($rose(rclk));
    cov_F15_same_step_edges: cover ($rose(wclk) && $rose(rclk) && wrst_n && rrst_n);
    cov_F15_wclk_burst: cover (f_wburst == 3'd5);
    cov_F15_rclk_burst: cover (f_rburst == 3'd5);
    cov_F16_rw_at_one: cover ($rose(wclk) && $rose(rclk) && $past(w_acc) && $past(r_acc)
                              && $past(fill) == {{ASIZE{1'b0}}, 1'b1});
    cov_F16_rw_at_depth_m1: cover ($rose(wclk) && $rose(rclk) && $past(w_acc) && $past(r_acc)
                                   && $past(fill) == FILL_FULL - 1'b1);
  end

  // ---- Checker-only induction invariants (inv_ labels: proof aids, checked every step;
  // FORMAL_NO_INV removes them, as in rtl/async_fifo_props.svh).
`ifndef FORMAL_NO_INV
  // Edge counters stay in range; rd_total mirrors rd_cnt until it saturates, and "no read yet"
  // means the write side has sampled nothing but 0; F14's history equals rdata while the head
  // entry is held; a pair is armed only after its first write; after the first tracked index was
  // read in a lap, its read came back intact.
  always @(*) begin
    inv_e2e_edge_counters: assert (w_after_rd_q != '0 && w_after_rd_q <= SAT
                                   && r_after_wr_q != '0 && r_after_wr_q <= SAT);
    inv_e2e_rd_total: assert (rd_total <= TWO_WRAPS && (rd_total == TWO_WRAPS || rd_total[ASIZE:0] == rd_cnt));
    if (rd_total == '0) inv_e2e_no_read_yet: assert (rd_cnt_at_w == '0);
    if (r_pv && !rempty && !r_acc_q) inv_e2e_head_held: assert (rdata == r_rdata_q);
    if (f_pair_r) inv_e2e_pair_after_first: assert (f_have1_r);
    if (f_have1_r && rd_cnt == f_idx2) inv_e2e_first_ok: assert (f_first_ok);
  end
`endif

  // Exports for the white-box invariants (rtl/async_fifo_props.svh).
  assign f_rd_cnt_at_w  = rd_cnt_at_w;
  assign f_w_after_rd_q = w_after_rd_q;
  assign f_wr_cnt_at_r  = wr_cnt_at_r;
  assign f_r_after_wr_q = r_after_wr_q;
  assign f_rd_total     = rd_total;
  assign f_idx          = f_idx_c;
  assign f_have1        = f_have1_r;
  assign f_d1           = f_d1_r;
  assign f_pair         = f_pair_r;
  assign f_d2           = f_d2_r;
`endif

endmodule

`undef E2E_ELSE
`undef E2E_ASM

`default_nettype wire
