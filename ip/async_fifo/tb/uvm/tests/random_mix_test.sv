// random_mix_test.sv — vplan §2.2: a random series of the M4 virtual sequences in short form,
// each starting from the fill the previous one left (vseq_random_mix).

class random_mix_test extends fifo_base_test;
  `uvm_component_utils(random_mix_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // The traffic: vseq_random_mix with its approved defaults (4..8 picks, more until S5).
  task run_traffic();
    vseq_random_mix vs = vseq_random_mix::type_id::create("random_mix");
    vs.start(env.vsqr);
  endtask
endclass
