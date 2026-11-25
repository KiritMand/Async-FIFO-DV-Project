// T17 (M7, DEC-011 D3): what an async-reset flop does under `multiclock on` when its reset is
// released in the same formal step as a rising clock edge. Two counters mirror the FIFO: `dut`
// keeps the reset out of its data path (like wbin), `chk` counts an accept term that includes
// rst_n (like the e2e checker's w_acc). The release rule comes from a define:
// SAME = rst_n rises only in a step where clk rises (the vplan's A02 wording);
// LATE = only in a step where clk does not rise; neither = free release (A02 dropped).
module t17_arst (input wire clk, input wire rst_n, input wire inc);
  // Global formal step and a past-valid flag for $rose on the first step.
  (* gclk *) reg gclk;
  reg pv = 1'b0;
  always @(posedge gclk) pv <= 1'b1;
  // A01 (reset asserted at the start) and the selected A02 form.
  initial assume (!rst_n);
  always @(posedge gclk) if (pv && $rose(rst_n)) begin
`ifdef SAME
    asm_same: assume ($rose(clk));
`elsif LATE
    asm_late: assume (!$rose(clk));
`endif
  end
  // The two counters, written the way the RTL and the e2e checker write theirs.
  wire acc = rst_n && inc;
  reg [1:0] dut, chk;
  always @(posedge clk or negedge rst_n) if (!rst_n) dut <= 2'd0; else dut <= dut + {1'b0, inc};
  always @(posedge clk or negedge rst_n) if (!rst_n) chk <= 2'd0; else if (acc) chk <= chk + 2'd1;
  // They agree in every step, and the flop has not captured at the release step itself (it acts
  // as if still in reset at that edge, like simulation). Covers: a release, a counted increment,
  // and (not under LATE) the decisive case: release together with a clk rise while inc was 1.
  always @(*) ast_agree: assert (dut == chk);
  always @(posedge gclk) if (pv && $rose(rst_n)) ast_release_holds: assert (dut == 2'd0);
  always @(posedge gclk) cov_release: cover (pv && $rose(rst_n));
  always @(posedge gclk) cov_counted: cover (chk == 2'd2);
`ifndef LATE
  always @(posedge gclk) cov_edge_inc: cover (pv && $rose(rst_n) && $rose(clk) && $past(inc));
`endif
endmodule
