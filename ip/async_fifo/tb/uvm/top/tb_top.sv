// tb_top.sv — top module of the async FIFO UVM testbench: one clock/reset generator per domain,
// the two FIFO interfaces, the DUT, and run_test() (test chosen with +UVM_TESTNAME=).
// +trace writes waves.vcd in the run directory (VCD: this host has no FST support, toolchain.md).

module tb_top;
  import uvm_pkg::*;
  import fifo_params_pkg::*;
  import fifo_tb_pkg::*;

  // Clock and reset per domain; tests start and release them through virtual interfaces.
  clk_rst_if wclk_if ();
  clk_rst_if rclk_if ();

  // Testbench side of each port group.
  fifo_wr_if wr_if (.wclk(wclk_if.clk), .wrst_n(wclk_if.rst_n));
  fifo_rd_if rd_if (.rclk(rclk_if.clk), .rrst_n(rclk_if.rst_n));

  // Device under test. The sim flow builds it with ASYNC_FIFO_PROPS, so its white-box properties
  // (rtl/async_fifo_props.svh) run inside it (M6).
  async_fifo #(.DSIZE(DSIZE), .ASIZE(ASIZE)) dut (
    .wclk  (wclk_if.clk), .wrst_n(wclk_if.rst_n), .winc(wr_if.winc), .wdata(wr_if.wdata), .wfull(wr_if.wfull),
    .rclk  (rclk_if.clk), .rrst_n(rclk_if.rst_n), .rinc(rd_if.rinc), .rdata(rd_if.rdata), .rempty(rd_if.rempty)
  );

  // End-to-end property checker on the same port nets (sva/async_fifo_e2e_props.sv, M6). Its
  // asm_ checks hold the testbench to the formal assumptions; its counts are unused here.
  async_fifo_e2e_props #(.DSIZE(DSIZE), .ASIZE(ASIZE), .K(K)) u_e2e (
    .wclk  (wclk_if.clk), .wrst_n(wclk_if.rst_n), .winc(wr_if.winc), .wdata(wr_if.wdata), .wfull(wr_if.wfull),
    .rclk  (rclk_if.clk), .rrst_n(rclk_if.rst_n), .rinc(rd_if.rinc), .rdata(rd_if.rdata), .rempty(rd_if.rempty),
    .wr_cnt(), .rd_cnt()
  );

  // Publish the virtual interfaces, then start UVM.
  initial begin
    uvm_config_db#(virtual clk_rst_if)::set(null, "uvm_test_top", "wclk_vif", wclk_if);
    uvm_config_db#(virtual clk_rst_if)::set(null, "uvm_test_top", "rclk_vif", rclk_if);
    uvm_config_db#(virtual fifo_wr_if)::set(null, "uvm_test_top.env.wr_agt*", "vif", wr_if);
    uvm_config_db#(virtual fifo_rd_if)::set(null, "uvm_test_top.env.rd_agt*", "vif", rd_if);
    run_test();
  end

  // Optional waveform dump (module hierarchy only; class objects are not traced).
  initial begin
    if ($test$plusargs("trace")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
    end
  end
endmodule
