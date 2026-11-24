// wr_agent.sv — write-side agent: sequencer, driver and monitor on fifo_wr_if (plan M3 step 5).
// Passive mode (monitor only) is available for reuse, e.g. watching a FIFO inside a bigger design.

// The write sequencer needs nothing beyond the standard one.
typedef uvm_sequencer #(wr_item) wr_sequencer;

class wr_agent extends uvm_agent;
  `uvm_component_utils(wr_agent)

  wr_sequencer sqr;
  wr_driver    drv;
  wr_monitor   mon;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Monitor always; sequencer and driver only when active (the default).
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = wr_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = wr_sequencer::type_id::create("sqr", this);
      drv = wr_driver::type_id::create("drv", this);
    end
  endfunction

  // Driver pulls items from the sequencer.
  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
