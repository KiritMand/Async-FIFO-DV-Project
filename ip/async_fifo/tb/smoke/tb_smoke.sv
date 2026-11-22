// tb_smoke.sv — directed smoke test for async_fifo (plan M1 step 5). Plain SystemVerilog, no UVM:
// the ten-second "did I break it?" check. Contract: ip/async_fifo/docs/spec.md.
//
// Each round (ROUNDS of them, so the ASIZE+1-bit pointers wrap twice):
//   1. one write into the empty FIFO; rempty must fall within K rclk edges  (spec §7.4)
//   2. fill; wfull must be exact at every edge and rise at exactly DEPTH    (spec W5, §7.2, §7.4)
//   3. writes while full, with data ~head; they must be blocked and harmless  (spec W2)
//   4. one read from the full FIFO; wfull must fall within K wclk edges     (spec §7.4)
//   5. drain; data in order, rempty exact at every edge, DEPTH reads        (spec R1, R2)
//   6. reads while empty; they must be blocked and harmless                 (spec R4)
// A monitor checks rdata against the model head at every rclk negedge while !rempty (R1, R3).
//
// Timing: inputs are driven, and outputs sampled, at the negedge of their own clock. The flags
// are registered, so the negedge value is exactly what the DUT samples at the next posedge.
// Plusargs: +RATIO=w:r  wclk period : rclk period (default 1:1); +trace  write smoke.vcd.
// Result: one line "SMOKE PASS ..." or "SMOKE FAIL at <time>: <reason>" (the Make target greps it).

`timescale 1ns / 1ps

// Top-level testbench; ASIZE/DSIZE are overridden from the build (-G) and passed to the DUT.
module tb_smoke #(
  parameter int ASIZE = 4,
  parameter int DSIZE = 8
);
  localparam int DEPTH  = 1 << ASIZE;
  localparam int K      = 3;  // flag pessimism bound, spec §7.4
  localparam int ROUNDS = 4;  // 4*DEPTH writes = two full wraps of the ASIZE+1-bit pointers
  localparam int UNIT   = 5;  // half-period (ns) of a clock with ratio weight 1

  // DUT connections (no initializers: everything is set in time order by the blocks below).
  logic             wclk, rclk, wrst_n, rrst_n, winc, rinc;
  logic [DSIZE-1:0] wdata, rdata;
  logic             wfull, rempty;

  // Device under test, normal build (no ASYNC_FIFO_PROPS).
  async_fifo #(.DSIZE(DSIZE), .ASIZE(ASIZE)) dut (
    .wclk, .wrst_n, .winc, .wdata, .wfull,
    .rclk, .rrst_n, .rinc, .rdata, .rempty
  );

  // Reference model (expected contents, oldest first) and counters for the summary line.
  logic [DSIZE-1:0] model[$];
  int n_wr, n_rd, n_blk_wr, n_blk_rd;
  int wmul, rmul;
  int lat_e_min, lat_e_max, lat_f_min, lat_f_max;

  // For the K checks: edges of each clock strictly after the other side's last accepted
  // operation. Comparing times means an edge coincident with that operation never counts (§5).
  longint unsigned t_w, t_r;
  int rclk_since_w, wclk_since_r;

  // Stop at the first failure with one greppable line.
  task automatic fail(input string msg);
    $display("SMOKE FAIL at %0t: %s", $time, msg);
    $fatal(1, "tb_smoke: failed");
  endtask

  // Write data for the i-th accepted write: odd multiplier, so DEPTH consecutive values are
  // distinct whenever DSIZE >= ASIZE (ordering errors can't hide behind repeated values).
  function automatic logic [DSIZE-1:0] pattern(input int i);
    return DSIZE'(i * 37 + 11);
  endfunction

  // Clocks: parse +RATIO, then start both clocks low at time 0. With an integer ratio every edge of
  // the slower clock coincides with an edge of the faster one, exercising spec §5. Also the watchdog.
  initial begin : clocks
    string ratio;
    $timeformat(-9, 0, " ns", 0);  // %t prints in ns
    wclk = 1'b0; rclk = 1'b0; wmul = 1; rmul = 1;
    if ($value$plusargs("RATIO=%s", ratio))
      if ($sscanf(ratio, "%d:%d", wmul, rmul) != 2 || wmul < 1 || rmul < 1)
        fail($sformatf("bad +RATIO=%s (want w:r, e.g. 1:3)", ratio));
    $display("SMOKE config: ASIZE=%0d DSIZE=%0d DEPTH=%0d RATIO=%0d:%0d (wclk %0d ns, rclk %0d ns) K=%0d",
             ASIZE, DSIZE, DEPTH, wmul, rmul, 2 * UNIT * wmul, 2 * UNIT * rmul, K);
    // Lint waiver: ZERODLY fires because these delays are run-time values; they are >= UNIT
    // because wmul, rmul >= 1 is checked above (docs/toolchain.md, M1 findings).
    /* verilator lint_off ZERODLY */
    fork
      forever #(UNIT * wmul) wclk = ~wclk;
      forever #(UNIT * rmul) rclk = ~rclk;
    join_none
    #(4 * UNIT * (wmul > rmul ? wmul : rmul) * ROUNDS * (2 * DEPTH + 40));
    /* verilator lint_on ZERODLY */
    fail("watchdog timeout: the test stopped making progress");
  end

  // Optional waveform for debugging (+trace): smoke.vcd in the run directory.
  initial begin : waves
    if ($test$plusargs("trace")) begin
      $dumpfile("smoke.vcd");
      $dumpvars(0, tb_smoke);
    end
  end

  // Edge counters for the K checks (see t_w/t_r above).
  initial forever begin
    @(posedge rclk);
    if ($time > t_w) rclk_since_w++;
  end
  initial forever begin
    @(posedge wclk);
    if ($time > t_r) wclk_since_r++;
  end

  // Head monitor (spec R1, R3, §7.2): whenever rempty is low outside reset, rdata must be the
  // oldest model entry, including while the write side is busy filling.
  initial forever begin
    @(negedge rclk);
    if (rrst_n && !rempty) begin
      if (model.size() == 0) fail("rempty low with nothing to read (optimistic, spec 7.2)");
      else if (rdata !== model[0])
        fail($sformatf("rdata=%0h but head is %0h (spec R1/R3)", rdata, model[0]));
    end
  end

  // One write attempt: drive at the wclk negedge, decide acceptance from wfull, let the posedge
  // sample, then drop winc. exact=1 also requires wfull == (model full) at that negedge.
  task automatic write_attempt(input logic [DSIZE-1:0] d, input bit exact, output bit accepted);
    @(negedge wclk);
    if (exact && (wfull !== (model.size() == DEPTH)))
      fail($sformatf("wfull=%b with %0d of %0d entries (must be exact, spec 7.4)", wfull, model.size(), DEPTH));
    if (!wfull && model.size() >= DEPTH) fail("wfull low while full (optimistic, spec 7.2)");
    winc = 1'b1; wdata = d; accepted = !wfull;
    @(posedge wclk);
    if (accepted) begin model.push_back(d); n_wr++; t_w = $time; rclk_since_w = 0; end
    else n_blk_wr++;
    #1 winc = 1'b0;
  endtask

  // One read attempt: at the rclk negedge, check the head (if any) and drive rinc; the posedge
  // pops it, then rinc drops. exact=1 also requires rempty == (model empty) at that negedge.
  task automatic read_attempt(input bit exact, output bit accepted);
    @(negedge rclk);
    if (exact && (rempty !== (model.size() == 0)))
      fail($sformatf("rempty=%b with %0d entries (must be exact, spec 7.4)", rempty, model.size()));
    if (!rempty && model.size() == 0) fail("rempty low while empty (optimistic, spec 7.2)");
    rinc = 1'b1; accepted = !rempty;
    if (accepted && rdata !== model[0])
      fail($sformatf("read %0h, expected %0h (order/integrity, spec R1)", rdata, model[0]));
    @(posedge rclk);
    if (accepted) begin model.delete(0); n_rd++; t_r = $time; wclk_since_r = 0; end
    else n_blk_rd++;
    #1 rinc = 1'b0;
  endtask

  // After a lone write with the read side idle: rempty must be low once K rclk edges have passed
  // (spec 7.4). Returns the measured latency in rclk edges.
  task automatic wait_rempty_fall(output int lat);
    forever begin
      @(negedge rclk);
      if (!rempty) break;
      if (rclk_since_w >= K) fail($sformatf("rempty still high %0d rclk edges after a write (K=%0d)", rclk_since_w, K));
    end
    lat = rclk_since_w;
  endtask

  // After a lone read with the write side idle: wfull must be low once K wclk edges have passed.
  task automatic wait_wfull_fall(output int lat);
    forever begin
      @(negedge wclk);
      if (!wfull) break;
      if (wclk_since_r >= K) fail($sformatf("wfull still high %0d wclk edges after a read (K=%0d)", wclk_since_r, K));
    end
    lat = wclk_since_r;
  endtask

  // Main sequence: reset, then ROUNDS x (fill / blocked writes / drain / blocked reads).
  initial begin : main
    bit acc;
    int lat;
    wrst_n = 1'b1; rrst_n = 1'b1; winc = 1'b0; rinc = 1'b0; wdata = '0;
    t_w = 0; t_r = 0; lat_e_min = K + 1; lat_f_min = K + 1;

    // Reset (spec §8): A01, assert both together, as an edge so the async reset acts at once;
    // flags must take their reset values with no clock edge (F01).
    #1 wrst_n = 1'b0; rrst_n = 1'b0;
    #1 if (wfull !== 1'b0 || rempty !== 1'b1) fail("flags not at reset values without a clock (spec 8)");
    // A02: each reset is released 1 ns after an edge of its own clock, like a reset synchronizer.
    fork
      begin repeat (3) @(posedge wclk); #1 wrst_n = 1'b1; end
      begin repeat (3) @(posedge rclk); #1 rrst_n = 1'b1; end
    join
    if (wfull !== 1'b0 || rempty !== 1'b1) fail("flags not at reset values after release (spec 8)");

    for (int r = 0; r < ROUNDS; r++) begin
      // Quiet gap: more than K edges of each clock with no operations, so both flags are exact.
      repeat (K + 1) @(posedge wclk);
      repeat (K + 1) @(posedge rclk);

      // 1. Lone write into the empty FIFO, then measure how long rempty takes to fall.
      write_attempt(pattern(n_wr), 1'b1, acc);
      if (!acc) fail("first write of a round was blocked");
      wait_rempty_fall(lat);
      lat_e_min = (lat < lat_e_min) ? lat : lat_e_min; lat_e_max = (lat > lat_e_max) ? lat : lat_e_max;

      // 2. Fill. wfull is checked exact before every attempt, so it must stay low below DEPTH.
      while (model.size() < DEPTH) begin
        write_attempt(pattern(n_wr), 1'b1, acc);
        if (!acc) fail($sformatf("write blocked with only %0d of %0d entries (spec W5)", model.size(), DEPTH));
      end

      // 3. Writes while full. The exact check requires wfull high at once (spec 7.2); data ~head
      //    would corrupt the oldest entry if the memory write were not gated (spec W2).
      repeat (3) begin
        write_attempt(~model[0], 1'b1, acc);
        if (acc) fail("write accepted while full (spec W2)");
      end

      // 4. Quiet gap for the read side, then a lone read; measure how long wfull takes to fall.
      repeat (K + 1) @(posedge rclk);
      read_attempt(1'b1, acc);
      if (!acc) fail("read blocked on a full FIFO");
      wait_wfull_fall(lat);
      lat_f_min = (lat < lat_f_min) ? lat : lat_f_min; lat_f_max = (lat > lat_f_max) ? lat : lat_f_max;

      // 5. Drain. rempty is checked exact before every attempt; data must come out in order.
      while (model.size() > 0) begin
        read_attempt(1'b1, acc);
        if (!acc) fail("read blocked while data present (rempty must be exact, spec 7.4)");
      end

      // 6. Reads while empty: blocked, and must not move the read pointer (next round's data
      //    and flags would go wrong if they did; spec R4).
      repeat (2) begin
        read_attempt(1'b1, acc);
        if (acc) fail("read accepted while empty (spec R4)");
      end
    end

    // Totals: every accepted write was read exactly once.
    if (n_wr != ROUNDS * DEPTH || n_rd != n_wr)
      fail($sformatf("count mismatch: %0d writes, %0d reads, expected %0d each", n_wr, n_rd, ROUNDS * DEPTH));
    $display("SMOKE PASS: %0d writes and %0d reads in order, %0d blocked writes, %0d blocked reads; flag latency rempty %0d..%0d rclk, wfull %0d..%0d wclk edges (K=%0d)",
             n_wr, n_rd, n_blk_wr, n_blk_rd, lat_e_min, lat_e_max, lat_f_min, lat_f_max, K);
    $finish;
  end
endmodule
