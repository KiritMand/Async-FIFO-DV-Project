// clk_rst_if.sv — reusable clock and reset generator for one clock domain (plan M3 step 3).
// One instance per domain in the testbench top; tests drive it through a virtual interface.
// All times are in ps. The reset is asserted at time 0 (power-up) and released synchronously.
// DUT-agnostic: nothing here knows about the FIFO.

interface clk_rst_if;
  timeunit 1ps;
  timeprecision 1ps;

  // Clock and active-low reset. rst_n starts at 1 only so that the time-0 assertion below is a
  // real negedge: a reset that merely starts at 0 never fires async-reset flops (toolchain T9).
  logic        clk       = 1'b0;
  logic        rst_n     = 1'b1;
  int unsigned period_ps = 0;   // 0 = clock not started yet
  int unsigned phase_ps  = 0;   // delay from start_clock() to the first rising edge

  // Power-up: assert reset at time 0, after every process has started waiting (#0, T9).
  initial #0 rst_n = 1'b0;

  // The clock process belongs to the interface, not to a class (plan M3 pitfall). It idles
  // until start_clock() sets a period, then gives the first rising edge after phase_ps.
  // Run-time delays raise ZERODLY: period_ps >= 2 is checked by start_clock(), so the half
  // periods are never 0; phase_ps = 0 (first edge immediately) is a legal, intended #0.
  /* verilator lint_off ZERODLY */
  initial begin
    wait (period_ps != 0);
    #(phase_ps);
    forever begin
      clk = 1'b1;
      #(period_ps / 2);
      clk = 1'b0;
      #(period_ps - period_ps / 2);
    end
  end
  /* verilator lint_on ZERODLY */

  // Start the clock: period, and delay to the first rising edge, both in ps. Call once.
  function automatic void start_clock(int unsigned period, int unsigned phase);
    if (period < 2 || period_ps != 0)
      $fatal(1, "clk_rst_if: start_clock(%0d, %0d) called twice or with period < 2", period, phase);
    phase_ps  = phase;
    period_ps = period;
  endfunction

  // Assert reset asynchronously, now. Power-up already does this at time 0; kept for reuse
  // (the FIFO project allows no reset after power-up, vplan A05).
  function automatic void assert_reset();
    rst_n = 1'b0;
  endfunction

  // Release reset synchronously at the next rising edge, with a non-blocking update: the
  // design still sees reset at that edge and is out of reset from the next one (vplan A02).
  task automatic release_reset_sync();
    @(posedge clk);
    rst_n <= 1'b1;
  endtask

  // Wait for n rising edges of this clock (n = 0 returns at once).
  task automatic wait_cycles(int unsigned n);
    repeat (n) @(posedge clk);
  endtask
endinterface
