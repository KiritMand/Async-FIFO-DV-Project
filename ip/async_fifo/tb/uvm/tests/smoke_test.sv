// smoke_test.sv — directed smoke test (vplan §2.2): DEPTH+2 writes, two of them blocked; then
// reads to empty, with blocked reads. Clocks and resets are randomized as in every test, so
// different seeds run it at different ratios, phases and reset orders.

class smoke_test extends fifo_base_test;
  `uvm_component_utils(smoke_test)

  // Constructor (UVM factory signature). The directed traffic reads only DEPTH entries, so S5
  // does not apply (vplan S5 exempts smoke_test).
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_reads = 0;
  endfunction

  // Traffic knobs that match the directed traffic, so the printed configuration is truthful:
  // full rate, flags ignored, every attempt presented. They also govern the final drain.
  function void adjust_cfg();
    cfg.wr_rate_class       = 0;
    cfg.rd_rate_class       = 0;
    cfg.wr_rate_pct         = 100;
    cfg.rd_rate_pct         = 100;
    cfg.respect_full        = 0;
    cfg.respect_empty       = 0;
    cfg.blocked_all         = 1;
    cfg.blocked_attempt_pct = 100;
  endfunction

  // The directed traffic.
  task run_traffic();
    smoke_vseq vs = smoke_vseq::type_id::create("smoke");
    vs.start(env.vsqr);
  endtask
endclass
