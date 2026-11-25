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
// Formal-only properties (vplan Runs = formal) and the formal (gclk) forms of the asm_A02/A03/A05
// checks are added in M7 under `ifdef FORMAL`.

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

  // Read-side history: r_pv is 1 once the previous rclk edge was out of reset, so $past refers
  // to a real, out-of-reset edge; r_seen_full records that fill has reached DEPTH (F12 cover).
  logic r_pv, r_seen_full;
  always @(posedge rclk or negedge rrst_n)
    if (!rrst_n) begin
      r_pv        <= 1'b0;
      r_seen_full <= 1'b0;
    end else begin
      r_pv        <= 1'b1;
      if (fill == FILL_FULL) r_seen_full <= 1'b1;
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
      if (r_pv && !rempty && !$past(r_acc))
        ast_F14_rdata_stable: assert (rdata == $past(rdata))
          `E2E_ELSE(("rdata changed from %0h to %0h with no read", $past(rdata), rdata));

      // Covers: a blocked read at true empty; flag lag and its (K-1)-th-edge tightness; empty
      // again after full; two pointer wraps; rdata held while writes arrive; reader released first.
      cov_F05_blocked_read_at_empty: cover (r_blk && fill == '0);
      cov_F08_rempty_lag: cover (rempty && fill != '0);
      cov_F08_rempty_lag_k_minus_1: cover (wrst_n && r_after_wr == KV && rempty && fill != '0);
      cov_F12_empty_after_full: cover (r_seen_full && fill == '0 && rempty);
      cov_F13_two_wraps: cover (rd_total == TWO_WRAPS);
      cov_F14_hold_while_writing: cover (r_pv && !rempty && !$past(r_acc) && wr_moved_r && rdata == $past(rdata));
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
`endif

endmodule

`undef E2E_ELSE
`undef E2E_ASM

`default_nettype wire
