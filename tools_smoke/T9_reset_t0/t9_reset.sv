// T9 (M3): with registers starting random (--x-initial unique, +verilator+rand+reset+2), does a
// reset asserted at time 0 fire an async reset before the first clock edge? clk_rst_if needs it
// (A01) so rempty is 1 from time 0, not a random power-up value until the first rclk edge.
`timescale 1ps/1ps

// Three ways to assert reset at time 0, each on its own async-reset 16-bit register that resets
// to all ones (like rempty = 1; 16 bits so a random start can't fake a reset), plus a register
// that is never reset (to see random init at work).
module t9_top;
  logic ra = 1'b1, rb = 1'b1, rc;   // A: init 1, then 0 at time 0; B: same after #0; C: no init
  logic [15:0] qa, qb, qc;
  logic [15:0] junk;
  initial ra = 1'b0;
  initial #0 rb = 1'b0;
  initial rc = 1'b0;

  // No clock ever runs: only the reset edge can set a register to all ones.
  always_ff @(negedge ra) qa <= '1;
  always_ff @(negedge rb) qb <= '1;
  always_ff @(negedge rc) qc <= '1;

  // Report at 500 ps, before any clock edge could have happened in the real testbench.
  initial begin #500; $display("T9 RESULT qa=%04h qb=%04h qc=%04h junk=%04h", qa, qb, qc, junk); $finish; end
endmodule
