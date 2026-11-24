// fifo_base_test.sv — the run skeleton every test shares (plan M3 step 7):
//   build: randomize the cfg (plusargs may override), let the test adjust traffic knobs, publish it;
//   run:   start both clocks, release the resets per S2 (in parallel with traffic), run the test's
//          traffic, drain (S6), wait, end. A watchdog turns a hang into UVM_FATAL.
// Tests override pre_cfg(), adjust_cfg() and run_traffic() only. check_phase enforces vplan S5.

class fifo_base_test extends uvm_test;
  `uvm_component_utils(fifo_base_test)

  fifo_env           env;
  fifo_env_cfg       cfg;
  virtual clk_rst_if wclk_vif;  // write-domain clock and reset (set by tb_top)
  virtual clk_rst_if rclk_vif;  // read-domain clock and reset

  // vplan S5: accepted reads every test must make (F13: two pointer wraps). smoke_test sets 0.
  int unsigned min_reads = 4 * DEPTH;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Clock/reset handles, then the configuration (fatal if no valid one), then the environment.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual clk_rst_if)::get(this, "", "wclk_vif", wclk_vif) ||
        !uvm_config_db#(virtual clk_rst_if)::get(this, "", "rclk_vif", rclk_vif))
      `uvm_fatal("NOVIF", "fifo_base_test: wclk_vif/rclk_vif missing in config_db")
    cfg = fifo_env_cfg::type_id::create("cfg");
    pre_cfg();
    if (!cfg.randomize_all()) `uvm_fatal("CFG", "no valid configuration (see the CFG error above)")
    adjust_cfg();
    uvm_config_db#(fifo_env_cfg)::set(this, "*", "cfg", cfg);
    env = fifo_env::type_id::create("env", this);
  endfunction

  // Hook: a test may set cfg fields that steer randomization (e.g. int_pct) before it runs.
  virtual function void pre_cfg();
  endfunction

  // Hook: a test may change traffic knobs after randomization. Clocks and resets stay random.
  virtual function void adjust_cfg();
  endfunction

  // Hook: the test's stimulus (virtual sequences on env.vsqr). The base test sends nothing.
  virtual task run_traffic();
  endtask

  // Print the configuration on one line, so every log says how to reproduce its clocks.
  function void start_of_simulation_phase(uvm_phase phase);
    `uvm_info("CFG", cfg.convert2string(), UVM_NONE)
  endfunction

  // The run: clocks, resets and watchdog in the background; traffic; drain; idle wait.
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wclk_vif.start_clock(cfg.wclk_period_ps, cfg.clk_start_ps);
    rclk_vif.start_clock(cfg.rclk_period_ps, cfg.clk_start_ps + cfg.rclk_phase_ps);
    fork
      release_resets();
      watchdog();
    join_none
    run_traffic();
    drain();
    phase.drop_objection(this);
  endtask

  // Reset release (vplan S2, A02): the first side leaves reset at its rst_hold-th rising edge,
  // the other side at its own first rising edge after rst_gap more cycles of the first clock.
  // Each release is synchronous to its own clock; traffic on a side starts at its release.
  task release_resets();
    virtual clk_rst_if first  = cfg.w_first ? wclk_vif : rclk_vif;
    virtual clk_rst_if second = cfg.w_first ? rclk_vif : wclk_vif;
    time t_first;
    first.wait_cycles(cfg.rst_hold - 1);
    first.release_reset_sync();
    t_first = $time;
    first.wait_cycles(cfg.rst_gap);
    second.release_reset_sync();
    `uvm_info("RESET", $sformatf("%s side released at %0t ps, %s side at %0t ps",
                                 cfg.w_first ? "write" : "read", t_first,
                                 cfg.w_first ? "read" : "write", $time), UVM_LOW)
  endtask

  // Watchdog: a run longer than timeout_cycles of the slower clock is a hang (a stuck flag, or a
  // sequence waiting forever). It ends the test as a failure, never as a silent pass.
  task watchdog();
    virtual clk_rst_if slow = (cfg.wclk_period_ps >= cfg.rclk_period_ps) ? wclk_vif : rclk_vif;
    slow.wait_cycles(cfg.timeout_cycles);
    `uvm_fatal("WATCHDOG", $sformatf("test still running after %0d cycles of the slower clock (+TIMEOUT_CYCLES=)",
                                     cfg.timeout_cycles))
  endtask

  // End of every test (vplan S6): read until the model is empty, then let both domains idle for
  // drain_wait_cycles slower-clock cycles so a late wrong read would still be seen.
  task drain();
    virtual clk_rst_if slow = (cfg.wclk_period_ps >= cfg.rclk_period_ps) ? wclk_vif : rclk_vif;
    drain_vseq d = drain_vseq::type_id::create("drain");
    d.start(env.vsqr);
    slow.wait_cycles(cfg.drain_wait_cycles);
  endtask

  // Stimulus obligation S5: too few accepted reads means this run did not wrap the pointers
  // twice, so its coverage claim (F13) would be false. A test failure, never a warning.
  function void check_phase(uvm_phase phase);
    if (env.sb.n_reads < min_reads)
      `uvm_error("S5_SHORT", $sformatf("%0d accepted reads, vplan S5 needs at least %0d (4*DEPTH)",
                                       env.sb.n_reads, min_reads))
  endfunction

  // End-of-test marker for the log checker: its absence means the run died before reporting.
  function void report_phase(uvm_phase phase);
    $display("TB_DONE test=%s", get_type_name());
  endfunction
endclass
