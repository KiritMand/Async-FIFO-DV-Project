// T18 (M7): the structure the FIFO harness needs. A (* gclk *) register declared in two modules
// of one design; $rose/$changed of a design clock in a gclk block; an assumption that abc pdr
// must honor under multiclock (-DNOASM drops it, so ast_cap must fail); -DBREAK makes the
// submodule's gclk assertion fail by label (so its gclk block really runs); -DHIER tries a
// hierarchical reference into the instance (plan R5 expects open-source Yosys to reject it);
// -DSTRICT adds `default_nettype none, which should turn an unresolved name into an error.
`ifdef STRICT
`default_nettype none
`endif

// Submodule: a counter on clk, with its own gclk and past-valid flag; c changes only in a step
// where clk rises; a cover shows the counter moves.
module t18_sub (input wire clk, input wire a, output reg [1:0] c);
  (* gclk *) reg g;
  reg pv = 1'b0;
  always @(posedge g) pv <= 1'b1;
  initial c = 2'd0;
  always @(posedge clk) if (a) c <= c + 2'd1;
  always @(posedge g) if (pv && $changed(c)) ast_sub_on_edge: assert ($rose(clk) `ifdef BREAK && 1'b0 `endif);
  always @(posedge g) cov_sub_two: cover (c == 2'd2);
endmodule

// Top: a second gclk declaration, the instance, the assumption and the checks.
module t18_top (input wire clk, input wire a);
  (* gclk *) reg g;
  wire [1:0] c;
  t18_sub u (.clk(clk), .a(a), .c(c));
`ifndef NOASM
  always @(*) asm_cap: assume (!(a && c == 2'd2));
`endif
  always @(*) ast_cap: assert (c != 2'd3);
`ifdef HIER
  always @(*) ast_hier: assert (u.c == c);
`endif
endmodule
