// fifo_coverage.sv — functional coverage collector: the six covergroups of vplan §3 (150 bins).
// Every bin is sampled from the reference model (scoreboard steps and fill) and the monitors'
// edge samples, never from the DUT's flags alone, so a buggy flag cannot fake coverage. Bucket
// and phase come from fifo_env_cfg. Coverage is type-level (option.per_instance = 0): bins are
// recorded by covergroup type, so the regression merges them across runs (toolchain T11).
// Each covergroup with a "× bucket" cross carries a helper cp_bucket; its 5 bins are implied by
// the cross and are not counted in the vplan total.

// Analysis imps for the per-edge monitor streams and the scoreboard's time steps (macros must
// sit at package scope).
`uvm_analysis_imp_decl(_wr_edge)
`uvm_analysis_imp_decl(_rd_edge)
`uvm_analysis_imp_decl(_step)

class fifo_coverage extends uvm_component;
  `uvm_component_utils(fifo_coverage)

  uvm_analysis_imp_wr_edge #(wr_item, fifo_coverage)        wr_edge_imp;
  uvm_analysis_imp_rd_edge #(rd_item, fifo_coverage)        rd_edge_imp;
  uvm_analysis_imp_step    #(fifo_step_item, fifo_coverage) step_imp;
  fifo_env_cfg    cfg;  // set by fifo_env: bucket, kind, phase, release order
  fifo_scoreboard sb;   // set by fifo_env: fill at the start of a time step

  // Event codes for cg_flags and cg_attempts (plain ints: the bins hold constants).
  localparam int EV_WFULL_RISE = 0, EV_WFULL_FALL = 1, EV_REMPTY_RISE = 2, EV_REMPTY_FALL = 3,
                 EV_WFULL_LAG = 4, EV_REMPTY_LAG = 5;
  localparam int BL_WRITE_AT_FULL = 0, BL_WRITE_LAG = 1, BL_READ_AT_EMPTY = 2, BL_READ_LAG = 3;

  // Run state: this run's ratio bucket; previous flag values (rise/fall); reset bookkeeping.
  protected int  bucket;
  protected bit  prev_wfull = 0, prev_rempty = 1;   // reset values (F01) before the first edge
  protected bit  wr_out_seen, rd_out_seen;          // each side seen out of reset
  protected bit  winc_in_reset, rinc_in_reset;      // cp_*_in_reset: seen at least once
  protected int unsigned n_wr_acc;                  // accepted writes seen on wr edges
  protected time t_last_wr_acc;                     // time of the latest of them
  protected int unsigned wr_before_rd_release;      // snapshot at the read side's release edge
  protected bit  reset_sampled;

  // Sample counts per covergroup, for the log and the report_phase sanity check.
  int unsigned n_cfg, n_reset, n_fill, n_conc, n_flags, n_attempts;

  // ---- cg_cfg: once per run (vplan S1): every bucket, integer vs arbitrary, edge phase.
  covergroup cg_cfg with function sample(int b, bit is_int, bit aligned);
    option.per_instance = 0;
    cp_bucket: coverpoint b { bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; bins B4 = {4}; }
    cp_kind:   coverpoint is_int { bins int_ratio = {1}; bins arbitrary = {0}; }
    cp_phase:  coverpoint aligned { bins aligned = {1}; bins unaligned = {0}; }
    x_bucket_kind: cross cp_bucket, cp_kind;
    x_b2_phase:    cross cp_bucket, cp_phase { ignore_bins not_b2 = !binsof(cp_bucket) intersect {2}; }
  endgroup

  // ---- cg_reset: once per run, when the second reset is released (F01, F17).
  covergroup cg_reset with function sample(bit w_first, int writes, bit winc_seen, bit rinc_seen);
    option.per_instance = 0;
    cp_order: coverpoint w_first { bins w_first = {1}; bins r_first = {0}; }
    cp_writes_before_rd_release: coverpoint writes { bins none = {0}; bins some = {[1:DEPTH-1]}; bins full = {DEPTH}; }
    x_order_writes: cross cp_order, cp_writes_before_rd_release {
      ignore_bins r_first_writes = binsof(cp_order.r_first) && binsof(cp_writes_before_rd_release) intersect {[1:DEPTH]}; }
    cp_winc_in_reset: coverpoint winc_seen { bins seen = {1}; }
    cp_rinc_in_reset: coverpoint rinc_seen { bins seen = {1}; }
  endgroup

  // ---- cg_fill: at the end of each time step whose net fill changed (F02, F03, F12, F13).
  // lap = 2*(f == DEPTH) + bit ASIZE of the write count; only meaningful at 0 and DEPTH.
  covergroup cg_fill with function sample(int f, int b, int lap);
    option.per_instance = 0;
    cp_fill: coverpoint f { bins zero = {0}; bins one = {1}; bins mid = {[2:DEPTH-2]};
                            bins almost_full = {DEPTH-1}; bins full = {DEPTH}; }
    cp_fill_trans: coverpoint f { bins full_bounce  = (DEPTH-1 => DEPTH => DEPTH-1);
                                  bins empty_bounce = (1 => 0 => 1); }
    cp_lap: coverpoint lap iff (f == 0 || f == DEPTH) {
      bins empty_msb0 = {0}; bins empty_msb1 = {1}; bins full_msb0 = {2}; bins full_msb1 = {3}; }
    cp_bucket: coverpoint b { bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; bins B4 = {4}; }
    x_fill_bucket:  cross cp_fill, cp_bucket;
    x_trans_bucket: cross cp_fill_trans, cp_bucket;
  endgroup

  // ---- cg_concurrent: time steps with an accepted write and an accepted read (F16); f is the
  // fill at the start of the step. At 0 or DEPTH such a pair is a scoreboard error, not a bin.
  covergroup cg_concurrent with function sample(int f, int b);
    option.per_instance = 0;
    cp_start_fill: coverpoint f { bins at_one = {1}; bins at_depth_m1 = {DEPTH-1}; }
    cp_bucket: coverpoint b { bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; bins B4 = {4}; }
    x_concurrent_bucket: cross cp_start_fill, cp_bucket;
  endgroup

  // ---- cg_flags: flag edges and the lag window F08 checks, at the flag's own clock edges out
  // of reset. One sample per event: an edge can give two (e.g. wfull_rise and wfull_lag).
  covergroup cg_flags with function sample(int ev, int b);
    option.per_instance = 0;
    cp_flag_event: coverpoint ev { bins wfull_rise = {EV_WFULL_RISE}; bins wfull_fall = {EV_WFULL_FALL};
                                   bins rempty_rise = {EV_REMPTY_RISE}; bins rempty_fall = {EV_REMPTY_FALL};
                                   bins wfull_lag = {EV_WFULL_LAG}; bins rempty_lag = {EV_REMPTY_LAG}; }
    cp_bucket: coverpoint b { bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; bins B4 = {4}; }
    x_flag_bucket: cross cp_flag_event, cp_bucket;
  endgroup

  // ---- cg_attempts: blocked writes and reads out of reset (F04, F05), split by the true fill at
  // the start of the step: only write_at_full can expose an overwrite (B03).
  covergroup cg_attempts with function sample(int ev, int b);
    option.per_instance = 0;
    cp_blocked: coverpoint ev { bins write_at_full = {BL_WRITE_AT_FULL}; bins write_lag = {BL_WRITE_LAG};
                                bins read_at_empty = {BL_READ_AT_EMPTY}; bins read_lag = {BL_READ_LAG}; }
    cp_bucket: coverpoint b { bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; bins B4 = {4}; }
    x_blocked_bucket: cross cp_blocked, cp_bucket;
  endgroup

  // Constructor: embedded covergroups must be created here (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_cfg        = new();
    cg_reset      = new();
    cg_fill       = new();
    cg_concurrent = new();
    cg_flags      = new();
    cg_attempts   = new();
  endfunction

  // Create the imps.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wr_edge_imp = new("wr_edge_imp", this);
    rd_edge_imp = new("rd_edge_imp", this);
    step_imp    = new("step_imp", this);
  endfunction

  // The cfg is final once the test's build_phase is over: record the run's configuration.
  function void start_of_simulation_phase(uvm_phase phase);
    bucket = cfg.ratio_bucket();
    cg_cfg.sample(bucket, fifo_env_cfg::is_int_ratio(cfg.wclk_period_ps, cfg.rclk_period_ps),
                  cfg.phase_aligned());
    n_cfg++;
  endfunction

  // Accepted writes before time t: a write at t itself (same instant) does not count (spec §5).
  protected function int unsigned writes_before(time t);
    return (n_wr_acc != 0 && t_last_wr_acc == t) ? n_wr_acc - 1 : n_wr_acc;
  endfunction

  // Once both sides have been seen out of reset, record the reset scenario (once per run).
  protected function void maybe_sample_reset();
    if (reset_sampled || !wr_out_seen || !rd_out_seen) return;
    cg_reset.sample(cfg.w_first, wr_before_rd_release, winc_in_reset, rinc_in_reset);
    n_reset++;
    reset_sampled = 1;
  endfunction

  // One call per wclk edge: reset bookkeeping, wfull events, blocked writes.
  function void write_wr_edge(wr_item it);
    if (it.status == OP_ACCEPTED) begin n_wr_acc++; t_last_wr_acc = it.t; end
    if (it.in_reset) begin
      if (it.inc) winc_in_reset = 1;
    end else begin
      int f = sb.fill_at_step_start(it.t);
      if (it.flag && !prev_wfull) sample_flag(EV_WFULL_RISE);
      if (!it.flag && prev_wfull) sample_flag(EV_WFULL_FALL);
      if (it.flag && f < DEPTH)   sample_flag(EV_WFULL_LAG);
      if (it.status == OP_BLOCKED) sample_blocked(f == DEPTH ? BL_WRITE_AT_FULL : BL_WRITE_LAG);
      wr_out_seen = 1;
      maybe_sample_reset();
    end
    prev_wfull = it.flag;
  endfunction

  // One call per rclk edge: reset bookkeeping, rempty events, blocked reads. The last in-reset
  // edge is the release edge (rrst_n rises after it), so the write snapshot taken there ends up
  // as "accepted writes before the read side's release".
  function void write_rd_edge(rd_item it);
    if (it.in_reset) begin
      if (it.inc) rinc_in_reset = 1;
      wr_before_rd_release = writes_before(it.t);
    end else begin
      int f = sb.fill_at_step_start(it.t);
      if (it.flag && !prev_rempty) sample_flag(EV_REMPTY_RISE);
      if (!it.flag && prev_rempty) sample_flag(EV_REMPTY_FALL);
      if (it.flag && f > 0)        sample_flag(EV_REMPTY_LAG);
      if (it.status == OP_BLOCKED) sample_blocked(f == 0 ? BL_READ_AT_EMPTY : BL_READ_LAG);
      rd_out_seen = 1;
      maybe_sample_reset();
    end
    prev_rempty = it.flag;
  endfunction

  // One call per completed time step of the model: fill level, transitions and pointer lap when
  // the fill changed; boundary concurrency when the step had both an accepted write and read.
  function void write_step(fifo_step_item st);
    if (st.fill_end != st.fill_start) begin
      cg_fill.sample(st.fill_end, bucket, 2 * int'(st.fill_end == DEPTH) + int'(st.n_writes[ASIZE]));
      n_fill++;
    end
    if (st.wr && st.rd) begin
      cg_concurrent.sample(st.fill_start, bucket);
      n_conc++;
    end
  endfunction

  // Sample one flag event / one blocked attempt at this run's bucket.
  protected function void sample_flag(int ev);
    cg_flags.sample(ev, bucket);
    n_flags++;
  endfunction
  protected function void sample_blocked(int ev);
    cg_attempts.sample(ev, bucket);
    n_attempts++;
  endfunction

  // A run that never recorded its configuration or its reset scenario means the collector is
  // miswired: fail the run rather than report coverage that silently stopped counting.
  function void check_phase(uvm_phase phase);
    if (n_cfg != 1 || n_reset != 1 || n_fill == 0)
      `uvm_error("COV_WIRING", $sformatf("expected 1 cfg sample, 1 reset sample and fill samples; got %0d, %0d, %0d",
                                         n_cfg, n_reset, n_fill))
  endfunction

  // Summary for the log: samples per covergroup and this run's own coverage per item (the merged
  // numbers come from the coverage database, toolchain T11).
  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf({"samples: cfg=%0d reset=%0d fill=%0d concurrent=%0d flags=%0d attempts=%0d; ",
                                "this run: x_fill_bucket=%0.1f%% x_flag_bucket=%0.1f%% x_blocked_bucket=%0.1f%% ",
                                "cp_fill_trans=%0.1f%% cp_lap=%0.1f%% cp_start_fill=%0.1f%%"},
                               n_cfg, n_reset, n_fill, n_conc, n_flags, n_attempts,
                               cg_fill.x_fill_bucket.get_inst_coverage(), cg_flags.x_flag_bucket.get_inst_coverage(),
                               cg_attempts.x_blocked_bucket.get_inst_coverage(), cg_fill.cp_fill_trans.get_inst_coverage(),
                               cg_fill.cp_lap.get_inst_coverage(), cg_concurrent.cp_start_fill.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
