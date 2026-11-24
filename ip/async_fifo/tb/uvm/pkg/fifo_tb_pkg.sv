// fifo_tb_pkg.sv — every class of the async FIFO UVM testbench, in dependency order.
// Source files live by role in tb/uvm/{agents,env,seq,tests}; the sim flow puts those
// directories on the include path. Sizes come from fifo_params_pkg.

`include "uvm_macros.svh"

package fifo_tb_pkg;
  import uvm_pkg::*;
  import fifo_params_pkg::*;

  // Shared types. Outcome of an attempt or an edge: accepted/blocked per spec §5; gated = the
  // producer/consumer stage withheld the request because of the flag (driver only).
  typedef logic [DSIZE-1:0] data_t;
  typedef enum {OP_IDLE, OP_ACCEPTED, OP_BLOCKED, OP_GATED} op_status_e;
  // How an attempt treats its flag: per the cfg knobs, always respect it, or always ignore it.
  typedef enum {FLAG_CFG, FLAG_RESPECT, FLAG_IGNORE} flag_policy_e;

  // Random data word of any width, built from 32-bit $urandom chunks.
  function automatic data_t rand_data();
    data_t d = '0;
    for (int i = 0; i < (DSIZE + 31) / 32; i++) d = data_t'({d, $urandom});
    return d;
  endfunction

  // Configuration, agents, environment, sequences, tests.
  `include "fifo_env_cfg.sv"
  `include "wr_item.sv"
  `include "wr_driver.sv"
  `include "wr_monitor.sv"
  `include "wr_agent.sv"
  `include "rd_item.sv"
  `include "rd_driver.sv"
  `include "rd_monitor.sv"
  `include "rd_agent.sv"
  `include "fifo_scoreboard.sv"
  `include "fifo_coverage.sv"
  `include "fifo_vsequencer.sv"
  `include "fifo_env.sv"
  `include "fifo_agent_seqs.sv"
  `include "fifo_vseqs.sv"
  `include "fifo_random_vseqs.sv"
  `include "fifo_base_test.sv"
  `include "smoke_test.sv"
  `include "fill_to_full_test.sv"
  `include "drain_to_empty_test.sv"
  `include "thrash_full_test.sv"
  `include "thrash_empty_test.sv"
  `include "random_rates_test.sv"
  `include "random_mix_test.sv"
endpackage
