// T12 testbench: a class method with a branch, module-level signals and a covergroup. With
// t12.vlt the branch and signals must get no line/branch/toggle points; the covergroup must stay.
module t12_tb;
  // Testbench class with its own branch (stands in for UVM code) and a covergroup (fifo_coverage).
  class drv_c;
    covergroup cg with function sample(bit v); cp_v: coverpoint v { bins hi = {1}; } endgroup
    function new(); cg = new(); endfunction
    function bit pick(int i); if (i > 2) return 1; else return 0; endfunction
  endclass
  logic clk = 0, en = 1; logic [3:0] cnt; int tb_sig;
  t12_dut dut (.*);
  // Ten clock cycles with en held at 1; tb_sig counts in the testbench only, so pick() returns 1 later.
  initial begin
    static drv_c d = new();
    repeat (20) begin #5 clk = ~clk; tb_sig++; d.cg.sample(d.pick(tb_sig)); end
    $finish;
  end
endmodule
