// fifo_env.sv — the async FIFO environment (plan M3 step 7): write and read agents, scoreboard,
// coverage collector and virtual sequencer, wired together.

class fifo_env extends uvm_env;
  `uvm_component_utils(fifo_env)

  fifo_env_cfg    cfg;
  wr_agent        wr_agt;
  rd_agent        rd_agt;
  fifo_scoreboard sb;
  fifo_coverage   cov;
  fifo_vsequencer vsqr;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Get the run configuration (set by the test) and create the components.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(fifo_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "fifo_env: no 'cfg' in config_db")
    wr_agt = wr_agent::type_id::create("wr_agt", this);
    rd_agt = rd_agent::type_id::create("rd_agt", this);
    sb     = fifo_scoreboard::type_id::create("sb", this);
    cov    = fifo_coverage::type_id::create("cov", this);
    vsqr   = fifo_vsequencer::type_id::create("vsqr", this);
  endfunction

  // Monitors feed the scoreboard (accepted operations) and coverage (every edge); the virtual
  // sequencer and coverage get their handles.
  function void connect_phase(uvm_phase phase);
    wr_agt.mon.ap.connect(sb.wr_imp);
    rd_agt.mon.ap.connect(sb.rd_imp);
    wr_agt.mon.ap_edge.connect(cov.wr_edge_imp);
    rd_agt.mon.ap_edge.connect(cov.rd_edge_imp);
    cov.cfg     = cfg;
    cov.sb      = sb;
    vsqr.wr_sqr = wr_agt.sqr;
    vsqr.rd_sqr = rd_agt.sqr;
    vsqr.wr_mon = wr_agt.mon;
    vsqr.rd_mon = rd_agt.mon;
    vsqr.sb     = sb;
    vsqr.cfg    = cfg;
  endfunction
endclass
