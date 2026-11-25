// async_fifo_sva_concurrent.sv — the eight e2e assertions of async_fifo_e2e_props.sv written again
// as concurrent SVA (`assert property` with implication, sequences and disable iff), simulation
// only (plan M6 "optional concurrent file", decision D2). Open-source formal rejects concurrent
// SVA (toolchain T6), so the immediate versions remain the ones formal proves; running both in the
// regression shows the two styles agree, and this file is ready for a tool that has Verific.
//
// It is bound into the e2e checker (bind at the end), so it reuses that checker's reference model:
// the true fill and the "a read/write was accepted since my previous edge" flags. Concurrent
// assertions sample every signal in the Preponed region, i.e. the value just before the edge,
// which is the same view the immediate versions have (spec §5). Verilator support: toolchain T16.
//
// Labels: cast_<FID>_<name> is the concurrent twin of ast_<FID>_<name> (vplan §4). Distinct names
// keep the twins from hiding each other in failure reports; sva_neg.py checks every twin fires in
// its immediate twin's negative test.

`default_nettype none

// The checker. Port names match signals inside async_fifo_e2e_props, so `.*` connects them.
module async_fifo_sva_concurrent #(
  parameter int DSIZE = 8,
  parameter int ASIZE = 4,
  parameter int K     = 3
) (
  input wire logic             wclk,
  input wire logic             wrst_n,
  input wire logic             wfull,
  input wire logic             rclk,
  input wire logic             rrst_n,
  input wire logic             rempty,
  input wire logic [DSIZE-1:0] rdata,
  input wire logic [ASIZE:0]   fill,         // true fill (e2e model)
  input wire logic             rd_moved_w,   // a read was accepted since the previous wclk edge
  input wire logic             wr_moved_r,   // a write was accepted since the previous rclk edge
  input wire logic             r_acc,        // a read is accepted at this rclk edge
  input wire logic [ASIZE+2:0] rd_total      // accepted reads since reset (saturating)
);
  // DEPTH at the fill's width.
  localparam logic [ASIZE:0] FILL_FULL = {1'b1, {ASIZE{1'b0}}};

  // F01: in reset, the flags hold their reset values (no disable: reset is the antecedent).
  cast_F01_wfull_low_in_reset: assert property (@(posedge wclk) !wrst_n |-> !wfull);
  cast_F01_rempty_high_in_reset: assert property (@(posedge rclk) !rrst_n |-> rempty);

  // F06/F07: never optimistic, while that side is out of reset.
  cast_F06_wfull_not_optimistic: assert property (
    @(posedge wclk) disable iff (!wrst_n) !wfull |-> fill < FILL_FULL);
  cast_F07_rempty_not_optimistic: assert property (
    @(posedge rclk) disable iff (!rrst_n) !rempty |-> fill != '0);

  // F08: K+1 consecutive edges with no read seen (the state just after the K-th edge after the
  // last read is what the (K+1)-th edge samples) make wfull exact; both resets released (§7.4).
  // Unlike the immediate twin, the first K edges after release are not covered (no history).
  cast_F08_wfull_exact: assert property (
    @(posedge wclk) disable iff (!wrst_n || !rrst_n)
    !rd_moved_w [*K+1] |-> wfull == (fill == FILL_FULL));
  cast_F08_rempty_exact: assert property (
    @(posedge rclk) disable iff (!rrst_n || !wrst_n)
    !wr_moved_r [*K+1] |-> rempty == (fill == '0));

  // F12: with no read accepted since reset, wfull is exact at every edge.
  cast_F12_capacity: assert property (
    @(posedge wclk) disable iff (!wrst_n) rd_total == '0 |-> wfull == (fill == FILL_FULL));

  // F14: an edge with no accepted read, then an edge with data present: rdata did not change.
  cast_F14_rdata_stable: assert property (
    @(posedge rclk) disable iff (!rrst_n) !r_acc ##1 !rempty |-> $stable(rdata));
endmodule

// Attach to every e2e checker instance; the parameters are the checker's own (bind evaluates them
// in the target's scope).
bind async_fifo_e2e_props async_fifo_sva_concurrent #(.DSIZE(DSIZE), .ASIZE(ASIZE), .K(K)) u_sva_conc (.*);

`default_nettype wire
