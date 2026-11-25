// T12 design under test: one branch and a counter, so line, branch and toggle points exist here.
module t12_dut (input logic clk, input logic en, output logic [3:0] cnt);
  // Count while enabled; the else branch is never taken by the testbench (a known hole).
  always_ff @(posedge clk)
    if (en) cnt <= cnt + 1;
    else    cnt <= '0;
endmodule
