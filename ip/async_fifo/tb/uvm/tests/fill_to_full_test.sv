// fill_to_full_test.sv — vplan §2.2: rounds of [write at 100% with no reads until k blocked
// writes; drain at the cfg's read rate]. Each round checks F12 (vseq_fill_to_full); the end
// check below is the vplan F12 checker: the scoreboard's maximum fill equals DEPTH.

class fill_to_full_test extends fifo_base_test;
  `uvm_component_utils(fill_to_full_test)

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // The traffic: vseq_fill_to_full with its approved defaults (4..6 rounds, k = 2..4).
  task run_traffic();
    vseq_fill_to_full vs = vseq_fill_to_full::type_id::create("fill_to_full");
    vs.start(env.vsqr);
  endtask

  // F12 end check, on top of the base test's S5 check.
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.sb.max_fill != DEPTH)
      `uvm_error("F12_MAX_FILL", $sformatf("maximum fill %0d, expected DEPTH = %0d (F12)", env.sb.max_fill, DEPTH))
  endfunction
endclass
