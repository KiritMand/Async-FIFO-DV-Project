// rd_item.sv — one read attempt (driver) or one observed rclk edge (monitor).
// Mirror of wr_item; data is the rdata the DUT presented at the edge (the popped word when the
// read was accepted, spec R2).

class rd_item extends uvm_sequence_item;
  `uvm_object_utils(rd_item)

  // Stimulus (set by a sequence; plain fields, see wr_item).
  int unsigned  idle   = 0;      // edges with no request before the attempt
  flag_policy_e policy = FLAG_CFG;  // how the attempt treats rempty

  // Observed (driver response, or monitor sample at one edge).
  op_status_e   status = OP_IDLE;  // accepted, blocked, gated (driver only) or idle
  data_t        data;            // rdata at the edge (meaningful only when accepted, spec R6)
  bit           in_reset;        // rrst_n was 0 at the edge
  bit           inc;             // rinc at the edge
  bit           flag;            // rempty at the edge
  time          t;               // time of the edge, ps

  // Constructor (UVM factory signature).
  function new(string name = "rd_item");
    super.new(name);
  endfunction

  // One-line description for debug messages (string'() avoids literal padding, see fifo_env_cfg).
  function string convert2string();
    return $sformatf("rd %s data=%0h rinc=%0b rempty=%0b%s @%0t", status.name(), data, inc, flag,
                     in_reset ? string'(" (in reset)") : string'(""), t);
  endfunction
endclass
