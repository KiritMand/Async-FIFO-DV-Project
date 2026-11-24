// rd_monitor.sv — observes every rclk edge on fifo_rd_if (plan M3 step 5).
// Accepted read = rinc && !rempty out of reset; its data is the rdata sampled at that same edge
// (show-ahead, spec R2/R7). Blocked read = rinc && rempty out of reset.

class rd_monitor extends uvm_monitor;
  `uvm_component_utils(rd_monitor)

  virtual fifo_rd_if vif;

  // Outputs: accepted reads (scoreboard), blocked reads, and every edge (coverage, M5).
  uvm_analysis_port #(rd_item) ap;
  uvm_analysis_port #(rd_item) ap_blocked;
  uvm_analysis_port #(rd_item) ap_edge;

  // Counts for the report and for directed tests.
  int unsigned n_accepted, n_blocked, n_inc_in_reset;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Get the interface; create the analysis ports.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_rd_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rd_monitor: no virtual interface 'vif' in config_db")
    ap         = new("ap", this);
    ap_blocked = new("ap_blocked", this);
    ap_edge    = new("ap_edge", this);
  endfunction

  // One sample per edge; accepted reads go out first (see wr_monitor).
  task run_phase(uvm_phase phase);
    forever begin
      rd_item it;
      @(vif.mon_cb);
      it          = rd_item::type_id::create("rd_obs");
      it.t        = $time;
      it.in_reset = (vif.mon_cb.rrst_n !== 1'b1);
      it.inc      = vif.mon_cb.rinc;
      it.flag     = vif.mon_cb.rempty;
      it.data     = vif.mon_cb.rdata;
      if (it.in_reset) begin
        if (it.inc) n_inc_in_reset++;  // ignored by the DUT (spec R5)
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
    `uvm_info("RD_MON", $sformatf("accepted=%0d blocked=%0d rinc_in_reset=%0d",
                                  n_accepted, n_blocked, n_inc_in_reset), UVM_LOW)
  endfunction
endclass
