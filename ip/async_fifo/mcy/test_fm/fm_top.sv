// fm_top.sv — MCY formal test harness (M9, test_fm): one mutant of MCY's netlist (mutsel = MUTSEL)
// with the e2e checker on its ports. The netlist has no white-box properties (they live in
// rtl/async_fifo_props.svh, which MCY never reads, so properties are never mutated), so this is
// the formal flow with the end-to-end property set only: F01–F08, F12, F14 and the formal-only
// F02/F03 tracked-word and F14 gclk properties, under the formal assumptions A01, A05 (DEC-012).
// test_fm.sby reads the checker with FORMAL_NO_INV: its inv_ proof aids are not spec properties.

`default_nettype none

// The harness. MUTSEL is set per mutant by the .sby script (chparam).
module fm_top #(
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

  logic             wfull, rempty;
  logic [DSIZE-1:0] rdata;

  // The mutant.
  async_fifo dut (
    .mutsel(SEL),
    .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
    .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
  );

  // The end-to-end checker: assumptions, spec assertions, covers (covers are ignored in prove).
  async_fifo_e2e_props #(.DSIZE(DSIZE), .ASIZE(ASIZE)) p_e2e (
    .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
    .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty),
    .wr_cnt(), .rd_cnt()
  );
endmodule

`default_nettype wire
