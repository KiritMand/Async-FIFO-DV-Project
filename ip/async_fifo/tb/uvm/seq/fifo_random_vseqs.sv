// fifo_random_vseqs.sv — randomized virtual sequences (plan M4 step 2): vseq_random_rates (timed
// phases with independent write and read rates) and vseq_random_mix (a random series of every
// M4 virtual sequence). Parameter defaults are the owner-approved M4 values (vplan §2.2).

// Random rates: n_phases timed phases. Each phase lasts L cycles of the slower clock and gives
// each side its own rate, weighted toward 0% (that side idle: flag-exactness and F14 hold
// windows), 100% (back-to-back), and the middle. Both sides use the cfg's flag policies.
// With s5_top_up, extra phases at non-zero rates follow until 4*DEPTH reads were accepted (S5).
class vseq_random_rates extends fifo_base_vseq;
  `uvm_object_utils(vseq_random_rates)

  int unsigned n_phases  = 0;  // 0: draw 4..8
  bit          s5_top_up = 1;  // 0 in random_mix, which handles S5 itself

  // Constructor (UVM factory signature).
  function new(string name = "vseq_random_rates");
    super.new(name);
  endfunction

  // Approved rate distribution per side and phase: 0% weight 25, 100% weight 25, [10, 90]% weight 50.
  protected function int unsigned draw_rate();
    int unsigned x = $urandom_range(99, 0);
    if (x < 25) return 0;
    if (x < 50) return 100;
    return $urandom_range(90, 10);
  endfunction

  // The phases, then the S5 top-up phases (rates from [50, 100], so reads accumulate quickly).
  task body();
    int unsigned reads0 = p_sequencer.sb.n_reads;
    if (n_phases == 0) n_phases = $urandom_range(8, 4);
    for (int unsigned p = 1; p <= n_phases; p++) run_phase(p, draw_rate(), draw_rate());
    if (s5_top_up)
      while (p_sequencer.sb.n_reads - reads0 < 4 * DEPTH)
        run_phase(0, $urandom_range(100, 50), $urandom_range(100, 50));
  endtask

  // One phase: L = 2*DEPTH..8*DEPTH cycles of the slower clock, the same duration on both sides
  // (each counts its own edges). Phase 0 = S5 top-up.
  protected task run_phase(int unsigned p, int unsigned wr_rate, int unsigned rd_rate);
    fifo_env_cfg cfg    = p_sequencer.cfg;
    int unsigned len    = $urandom_range(8 * DEPTH, 2 * DEPTH);
    longint      dur_ps = longint'(len) * cfg.slow_period_ps();
    wr_burst_seq w      = wr_burst_seq::type_id::create("phase_wr");
    rd_burst_seq r      = rd_burst_seq::type_id::create("phase_rd");
    int unsigned rd0    = p_sequencer.sb.n_reads;
    w.n         = 0;
    w.rate      = wr_rate;
    w.max_edges = int'(dur_ps / cfg.wclk_period_ps);
    w.policy    = FLAG_CFG;
    r.n         = 0;
    r.rate      = rd_rate;
    r.max_edges = int'(dur_ps / cfg.rclk_period_ps);
    r.policy    = FLAG_CFG;
    fork
      w.start(p_sequencer.wr_sqr);
      r.start(p_sequencer.rd_sqr);
    join
    `uvm_info("RATES", $sformatf("phase %s: %0d slow cycles, wr %0d%% (%0d accepted, %0d blocked), rd %0d%% (%0d accepted, %0d blocked), fill now %0d",
                                 p == 0 ? string'("S5 top-up") : $sformatf("%0d/%0d", p, n_phases), len,
                                 wr_rate, w.n_accepted, w.n_blocked, rd_rate, p_sequencer.sb.n_reads - rd0,
                                 r.n_blocked, p_sequencer.sb.fill()), UVM_LOW)
  endtask
endclass

// Random mix: 4..8 picks, uniformly among the five M4 virtual sequences in a short form (one
// round, DEPTH thrash operations, 1..2 rate phases), then more picks until 4*DEPTH reads were
// accepted (S5). Each pick starts from whatever fill the previous one left.
class vseq_random_mix extends fifo_base_vseq;
  `uvm_object_utils(vseq_random_mix)

  int unsigned n_picks = 0;  // 0: draw 4..8

  // Constructor (UVM factory signature).
  function new(string name = "vseq_random_mix");
    super.new(name);
  endfunction

  // Picks until both the count and S5 are met.
  task body();
    int unsigned reads0 = p_sequencer.sb.n_reads;
    int unsigned i      = 0;
    if (n_picks == 0) n_picks = $urandom_range(8, 4);
    while (i < n_picks || p_sequencer.sb.n_reads - reads0 < 4 * DEPTH) begin
      i++;
      run_pick(i, $urandom_range(4, 0));
    end
  endtask

  // One short-form sequence, started as a child of this one. Thrash windows are too short for
  // the 20-crossing check, which the thrash tests carry; every other check stays on.
  protected task run_pick(int unsigned i, int unsigned which);
    string names[5] = '{"fill_to_full", "drain_to_empty", "thrash_full", "thrash_empty", "random_rates"};
    `uvm_info("MIX", $sformatf("pick %0d: %s from fill %0d", i, names[which], p_sequencer.sb.fill()), UVM_LOW)
    case (which)
      0: begin
        vseq_fill_to_full s = vseq_fill_to_full::type_id::create("mix_fill");
        s.rounds = 1;
        s.start(p_sequencer, this);
      end
      1: begin
        vseq_drain_to_empty s = vseq_drain_to_empty::type_id::create("mix_drain");
        s.rounds = 1;
        s.start(p_sequencer, this);
      end
      2: begin
        vseq_thrash_full s = vseq_thrash_full::type_id::create("mix_thrash_full");
        s.n_ops         = DEPTH;
        s.min_crossings = 0;
        s.start(p_sequencer, this);
      end
      3: begin
        vseq_thrash_empty s = vseq_thrash_empty::type_id::create("mix_thrash_empty");
        s.n_ops         = DEPTH;
        s.min_crossings = 0;
        s.start(p_sequencer, this);
      end
      default: begin
        vseq_random_rates s = vseq_random_rates::type_id::create("mix_rates");
        s.n_phases  = $urandom_range(2, 1);
        s.s5_top_up = 0;
        s.start(p_sequencer, this);
      end
    endcase
  endtask
endclass
