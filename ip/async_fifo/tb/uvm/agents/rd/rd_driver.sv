// rd_driver.sv — drives read attempts on fifo_rd_if (plan M3 step 5).
// Mirror of wr_driver: random rinc while rrst_n is low (vplan S3); then one item per attempt.

class rd_driver extends uvm_driver #(rd_item);
  `uvm_component_utils(rd_driver)

  virtual fifo_rd_if vif;
  fifo_env_cfg       cfg;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Get the interface and the run configuration.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_rd_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rd_driver: no virtual interface 'vif' in config_db")
    if (!uvm_config_db#(fifo_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "rd_driver: no 'cfg' in config_db")
  endfunction

  // Main loop, one pass per rclk edge (same scheme as wr_driver).
  task run_phase(uvm_phase phase);
    rd_item it;
    @(vif.drv_cb);
    forever begin
      if (vif.drv_cb.rrst_n !== 1'b1) begin
        // In reset at this edge: random rinc, no items.
        vif.drv_cb.req   <= 1'b0;
        vif.drv_cb.noise <= 1'($urandom_range(1, 0));
        @(vif.drv_cb);
      end else begin
        // Out of reset: one attempt per item; no item ready means an idle edge.
        seq_item_port.try_next_item(it);
        if (it == null) begin
          vif.drv_cb.req <= 1'b0;
          @(vif.drv_cb);
        end else begin
          drive_attempt(it);
          seq_item_port.item_done();
        end
      end
    end
  endtask

  // One attempt: `idle` edges without a request, then the request for one edge; the outcome
  // comes from that edge's pre-edge samples (no rinc = gated, rinc with rempty = blocked).
  // A nop item ends after the idle edges (status OP_IDLE).
  task drive_attempt(rd_item it);
    repeat (it.idle) begin
      vif.drv_cb.req <= 1'b0;
      @(vif.drv_cb);
    end
    if (it.nop) begin
      it.status = OP_IDLE;
      return;
    end
    vif.drv_cb.req          <= 1'b1;
    vif.drv_cb.ignore_empty <= ignore_flag(it.policy);
    @(vif.drv_cb);
    it.t      = $time;
    it.inc    = vif.drv_cb.rinc;
    it.flag   = vif.drv_cb.rempty;
    it.status = !it.inc ? OP_GATED : it.flag ? OP_BLOCKED : OP_ACCEPTED;
  endtask

  // Whether this attempt ignores rempty: forced by the item, or the cfg policy.
  function bit ignore_flag(flag_policy_e p);
    case (p)
      FLAG_IGNORE:  return 1'b1;
      FLAG_RESPECT: return 1'b0;
      default:      return !cfg.respect_empty && ($urandom_range(100, 1) <= cfg.blocked_attempt_pct);
    endcase
  endfunction
endclass
