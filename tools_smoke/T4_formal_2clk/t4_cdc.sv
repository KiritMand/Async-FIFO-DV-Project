// T4: two-clock formal toy. A toggle in clka crosses a 2-FF synchronizer into clkb.
// Clocks are free inputs; the solver steps on the global clock ((* gclk *), multiclock on).
// -D BREAK bypasses the first synchronizer stage, so the labeled assert must fail.
// Proves open-source SBY handles the two-clock setup M7 needs for the async FIFO.
module t4_cdc (input wire clka, input wire clkb);
  // Source domain (clka): a bit that flips on every clka edge.
  reg tog = 1'b0;
  always @(posedge clka) tog <= ~tog;

  // Destination domain (clkb): two-flop synchronizer, the same structure the FIFO uses for
  // its gray pointers. BREAK skips q1 to create a detectable bug.
  reg q1 = 1'b0, q2 = 1'b0;
  always @(posedge clkb) begin
    q1 <= tog;
`ifdef BREAK
    q2 <= tog;
`else
    q2 <= q1;
`endif
  end

`ifdef FORMAL
  // Global formal clock: one tick per solver step; clka/clkb may change on any tick.
  // f_past_valid blocks $past() on the first step, where it has no history.
  (* gclk *) reg gclk;
  reg f_past_valid = 1'b0;
  always @(posedge gclk) f_past_valid <= 1'b1;

  // Labeled assertion (DEC-002 style: immediate, clocked): q2 only ever takes the value q1
  // held on the previous global-clock step.
  always @(posedge gclk)
    if (f_past_valid && $changed(q2)) ast_T4_q2_from_q1: assert (q2 == $past(q1));

  // Labeled cover: the toggle makes it all the way through, twice (proves the design can
  // actually do something, so a passing proof isn't vacuous).
  reg [1:0] f_q2_rises = 2'd0;
  always @(posedge gclk) if (f_past_valid && $rose(q2) && f_q2_rises != 2'd3) f_q2_rises <= f_q2_rises + 2'd1;
  always @(posedge gclk) cov_T4_q2_rose_twice: cover (f_q2_rises == 2'd2);
`endif
endmodule
