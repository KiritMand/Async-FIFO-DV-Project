// t20_tb.sv — T20 (M9): drives a Yosys-written, mutated async_fifo (ASIZE=2, DSIZE=4, so the
// netlist has no parameters): writes 4 words, reads them back, prints how many came back wrong.
module t20_tb;
  logic wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0, winc = 0, rinc = 0, wfull, rempty;
  logic [3:0] wdata = 0, rdata;
  logic [7:0] mutsel = 0;  // +mutsel=<n> activates mutation n; 0 = the original design
  int bad = 0;
  async_fifo dut (.*);
  always #5 wclk = ~wclk;
  always #7 rclk = ~rclk;
  // Release both resets, write 5..8, wait for the synchronizers, read 4 words checking each.
  initial begin
    void'($value$plusargs("mutsel=%d", mutsel));
    repeat (2) @(posedge wclk); wrst_n <= 1; @(posedge rclk); rrst_n <= 1;
    for (int i = 0; i < 4; i++) begin @(posedge wclk); winc <= 1; wdata <= 4'(i + 5); end
    @(posedge wclk) winc <= 0; repeat (6) @(posedge rclk);
    for (int i = 0; i < 4; i++) begin @(negedge rclk); bad += int'(rdata != 4'(i + 5)); rinc = 1; @(posedge rclk); #1 rinc = 0; end
    $display("T20 mutsel=%0d bad=%0d", mutsel, bad); $finish;
  end
endmodule
