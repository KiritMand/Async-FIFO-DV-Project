// wr_driver.sv — drives write attempts on fifo_wr_if (plan M3 step 5).
// While wrst_n is low it toggles winc and wdata at random (vplan S3). Once out of reset it takes
// one item per attempt (idle edges, then one edge with req = 1) and reports what happened.

class wr_driver extends uvm_driver #(wr_item);
  `uvm_component_utils(wr_driver)

  virtual fifo_wr_if vif;
  fifo_env_cfg       cfg;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Get the interface and the run configuration.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_wr_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "wr_driver: no virtual interface 'vif' in config_db")
    if (!uvm_config_db#(fifo_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "wr_driver: no 'cfg' in config_db")
  endfunction

  // Main loop, one pass per wclk edge. Every drive is made right after an edge through the
  // clocking block, so the DUT sees it at the next edge; each signal is driven once per edge.
  task run_phase(uvm_phase phase);
    wr_item it;
    @(vif.drv_cb);
    forever begin
      if (vif.drv_cb.wrst_n !== 1'b1) begin
        // In reset at this edge: random noise, no items (traffic starts at the release, S2).
        vif.drv_cb.req   <= 1'b0;
        vif.drv_cb.noise <= 1'($urandom_range(1, 0));
        vif.drv_cb.wdata <= rand_data();
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

  // One attempt: `idle` edges without a request, then the request for one edge. The outcome
  // comes from that edge's pre-edge samples: no winc = gated, winc with wfull = blocked.
  // A nop item ends after the idle edges (status OP_IDLE).
  task drive_attempt(wr_item it);
    repeat (it.idle) begin
      vif.drv_cb.req <= 1'b0;
      @(vif.drv_cb);
    end
    if (it.nop) begin
      it.status = OP_IDLE;
      return;
    end
    vif.drv_cb.req         <= 1'b1;
    vif.drv_cb.wdata       <= it.data;
    vif.drv_cb.ignore_full <= ignore_flag(it.policy);
    @(vif.drv_cb);
    it.t      = $time;
    it.inc    = vif.drv_cb.winc;
    it.flag   = vif.drv_cb.wfull;
    it.status = !it.inc ? OP_GATED : it.flag ? OP_BLOCKED : OP_ACCEPTED;
  endtask

  // Whether this attempt ignores wfull: forced by the item, or the cfg policy (respect_full = 0:
  // ignore with probability blocked_attempt_pct).
  function bit ignore_flag(flag_policy_e p);
    case (p)
      FLAG_IGNORE:  return 1'b1;
      FLAG_RESPECT: return 1'b0;
      default:      return !cfg.respect_full && ($urandom_range(100, 1) <= cfg.blocked_attempt_pct);
    endcase
  endfunction
endclass
