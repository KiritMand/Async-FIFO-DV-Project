// fifo_rd_if.sv — read-side interface of the async FIFO testbench (plan M3 step 2).
// Mirror of fifo_wr_if: DUT read ports, driver and monitor clocking blocks, and a combinational
// stage that models how a consumer treats rempty (validated by toolchain T8).

interface fifo_rd_if (input logic rclk, input logic rrst_n);
  import fifo_params_pkg::*;

  // DUT-facing signals: rinc is computed below; rdata and rempty come from the DUT.
  wire  logic             rinc;
  logic       [DSIZE-1:0] rdata;
  logic                   rempty;

  // Driver requests. req: attempt a read at the next edge. ignore_empty: present it even if
  // rempty is set (a deliberate blocked read). noise: the rinc value while in reset (vplan S3).
  logic req          = 1'b0;
  logic ignore_empty = 1'b0;
  logic noise        = 1'b0;

  // Consumer output stage. In reset: random noise. Otherwise req, gated by rempty unless
  // ignore_empty, like real consumer logic `rinc = want & ~rempty` (see fifo_wr_if).
  assign rinc = !rrst_n ? noise : (req & ~(rempty & ~ignore_empty));

  // Driver view: drives land in the edge's own time step; inputs are pre-edge values.
  clocking drv_cb @(posedge rclk);
    default input #1step output #0;
    output req, ignore_empty, noise;
    input  rinc, rempty, rrst_n;
  endclocking

  // Monitor view: the values the DUT sampled at this edge. rdata is the show-ahead word that an
  // accepted read at this edge pops (spec R2, R7).
  clocking mon_cb @(posedge rclk);
    default input #1step;
    input rrst_n, rinc, rdata, rempty;
  endclocking
endinterface
