// async_fifo_props.svh — white-box properties of async_fifo (vplan §4, kind white-box).
// Included at the end of the RTL module when ASYNC_FIFO_PROPS is defined, so it sees the
// internal names of spec §10 directly: open-source Yosys has no bind and no hierarchical
// references (plan R5, toolchain T18). Same style as sva/async_fifo_e2e_props.sv: labeled
// immediate assertions in blocks clocked by one DUT clock, reading values as they were just
// before the edge. Under `ifdef FORMAL (M7) it also holds the formal harness: the global step,
// the e2e checker instance, the formal-only white-box properties (F09 off-edge stability, F11)
// and the induction invariants (inv_ labels). Names added here start with p_ so they never clash
// with the RTL.

// Action blocks exist only in simulation: Yosys rejects `else` on an immediate assertion (T15).
`ifdef FORMAL
  `define AFP_ELSE(msg)
`else
  `define AFP_ELSE(msg) else $error msg
`endif

  // True when a pointer moved by at most one bit: d is the XOR of its old and new values.
  function automatic logic p_one_bit_at_most(input logic [ASIZE:0] d);
    p_one_bit_at_most = ((d & (d - 1'b1)) == '0);
  endfunction

  // Past-valid flags, one per domain: 1 once the previous edge of that clock was out of reset,
  // so the history registers below hold a real, out-of-reset edge (the first edge after release
  // is skipped).
  logic p_wpv, p_rpv;
  always @(posedge wclk or negedge wrst_n) if (!wrst_n) p_wpv <= 1'b0; else p_wpv <= 1'b1;
  always @(posedge rclk or negedge rrst_n) if (!rrst_n) p_rpv <= 1'b0; else p_rpv <= 1'b1;

  // Edge-to-edge history of the write domain: each register holds what $past would return at
  // the next wclk edge (the value just before the previous edge). Named rather than $past so the
  // M7 induction invariants can constrain them (toolchain T15).
  logic           p_wblk_q, p_wacc_q;
  logic [ASIZE:0] p_wbin_q, p_wptr_q, p_wcdc_q;
  always @(posedge wclk) begin
    p_wblk_q <= winc && wfull;
    p_wacc_q <= winc && !wfull;
    p_wbin_q <= wbin;
    p_wptr_q <= wptr;
    p_wcdc_q <= wptr_cdc;
  end

  // Edge-to-edge history of the read domain (mirror of the block above).
  logic           p_rblk_q, p_racc_q;
  logic [ASIZE:0] p_rbin_q, p_rptr_q, p_rcdc_q;
  always @(posedge rclk) begin
    p_rblk_q <= rinc && rempty;
    p_racc_q <= rinc && !rempty;
    p_rbin_q <= rbin;
    p_rptr_q <= rptr;
    p_rcdc_q <= rptr_cdc;
  end

  // Write domain (posedge wclk): gray/binary consistency at every edge (F10); reset values (F01);
  // then, edge to edge: a blocked write holds the pointer (F04), and the crossing net moves by at
  // most one bit and only after an accepted write (F09, a source-side property, plan R10).
  always @(posedge wclk) begin
    ast_F10_wptr_is_gray_of_wbin: assert (wptr == ((wbin >> 1) ^ wbin))
      `AFP_ELSE(("wptr=%0h is not gray(wbin=%0h)", wptr, wbin));
    if (!wrst_n) begin
      ast_F01_wside_regs_zero: assert (wbin == '0 && wptr == '0 && wq1_rptr == '0 && wq2_rptr == '0)
        `AFP_ELSE(("in reset: wbin=%0h wptr=%0h wq1_rptr=%0h wq2_rptr=%0h", wbin, wptr, wq1_rptr, wq2_rptr));
    end else if (p_wpv) begin
      if (p_wblk_q)
        ast_F04_blocked_write_holds_wptr: assert (wbin == p_wbin_q && wptr == p_wptr_q)
          `AFP_ELSE(("blocked write moved wbin %0h->%0h", p_wbin_q, wbin));
      ast_F09_wptr_cdc_one_bit: assert (p_one_bit_at_most(wptr_cdc ^ p_wcdc_q))
        `AFP_ELSE(("wptr_cdc %0h->%0h changed more than one bit", p_wcdc_q, wptr_cdc));
      ast_F09_wptr_cdc_moves_on_write: assert (wptr_cdc == p_wcdc_q || p_wacc_q)
        `AFP_ELSE(("wptr_cdc %0h->%0h without an accepted write", p_wcdc_q, wptr_cdc));
    end
  end

  // Read domain (posedge rclk): the mirror of the write domain (F10, F01, F05, F09).
  always @(posedge rclk) begin
    ast_F10_rptr_is_gray_of_rbin: assert (rptr == ((rbin >> 1) ^ rbin))
      `AFP_ELSE(("rptr=%0h is not gray(rbin=%0h)", rptr, rbin));
    if (!rrst_n) begin
      ast_F01_rside_regs_zero: assert (rbin == '0 && rptr == '0 && rq1_wptr == '0 && rq2_wptr == '0)
        `AFP_ELSE(("in reset: rbin=%0h rptr=%0h rq1_wptr=%0h rq2_wptr=%0h", rbin, rptr, rq1_wptr, rq2_wptr));
    end else if (p_rpv) begin
      if (p_rblk_q)
        ast_F05_blocked_read_holds_rptr: assert (rbin == p_rbin_q && rptr == p_rptr_q)
          `AFP_ELSE(("blocked read moved rbin %0h->%0h", p_rbin_q, rbin));
      ast_F09_rptr_cdc_one_bit: assert (p_one_bit_at_most(rptr_cdc ^ p_rcdc_q))
        `AFP_ELSE(("rptr_cdc %0h->%0h changed more than one bit", p_rcdc_q, rptr_cdc));
      ast_F09_rptr_cdc_moves_on_read: assert (rptr_cdc == p_rcdc_q || p_racc_q)
        `AFP_ELSE(("rptr_cdc %0h->%0h without an accepted read", p_rcdc_q, rptr_cdc));
    end
  end

`ifdef FORMAL
  // =======================================================================================
  // Formal harness (M7; formal/async_fifo.sby). Everything below exists only under FORMAL.
  // =======================================================================================

  // Global formal step (multiclock on: wclk and rclk are free inputs sampled every step, A04)
  // and its past-valid flag for $past/$changed/$rose on the first step.
  (* gclk *) reg p_gclk;
  reg p_fpv = 1'b0;
  always @(posedge p_gclk) p_fpv <= 1'b1;

  // The e2e checker, instantiated here so the formal top is async_fifo itself. Its f_ outputs
  // export the checker state that the invariants below tie to the DUT internals (no hierarchical
  // references in open-source Yosys, T18). P_K is the flag bound of spec §7.4.
  localparam int P_K  = 3;
  localparam int P_SW = $clog2(P_K + 2);
  logic [ASIZE:0]   p_wr_cnt, p_rd_cnt, p_rd_cnt_at_w, p_wr_cnt_at_r, p_idx;
  logic [P_SW-1:0]  p_w_after_rd_q, p_r_after_wr_q;
  logic [ASIZE+2:0] p_rd_total;
  logic             p_have1, p_pair;
  logic [DSIZE-1:0] p_d1, p_d2;
  async_fifo_e2e_props #(.DSIZE(DSIZE), .ASIZE(ASIZE), .K(P_K)) p_e2e (
    .wclk, .wrst_n, .winc, .wdata, .wfull, .rclk, .rrst_n, .rinc, .rdata, .rempty,
    .wr_cnt(p_wr_cnt), .rd_cnt(p_rd_cnt),
    .f_rd_cnt_at_w(p_rd_cnt_at_w), .f_w_after_rd_q(p_w_after_rd_q),
    .f_wr_cnt_at_r(p_wr_cnt_at_r), .f_r_after_wr_q(p_r_after_wr_q), .f_rd_total(p_rd_total),
    .f_idx(p_idx), .f_have1(p_have1), .f_d1(p_d1), .f_pair(p_pair), .f_d2(p_d2)
  );

  // Formal-only white-box properties (vplan §4, Runs = formal, clock gclk): the crossing nets
  // (F09b) and the synchronizer stages (F11) change only in a step where their clock rises.
  always @(posedge p_gclk) if (p_fpv) begin
    if ($changed(wptr_cdc)) ast_F09_wptr_cdc_stable_off_edge: assert ($rose(wclk));
    if ($changed(rptr_cdc)) ast_F09_rptr_cdc_stable_off_edge: assert ($rose(rclk));
    if ($changed(wq1_rptr) || $changed(wq2_rptr)) ast_F11_wsync_on_wclk: assert ($rose(wclk));
    if ($changed(rq1_wptr) || $changed(rq2_wptr)) ast_F11_rsync_on_rclk: assert ($rose(rclk));
  end

  // ---- Induction invariants: proof aids, asserted (never assumed), checked at every step.
  // FORMAL_NO_INV removes them (tasks prove_noinv/pdr_noinv: are they needed, and does PDR find
  // its own?).
`ifndef FORMAL_NO_INV

  // Binary value of a gray code (inverse of (b >> 1) ^ b).
  function automatic logic [ASIZE:0] p_gray2bin(input logic [ASIZE:0] g);
    p_gray2bin = g;
    for (int s = 1; s <= ASIZE; s++) p_gray2bin = p_gray2bin ^ (g >> s);
  endfunction

  // Pointer values each domain has seen of the other (binary), and the modular distances the
  // invariants compare: every pointer copy lies between the reader and the writer, in order.
  localparam logic [ASIZE:0] P_DEPTH = {1'b1, {ASIZE{1'b0}}};
  wire [ASIZE:0] p_rs1 = p_gray2bin(wq1_rptr), p_rs2 = p_gray2bin(wq2_rptr);
  wire [ASIZE:0] p_ws1 = p_gray2bin(rq1_wptr), p_ws2 = p_gray2bin(rq2_wptr);
  wire [ASIZE:0] p_w_rs1 = p_rs1 - p_rs2, p_w_r = rbin - p_rs2, p_w_w = wbin - p_rs2;
  wire [ASIZE:0] p_r_ws2 = p_ws2 - rbin, p_r_ws1 = p_ws1 - rbin, p_r_w = wbin - rbin;

  // Index of the second tracked write (F03).
  wire [ASIZE:0] p_idx2 = p_idx + 1'b1;

  // Is entry index i (mod 2*DEPTH) written and not yet read?
  function automatic logic p_in_flight(input logic [ASIZE:0] i);
    p_in_flight = ((i - rbin) < (wbin - rbin));
  endfunction

  // Structure: the checker's counts are the pointers; gray pointers match their binary twins;
  // stage 1 of each synchronizer holds exactly what the checker saw at the latest edge.
  always @(*) begin
    inv_wbin_is_wr_cnt: assert (wbin == p_wr_cnt);
    inv_rbin_is_rd_cnt: assert (rbin == p_rd_cnt);
    inv_wptr_gray: assert (wptr == ((wbin >> 1) ^ wbin));
    inv_rptr_gray: assert (rptr == ((rbin >> 1) ^ rbin));
    inv_wq1_is_sampled_rd_cnt: assert (p_rs1 == p_rd_cnt_at_w);
    inv_rq1_is_sampled_wr_cnt: assert (p_ws1 == p_wr_cnt_at_r);
  end

  // Order: rs2 <= rs1 <= rbin <= wbin (write side) and rbin <= ws2 <= ws1 <= wbin (read side),
  // at most DEPTH apart; flag safety in terms of the synchronized pointers.
  always @(*) begin
    inv_w_chain: assert (p_w_rs1 <= p_w_r && p_w_r <= p_w_w && p_w_w <= P_DEPTH);
    inv_r_chain: assert (p_r_ws2 <= p_r_ws1 && p_r_ws1 <= p_r_w && p_r_w <= P_DEPTH);
    inv_wfull_safe: assert (wfull || p_w_w < P_DEPTH);
    inv_rempty_safe: assert (rempty || p_r_ws2 != '0);
  end

  // Settling (F08, F12): with no read for 2 wclk edges stage 2 equals stage 1; for 3 edges wfull
  // is exact for the synchronized pointer; with no read since reset nothing has crossed yet.
  // The read side mirrors it.
  always @(*) begin
    if (p_w_after_rd_q >= 2) inv_wq2_settled: assert (wq2_rptr == wq1_rptr);
    if (p_w_after_rd_q >= 3) inv_wfull_exact: assert (wfull == (p_w_w == P_DEPTH));
    if (p_r_after_wr_q >= 2) inv_rq2_settled: assert (rq2_wptr == rq1_wptr);
    if (p_r_after_wr_q >= 3) inv_rempty_exact: assert (rempty == (p_r_ws2 == '0));
    if (p_rd_total == '0) inv_no_read_yet: assert (wq1_rptr == '0 && wq2_rptr == '0 && wfull == (wbin == P_DEPTH));
  end

  // History registers: the latest edge out of reset moved each pointer by its accept bit.
  always @(*) begin
    if (p_wpv) inv_w_history: assert (wbin == p_wbin_q + p_wacc_q && p_wptr_q == ((p_wbin_q >> 1) ^ p_wbin_q)
                                      && p_wcdc_q == p_wptr_q && !(p_wacc_q && p_wblk_q));
    if (p_rpv) inv_r_history: assert (rbin == p_rbin_q + p_racc_q && p_rptr_q == ((p_rbin_q >> 1) ^ p_rbin_q)
                                      && p_rcdc_q == p_rptr_q && !(p_racc_q && p_rblk_q));
  end

  // Tracked data (F02, F03): an in-flight tracked entry still holds the data the checker captured.
  always @(*) begin
    if (p_in_flight(p_idx)) inv_tracked_word_in_mem: assert (p_have1 && mem[p_idx[ASIZE-1:0]] == p_d1);
    if (p_pair && p_in_flight(p_idx2)) inv_tracked_pair_in_mem: assert (mem[p_idx2[ASIZE-1:0]] == p_d2);
  end
`endif  // FORMAL_NO_INV
`endif  // FORMAL

`undef AFP_ELSE
