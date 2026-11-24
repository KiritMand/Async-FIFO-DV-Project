// fifo_coverage.sv — functional coverage collector (stub in M3; M5 adds vplan §3's covergroups).
// Already subscribed to every monitor edge and holding the cfg and scoreboard handles M5 needs,
// so the wiring is exercised from the first test on.

// Analysis imps for the per-edge monitor streams (macros must sit at package scope).
`uvm_analysis_imp_decl(_wr_edge)
`uvm_analysis_imp_decl(_rd_edge)

class fifo_coverage extends uvm_component;
  `uvm_component_utils(fifo_coverage)

  uvm_analysis_imp_wr_edge #(wr_item, fifo_coverage) wr_edge_imp;
  uvm_analysis_imp_rd_edge #(rd_item, fifo_coverage) rd_edge_imp;
  fifo_env_cfg    cfg;  // set by fifo_env: bucket and phase helpers
  fifo_scoreboard sb;   // set by fifo_env: true fill

  // Edge counts (placeholder content until M5).
  int unsigned n_wr_edges, n_rd_edges;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Create the imps.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wr_edge_imp = new("wr_edge_imp", this);
    rd_edge_imp = new("rd_edge_imp", this);
  endfunction

  // One call per wclk edge (M5: cg_reset, cg_flags, cg_attempts sampling).
  function void write_wr_edge(wr_item it);
    n_wr_edges++;
  endfunction

  // One call per rclk edge.
  function void write_rd_edge(rd_item it);
    n_rd_edges++;
  endfunction

  // Summary line for the log.
  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("stub: wclk edges=%0d rclk edges=%0d (covergroups arrive in M5)",
                               n_wr_edges, n_rd_edges), UVM_LOW)
  endfunction
endclass
