// T2: covergroup with two coverpoints, a cross and ignore_bins. +HALF=0 hits a in {0,1},
// +HALF=1 hits a in {2,3}; neither run hits the ignored cross bin (a=3,b=1), so the merged
// cross reaches 100% only if ignore_bins is honored (7 live cross bins of 8).
// Proves coverage can be merged across runs — sign-off SO-1 depends on it.
module t2_top;
  // Stimulus signals and the +HALF selector.
  bit clk;
  bit [1:0] a;
  bit b;
  int half;

  // The covergroup under test: per-value bins on a, auto bins on b, and their cross minus
  // one ignored combination. No clocking event: sample() is called explicitly, as a UVM
  // subscriber would (a clocked group also samples idle values, which skewed the first try).
  covergroup cg_t2;
    cp_a: coverpoint a { bins lo[] = {0, 1}; bins hi[] = {2, 3}; }
    cp_b: coverpoint b;
    x_ab: cross cp_a, cp_b { ignore_bins ig_a3_b1 = binsof(cp_a) intersect {3} && binsof(cp_b) intersect {1}; }
  endgroup
  cg_t2 cg = new();

  // Free-running clock that paces the stimulus.
  always #5 clk = ~clk;

  // Drive 64 random samples from this run's half, then print in-run coverage numbers.
  // get_inst_coverage() is used on coverpoint/cross: get_coverage() there is unsupported.
  initial begin
    if (!$value$plusargs("HALF=%d", half)) $fatal(1, "need +HALF=0|1");
    repeat (64) begin
      @(negedge clk);
      a = (half != 0) ? 2'($urandom_range(3, 2)) : 2'($urandom_range(1, 0));
      b = 1'($urandom_range(1, 0));
      if (a == 3) b = 0;  // never hit the ignored bin
      cg.sample();
    end
    @(negedge clk);
    $display("GETCOV half=%0d cg=%0.2f cp_a=%0.2f cp_b=%0.2f x_ab=%0.2f", half,
             cg.get_coverage(), cg.cp_a.get_inst_coverage(), cg.cp_b.get_inst_coverage(), cg.x_ab.get_inst_coverage());
    $finish;
  end
endmodule
