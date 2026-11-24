// fifo_agent_seqs.sv — agent-level sequences (plan M4 step 1), one family per side:
//   *_burst_seq        n attempts at rate% per edge, optionally time-boxed or stopped from outside
//   *_until_blocked_seq attempts at 100% until k blocked ones (the full/empty boundary)
//   *_to_fill_seq       attempts until the scoreboard's model reaches a target fill
// Items are filled procedurally, not with randomize(): a constrained randomize() call costs about
// 20 ms in Verilator (toolchain T10), far too slow per transaction.

// Idle edges before the next attempt when each edge carries an attempt with probability rate%
// (a geometric draw). 100% draws nothing, so full-rate traffic leaves the random stream alone.
function automatic int unsigned idle_for_rate(int unsigned rate);
  int unsigned n = 0;
  if (rate >= 100) return 0;
  while ($urandom_range(100, 1) > rate) n++;
  return n;
endfunction

// ------------------------------------------------------------------------------------------
// Write side
// ------------------------------------------------------------------------------------------

// Base of every write sequence: one attempt or one wait on the write agent, with outcome counts.
class wr_base_seq extends uvm_sequence #(wr_item);
  `uvm_object_utils(wr_base_seq)

  flag_policy_e policy = FLAG_CFG;  // how each attempt treats wfull

  int unsigned n_accepted, n_blocked, n_gated;  // outcomes reported by the driver
  int unsigned edges;                           // wclk edges used so far (idle + attempt)

  // Constructor (UVM factory signature).
  function new(string name = "wr_base_seq");
    super.new(name);
  endfunction

  // One write attempt after `idle` idle edges; the driver writes the outcome back into the item.
  protected task attempt(int unsigned idle, data_t data, output op_status_e st);
    wr_item it = wr_item::type_id::create("it");
    start_item(it);
    it.data   = data;
    it.idle   = idle;
    it.policy = policy;
    finish_item(it);
    st     = it.status;
    edges += idle + 1;
    case (st)
      OP_ACCEPTED: n_accepted++;
      OP_BLOCKED:  n_blocked++;
      default:     n_gated++;
    endcase
  endtask

  // Let n wclk edges pass without a request (a nop item; n = 0 does nothing).
  protected task wait_edges(int unsigned n);
    wr_item it;
    if (n == 0) return;
    it = wr_item::type_id::create("nop");
    start_item(it);
    it.idle = n;
    it.nop  = 1;
    finish_item(it);
    edges += n;
  endtask
endclass

// Write burst: attempts at rate% per wclk edge. Ends after n attempts, after n_accept accepted
// writes, after max_edges edges (the rest of the budget is waited out), or when `stop` is set by
// a virtual sequence; 0 disables a limit. With distinct data an ordering error can't hide behind
// a repeated value (37 is odd, so i -> 37*i is one-to-one modulo 2**DSIZE).
class wr_burst_seq extends wr_base_seq;
  `uvm_object_utils(wr_burst_seq)

  int unsigned n         = 1;    // attempts
  int unsigned n_accept  = 0;    // accepted writes
  int unsigned max_edges = 0;    // wclk edges
  int unsigned rate      = 100;  // chance of an attempt on each wclk edge, 0..100
  bit          distinct  = 0;    // 1: data = base + 37*i
  bit          stop;             // set from outside: end after the current attempt
  int unsigned stall_limit = 4 * K + 16;  // n_accept mode: attempts in a row without an accept

  // Constructor (UVM factory signature).
  function new(string name = "wr_burst_seq");
    super.new(name);
  endfunction

  // Attempt loop. With n_accept, a long run of attempts that are not accepted means a stuck wfull
  // (only used where the FIFO is far from full), so it ends with an error instead of a hang.
  task body();
    data_t       base  = rand_data();
    int unsigned i     = 0;
    int unsigned stall = 0;
    op_status_e  st;
    forever begin
      int unsigned idle;
      if (stop || (n != 0 && i >= n) || (n_accept != 0 && n_accepted >= n_accept)) break;
      if (max_edges != 0 && edges >= max_edges) break;
      // Rate 0: wait one edge at a time (or the whole budget at once), never attempt.
      if (rate == 0) begin
        wait_edges(max_edges != 0 ? max_edges - edges : 1);
        continue;
      end
      idle = idle_for_rate(rate);
      if (max_edges != 0 && edges + idle + 1 > max_edges) begin
        wait_edges(max_edges - edges);
        break;
      end
      attempt(idle, distinct ? data_t'(base + 37 * i) : rand_data(), st);
      i++;
      stall = (st == OP_ACCEPTED) ? 0 : stall + 1;
      if (n_accept != 0 && stall > stall_limit) begin
        `uvm_error("WR_STALL", $sformatf("%0d write attempts in a row not accepted (%0d of %0d accepted; wfull stuck? F08)",
                                         stall, n_accepted, n_accept))
        break;
      end
    end
  endtask
endclass

// Write at 100% until k blocked writes (spec W2). Records how many writes were accepted before
// the first blocked one, for the F12 capacity check. Stops with an error if no write is ever
// blocked (an overflowing DUT would otherwise keep this sequence going forever).
class wr_until_blocked_seq extends wr_base_seq;
  `uvm_object_utils(wr_until_blocked_seq)

  int unsigned k            = 1;                         // blocked writes to stop after
  int unsigned max_attempts = 2 * DEPTH + 4 * K + 16;    // give up after this many
  int unsigned n_before_block;                           // accepted before the first blocked

  // Constructor (UVM factory signature). Blocked writes need the flag ignored.
  function new(string name = "wr_until_blocked_seq");
    super.new(name);
    policy = FLAG_IGNORE;
  endfunction

  // Back-to-back attempts until k are blocked.
  task body();
    op_status_e  st;
    int unsigned tries = 0;
    while (n_blocked < k) begin
      attempt(0, rand_data(), st);
      if (st == OP_ACCEPTED && n_blocked == 0) n_before_block++;
      if (++tries >= max_attempts && n_blocked < k) begin
        `uvm_error("FILL_NEVER_BLOCKED", $sformatf("%0d write attempts, %0d accepted, only %0d of %0d blocked (wfull never rises? F04/F06)",
                                                   tries, n_accepted, n_blocked, k))
        return;
      end
    end
  endtask
endclass

// Write until the scoreboard's model holds `target` entries (no reads may run meanwhile).
// Stops with an error if writes stall, e.g. a stuck wfull.
class wr_to_fill_seq extends wr_base_seq;
  `uvm_object_utils(wr_to_fill_seq)

  fifo_scoreboard sb;                         // true fill (set by the virtual sequence)
  int unsigned    target      = DEPTH;        // fill to reach
  int unsigned    rate        = 100;          // chance of an attempt on each wclk edge, 1..100
  int unsigned    stall_limit = 4 * K + 16;   // attempts in a row without an accepted write

  // Constructor (UVM factory signature).
  function new(string name = "wr_to_fill_seq");
    super.new(name);
  endfunction

  // Fill loop. After each attempt, wait for the NBA region so the monitor has published this
  // edge before the fill is read. With no reads, a correct wfull is exact within K edges (F08).
  task body();
    op_status_e  st;
    int unsigned stall = 0;
    if (sb == null) `uvm_fatal("WR_SEQ", "wr_to_fill_seq: sb handle not set")
    if (target > DEPTH) `uvm_fatal("WR_SEQ", $sformatf("wr_to_fill_seq: target %0d > DEPTH", target))
    while (sb.fill() < int'(target)) begin
      attempt(idle_for_rate(rate), rand_data(), st);
      uvm_wait_for_nba_region();
      stall = (st == OP_ACCEPTED) ? 0 : stall + 1;
      if (stall > stall_limit) begin
        `uvm_error("FILL_STUCK", $sformatf("fill %0d of target %0d; no write accepted in %0d attempts (wfull stuck? F08)",
                                           sb.fill(), target, stall))
        return;
      end
    end
  endtask
endclass

// ------------------------------------------------------------------------------------------
// Read side (mirror of the write side)
// ------------------------------------------------------------------------------------------

// Base of every read sequence: one attempt or one wait on the read agent, with outcome counts.
class rd_base_seq extends uvm_sequence #(rd_item);
  `uvm_object_utils(rd_base_seq)

  flag_policy_e policy = FLAG_CFG;  // how each attempt treats rempty

  int unsigned n_accepted, n_blocked, n_gated;  // outcomes reported by the driver
  int unsigned edges;                           // rclk edges used so far

  // Constructor (UVM factory signature).
  function new(string name = "rd_base_seq");
    super.new(name);
  endfunction

  // One read attempt after `idle` idle edges; returns the driver's outcome and counts it.
  protected task attempt(int unsigned idle, output op_status_e st);
    rd_item it = rd_item::type_id::create("it");
    start_item(it);
    it.idle   = idle;
    it.policy = policy;
    finish_item(it);
    st     = it.status;
    edges += idle + 1;
    case (st)
      OP_ACCEPTED: n_accepted++;
      OP_BLOCKED:  n_blocked++;
      default:     n_gated++;
    endcase
  endtask

  // Let n rclk edges pass without a request (a nop item; n = 0 does nothing).
  protected task wait_edges(int unsigned n);
    rd_item it;
    if (n == 0) return;
    it = rd_item::type_id::create("nop");
    start_item(it);
    it.idle = n;
    it.nop  = 1;
    finish_item(it);
    edges += n;
  endtask
endclass

// Read burst: attempts at rate% per rclk edge, with the same end conditions as wr_burst_seq.
class rd_burst_seq extends rd_base_seq;
  `uvm_object_utils(rd_burst_seq)

  int unsigned n         = 1;    // attempts
  int unsigned n_accept  = 0;    // accepted reads
  int unsigned max_edges = 0;    // rclk edges
  int unsigned rate      = 100;  // chance of an attempt on each rclk edge, 0..100
  bit          stop;             // set from outside: end after the current attempt
  int unsigned stall_limit = 4 * K + 16;  // n_accept mode: attempts in a row without an accept

  // Constructor (UVM factory signature).
  function new(string name = "rd_burst_seq");
    super.new(name);
  endfunction

  // Attempt loop (see wr_burst_seq; a stall here means a stuck rempty).
  task body();
    int unsigned i     = 0;
    int unsigned stall = 0;
    op_status_e  st;
    forever begin
      int unsigned idle;
      if (stop || (n != 0 && i >= n) || (n_accept != 0 && n_accepted >= n_accept)) break;
      if (max_edges != 0 && edges >= max_edges) break;
      // Rate 0: wait one edge at a time (or the whole budget at once), never attempt.
      if (rate == 0) begin
        wait_edges(max_edges != 0 ? max_edges - edges : 1);
        continue;
      end
      idle = idle_for_rate(rate);
      if (max_edges != 0 && edges + idle + 1 > max_edges) begin
        wait_edges(max_edges - edges);
        break;
      end
      attempt(idle, st);
      i++;
      stall = (st == OP_ACCEPTED) ? 0 : stall + 1;
      if (n_accept != 0 && stall > stall_limit) begin
        `uvm_error("RD_STALL", $sformatf("%0d read attempts in a row not accepted (%0d of %0d accepted; rempty stuck? F08)",
                                         stall, n_accepted, n_accept))
        break;
      end
    end
  endtask
endclass

// Read at 100% until k blocked reads (spec R4). Records how many reads were accepted before the
// first blocked one, for the drain count check. Stops with an error if no read is ever blocked.
class rd_until_blocked_seq extends rd_base_seq;
  `uvm_object_utils(rd_until_blocked_seq)

  int unsigned k            = 1;                         // blocked reads to stop after
  int unsigned max_attempts = 2 * DEPTH + 4 * K + 16;    // give up after this many
  int unsigned n_before_block;                           // accepted before the first blocked

  // Constructor (UVM factory signature). Blocked reads need the flag ignored.
  function new(string name = "rd_until_blocked_seq");
    super.new(name);
    policy = FLAG_IGNORE;
  endfunction

  // Back-to-back attempts until k are blocked.
  task body();
    op_status_e  st;
    int unsigned tries = 0;
    while (n_blocked < k) begin
      attempt(0, st);
      if (st == OP_ACCEPTED && n_blocked == 0) n_before_block++;
      if (++tries >= max_attempts && n_blocked < k) begin
        `uvm_error("DRAIN_NEVER_BLOCKED", $sformatf("%0d read attempts, %0d accepted, only %0d of %0d blocked (rempty never rises? F05/F07)",
                                                    tries, n_accepted, n_blocked, k))
        return;
      end
    end
  endtask
endclass

// Read until the scoreboard's model holds `target` entries (no writes may run meanwhile), then
// `extra` more attempts (blocked reads when target is 0 and the DUT is correct). Target 0 is the
// end-of-test drain (vplan S6). Stops with an error if reads stall, e.g. a stuck rempty.
class rd_to_fill_seq extends rd_base_seq;
  `uvm_object_utils(rd_to_fill_seq)

  fifo_scoreboard sb;                         // true fill (set by the virtual sequence)
  int unsigned    target      = 0;            // fill to reach
  int unsigned    rate        = 100;          // chance of an attempt on each rclk edge, 1..100
  int unsigned    extra       = 0;            // attempts after the target is reached
  int unsigned    stall_limit = 4 * K + 16;   // attempts in a row without an accepted read

  int unsigned n_extra_blocked;  // extra attempts that were blocked

  // Constructor (UVM factory signature).
  function new(string name = "rd_to_fill_seq");
    super.new(name);
  endfunction

  // Drain loop. After each attempt, wait for the NBA region so the monitor has published this
  // edge before the fill is read. Once no write is accepted, a correct rempty falls within K
  // edges (F08), so stall_limit attempts without progress means the drain is stuck.
  task body();
    op_status_e  st;
    int unsigned stall = 0;
    if (sb == null) `uvm_fatal("RD_SEQ", "rd_to_fill_seq: sb handle not set")
    while (sb.fill() > int'(target)) begin
      attempt(idle_for_rate(rate), st);
      uvm_wait_for_nba_region();
      stall = (st == OP_ACCEPTED) ? 0 : stall + 1;
      if (stall > stall_limit) begin
        `uvm_error("DRAIN_STUCK", $sformatf("%0d entries left (target %0d); no read accepted in %0d attempts (rempty stuck? F08)",
                                            sb.fill(), target, stall))
        return;
      end
    end
    repeat (extra) begin
      attempt(0, st);
      if (st == OP_BLOCKED) n_extra_blocked++;
    end
  endtask
endclass
