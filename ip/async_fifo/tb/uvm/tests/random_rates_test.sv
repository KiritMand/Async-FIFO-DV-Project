// random_rates_test.sv — vplan §2.2: 4..8 timed phases, each with its own write and read rate
// (weighted toward 0%, 100% and the middle), then top-up phases until S5 is met.

class random_rates_test extends fifo_base_test;
  `uvm_component_utils(random_rates_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // The traffic: vseq_random_rates with its approved defaults.
  task run_traffic();
    vseq_random_rates vs = vseq_random_rates::type_id::create("random_rates");
    vs.start(env.vsqr);
  endtask
endclass
