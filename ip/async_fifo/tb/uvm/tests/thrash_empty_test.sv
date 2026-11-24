// thrash_empty_test.sv — vplan §2.2: the fill bounces between 0 and 1 for max(4*DEPTH, 64) accepted
// writes, with at least 20 crossings (vseq_thrash_empty, THRASH_WEAK). Like thrash_full_test,
// half of its runs use an exact integer ratio (owner decision M4/D1; F16 at fill 1).

class thrash_empty_test extends fifo_base_test;
  `uvm_component_utils(thrash_empty_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 50% integer ratios instead of the default 20% (plusargs still override).
  function void pre_cfg();
    cfg.int_pct = 50;
  endfunction

  // The traffic: vseq_thrash_empty with its approved defaults.
  task run_traffic();
    vseq_thrash_empty vs = vseq_thrash_empty::type_id::create("thrash_empty");
    vs.start(env.vsqr);
  endtask
endclass
