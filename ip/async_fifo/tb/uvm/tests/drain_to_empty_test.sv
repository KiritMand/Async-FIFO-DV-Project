// drain_to_empty_test.sv — vplan §2.2: rounds of [fill to DEPTH at the cfg's write rate; read at
// 100% until k blocked reads]. Each round checks that exactly the stored entries come out before
// the first blocked read (vseq_drain_to_empty, DRAIN_COUNT).

class drain_to_empty_test extends fifo_base_test;
  `uvm_component_utils(drain_to_empty_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // The traffic: vseq_drain_to_empty with its approved defaults (4..6 rounds, k = 2..4).
  task run_traffic();
    vseq_drain_to_empty vs = vseq_drain_to_empty::type_id::create("drain_to_empty");
    vs.start(env.vsqr);
  endtask
endclass
