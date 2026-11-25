// T16 (M6, D2): concurrent SVA as sva/async_fifo_sva_concurrent.sv uses it: a checker bound with
// `.*` into a module (reaching its internal nets), consecutive repetition with a parameter count,
// a ##1 sequence as antecedent, $stable/$past, a two-term disable iff. +define+BREAK makes the
// counter step once inside an idle stretch, so cast_hold (and only it) must fail; +define+BREAK2
// drops one increment, so cast_step (and only it) must fail.
module t16_dut (input logic clk, rst_n, en, inc);
  logic [3:0] cnt;  logic [2:0] run;  wire idle = !inc;  // internal state the checker reads
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin cnt <= '0; run <= '0; end
    else begin
      run <= inc ? 3'd0 : run + {2'b0, run != 3'd7};      // consecutive idle edges
      if (inc `ifdef BREAK || (run == 3'd4 && cnt == 4'd4) `endif `ifdef BREAK2 && cnt != 4'd6 `endif) cnt <= cnt + 4'd1;
    end
endmodule
// Checker: N idle edges in a row leave cnt unchanged; an inc followed by an idle edge moved it.
module t16_conc #(parameter int N = 2) (input logic clk, rst_n, en, inc, idle, input logic [3:0] cnt);
  cast_hold: assert property (@(posedge clk) disable iff (!rst_n || !en) idle [*N] |-> $stable(cnt));
  cast_step: assert property (@(posedge clk) disable iff (!rst_n || !en) inc ##1 idle |-> cnt != $past(cnt));
endmodule
bind t16_dut t16_conc #(.N(2 + 1)) u_conc (.*);
// Stimulus: reset, then inc for 2 of every 8 cycles (changed at falling edges), 200 cycles.
module t16_top;
  logic clk = 0, rst_n = 0, en = 1, inc = 0;
  t16_dut dut (.*);
  always #5 clk = ~clk;
  initial begin #12 rst_n = 1; for (int i = 0; i < 200; i++) @(negedge clk) inc = (i % 8) < 2; $display("T16 END"); $finish; end
endmodule
