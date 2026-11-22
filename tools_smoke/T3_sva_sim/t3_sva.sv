// T3: SVA in simulation. (a) immediate assert with $past in a clocked block; (b) concurrent
// assert property with disable iff + implication; (c) a checker attached with bind.
// +define+BREAK_A / BREAK_B / BREAK_C breaks exactly one of them.
// Proves Verilator runs all three assertion styles M6 may use, and reports failures by label.

// Toy DUT: a free-running counter and an ack that echoes req one cycle later.
module t3_dut (input logic clk, rst_n, req, output logic ack, output logic [3:0] cnt);
  // Registers. Each BREAK_* define injects one bug aimed at exactly one assertion.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin cnt <= '0; ack <= 1'b0; end
    else begin
`ifdef BREAK_A
      cnt <= cnt + ((cnt == 4'd5) ? 4'd2 : 4'd1);
`else
      cnt <= cnt + 4'd1;
`endif
`ifdef BREAK_B
      ack <= req && cnt != 4'd7;   // drops an ack: (b) fails, (c) still holds
`elsif BREAK_C
      ack <= req || cnt == 4'd9;   // spurious ack: (c) fails, (b) still holds
`else
      ack <= req;
`endif
    end

  // (a) Immediate assertion inside a clocked block: the counter steps by exactly 1.
  always @(posedge clk)
    if (rst_n && $past(rst_n)) ast_a_cnt_inc: assert (cnt == 4'($past(cnt) + 4'd1));

  // (b) Concurrent assertion at module level: every req is acked on the next cycle.
  ast_b_req_ack: assert property (@(posedge clk) disable iff (!rst_n) req |=> ack);
endmodule

// (c) Separate checker module, attached to the DUT with bind (no DUT edits): no ack without
// a req on the previous cycle.
module t3_chk (input logic clk, rst_n, req, ack);
  ast_c_ack_has_req: assert property (@(posedge clk) disable iff (!rst_n) ack |-> $past(req));
endmodule
bind t3_dut t3_chk u_chk (.clk(clk), .rst_n(rst_n), .req(req), .ack(ack));

// Testbench top: clock, reset, and a deterministic req pattern.
module t3_top;
  logic clk = 0, rst_n = 0, req = 0, ack; logic [3:0] cnt;
  t3_dut dut (.clk(clk), .rst_n(rst_n), .req(req), .ack(ack), .cnt(cnt));
  always #5 clk = ~clk;

  // Release reset, then drive req. Period 3 vs. counter period 16 means every (cnt, req) pair
  // occurs within 48 cycles, so each injected bug is guaranteed to be exercised.
  initial begin
    repeat (2) @(negedge clk); rst_n = 1;
    for (int i = 0; i < 60; i++) begin @(negedge clk); req = (i % 3 == 0); end
    $display("T3_END"); $finish;
  end
endmodule
