// t19.sv — T19 (M8): SBY cover mode on a design whose assertion fails. A free-running counter;
// ast_small fails when cnt reaches 3; cov_early (cnt == 2) is reachable before that failure,
// cov_late (cnt == 5) only after it. Which covers does cover mode reach, and what is the verdict?
module t19 (input wire clk);
  reg [3:0] cnt = 4'd0;
  // The design: count every clock.
  always @(posedge clk) cnt <= cnt + 4'd1;
  // The properties: one assertion that a "bug" breaks at cnt = 3, one cover on each side of it.
  always @(posedge clk) begin
    ast_small: assert (cnt < 4'd3);
    cov_early: cover (cnt == 4'd2);
    cov_late:  cover (cnt == 4'd5);
  end
endmodule
