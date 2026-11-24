// thrash_full_test.sv — vplan §2.2: the fill bounces between DEPTH-1 and DEPTH for max(4*DEPTH, 64)
// accepted reads, with at least 20 crossings (vseq_thrash_full, THRASH_WEAK).
// Half of its runs use an exact integer ratio (owner decision M4/D1), and half of those align
// the edges, so simultaneous accepted reads and writes at fill DEPTH-1 are common (F16).

class thrash_full_test extends fifo_base_test;
  `uvm_component_utils(thrash_full_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 50% integer ratios instead of the default 20% (plusargs still override).
  function void pre_cfg();
    cfg.int_pct = 50;
  endfunction

  // The traffic: vseq_thrash_full with its approved defaults.
  task run_traffic();
    vseq_thrash_full vs = vseq_thrash_full::type_id::create("thrash_full");
    vs.start(env.vsqr);
  endtask
endclass
