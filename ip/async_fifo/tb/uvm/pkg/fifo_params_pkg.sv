// fifo_params_pkg.sv — FIFO size for the UVM testbench, fixed at compile time (plan M3 step 1).
// The sim flow passes +define+FIFO_ASIZE=<n> +define+FIFO_DSIZE=<n>, so M7/M9 can build the
// small configurations from the same sources. Defaults are the simulation size (ASIZE=4, DSIZE=8).

`ifndef FIFO_ASIZE
  `define FIFO_ASIZE 4
`endif
`ifndef FIFO_DSIZE
  `define FIFO_DSIZE 8
`endif

// Sizes shared by tb_top (DUT parameters), the interfaces and every testbench class.
package fifo_params_pkg;
  localparam int ASIZE = `FIFO_ASIZE;  // address bits (spec §2: >= 2; the RTL guard rejects less)
  localparam int DSIZE = `FIFO_DSIZE;  // data bits per entry (>= 1)
  localparam int DEPTH = 1 << ASIZE;   // entries
  localparam int K     = 3;            // flag pessimism bound in edges (spec §7.4)
endpackage
