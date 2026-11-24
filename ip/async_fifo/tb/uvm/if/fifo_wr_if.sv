// fifo_wr_if.sv — write-side interface of the async FIFO testbench (plan M3 step 2).
// Carries the DUT write ports, a driver and a monitor clocking block, and a small combinational
// output stage that models how a producer treats wfull (validated by toolchain T8).

interface fifo_wr_if (input logic wclk, input logic wrst_n);
  import fifo_params_pkg::*;

  // DUT-facing signals: winc is computed below; wdata comes from the driver; wfull from the DUT.
  wire  logic             winc;
  logic       [DSIZE-1:0] wdata = '0;
  logic                   wfull;

  // Driver requests. req: attempt a write at the next edge. ignore_full: present it even if
  // wfull is set (a deliberate blocked write). noise: the winc value while in reset (vplan S3).
  logic req         = 1'b0;
  logic ignore_full = 1'b0;
  logic noise       = 1'b0;

  // Producer output stage. In reset: random noise. Otherwise req, gated by wfull unless
  // ignore_full, like real producer logic `winc = want & ~wfull`. Being combinational, it reacts
  // to a new wfull or wrst_n in the same time step, which a class-based driver cannot do race-free.
  assign winc = !wrst_n ? noise : (req & ~(wfull & ~ignore_full));

  // Driver view: drives land in the edge's own time step and are seen by the DUT at the next
  // edge; inputs are the pre-edge values, i.e. what decided the attempt at this edge.
  clocking drv_cb @(posedge wclk);
    default input #1step output #0;
    output req, ignore_full, noise, wdata;
    input  winc, wfull, wrst_n;
  endclocking

  // Monitor view: exactly the values the DUT sampled at this edge (spec §5, "values at an edge").
  clocking mon_cb @(posedge wclk);
    default input #1step;
    input wrst_n, winc, wdata, wfull;
  endclocking
endinterface
