// wr_monitor.sv — observes every wclk edge on fifo_wr_if (plan M3 step 5).
// Classifies each edge by spec §5: accepted write (winc && !wfull out of reset), blocked write
// (winc && wfull out of reset), or nothing; values are the ones the DUT sampled at the edge.

class wr_monitor extends uvm_monitor;
  `uvm_component_utils(wr_monitor)

  virtual fifo_wr_if vif;

  // Outputs: accepted writes (scoreboard), blocked writes, and every edge (coverage, M5).
  uvm_analysis_port #(wr_item) ap;
  uvm_analysis_port #(wr_item) ap_blocked;
  uvm_analysis_port #(wr_item) ap_edge;

  // Counts for the report and for directed tests.
  int unsigned n_accepted, n_blocked, n_inc_in_reset;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Get the interface; create the analysis ports.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_wr_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "wr_monitor: no virtual interface 'vif' in config_db")
    ap         = new("ap", this);
    ap_blocked = new("ap_blocked", this);
    ap_edge    = new("ap_edge", this);
  endfunction

  // One sample per edge. Accepted writes go out first, so the scoreboard is up to date before
  // any edge subscriber sees the same edge.
  task run_phase(uvm_phase phase);
    forever begin
      wr_item it;
      @(vif.mon_cb);
      it          = wr_item::type_id::create("wr_obs");
      it.t        = $time;
      it.in_reset = (vif.mon_cb.wrst_n !== 1'b1);
      it.inc      = vif.mon_cb.winc;
      it.flag     = vif.mon_cb.wfull;
      it.data     = vif.mon_cb.wdata;
      if (it.in_reset) begin
        if (it.inc) n_inc_in_reset++;  // ignored by the DUT (spec W3)
      end else if (it.inc && it.flag) begin
        it.status = OP_BLOCKED;
        n_blocked++;
        ap_blocked.write(it);
      end else if (it.inc) begin
        it.status = OP_ACCEPTED;
        n_accepted++;
        ap.write(it);
      end
      ap_edge.write(it);
    end
  endtask

  // Summary line for the log.
  function void report_phase(uvm_phase phase);
    `uvm_info("WR_MON", $sformatf("accepted=%0d blocked=%0d winc_in_reset=%0d",
                                  n_accepted, n_blocked, n_inc_in_reset), UVM_LOW)
  endfunction
endclass
