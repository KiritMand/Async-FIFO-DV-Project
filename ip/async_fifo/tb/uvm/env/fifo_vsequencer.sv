// fifo_vsequencer.sv — virtual sequencer: the handles virtual sequences need to coordinate both
// agents. It carries the scoreboard so sequences use the true fill rather than the DUT's flags,
// which are pessimistic (plan M4 pitfall).

class fifo_vsequencer extends uvm_sequencer;
  `uvm_component_utils(fifo_vsequencer)

  wr_sequencer    wr_sqr;  // set by fifo_env
  rd_sequencer    rd_sqr;
  wr_monitor      wr_mon;  // blocked-attempt counts
  rd_monitor      rd_mon;
  fifo_scoreboard sb;      // true fill
  fifo_env_cfg    cfg;     // clocks and traffic knobs

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
