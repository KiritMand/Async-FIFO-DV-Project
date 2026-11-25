// tb_sva_neg.sv — negative tests for the M6 properties (plan M6 step 4): each run breaks one
// assertion on purpose and the property must fire. Plain SystemVerilog, no UVM; driven by
// common/scripts/sva_neg.py through `make sva-neg`.
//
// The DUT is built with ASYNC_FIFO_PROPS (white-box properties inside it) and the e2e checker sits
// on its ports, exactly as in the UVM top. Inputs change only at rising edges of their own clock
// and each reset is released at an edge of its own clock, so the clean run meets every
// assumption check (A01–A05) and fires nothing.
//
// Plusargs: +BREAK=<label>  run that label's case ("" = the clean run); +LIST  print the cases.
// Output: "SVA_NEG inject <label> at <t>: <fault>" right before the fault, "SVA_NEG end" at the end, and
// "SVA_NEG case|nocase <label> ..." lines for +LIST. Faults are `force` statements on DUT
// registers or nets (white-box and port properties) or illegal stimulus (asm_ checks).

`timescale 1ns / 1ps
`default_nettype none

// Top level; ASIZE/DSIZE come from the build (-G), as for tb_smoke.
module tb_sva_neg #(
  parameter int ASIZE = 4,
  parameter int DSIZE = 8
);
  localparam int DEPTH = 1 << ASIZE;
  localparam int K     = 3;                                  // spec §7.4
  localparam logic [ASIZE:0] ONE = {{ASIZE{1'b0}}, 1'b1};    // pointer-width constant 1

  // Lint waiver (PROCASSINIT, -Wall style): the resets need initializer 1 so the time-0 assertion
  // below is a real negedge (toolchain T9); clocks and inputs need defined time-0 values.
  /* verilator lint_off PROCASSINIT */
  logic             wclk = 1'b0, rclk = 1'b0;
  logic             wrst_n = 1'b1, rrst_n = 1'b1;
  logic             winc = 1'b0, rinc = 1'b0;
  logic [DSIZE-1:0] wdata = '0;
  /* verilator lint_on PROCASSINIT */
  wire  logic [DSIZE-1:0] rdata;
  wire  logic             wfull, rempty;

  // Clocks: wclk 10 ns (rising at 5, 15, ...), rclk 14 ns (rising at 7, 21, ...). Their rising
  // edges coincide every 70 ns, so the coincident-edge rule is exercised in the clean run too.
  always #5 wclk = ~wclk;
  always #7 rclk = ~rclk;

  // Device under test, with its white-box properties (built with ASYNC_FIFO_PROPS).
  async_fifo #(.DSIZE(DSIZE), .ASIZE(ASIZE)) dut (
    .wclk, .wrst_n, .winc, .wdata, .wfull,
    .rclk, .rrst_n, .rinc, .rdata, .rempty
  );

  // End-to-end checker on the same ports (its counts are not needed here).
  async_fifo_e2e_props #(.DSIZE(DSIZE), .ASIZE(ASIZE), .K(K)) u_e2e (
    .wclk, .wrst_n, .winc, .wdata, .wfull,
    .rclk, .rrst_n, .rinc, .rdata, .rempty,
    .wr_cnt(), .rd_cnt()
  );

  // Optional waveform (+trace): sva_neg.vcd in the run directory.
  initial if ($test$plusargs("trace")) begin
    $dumpfile("sva_neg.vcd");
    $dumpvars(0, tb_sva_neg);
  end

  // ---------------------------------------------------------------------------------------
  // Stimulus helpers: every input change happens at a rising edge of its own clock (A03).
  // ---------------------------------------------------------------------------------------

  // Release one reset at a rising edge of its own clock with a non-blocking update (A02).
  task automatic release_w(); repeat (2) @(posedge wclk); wrst_n <= 1'b1; endtask
  task automatic release_r(); repeat (2) @(posedge rclk); rrst_n <= 1'b1; endtask
  task automatic release_both(); fork release_w(); release_r(); join endtask

  // Present winc (rinc) at n consecutive edges, new data each time; the DUT accepts or blocks.
  task automatic wr(int n);
    repeat (n) begin @(posedge wclk); winc <= 1'b1; wdata <= wdata + 1'b1; end
    @(posedge wclk); winc <= 1'b0;
  endtask
  task automatic rd(int n);
    repeat (n) @(posedge rclk) rinc <= 1'b1;
    @(posedge rclk); rinc <= 1'b0;
  endtask

  // Wait n rising edges of one clock with no operations.
  task automatic idle_w(int n); repeat (n) @(posedge wclk); endtask
  task automatic idle_r(int n); repeat (n) @(posedge rclk); endtask

  // Announce the fault and describe it (the script checks nothing fired before this line, and
  // puts the description in docs/sva_negative_tests.md).
  task automatic inject(string what, string fault);
    $display("SVA_NEG inject %s at %0t: %s", what, $time, fault);
  endtask

  // Run a few edges of both clocks after the fault so its effect is sampled, then stop.
  task automatic finish_soon();
    fork idle_w(12); idle_r(12); join
    $display("SVA_NEG end");
    $finish;
  endtask

  // Clean run: three rounds of fill past full (blocked writes) and drain past empty (blocked
  // reads), then simultaneous traffic and a final drain. Exercises every property's antecedent.
  task automatic clean_run();
    release_both();
    repeat (3) begin
      wr(DEPTH + 2); idle_w(K + 2);
      rd(DEPTH + 2); idle_r(K + 2);
    end
    fork wr(3 * DEPTH); rd(3 * DEPTH); join
    rd(DEPTH + 2); idle_r(K + 2);
  endtask

  // The cases: one per assertion label (vplan §4, Runs = sim or both). A06 cannot fail in a
  // two-state simulator, so it has no case (vplan §5); +LIST says so for the script.
  localparam int NCASE = 25;
  localparam string CASES [NCASE] = '{
    "ast_F01_wfull_low_in_reset", "ast_F01_rempty_high_in_reset", "ast_F01_wside_regs_zero",
    "ast_F01_rside_regs_zero", "ast_F04_blocked_write_holds_wptr", "ast_F05_blocked_read_holds_rptr",
    "ast_F06_wfull_not_optimistic", "ast_F07_rempty_not_optimistic", "ast_F08_wfull_exact",
    "ast_F08_rempty_exact", "ast_F09_wptr_cdc_one_bit", "ast_F09_rptr_cdc_one_bit",
    "ast_F09_wptr_cdc_moves_on_write", "ast_F09_rptr_cdc_moves_on_read", "ast_F10_wptr_is_gray_of_wbin",
    "ast_F10_rptr_is_gray_of_rbin", "ast_F12_capacity", "ast_F14_rdata_stable",
    "asm_A01_resets_low_at_start", "asm_A02_wrst_release_on_wclk", "asm_A02_rrst_release_on_rclk",
    "asm_A03_w_inputs_after_wclk", "asm_A03_r_inputs_after_rclk", "asm_A05_wrst_stays_released",
    "asm_A05_rrst_stays_released"};

  // ---------------------------------------------------------------------------------------
  // Main: power-up reset, then the selected case. Each case states the fault and why it breaks
  // the target property; other labels that fire at the same edge are recorded by the script.
  // ---------------------------------------------------------------------------------------
  initial begin : main
    string brk;
    logic [DSIZE-1:0] frozen;
    if (!$value$plusargs("BREAK=%s", brk)) brk = "";

    // +LIST: the case list and the labels without a case.
    if ($test$plusargs("LIST")) begin
      foreach (CASES[i]) $display("SVA_NEG case %s", CASES[i]);
      $display("SVA_NEG nocase asm_A06_w_inputs_known two-state simulator: inputs are never X");
      $display("SVA_NEG nocase asm_A06_r_inputs_known two-state simulator: inputs are never X");
      $finish;
    end

    // Power-up (A01): both resets fall at time 0 as a real edge — except in the A01 case.
    if (brk != "asm_A01_resets_low_at_start") begin
      #0 wrst_n = 1'b0;
      rrst_n = 1'b0;
    end

    case (brk)
      "": begin
        clean_run();
        $display("SVA_NEG end");
        $finish;
      end
      // F01, in reset: a flag or synchronizer register leaves its reset value.
      "ast_F01_wfull_low_in_reset": begin
        inject(brk, "force wfull = 1 during reset");
        force dut.wfull = 1'b1;
      end
      "ast_F01_rempty_high_in_reset": begin
        inject(brk, "force rempty = 0 during reset");
        force dut.rempty = 1'b0;
      end
      "ast_F01_wside_regs_zero": begin
        inject(brk, "force wq2_rptr = all ones during reset");
        force dut.wq2_rptr = '1;
      end
      "ast_F01_rside_regs_zero": begin
        inject(brk, "force rq1_wptr = all ones during reset");
        force dut.rq1_wptr = '1;
      end
      // F04: at full, a write is blocked, but the next-pointer logic advances anyway for that
      // one edge. The force starts and ends at falling edges, so no other edge sees it.
      "ast_F04_blocked_write_holds_wptr": begin
        release_both(); wr(DEPTH); idle_w(2);
        @(posedge wclk); winc <= 1'b1;
        @(negedge wclk);
        inject(brk, "at full, force wbin_next = wbin + 1 for the edge of a blocked write");
        force dut.wbin_next = dut.wbin + 1'b1;
        @(negedge wclk); release dut.wbin_next;
        @(posedge wclk); winc <= 1'b0;
      end
      // F05: at empty, a read is blocked, but the read pointer advances anyway for that edge.
      "ast_F05_blocked_read_holds_rptr": begin
        release_both(); idle_r(2);
        @(posedge rclk); rinc <= 1'b1;
        @(negedge rclk);
        inject(brk, "at empty, force rbin_next = rbin + 1 for the edge of a blocked read");
        force dut.rbin_next = dut.rbin + 1'b1;
        @(negedge rclk); release dut.rbin_next;
        @(posedge rclk); rinc <= 1'b0;
      end
      // F06: full (two reads were accepted, so F12 is idle), and wfull is forced low. The idle
      // gaps let each flag catch up (K edges), so the reads are accepted, not blocked.
      "ast_F06_wfull_not_optimistic": begin
        release_both(); wr(2); idle_r(K + 2); rd(2); idle_w(K + 2); wr(DEPTH); idle_w(K + 2);
        inject(brk, "at fill DEPTH, force wfull = 0"); force dut.wfull = 1'b0;
      end
      // F07: empty after two accepted reads, and rempty is forced low.
      "ast_F07_rempty_not_optimistic": begin
        release_both(); wr(2); idle_r(K + 2); rd(2); idle_r(K + 2);
        inject(brk, "at fill 0, force rempty = 0"); force dut.rempty = 1'b0;
      end
      // F08: long after the last (accepted) read, with fill 1, wfull is forced high.
      "ast_F08_wfull_exact": begin
        release_both(); wr(2); idle_r(K + 2); rd(1); idle_w(K + 2);
        inject(brk, "fill 1, more than K edges after the last read: force wfull = 1");
        force dut.wfull = 1'b1;
      end
      // F08: long after the last write, with fill 3, rempty is forced high.
      "ast_F08_rempty_exact": begin
        release_both(); wr(3); idle_r(K + 2);
        inject(brk, "fill 3, more than K edges after the last write: force rempty = 1");
        force dut.rempty = 1'b1;
      end
      // F09: the binary pointer crosses instead of the gray one (bug B07); 1 -> 2 changes 2 bits.
      "ast_F09_wptr_cdc_one_bit": begin
        inject(brk, "force wptr_cdc = wbin (binary pointer crosses, bug B07), then write");
        force dut.wptr_cdc = dut.wbin;
        release_both(); wr(3);
      end
      "ast_F09_rptr_cdc_one_bit": begin
        inject(brk, "force rptr_cdc = rbin (binary pointer crosses), then read");
        force dut.rptr_cdc = dut.rbin;
        release_both(); wr(4); idle_r(K + 2); rd(3);
      end
      // F09: with no operation, one bit of the crossing net flips just after an edge.
      "ast_F09_wptr_cdc_moves_on_write": begin
        release_both(); wr(2); idle_w(2);
        @(posedge wclk); #1
        inject(brk, "no write: flip bit 0 of wptr_cdc just after a wclk edge");
        force dut.wptr_cdc = dut.wptr ^ ONE;
      end
      "ast_F09_rptr_cdc_moves_on_read": begin
        release_both(); wr(2); idle_r(K + 2); rd(1); idle_r(2);
        @(posedge rclk); #1
        inject(brk, "no read: flip bit 0 of rptr_cdc just after an rclk edge");
        force dut.rptr_cdc = dut.rptr ^ ONE;
      end
      // F10: right after wbin steps 1 -> 2, the gray register keeps gray(1) = 1 instead of 3.
      "ast_F10_wptr_is_gray_of_wbin": begin
        release_both();
        fork
          wr(4);
          begin wait (dut.wbin == 2);
          inject(brk, "when wbin becomes 2, force wptr = 1 (gray of the old value)");
          force dut.wptr = ONE; end
        join
      end
      "ast_F10_rptr_is_gray_of_rbin": begin
        release_both(); wr(4); idle_r(K + 2);
        fork
          rd(3);
          begin wait (dut.rbin == 2);
          inject(brk, "when rbin becomes 2, force rptr = 1 (gray of the old value)");
          force dut.rptr = ONE; end
        join
      end
      // F12: read side still in reset (so F08 is idle), fill 3, and wfull is forced high.
      "ast_F12_capacity": begin
        release_w(); wr(3); idle_w(2);
        inject(brk, "read side still in reset, fill 3: force wfull = 1"); force dut.wfull = 1'b1;
      end
      // F14: data present, no read, and rdata is forced to a different value between edges.
      "ast_F14_rdata_stable": begin
        release_both(); wr(3); idle_r(K + 2);
        @(posedge rclk); #1 frozen = ~rdata;
        inject(brk, "fill 3, no read: force rdata to the inverse of its value between rclk edges");
        force dut.rdata = frozen;
      end
      // A01: no reset at power-up; both resets are first asserted after the first wclk edge.
      "asm_A01_resets_low_at_start": begin
        inject(brk, "no power-up reset: resets first asserted after the first wclk edge");
        @(posedge wclk); #1 wrst_n = 1'b0; rrst_n = 1'b0;
        release_both();
      end
      // A02: a reset released between edges of its clock (at a falling edge).
      "asm_A02_wrst_release_on_wclk": begin
        idle_w(2); @(negedge wclk);
        inject(brk, "release wrst_n at a falling wclk edge");
        wrst_n = 1'b1;
      end
      "asm_A02_rrst_release_on_rclk": begin
        idle_r(2); @(negedge rclk);
        inject(brk, "release rrst_n at a falling rclk edge");
        rrst_n = 1'b1;
      end
      // A03: an input changed at a falling edge of its clock.
      "asm_A03_w_inputs_after_wclk": begin
        release_both(); idle_w(2); @(negedge wclk);
        inject(brk, "change winc at a falling wclk edge");
        winc = 1'b1;
      end
      "asm_A03_r_inputs_after_rclk": begin
        release_both(); idle_r(2); @(negedge rclk);
        inject(brk, "change rinc at a falling rclk edge");
        rinc = 1'b1;
      end
      // A05: a reset asserted again after release (at an edge, so only A05 is broken).
      "asm_A05_wrst_stays_released": begin
        release_both(); wr(2); @(posedge wclk);
        inject(brk, "assert wrst_n again after release");
        wrst_n <= 1'b0;
      end
      "asm_A05_rrst_stays_released": begin
        release_both(); wr(2); idle_r(K + 2); @(posedge rclk);
        inject(brk, "assert rrst_n again after release");
        rrst_n <= 1'b0;
      end
      default: $fatal(1, "SVA_NEG unknown case '%s' (+LIST shows the cases)", brk);
    endcase
    finish_soon();
  end
endmodule

`default_nettype wire
