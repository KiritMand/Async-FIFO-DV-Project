// T8 (M3): clocking-block timing in Verilator, exactly as the UVM agents use it.
// PASS needs: #1step inputs give pre-edge values; an `output #0` drive lands in the edge's own
// time step but is sampled one edge later; a combinational gate on a registered DUT output is
// race-free; a class drives and samples through a virtual interface; the clock lives in the
// interface and is started by a class call.
`timescale 1ps/1ps

// Stand-in DUT: counts accepted pushes (inc && !full); registered `full` rises once 2 are stored.
module t8_dut (input logic clk, input logic inc, output logic full, output int n);
  initial begin full = 1'b0; n = 0; end
  always @(posedge clk) if (inc && !full) begin n <= n + 1; full <= (n >= 1); end
endmodule

// Interface: owns the clock (started by a class call), gates req with full, two clocking blocks.
interface t8_if;
  logic clk = 1'b0, req = 1'b0, gate = 1'b1, full; int n, period = 0;
  wire  inc = req & ~(gate & full);
  // Run-time delay raises ZERODLY; the wait guarantees period > 0 (waiver style as in M1).
  /* verilator lint_off ZERODLY */
  initial begin wait (period > 0); forever #(period / 2) clk = ~clk; end
  /* verilator lint_on ZERODLY */
  function automatic void start_clock(int p); period = p; endfunction
  clocking drv_cb @(posedge clk); default output #0; output req, gate; endclocking
  clocking mon_cb @(posedge clk); default input #1step; input inc, full, n; endclocking
endinterface

// Class-side driver and monitor, as a UVM agent holds them (virtual interface handle).
class t8_agent;
  virtual t8_if vif; int acc, blk, bad_n; time t_drive;
  function new(virtual t8_if v); vif = v; endfunction
  // Monitor: count accepted/blocked edges; the sampled n must equal the earlier accepts.
  task monitor(); forever begin @(vif.mon_cb);
    if (vif.mon_cb.n != acc) bad_n++;
    if (vif.mon_cb.inc) begin if (vif.mon_cb.full) blk++; else acc++; end
  end endtask
  // Driver: raise req at one edge; hold 6 edges with the gate on, then 4 with it off.
  task drive(); vif.start_clock(1000);
    @(vif.drv_cb); vif.drv_cb.req <= 1'b1; t_drive = $time;
    repeat (6) @(vif.drv_cb); vif.drv_cb.gate <= 1'b0;
    repeat (4) @(vif.drv_cb);
  endtask
endclass

// Top: connects DUT and interface, timestamps signal changes, runs the agent, judges the result.
module t8_top;
  t8_if vif (); t8_agent a; time t_req, t_full, t_inc_fall;
  t8_dut dut (.clk(vif.clk), .inc(vif.inc), .full(vif.full), .n(vif.n));
  always @(posedge vif.req)  t_req = $time;
  always @(posedge vif.full) t_full = $time;
  always @(negedge vif.inc)  if (vif.gate) t_inc_fall = $time;
  initial begin
    a = new(vif); fork a.monitor(); join_none
    a.drive(); #100;
    $display("T8 RESULT acc=%0d blk=%0d n=%0d bad_n=%0d drive@%0t req@%0t full@%0t inc_fall@%0t",
             a.acc, a.blk, vif.n, a.bad_n, a.t_drive, t_req, t_full, t_inc_fall);
    if (a.acc == 2 && a.blk == 4 && vif.n == 2 && a.bad_n == 0 && t_req == a.t_drive
        && t_full != 0 && t_inc_fall == t_full) $display("T8_OK");
    $finish;
  end
endmodule
