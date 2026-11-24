// wr_item.sv — one write attempt (driver) or one observed wclk edge (monitor).
// The same class serves both, as usual in UVM: stimulus fields are set by sequences, the
// observed fields are filled by the driver (outcome) or the monitor (edge sample).

class wr_item extends uvm_sequence_item;
  `uvm_object_utils(wr_item)

  // Stimulus (set by a sequence; plain fields: a randomize() call costs ~20 ms, toolchain T10).
  data_t        data;            // wdata for the attempt
  int unsigned  idle   = 0;      // edges with no request before the attempt
  flag_policy_e policy = FLAG_CFG;  // how the attempt treats wfull
  bit           nop    = 0;      // 1: only wait `idle` edges, no attempt (timed phases, M4)

  // Observed (driver response, or monitor sample at one edge).
  op_status_e   status = OP_IDLE;  // accepted, blocked, gated (driver only) or idle
  bit           in_reset;        // wrst_n was 0 at the edge
  bit           inc;             // winc at the edge
  bit           flag;            // wfull at the edge
  time          t;               // time of the edge, ps

  // Constructor (UVM factory signature).
  function new(string name = "wr_item");
    super.new(name);
  endfunction

  // One-line description for debug messages (string'() avoids literal padding, see fifo_env_cfg).
  function string convert2string();
    return $sformatf("wr %s data=%0h winc=%0b wfull=%0b%s @%0t", status.name(), data, inc, flag,
                     in_reset ? string'(" (in reset)") : string'(""), t);
  endfunction
endclass
