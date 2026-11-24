// rd_agent.sv — read-side agent: sequencer, driver and monitor on fifo_rd_if (plan M3 step 5).

// The read sequencer needs nothing beyond the standard one.
typedef uvm_sequencer #(rd_item) rd_sequencer;

class rd_agent extends uvm_agent;
  `uvm_component_utils(rd_agent)

  rd_sequencer sqr;
  rd_driver    drv;
  rd_monitor   mon;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Monitor always; sequencer and driver only when active (the default).
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = rd_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = rd_sequencer::type_id::create("sqr", this);
      drv = rd_driver::type_id::create("drv", this);
    end
  endfunction

  // Driver pulls items from the sequencer.
  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
