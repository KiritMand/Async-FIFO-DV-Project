// async_fifo.sv — dual-clock FIFO, Cummings SNUG 2002 style #1. 
// Each domain keeps a binary pointer (addressing) and a gray pointer (crossing); only the gray
// pointers cross, each through a two-flop synchronizer clocked and reset by the destination.

`default_nettype none

module async_fifo #(
  parameter int DSIZE = 8,  // data bits per entry, >= 1
  parameter int ASIZE = 4   // address bits, >= 2; DEPTH = 2**ASIZE entries
) (
  // Write domain
  input  wire logic             wclk,
  input  wire logic             wrst_n,  // async assert, released synchronously to wclk (A02)
  input  wire logic             winc,
  input  wire logic [DSIZE-1:0] wdata,
  output      logic             wfull,
  // Read domain
  input  wire logic             rclk,
  input  wire logic             rrst_n,  // async assert, released synchronously to rclk (A02)
  input  wire logic             rinc,
  output      logic [DSIZE-1:0] rdata,   // show-ahead: oldest entry whenever !rempty
  output      logic             rempty
);

  localparam int DEPTH = 1 << ASIZE;

  // Elaboration guard: the full compare slices [ASIZE-2:0], so ASIZE = 1 is illegal.
  // In Verilator this $error is only warning USERERROR; flows keep it fatal
  if (ASIZE < 2) begin : g_asize_check
    $error("async_fifo: ASIZE must be >= 2");
  end

  // Elaboration guard: DSIZE = 0 would silently give [-1:0], i.e. 2-bit data vectors
  // (Yosys accepts that without a word). Same construct and caveat as the ASIZE guard.
  if (DSIZE < 1) begin : g_dsize_check
    $error("async_fifo: DSIZE must be >= 1");
  end

  // ---------------------------------------------------------------------------------------
  // Declarations 
  // ---------------------------------------------------------------------------------------

  // Storage: DEPTH x DSIZE, not reset. 
  // Written on wclk, read combinationally on rclk.
  logic [DSIZE-1:0] mem [0:DEPTH-1];

  // Pointers are ASIZE+1 bits: the low ASIZE bits address mem, the extra MSB tells full from
  // empty. *_next is the value each register loads at its next clock edge.
  logic [ASIZE:0] wbin, wptr, wbin_next, wgray_next;
  logic [ASIZE:0] rbin, rptr, rbin_next, rgray_next;
  logic           wfull_next, rempty_next;

  // Crossing nets: the only drivers of the first synchronizer stages.
  logic [ASIZE:0] wptr_cdc, rptr_cdc;

  // Synchronizer stages. ASYNC_REG marks flops that may go metastable.
  (* ASYNC_REG = "TRUE" *) logic [ASIZE:0] wq1_rptr;  // rptr -> wclk, stage 1
  (* ASYNC_REG = "TRUE" *) logic [ASIZE:0] wq2_rptr;  // rptr -> wclk, stage 2 (used by wfull)
  (* ASYNC_REG = "TRUE" *) logic [ASIZE:0] rq1_wptr;  // wptr -> rclk, stage 1
  (* ASYNC_REG = "TRUE" *) logic [ASIZE:0] rq2_wptr;  // wptr -> rclk, stage 2 (used by rempty)

  // ---------------------------------------------------------------------------------------
  // Write domain (wclk, wrst_n)
  // ---------------------------------------------------------------------------------------

  // Next write pointer: advance by one only on an accepted write, winc && !wfull
  // Gray code (bin >> 1) ^ bin changes one bit per increment, so it can cross safely.
  always_comb begin
    wbin_next  = wbin + {{ASIZE{1'b0}}, (winc & ~wfull)};
    wgray_next = (wbin_next >> 1) ^ wbin_next;
  end

  // Full: the next gray write pointer equals the synchronized gray read pointer with its two
  // MSBs inverted, i.e. the writer is exactly DEPTH entries (one lap) ahead of the reader.
  assign wfull_next = (wgray_next == {~wq2_rptr[ASIZE:ASIZE-1], wq2_rptr[ASIZE-2:0]});

  // Write pointer and full flag. Loading wfull from *_next makes it see this edge's own write,
  // so the next edge can never overfill. wfull resets to 0.
  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wptr  <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_next;
      wptr  <= wgray_next;
      wfull <= wfull_next;
    end
  end

  // Memory write port: store wdata only on an accepted write. The !wfull gate is what makes a
  // write while full harmless.
  always_ff @(posedge wclk) begin
    if (winc && !wfull) mem[wbin[ASIZE-1:0]] <= wdata;
  end

  // The gray write pointer leaves the write domain only through this net.
  assign wptr_cdc = wptr;

  // Read pointer -> write domain: two flops on the destination clock and reset.
  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wq1_rptr <= '0;
      wq2_rptr <= '0;
    end else begin
      wq1_rptr <= rptr_cdc;
      wq2_rptr <= wq1_rptr;
    end
  end

  // ---------------------------------------------------------------------------------------
  // Read domain (rclk, rrst_n)
  // ---------------------------------------------------------------------------------------

  // Next read pointer: advance by one only on an accepted read, rinc && !rempty.
  always_comb begin
    rbin_next  = rbin + {{ASIZE{1'b0}}, (rinc & ~rempty)};
    rgray_next = (rbin_next >> 1) ^ rbin_next;
  end

  // Empty: the next gray read pointer has caught up with the synchronized gray write pointer.
  assign rempty_next = (rgray_next == rq2_wptr);

  // Read pointer and empty flag. Loading rempty from *_next makes it see this edge's own read,
  // so the next edge can never underflow. rempty resets to 1.
  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin   <= '0;
      rptr   <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_next;
      rptr   <= rgray_next;
      rempty <= rempty_next;
    end
  end

  // Show-ahead read port: combinational read at the current read address, no output register.
  // Valid whenever !rempty; don't-care while empty.
  assign rdata = mem[rbin[ASIZE-1:0]];

  // The gray read pointer leaves the read domain only through this net 
  assign rptr_cdc = rptr;

  // Write pointer -> read domain: two flops on the destination clock and reset 
  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rq1_wptr <= '0;
      rq2_wptr <= '0;
    end else begin
      rq1_wptr <= wptr_cdc;
      rq2_wptr <= rq1_wptr;
    end
  end

  // ---------------------------------------------------------------------------------------
  // Verification hook — the only one 
  // ---------------------------------------------------------------------------------------
`ifdef ASYNC_FIFO_PROPS
  `include "async_fifo_props.svh"   // white-box properties (M6/M7); absent from normal builds
`endif

endmodule

`default_nettype wire
