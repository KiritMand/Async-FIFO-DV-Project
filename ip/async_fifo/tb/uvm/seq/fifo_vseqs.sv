// fifo_vseqs.sv — virtual sequences that coordinate both agents (plan M4 step 2):
//   M3: drain_vseq (end of every test), smoke_vseq
//   M4: vseq_fill_to_full, vseq_drain_to_empty, vseq_thrash_full, vseq_thrash_empty
// (vseq_random_rates and vseq_random_mix are in fifo_random_vseqs.sv). Decisions use the
// scoreboard's true fill, never the DUT's flags, which are pessimistic (plan M4 pitfall).
// Parameter defaults are the owner-approved M4 values (vplan §2.2).

// Base: typed access to the virtual sequencer's handles, plus helpers shared by all vseqs.
class fifo_base_vseq extends uvm_sequence;
  `uvm_object_utils(fifo_base_vseq)
  `uvm_declare_p_sequencer(fifo_vsequencer)

  // Constructor (UVM factory signature).
  function new(string name = "fifo_base_vseq");
    super.new(name);
  endfunction

  // Let n wclk edges pass with no write request (a rate-0 burst).
  protected task wr_wait(int unsigned n);
    wr_burst_seq s = wr_burst_seq::type_id::create("wr_wait");
    s.rate      = 0;
    s.max_edges = n;
    s.start(p_sequencer.wr_sqr);
  endtask
  // Mirror: let n rclk edges pass with no read request.
  protected task rd_wait(int unsigned n);
    rd_burst_seq s = rd_burst_seq::type_id::create("rd_wait");
    s.rate      = 0;
    s.max_edges = n;
    s.start(p_sequencer.rd_sqr);
  endtask

  // Make wfull exact before a measured fill: K+1 wclk edges after the last read (F08: the flag
  // is exact K edges after the other side goes idle). Not needed if no read was ever accepted:
  // the write side's copy of the read pointer is then still its reset value, which is exact.
  protected task settle_wr();
    if (p_sequencer.sb.n_reads != 0) wr_wait(K + 1);
  endtask
  // Mirror: make rempty exact before a measured drain.
  protected task settle_rd();
    if (p_sequencer.sb.n_writes != 0) rd_wait(K + 1);
  endtask

  // Blocked attempts to stop after at a boundary (approved: uniform 2..4).
  protected function int unsigned draw_k();
    return $urandom_range(4, 2);
  endfunction

  // Attempt rate (%) that gives one side an effective rate 1/d of the other side's full rate,
  // from the periods (plan M4 pitfall: effective rate = rate% x clock frequency):
  //   rate/100 * f_self = f_other / d   =>   rate = 100 * T_self / (T_other * d)
  // Rounded, clamped to [1, 100]. d >= 4 keeps it at or below 100 for rho in [1/4, 4].
  static function int unsigned paced_rate(int unsigned t_self_ps, int unsigned t_other_ps, int unsigned d);
    longint num = 100 * longint'(t_self_ps);
    longint den = longint'(t_other_ps) * d;
    longint r   = (num + den / 2) / den;
    return (r < 1) ? 1 : (r > 100) ? 100 : int'(r);
  endfunction

  // Return once both sides are out of reset (it may already be so). Measured phases start here,
  // so a long reset gap (vplan S2) cannot use up their budget (coverage closure H03).
  protected task wait_both_released();
    wait (p_sequencer.wr_mon.vif.wrst_n === 1'b1 && p_sequencer.rd_mon.vif.rrst_n === 1'b1);
  endtask

  // Move the true fill to `target` without blocked attempts: write up or read down at 100%,
  // flags respected. The other side is idle meanwhile.
  protected task seek_fill(int unsigned target);
    int f = p_sequencer.sb.fill();
    if (f < int'(target)) begin
      wr_to_fill_seq s = wr_to_fill_seq::type_id::create("seek_wr");
      s.sb     = p_sequencer.sb;
      s.target = target;
      s.policy = FLAG_RESPECT;
      s.start(p_sequencer.wr_sqr);
    end else if (f > int'(target)) begin
      rd_to_fill_seq s = rd_to_fill_seq::type_id::create("seek_rd");
      s.sb     = p_sequencer.sb;
      s.target = target;
      s.policy = FLAG_RESPECT;
      s.start(p_sequencer.rd_sqr);
    end
  endtask
endclass

// End-of-test drain (vplan S6): read until the model is empty, treating rempty per the cfg.
class drain_vseq extends fifo_base_vseq;
  `uvm_object_utils(drain_vseq)

  // Constructor (UVM factory signature).
  function new(string name = "drain_vseq");
    super.new(name);
  endfunction

  // One read sequence, flags handled per cfg policy.
  task body();
    rd_to_fill_seq r = rd_to_fill_seq::type_id::create("drain");
    r.sb     = p_sequencer.sb;
    r.target = 0;
    r.policy = FLAG_CFG;
    r.start(p_sequencer.rd_sqr);
  endtask
endclass

// smoke_test's traffic (vplan §2.2): DEPTH+2 back-to-back writes with no reads, of which exactly
// the last two must be blocked (spec W5); then reads until empty plus two reads that must be blocked.
class smoke_vseq extends fifo_base_vseq;
  `uvm_object_utils(smoke_vseq)

  // Constructor (UVM factory signature).
  function new(string name = "smoke_vseq");
    super.new(name);
  endfunction

  // Write phase, then read phase; each checks its outcome counts. The flags are ignored on
  // purpose (FLAG_IGNORE) so the blocked attempts are certain, whatever the cfg says.
  task body();
    wr_burst_seq   w = wr_burst_seq::type_id::create("smoke_wr");
    rd_to_fill_seq r = rd_to_fill_seq::type_id::create("smoke_rd");

    // Fill: starting empty with no reads, exactly DEPTH writes are accepted, then blocked.
    w.n        = DEPTH + 2;
    w.policy   = FLAG_IGNORE;
    w.distinct = 1;
    w.start(p_sequencer.wr_sqr);
    if (w.n_accepted != DEPTH || w.n_blocked != 2)
      `uvm_error("SMOKE", $sformatf("writes: %0d accepted, %0d blocked, %0d gated; expected %0d, 2, 0 (spec W5, F12)",
                                    w.n_accepted, w.n_blocked, w.n_gated, DEPTH))

    // Empty: every entry comes back (scoreboard compares), then two reads at fill 0 are blocked.
    r.sb     = p_sequencer.sb;
    r.policy = FLAG_IGNORE;
    r.extra  = 2;
    r.start(p_sequencer.rd_sqr);
    if (r.n_accepted != DEPTH || r.n_extra_blocked != 2)
      `uvm_error("SMOKE", $sformatf("reads: %0d accepted, %0d of 2 final reads blocked; expected %0d and 2 (spec R4, F05)",
                                    r.n_accepted, r.n_extra_blocked, DEPTH))
    `uvm_info("SMOKE", $sformatf("writes %0d accepted / %0d blocked; reads %0d accepted / %0d blocked (%0d at fill 0)",
                                 w.n_accepted, w.n_blocked, r.n_accepted, r.n_blocked, r.n_extra_blocked), UVM_LOW)
  endtask
endclass

// Fill to full (vplan §2.2): rounds of [settle; write at 100% with no reads, flag ignored, until
// k blocked writes; drain at the cfg's read rate and flag policy]. Check F12 in every round:
// with wfull exact and no reads, exactly DEPTH - (starting fill) writes are accepted before the
// first blocked one. Starts from any fill, so random_mix can use it.
class vseq_fill_to_full extends fifo_base_vseq;
  `uvm_object_utils(vseq_fill_to_full)

  int unsigned rounds = 0;  // 0: draw 4..6 (each round reads DEPTH, so 4 meet S5)

  // Constructor (UVM factory signature).
  function new(string name = "vseq_fill_to_full");
    super.new(name);
  endfunction

  // The rounds.
  task body();
    if (rounds == 0) rounds = $urandom_range(6, 4);
    for (int unsigned r = 1; r <= rounds; r++) one_round(r);
  endtask

  // One round: measured fill, capacity check, then the drain.
  protected task one_round(int unsigned r);
    wr_until_blocked_seq w = wr_until_blocked_seq::type_id::create("fill");
    rd_to_fill_seq       d = rd_to_fill_seq::type_id::create("drain");
    int                  f0;
    settle_wr();
    f0  = p_sequencer.sb.fill();
    w.k = draw_k();
    w.start(p_sequencer.wr_sqr);
    if (int'(w.n_before_block) != DEPTH - f0)
      `uvm_error("F12_CAPACITY", $sformatf("round %0d: from fill %0d, %0d writes accepted before the first blocked one; expected %0d (F12)",
                                           r, f0, w.n_before_block, DEPTH - f0))
    `uvm_info("FILL", $sformatf("round %0d/%0d: from fill %0d, %0d writes accepted, then %0d blocked; draining at %0d%%",
                                r, rounds, f0, w.n_before_block, w.n_blocked, p_sequencer.cfg.rd_rate_pct), UVM_LOW)
    d.sb     = p_sequencer.sb;
    d.target = 0;
    d.rate   = p_sequencer.cfg.rd_rate_pct;
    d.policy = FLAG_CFG;
    d.start(p_sequencer.rd_sqr);
  endtask
endclass

// Drain to empty (vplan §2.2): rounds of [fill to DEPTH at the cfg's write rate and flag policy;
// settle; read at 100%, flag ignored, until k blocked reads]. Check in every round: with rempty
// exact and no writes, exactly (starting fill) reads are accepted before the first blocked one.
class vseq_drain_to_empty extends fifo_base_vseq;
  `uvm_object_utils(vseq_drain_to_empty)

  int unsigned rounds = 0;  // 0: draw 4..6 (each round reads DEPTH, so 4 meet S5)

  // Constructor (UVM factory signature).
  function new(string name = "vseq_drain_to_empty");
    super.new(name);
  endfunction

  // The rounds.
  task body();
    if (rounds == 0) rounds = $urandom_range(6, 4);
    for (int unsigned r = 1; r <= rounds; r++) one_round(r);
  endtask

  // One round: fill, measured drain, count check.
  protected task one_round(int unsigned r);
    wr_to_fill_seq       f = wr_to_fill_seq::type_id::create("fill");
    rd_until_blocked_seq d = rd_until_blocked_seq::type_id::create("drain");
    int                  f0;
    f.sb     = p_sequencer.sb;
    f.target = DEPTH;
    f.rate   = p_sequencer.cfg.wr_rate_pct;
    f.policy = FLAG_CFG;
    f.start(p_sequencer.wr_sqr);
    settle_rd();
    f0  = p_sequencer.sb.fill();
    d.k = draw_k();
    d.start(p_sequencer.rd_sqr);
    if (int'(d.n_before_block) != f0)
      `uvm_error("DRAIN_COUNT", $sformatf("round %0d: from fill %0d, %0d reads accepted before the first blocked one; expected %0d (F05/F07)",
                                          r, f0, d.n_before_block, f0))
    `uvm_info("DRAIN", $sformatf("round %0d/%0d: filled at %0d%%; from fill %0d, %0d reads accepted, then %0d blocked",
                                 r, rounds, p_sequencer.cfg.wr_rate_pct, f0, d.n_before_block, d.n_blocked), UVM_LOW)
  endtask
endclass

// Thrash at full (vplan §2.2): reach DEPTH-1 (during the reset gap if the write side is out
// first: F17 stimulus), wait until both sides are out of reset, then write at 100% while reading
// at 1/d of the write side's full rate (both flag policies per cfg), so the fill bounces between
// DEPTH-1 and DEPTH. Lasts n_ops accepted reads. Checks at least min_crossings DEPTH-1 <-> DEPTH crossings in
// the thrash window: fewer means the pacing failed at this ratio, or a flag is stuck.
// Why d >= 2K+1 (owner decision, M4; DEC-009): at an aligned 4:1 ratio the refill lands exactly
// one slow edge after each read, so a crossing needs a gap of 2+ slow edges, and the expected
// count is 2*n_ops*(1 - (K+1)/d). d = K+1 gives none; d = 5..6 still fell below 20 in 200 seeds.
class vseq_thrash_full extends fifo_base_vseq;
  `uvm_object_utils(vseq_thrash_full)

  int unsigned n_ops         = (4 * DEPTH > 64) ? 4 * DEPTH : 64;  // accepted reads; 4*DEPTH meets S5
  int unsigned d             = 0;   // pacing divisor; 0: draw 2K+1..2K+4 (+THRASH_D= overrides)
  int unsigned min_crossings = 20;  // THRASH_WEAK below this; 0: no check (short form)

  // Constructor (UVM factory signature).
  function new(string name = "vseq_thrash_full");
    super.new(name);
  endfunction

  // Seek, pace, thrash, check.
  task body();
    fifo_env_cfg cfg = p_sequencer.cfg;
    wr_burst_seq w   = wr_burst_seq::type_id::create("thrash_wr");
    rd_burst_seq r   = rd_burst_seq::type_id::create("thrash_rd");
    if (d == 0 && !$value$plusargs("THRASH_D=%d", d)) d = $urandom_range(2 * K + 4, 2 * K + 1);
    seek_fill(DEPTH - 1);
    wait_both_released();
    w.n      = 0;
    w.rate   = 100;
    w.policy = FLAG_CFG;
    r.n        = 0;
    r.n_accept = n_ops;
    r.rate     = paced_rate(cfg.rclk_period_ps, cfg.wclk_period_ps, d);
    r.policy   = FLAG_CFG;
    `uvm_info("THRASH", $sformatf("full: d=%0d, writes 100%%, reads %0d%% (read/write effective rate = 1/%.2f), %0d reads",
                                  d, r.rate, 100.0 * cfg.rclk_period_ps / (r.rate * cfg.wclk_period_ps), n_ops), UVM_LOW)
    p_sequencer.sb.open_window();
    fork
      begin r.start(p_sequencer.rd_sqr); w.stop = 1; end
      w.start(p_sequencer.wr_sqr);
    join
    report_window("full", p_sequencer.sb.win_full_x, w.n_accepted, r.n_accepted, w.n_blocked);
  endtask

  // Window summary and the crossing check (shared with vseq_thrash_empty).
  protected function void report_window(string side, int unsigned crossings, int unsigned wr_acc,
                                        int unsigned rd_acc, int unsigned blocked);
    fifo_scoreboard sb = p_sequencer.sb;
    `uvm_info("THRASH", $sformatf("%s: %0d writes, %0d reads accepted, %0d blocked; fill in [%0d, %0d]; %0d crossings at the %s boundary",
                                  side, wr_acc, rd_acc, blocked, sb.win_min, sb.win_max, crossings, side), UVM_LOW)
    if (crossings < min_crossings)
      `uvm_error("THRASH_WEAK", $sformatf("only %0d crossings at the %s boundary, need %0d (pacing at this ratio, or a stuck flag: F08)",
                                          crossings, side, min_crossings))
  endfunction
endclass

// Thrash at empty: the mirror image around 0 and 1. Reach fill 1, wait until both sides are out
// of reset, then read at 100% while writing at 1/d of the read side's full rate; lasts n_ops
// accepted writes. Without the wait, paced writes during a long reset gap filled the FIFO while
// the reader was still in reset and starved the thrash (closure H03). Same pacing rule
// (the worst case is an aligned 1:4 ratio).
class vseq_thrash_empty extends vseq_thrash_full;
  `uvm_object_utils(vseq_thrash_empty)

  // Constructor (UVM factory signature).
  function new(string name = "vseq_thrash_empty");
    super.new(name);
  endfunction

  // Seek, pace, thrash, check.
  task body();
    fifo_env_cfg cfg = p_sequencer.cfg;
    wr_burst_seq w   = wr_burst_seq::type_id::create("thrash_wr");
    rd_burst_seq r   = rd_burst_seq::type_id::create("thrash_rd");
    if (d == 0 && !$value$plusargs("THRASH_D=%d", d)) d = $urandom_range(2 * K + 4, 2 * K + 1);
    seek_fill(1);
    wait_both_released();
    r.n      = 0;
    r.rate   = 100;
    r.policy = FLAG_CFG;
    w.n        = 0;
    w.n_accept = n_ops;
    w.rate     = paced_rate(cfg.wclk_period_ps, cfg.rclk_period_ps, d);
    w.policy   = FLAG_CFG;
    `uvm_info("THRASH", $sformatf("empty: d=%0d, reads 100%%, writes %0d%% (write/read effective rate = 1/%.2f), %0d writes",
                                  d, w.rate, 100.0 * cfg.wclk_period_ps / (w.rate * cfg.rclk_period_ps), n_ops), UVM_LOW)
    p_sequencer.sb.open_window();
    fork
      begin w.start(p_sequencer.wr_sqr); r.stop = 1; end
      r.start(p_sequencer.rd_sqr);
    join
    report_window("empty", p_sequencer.sb.win_empty_x, w.n_accepted, r.n_accepted, r.n_blocked);
  endtask
endclass
