// async_fifo_props.svh — white-box properties of async_fifo (vplan §4, kind white-box).
// Included at the end of the RTL module when ASYNC_FIFO_PROPS is defined, so it sees the
// internal names of spec §10 directly: open-source Yosys has no bind and no hierarchical
// references (plan R5). Same style as sva/async_fifo_e2e_props.sv: labeled immediate assertions
// in blocks clocked by one DUT clock, reading values as they were just before the edge.
// M7 adds the formal-only properties (F09 off-edge stability, F11) and induction invariants
// here under `ifdef FORMAL`. Names added here start with p_ so they never clash with the RTL.

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
  // so $past refers to a real, out-of-reset edge (the first edge after release is skipped).
  logic p_wpv, p_rpv;
  always @(posedge wclk or negedge wrst_n) if (!wrst_n) p_wpv <= 1'b0; else p_wpv <= 1'b1;
  always @(posedge rclk or negedge rrst_n) if (!rrst_n) p_rpv <= 1'b0; else p_rpv <= 1'b1;

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
      if ($past(winc && wfull))
        ast_F04_blocked_write_holds_wptr: assert (wbin == $past(wbin) && wptr == $past(wptr))
          `AFP_ELSE(("blocked write moved wbin %0h->%0h", $past(wbin), wbin));
      ast_F09_wptr_cdc_one_bit: assert (p_one_bit_at_most(wptr_cdc ^ $past(wptr_cdc)))
        `AFP_ELSE(("wptr_cdc %0h->%0h changed more than one bit", $past(wptr_cdc), wptr_cdc));
      ast_F09_wptr_cdc_moves_on_write: assert (wptr_cdc == $past(wptr_cdc) || $past(winc && !wfull))
        `AFP_ELSE(("wptr_cdc %0h->%0h without an accepted write", $past(wptr_cdc), wptr_cdc));
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
      if ($past(rinc && rempty))
        ast_F05_blocked_read_holds_rptr: assert (rbin == $past(rbin) && rptr == $past(rptr))
          `AFP_ELSE(("blocked read moved rbin %0h->%0h", $past(rbin), rbin));
      ast_F09_rptr_cdc_one_bit: assert (p_one_bit_at_most(rptr_cdc ^ $past(rptr_cdc)))
        `AFP_ELSE(("rptr_cdc %0h->%0h changed more than one bit", $past(rptr_cdc), rptr_cdc));
      ast_F09_rptr_cdc_moves_on_read: assert (rptr_cdc == $past(rptr_cdc) || $past(rinc && !rempty))
        `AFP_ELSE(("rptr_cdc %0h->%0h without an accepted read", $past(rptr_cdc), rptr_cdc));
    end
  end

`undef AFP_ELSE
