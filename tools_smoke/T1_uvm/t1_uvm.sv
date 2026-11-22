// T1: UVM smoke — constrained randomize(), seed-dependent values, parsable report summary.
// Proves the simulator can run a minimal UVM test before M3 builds the real environment.
`include "uvm_macros.svh"

// Package holding the test's classes (UVM code lives in packages, not modules).
package t1_pkg;
  import uvm_pkg::*;

  // A transaction with two random fields and constraints: checks that randomize() honors
  // constraints (the free Questa-Altera edition is reported to block this — plan R1).
  class t1_item extends uvm_sequence_item;
    rand bit [7:0] data;
    rand bit [3:0] delay;
    constraint c_data  { data inside {[8'h10:8'hEF]}; data[0] == 1'b0; }
    constraint c_delay { delay < 10; }
    `uvm_object_utils(t1_item)
    function new(string name = "t1_item"); super.new(name); endfunction
  endclass

  // The test: randomizes the item 8 times, re-checks the constraints itself, and prints each
  // value with a "VAL" tag so run.sh can compare two seeds.
  class t1_test extends uvm_test;
    `uvm_component_utils(t1_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    // run_phase: the objection keeps the simulation alive until the loop is done.
    task run_phase(uvm_phase phase);
      t1_item it = t1_item::type_id::create("it");
      phase.raise_objection(this);
      repeat (8) begin
        // `!= 1` instead of `!`: randomize() returns int, and `!` trips Verilator WIDTHTRUNC.
        if (it.randomize() != 1) `uvm_error("T1", "randomize() failed")
        if (!(it.data inside {[8'h10:8'hEF]}) || it.data[0] || it.delay >= 10)
          `uvm_error("T1", $sformatf("constraint violated: data=%02h delay=%0d", it.data, it.delay))
        `uvm_info("T1", $sformatf("VAL data=%02h delay=%0d", it.data, it.delay), UVM_LOW)
        #10;
      end
      phase.drop_objection(this);
    endtask
  endclass
endpackage

// Top module: just starts UVM with the test above.
module t1_top;
  import uvm_pkg::*;
  import t1_pkg::*;
  initial run_test("t1_test");
endmodule
