// miter.sv — MCY equivalence miter (M9, test_eq): does a mutation change what the FIFO's ports
// show? Two copies of MCY's mutated netlist on the same inputs: gold with mutsel = 0 (the original
// design) and gate with mutsel = MUTSEL. test_eq.sby proves the outputs equal with ABC PDR (no
// depth bound) or finds an input sequence where they differ.
// Environment (DEC-014 D1): the e2e checker on the shared inputs, whose asserts and covers the
// .sby script removes (chformal), so only its formal assumptions remain: A01 both resets
// asserted at power-up, A05 never reset again; free clocks (A04). A02 is not assumed (DEC-012). No other assumption: inputs are otherwise free, as in the formal sign-off.
// Compared: wfull and rempty at every step (reset included, F01), rdata whenever gold is not
// empty (show-ahead data is a don't-care while empty, spec R3).
// Labels use the mcy_ prefix: they are harness checks, not vplan properties.

`default_nettype none

// The miter. MUTSEL is set per mutant by the .sby script (chparam).
module miter #(
  parameter int DSIZE  = 4,
  parameter int ASIZE  = 2,
  parameter int MUTSEL = 1
) (
  input wire logic             wclk,
  input wire logic             wrst_n,
  input wire logic             winc,
  input wire logic [DSIZE-1:0] wdata,
  input wire logic             rclk,
  input wire logic             rrst_n,
  input wire logic             rinc
);
  localparam logic [7:0] SEL = MUTSEL;

  logic             gold_wfull, gate_wfull, gold_rempty, gate_rempty;
  logic [DSIZE-1:0] gold_rdata, gate_rdata;

  // The original design and the mutant (fmcombine merges the two into one combined module).
  async_fifo gold (
    .mutsel(8'd0),
    .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(gold_wfull),
    .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(gold_rdata), .rempty(gold_rempty)
  );
  async_fifo gate (
    .mutsel(SEL),
    .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(gate_wfull),
    .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(gate_rdata), .rempty(gate_rempty)
  );

  // Environment only: the checker's assumptions constrain the shared inputs (its properties are
  // removed by the script). Its formal-only export ports stay unconnected.
  async_fifo_e2e_props #(.DSIZE(DSIZE), .ASIZE(ASIZE)) env (
    .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(gold_wfull),
    .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(gold_rdata), .rempty(gold_rempty),
    .wr_cnt(), .rd_cnt()
  );

  // Equal observable behavior at every formal step.
  always @(*) begin
    mcy_eq_wfull:  assert (gold_wfull == gate_wfull);
    mcy_eq_rempty: assert (gold_rempty == gate_rempty);
    if (!gold_rempty) mcy_eq_rdata: assert (gold_rdata == gate_rdata);
  end
endmodule

`default_nettype wire
