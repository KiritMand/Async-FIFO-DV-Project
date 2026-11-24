// fifo_env_cfg.sv — one run's configuration: clocks, resets and traffic knobs (plan M3 step 4;
// vplan §2.3 S1, S2, S4; values approved by the owner on 2026-11-24).
// Two stages, because no constraint solver gives the planned distribution (toolchain T10):
//   1. categories (bucket, integer/arbitrary, aligned, reset order, gap class, rate classes,
//      flag policy) come from randomize() with an explicit `dist` on each;
//   2. the numbers inside the chosen categories are drawn uniformly by post_randomize().
// Plusargs override either stage, and the result is always checked against the same rules.

class fifo_env_cfg extends uvm_object;
  `uvm_object_utils(fifo_env_cfg)

  // ---- Stage 1: categories. rho = f_wclk / f_rclk = T_rclk / T_wclk (vplan §1.3).
  rand int unsigned bucket;         // 0..4 = B0..B4
  rand bit          is_integer;     // the bucket's exact integer ratio: rho = 1/4, 1/2, 1, 2, 4
  rand bit          aligned;        // integer runs only: rclk phase 0, so rising edges coincide
  rand bit          w_first;        // reset release order: 1 = write side released first
  rand int unsigned gap_class;      // 0: gap 0; 1: [1, DEPTH-1]; 2: [DEPTH, 3*DEPTH] cycles
  rand int unsigned wr_rate_class;  // 0: 100%; 1: [50, 99]%; 2: [10, 49]%
  rand int unsigned rd_rate_class;  // same classes for reads
  rand bit          respect_full;   // 1: the producer gates winc with wfull (no blocked writes)
  rand bit          respect_empty;  // 1: the consumer gates rinc with rempty (no blocked reads)
  rand bit          blocked_all;    // 1: blocked_attempt_pct = 100; 0: [10, 99]

  // Approved weights. Every choice carries its own dist: without one, Verilator's solver does
  // not spread values evenly (T10: buckets came out 72/12/2/0/14%).
  constraint c_bucket { bucket dist {0 := 1, 1 := 1, 2 := 1, 3 := 1, 4 := 1}; }
  constraint c_kind   { is_integer dist {1 := 20, 0 := 80}; aligned dist {1 := 50, 0 := 50}; }
  constraint c_reset  { w_first dist {1 := 50, 0 := 50};
                        gap_class dist {0 := 20, 1 := 40, 2 := 40}; }
  constraint c_rates  { wr_rate_class dist {0 := 30, 1 := 40, 2 := 30};
                        rd_rate_class dist {0 := 30, 1 := 40, 2 := 30}; }
  constraint c_flags  { respect_full dist {1 := 50, 0 := 50};
                        respect_empty dist {1 := 50, 0 := 50};
                        blocked_all dist {1 := 30, 0 := 70}; }

  // Categorical plusarg overrides (+BUCKET, +KIND, +RST_ORDER, or derived from both periods).
  bit has_bucket, has_kind, has_order;
  int unsigned ovr_bucket;
  bit ovr_kind, ovr_w_first;
  constraint c_ovr { has_bucket -> bucket == ovr_bucket;
                     has_kind   -> is_integer == ovr_kind;
                     has_order  -> w_first == ovr_w_first; }

  // ---- Stage 2: numbers, drawn by post_randomize() or set by plusargs.
  int unsigned wclk_period_ps;       // multiple of 8 in [2000, 20000] (+WCLK_PS: any even value there)
  int unsigned rclk_period_ps;       // even, with rho inside the bucket (+RCLK_PS)
  int unsigned rclk_phase_ps;        // rclk first rises at clk_start_ps + this (+RPHASE_PS)
  int unsigned rst_hold;             // the first side leaves reset at its rst_hold-th rising edge
  int unsigned rst_gap;              // cycles of that clock until the other side's release (+RST_GAP)
  int unsigned wr_rate_pct;          // chance of a write attempt on a given wclk cycle
  int unsigned rd_rate_pct;          // chance of a read attempt on a given rclk cycle
  int unsigned blocked_attempt_pct;  // with respect_* = 0: chance an attempt ignores its flag

  // Numeric plusarg overrides; 0 / unset = not given.
  int unsigned ovr_wclk_ps, ovr_rclk_ps, ovr_phase_ps, ovr_gap;
  bit has_phase, has_gap;

  // Integer-ratio share set by a test before randomize_all() (owner decision M4/D1: 50% in the
  // thrash tests, so coincident edges for F16 are common). 0 = the approved 20% dist in c_kind.
  int unsigned int_pct = 0;

  // ---- Fixed settings (owner-approved defaults).
  int unsigned clk_start_ps      = 1000;   // wclk's first rising edge; no clock edge at time 0
  int unsigned timeout_cycles    = 20000;  // watchdog in cycles of the slower clock (+TIMEOUT_CYCLES)
  int unsigned drain_wait_cycles = 10;     // slower-clock cycles to wait after the drain (S6)

  // Constructor (UVM factory signature).
  function new(string name = "fifo_env_cfg");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------------------
  // Ratio helpers (integer arithmetic, no rounding). Also used by coverage in M5.
  // ---------------------------------------------------------------------------------------

  // Bucket of a period pair per vplan §1.3, or -1 if rho is outside [1/4, 4].
  static function int bucket_of(int unsigned wp, int unsigned rp);
    longint w = longint'(wp), r = longint'(rp);  // 64-bit: 105 * T_rclk may exceed 32 bits
    if (4 * r >= w && 2 * r < w)                return 0;  // B0 [0.25, 0.5)
    if (2 * r >= w && 100 * r < 95 * w)         return 1;  // B1 [0.5, 0.95)
    if (100 * r >= 95 * w && 100 * r <= 105 * w) return 2;  // B2 [0.95, 1.05]
    if (100 * r > 105 * w && r <= 2 * w)        return 3;  // B3 (1.05, 2.0]
    if (r > 2 * w && r <= 4 * w)                return 4;  // B4 (2.0, 4.0]
    return -1;
  endfunction

  // True if the pair is exactly one of the five integer ratios.
  static function bit is_int_ratio(int unsigned wp, int unsigned rp);
    longint w = longint'(wp), r = longint'(rp);
    return 4 * r == w || 2 * r == w || r == w || r == 2 * w || r == 4 * w;
  endfunction

  // T_rclk for the bucket's integer ratio (1/4, 1/2, 1, 2, 4 times T_wclk).
  static function int unsigned int_rclk(int unsigned b, int unsigned w);
    case (b)
      0:       return w / 4;
      1:       return w / 2;
      2:       return w;
      3:       return 2 * w;
      default: return 4 * w;
    endcase
  endfunction

  // Bucket of this configuration's periods (coverage cp_bucket).
  function int ratio_bucket();
    return bucket_of(wclk_period_ps, rclk_period_ps);
  endfunction

  // Coverage cp_phase: the first rising rclk edge lies within 5% of T_wclk of a rising wclk edge.
  function bit phase_aligned();
    int unsigned off = rclk_phase_ps % wclk_period_ps;
    int unsigned d   = (off <= wclk_period_ps - off) ? off : wclk_period_ps - off;
    return 20 * d <= wclk_period_ps;
  endfunction

  // Period of the slower clock (watchdog and drain timing).
  function int unsigned slow_period_ps();
    return (wclk_period_ps > rclk_period_ps) ? wclk_period_ps : rclk_period_ps;
  endfunction

  // ---------------------------------------------------------------------------------------
  // Randomization
  // ---------------------------------------------------------------------------------------

  // Full randomization for a test: read the plusargs, randomize the categories (overrides as
  // constraints), let post_randomize() draw the numbers, then check. 0 = contradiction/failure.
  function bit randomize_all();
    string s;
    // Categorical overrides.
    has_bucket = $value$plusargs("BUCKET=%d", ovr_bucket);
    if ($value$plusargs("KIND=%s", s)) begin
      if (s != "int" && s != "arb") begin
        `uvm_error("CFG", {"+KIND must be int or arb, got ", s})
        return 0;
      end
      has_kind = 1; ovr_kind = (s == "int");
    end
    if ($value$plusargs("RST_ORDER=%s", s)) begin
      if (s != "w" && s != "r") begin
        `uvm_error("CFG", {"+RST_ORDER must be w or r, got ", s})
        return 0;
      end
      has_order = 1; ovr_w_first = (s == "w");
    end
    // Numeric overrides.
    void'($value$plusargs("WCLK_PS=%d", ovr_wclk_ps));
    void'($value$plusargs("RCLK_PS=%d", ovr_rclk_ps));
    has_phase = $value$plusargs("RPHASE_PS=%d", ovr_phase_ps);
    has_gap   = $value$plusargs("RST_GAP=%d", ovr_gap);
    void'($value$plusargs("TIMEOUT_CYCLES=%d", timeout_cycles));

    // Both periods given: they decide bucket and kind; a contradicting +BUCKET/+KIND is an error.
    if (ovr_rclk_ps != 0) begin
      int b;
      if (ovr_wclk_ps == 0) begin
        `uvm_error("CFG", "+RCLK_PS needs +WCLK_PS")
        return 0;
      end
      b = bucket_of(ovr_wclk_ps, ovr_rclk_ps);
      if (b < 0 || (has_bucket && ovr_bucket != b) ||
          (has_kind && ovr_kind != is_int_ratio(ovr_wclk_ps, ovr_rclk_ps))) begin
        `uvm_error("CFG", $sformatf("+WCLK_PS=%0d +RCLK_PS=%0d contradict +BUCKET/+KIND or leave [1/4, 4]",
                                     ovr_wclk_ps, ovr_rclk_ps))
        return 0;
      end
      has_bucket = 1; ovr_bucket = b;
      has_kind = 1; ovr_kind = is_int_ratio(ovr_wclk_ps, ovr_rclk_ps);
    end

    // A test's integer-ratio share: drawn here as an override, so the solver needs nothing new
    // (toolchain T10 covers constant dist weights only). +KIND or both periods still win.
    if (int_pct != 0 && !has_kind) begin
      has_kind = 1;
      ovr_kind = ($urandom_range(99, 0) < int_pct);
    end

    if (this.randomize() != 1) begin
      `uvm_error("CFG", "randomize() failed (contradicting plusargs?)")
      return 0;
    end
    return check();
  endfunction

  // Stage 2: numbers uniformly inside the categories (overrides win).
  function void post_randomize();
    // Clock periods.
    wclk_period_ps = (ovr_wclk_ps != 0) ? ovr_wclk_ps : 8 * $urandom_range(2500, 250);
    if (ovr_rclk_ps != 0)  rclk_period_ps = ovr_rclk_ps;
    else if (is_integer)   rclk_period_ps = int_rclk(bucket, wclk_period_ps);
    else                   rclk_period_ps = draw_arbitrary_rclk();
    // Phase: aligned integer runs start both clocks together; otherwise uniform in [0, T_rclk).
    if (!is_integer) aligned = 0;
    if (has_phase)    rclk_phase_ps = ovr_phase_ps;
    else if (aligned) rclk_phase_ps = 0;
    else              rclk_phase_ps = $urandom_range(rclk_period_ps - 1, 0);
    // Resets.
    rst_hold = $urandom_range(8, 2);
    if (has_gap) begin
      rst_gap   = ovr_gap;
      gap_class = (ovr_gap == 0) ? 0 : (ovr_gap < DEPTH) ? 1 : 2;
    end else begin
      case (gap_class)
        0:       rst_gap = 0;
        1:       rst_gap = $urandom_range(DEPTH - 1, 1);
        default: rst_gap = $urandom_range(3 * DEPTH, DEPTH);
      endcase
    end
    // Traffic.
    wr_rate_pct         = rate_of(wr_rate_class);
    rd_rate_pct         = rate_of(rd_rate_class);
    blocked_attempt_pct = blocked_all ? 100 : $urandom_range(99, 10);
  endfunction

  // Arbitrary ratio: an even T_rclk uniform over the bucket (both ends as in vplan §1.3), never
  // the bucket's integer ratio. Rejection sampling over a slightly wider range keeps it uniform.
  protected function int unsigned draw_arbitrary_rclk();
    int unsigned w = wclk_period_ps, lo, hi, r;
    case (bucket)
      0:       begin lo = w / 4;          hi = w / 2;              end
      1:       begin lo = w / 2;          hi = w;                  end
      2:       begin lo = w * 95 / 100;   hi = w * 105 / 100 + 1;  end
      3:       begin lo = w;              hi = 2 * w;              end
      default: begin lo = 2 * w;          hi = 4 * w;              end
    endcase
    repeat (1000) begin
      r = 2 * $urandom_range(hi / 2, (lo + 1) / 2);
      if (bucket_of(w, r) == int'(bucket) && !is_int_ratio(w, r)) return r;
    end
    `uvm_fatal("CFG", $sformatf("no arbitrary T_rclk found for T_wclk=%0d in B%0d", w, bucket))
    return 0;
  endfunction

  // Rate class to a percentage.
  protected function int unsigned rate_of(int unsigned cls);
    case (cls)
      0:       return 100;
      1:       return $urandom_range(99, 50);
      default: return $urandom_range(49, 10);
    endcase
  endfunction

  // The rules every configuration must meet, overrides included (owner decision: out-of-range
  // plusargs are rejected, never adjusted). Reports the first broken rule; 0 = invalid.
  function bit check();
    string err;
    if (wclk_period_ps < 2000 || wclk_period_ps > 20000 || wclk_period_ps % 2 != 0)
      err = "T_wclk must be even and in [2000, 20000] ps";
    else if (rclk_period_ps % 2 != 0)
      err = "T_rclk must be even (exact 50% duty cycle)";
    else if (ratio_bucket() != int'(bucket))
      err = $sformatf("T_rclk/T_wclk is in bucket %0d, not B%0d", ratio_bucket(), bucket);
    else if (is_int_ratio(wclk_period_ps, rclk_period_ps) != is_integer)
      err = "kind (integer/arbitrary) does not match the periods";
    else if (rclk_phase_ps >= rclk_period_ps)
      err = "rclk phase must be in [0, T_rclk)";
    else if (rst_gap > 3 * DEPTH)
      err = $sformatf("reset gap must be in [0, 3*DEPTH = %0d]", 3 * DEPTH);
    if (err != "") begin
      `uvm_error("CFG", {"invalid configuration: ", err, " -- ", convert2string()})
      return 0;
    end
    return 1;
  endfunction

  // One-line summary for the log, ending with the plusargs that reproduce clocks and resets.
  // string'() on the ternaries: between two literals `?:` is a bit vector, so the shorter text
  // would be zero-padded to the longer one's width (stray blanks in the log).
  function string convert2string();
    return $sformatf({"B%0d %s rho=%.3f T_wclk=%0dps T_rclk=%0dps rphase=%0dps%s | ",
                      "reset %s first, hold=%0d gap=%0d | wr_rate=%0d%% rd_rate=%0d%% ",
                      "respect_full=%0d respect_empty=%0d blocked=%0d%% | plusargs: ",
                      "+WCLK_PS=%0d +RCLK_PS=%0d +RPHASE_PS=%0d +RST_ORDER=%s +RST_GAP=%0d"},
                     bucket, is_integer ? string'("integer") : string'("arbitrary"),
                     real'(rclk_period_ps) / real'(wclk_period_ps),
                     wclk_period_ps, rclk_period_ps, rclk_phase_ps, phase_aligned() ? string'(" (aligned)") : string'(""),
                     w_first ? "w" : "r", rst_hold, rst_gap, wr_rate_pct, rd_rate_pct,
                     respect_full, respect_empty, blocked_attempt_pct,
                     wclk_period_ps, rclk_period_ps, rclk_phase_ps, w_first ? "w" : "r", rst_gap);
  endfunction
endclass
