// T14 (M6): immediate assertions and covers in the style of the async FIFO property files.
// Questions: is --assert needed; does an `else $error` action fail the run and stop it; does
// +verilator+error+limit keep it going; is a labeled immediate cover counted in coverage.dat;
// does a keyword macro work as the verb; does a declaration initializer give a time-0 posedge;
// is $past sampled at every edge even when its statement runs only at some (ast_t14_past).
`define T14_ASM assert
module t14_top;
  // Clock (posedges at 5, 15, ...), power-up reset released at 20, edge counter n.
  logic clk = 1'b0, rst_n = 1'b1;  int n = 0;  bit brk;
  initial begin brk = $test$plusargs("BREAK"); #0 rst_n = 1'b0; #20 rst_n = 1'b1; #100 $display("T14 END"); $finish; end
  always #5 clk = ~clk;
  always @(posedge clk) n <= n + 1;
  // Out of reset: n is 2..11 at the sampled edges. +BREAK fails at n = 3 and n = 5; the cover
  // must count the 5 even values; the asm_ line uses the macro as its verb.
  always @(posedge clk) if (rst_n) begin
    ast_t14_n: assert (!(brk && (n == 3 || n == 5))) else $error("ast_t14_n: n=%0d", n);
    asm_t14_k: `T14_ASM (n >= 0);
    cov_t14_even: cover (n[0] == 1'b0);
    if (n >= 6 && n[0]) ast_t14_past: assert ($past(n) == n - 1);
  end
  // Event-driven check: report every rising edge of rst_n (expected: only t=20).
  always @(posedge rst_n) $display("T14 RST_ROSE t=%0t", $time);
endmodule
