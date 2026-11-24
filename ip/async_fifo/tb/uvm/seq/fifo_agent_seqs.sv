// fifo_agent_seqs.sv — agent-level sequences used by M3 (smoke and drain). M4 adds the burst and
// until-blocked sequences of the plan next to these.
// Items are filled procedurally, not with randomize(): a constrained randomize() call costs about
// 20 ms in Verilator (toolchain T10), far too slow per transaction.

// Write attempts: n items, each after `idle` idle edges, with one flag policy. Counts outcomes.
class wr_attempt_seq extends uvm_sequence #(wr_item);
  `uvm_object_utils(wr_attempt_seq)

  int unsigned  n        = 1;          // number of attempts
  int unsigned  idle     = 0;          // idle edges before each attempt
  flag_policy_e policy   = FLAG_CFG;   // how each attempt treats wfull
  bit           distinct = 0;          // 1: data = base + 37*i, all distinct below 2**DSIZE values

  int unsigned n_accepted, n_blocked, n_gated;  // outcomes reported by the driver

  // Constructor (UVM factory signature).
  function new(string name = "wr_attempt_seq");
    super.new(name);
  endfunction

  // Send the attempts one at a time; the driver writes each outcome back into the item. With
  // distinct data an ordering error can't hide behind a repeated value (37 is odd, so i -> 37*i
  // is one-to-one modulo 2**DSIZE).
  task body();
    data_t base = rand_data();
    for (int unsigned i = 0; i < n; i++) begin
      wr_item it = wr_item::type_id::create("it");
      start_item(it);
      it.data   = distinct ? data_t'(base + 37 * i) : rand_data();
      it.idle   = idle;
      it.policy = policy;
      finish_item(it);
      case (it.status)
        OP_ACCEPTED: n_accepted++;
        OP_BLOCKED:  n_blocked++;
        default:     n_gated++;
      endcase
    end
  endtask
endclass

// Read until the scoreboard's model is empty, then `extra` more attempts (blocked reads when the
// DUT is correct). Stops with an error if reads stall, e.g. a stuck rempty.
class rd_until_empty_seq extends uvm_sequence #(rd_item);
  `uvm_object_utils(rd_until_empty_seq)

  fifo_scoreboard sb;                         // true fill (set by the virtual sequence)
  int unsigned    idle        = 0;            // idle edges before each attempt
  flag_policy_e   policy      = FLAG_CFG;     // how each attempt treats rempty
  int unsigned    extra       = 0;            // attempts after the model is empty
  int unsigned    stall_limit = 4 * K + 16;   // attempts in a row without an accepted read

  int unsigned n_accepted, n_blocked, n_gated, n_extra_blocked;  // outcomes

  // Constructor (UVM factory signature).
  function new(string name = "rd_until_empty_seq");
    super.new(name);
  endfunction

  // One read attempt; returns the driver's outcome and counts it.
  protected task attempt(output op_status_e st);
    rd_item it = rd_item::type_id::create("it");
    start_item(it);
    it.idle   = idle;
    it.policy = policy;
    finish_item(it);
    st = it.status;
    case (st)
      OP_ACCEPTED: n_accepted++;
      OP_BLOCKED:  n_blocked++;
      default:     n_gated++;
    endcase
  endtask

  // Drain loop. After each attempt, wait for the NBA region so the monitor has published this
  // edge before the fill is read. Once no write is accepted, a correct rempty falls within K
  // edges (F08), so stall_limit attempts without progress means the drain is stuck.
  task body();
    op_status_e  st;
    int unsigned stall = 0;
    if (sb == null) `uvm_fatal("RD_SEQ", "rd_until_empty_seq: sb handle not set")
    while (sb.fill() > 0) begin
      attempt(st);
      uvm_wait_for_nba_region();
      stall = (st == OP_ACCEPTED) ? 0 : stall + 1;
      if (stall > stall_limit) begin
        `uvm_error("DRAIN_STUCK", $sformatf("%0d entries left; no read accepted in %0d attempts (rempty stuck? F08)",
                                            sb.fill(), stall))
        return;
      end
    end
    repeat (extra) begin
      attempt(st);
      if (st == OP_BLOCKED) n_extra_blocked++;
    end
  endtask
endclass
