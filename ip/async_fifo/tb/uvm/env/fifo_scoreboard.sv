// fifo_scoreboard.sv — reference model and end-to-end checks (plan M3 step 6; vplan F02–F07).
// A queue holds the expected contents, oldest first: accepted writes push, accepted reads pop and
// compare. Same-timestamp rule: overflow and underflow are judged on the fill at the *start* of
// the time step, so the order in which the two monitors deliver same-instant events can't hide
// an overflow or underflow (spec §5 coincident-edge rule). It also counts boundary crossings and
// keeps a window of fill statistics that the M4 thrash sequences check. Each completed time step
// is published on step_ap for fifo_coverage (cg_fill, cg_concurrent: sampled from the model).

// One completed simulation time step of the reference model (published by the scoreboard).
class fifo_step_item extends uvm_object;
  `uvm_object_utils(fifo_step_item)
  time         t;           // the step's timestamp
  int          fill_start;  // fill before any of the step's operations (spec §5 rule)
  int          fill_end;    // fill after all of them
  bit          wr, rd;      // the step had an accepted write / an accepted read
  int unsigned n_writes;    // accepted writes so far, this step included (pointer lap, F13)

  // Constructor (UVM factory signature).
  function new(string name = "fifo_step_item");
    super.new(name);
  endfunction
endclass

// Analysis imps for the two monitors (macros must sit at package scope).
`uvm_analysis_imp_decl(_wr)
`uvm_analysis_imp_decl(_rd)

class fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fifo_scoreboard)

  uvm_analysis_imp_wr #(wr_item, fifo_scoreboard) wr_imp;  // accepted writes
  uvm_analysis_imp_rd #(rd_item, fifo_scoreboard) rd_imp;  // accepted reads
  uvm_analysis_port #(fifo_step_item) step_ap;             // completed time steps (coverage)

  // Model state: expected contents; the time step being processed and its starting fill.
  protected data_t model[$];
  protected bit    in_step;
  protected time   t_step;
  protected int    fill_at_start;
  protected bit    step_wr, step_rd;  // this step has an accepted write / read

  // Results for the report (and for tests that check them). max/min are over step-end fills.
  int unsigned n_writes, n_reads, n_mismatch, n_overflow, n_underflow, n_unknown;
  int          max_fill = 0, min_fill = DEPTH;

  // Boundary crossings over the whole run (plan M4 step 4): a step-end fill change between
  // DEPTH-1 and DEPTH (full) or between 0 and 1 (empty), either direction. One time step changes
  // the fill by at most 1 (one edge per clock), so no crossing is skipped.
  int unsigned n_full_x, n_empty_x;
  protected int last_fill;  // step-end fill of the previous completed step

  // Window: the same statistics over an interval a virtual sequence chooses (open_window()), e.g.
  // only the thrash phase. Completed time steps only, like the run totals.
  int          win_min, win_max;
  int unsigned win_full_x, win_empty_x;

  // Boundary concurrency (F16): time steps with both an accepted write and an accepted read,
  // by the fill at the start of the step. The step-end hook M5's cg_concurrent will sample.
  int unsigned n_conc_at_one, n_conc_at_depth_m1, n_conc_other;

  // Self-test hook (+SB_INJECT_ERROR or +SB_INJECT_ERROR=n): flip bit 0 of the n-th read's
  // expected value, so a correct DUT must fail (plan M3 Done-when). 0 = off.
  protected int unsigned inject_at;

  // Constructor (UVM factory signature).
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Create the imps and arm the self-test hook if asked.
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wr_imp = new("wr_imp", this);
    rd_imp = new("rd_imp", this);
    step_ap = new("step_ap", this);
    if (!$value$plusargs("SB_INJECT_ERROR=%d", inject_at) && $test$plusargs("SB_INJECT_ERROR"))
      inject_at = 1;
    if (inject_at != 0)
      `uvm_info("SB_INJECT", $sformatf("armed: read #%0d will be compared against a wrong value", inject_at), UVM_NONE)
  endfunction

  // True fill right now. Within a time step it may include only some of that step's events;
  // between time steps it is exact. Sequences read it after the NBA region (rd_to_fill_seq).
  function int fill();
    return model.size();
  endfunction

  // Fill at the start of the time step at time t (spec §5): what flag and attempt coverage judge
  // against. Correct whichever monitor reports first: if no event of step t has been applied
  // yet, the current fill is the starting fill.
  function int fill_at_step_start(time t);
    return (in_step && t == t_step) ? fill_at_start : model.size();
  endfunction

  // Called before each event. When simulation time has moved on, the previous step is complete:
  // record its final fill (max/min) and remember the new step's starting fill.
  protected function void begin_event(time t);
    if (!in_step || t != t_step) begin
      if (in_step) track_fill();
      in_step       = 1;
      t_step        = t;
      fill_at_start = model.size();
      step_wr       = 0;
      step_rd       = 0;
    end
  endfunction

  // Fold one completed time step: max/min and crossings, for the run and the window, and
  // concurrency; then publish the step for coverage. Uses the fill at the step's end, never a
  // transient inside it (DEPTH >= 4, so the two crossing pairs are disjoint).
  protected function void track_fill();
    int f = model.size();
    fifo_step_item st = fifo_step_item::type_id::create("step");
    bit full_x  = (f == DEPTH && last_fill == DEPTH - 1) || (f == DEPTH - 1 && last_fill == DEPTH);
    bit empty_x = (f == 1 && last_fill == 0) || (f == 0 && last_fill == 1);
    if (f > max_fill) max_fill = f;
    if (f < min_fill) min_fill = f;
    if (f > win_max)  win_max  = f;
    if (f < win_min)  win_min  = f;
    if (full_x)  begin n_full_x++;  win_full_x++;  end
    if (empty_x) begin n_empty_x++; win_empty_x++; end
    if (step_wr && step_rd) begin
      if (fill_at_start == 1)              n_conc_at_one++;
      else if (fill_at_start == DEPTH - 1) n_conc_at_depth_m1++;
      else                                 n_conc_other++;
    end
    last_fill = f;
    st.t = t_step; st.fill_start = fill_at_start; st.fill_end = f;
    st.wr = step_wr; st.rd = step_rd; st.n_writes = n_writes;
    step_ap.write(st);
  endfunction

  // Start a new window at the current fill. Called by a virtual sequence between operations, so
  // the fill is exact (see fill()).
  function void open_window();
    win_min     = model.size();
    win_max     = model.size();
    win_full_x  = 0;
    win_empty_x = 0;
  endfunction

  // Accepted write: an overflow if the FIFO already held DEPTH entries at the start of this
  // time step (a same-instant read doesn't count, spec §5). Then push the data.
  function void write_wr(wr_item it);
    begin_event(it.t);
    n_writes++;
    step_wr = 1;
    if (fill_at_start >= DEPTH) begin
      n_overflow++;
      `uvm_error("SB_OVERFLOW", $sformatf("write #%0d accepted at %0t with fill %0d = DEPTH (F04/F06: wfull optimistic)",
                                          n_writes, it.t, fill_at_start))
    end
    model.push_back(it.data);
  endfunction

  // Accepted read: an underflow if the FIFO was empty at the start of this time step (a
  // same-instant write doesn't count). X/Z data is an error. Otherwise pop and compare.
  function void write_rd(rd_item it);
    data_t exp;
    begin_event(it.t);
    n_reads++;
    step_rd = 1;
    if ($isunknown(it.data)) begin
      n_unknown++;
      `uvm_error("SB_UNKNOWN", $sformatf("read #%0d at %0t: rdata has X/Z bits (%h)", n_reads, it.t, it.data))
    end
    if (fill_at_start == 0 || model.size() == 0) begin
      n_underflow++;
      `uvm_error("SB_UNDERFLOW", $sformatf("read #%0d accepted at %0t with fill 0 (F05/F07: rempty optimistic)",
                                           n_reads, it.t))
      if (model.size() == 0) return;  // nothing to compare against
    end
    exp = model.pop_front();
    if (n_reads == inject_at) begin
      exp[0] = ~exp[0];
      `uvm_info("SB_INJECT", $sformatf("read #%0d: expected value deliberately flipped to %h", n_reads, exp), UVM_NONE)
    end
    if (it.data !== exp) begin
      n_mismatch++;
      `uvm_error("SB_MISMATCH", $sformatf("read #%0d at %0t: got %h, expected %h (F02/F03)", n_reads, it.t, it.data, exp))
    end
  endfunction

  // End of test: every test drains first (vplan S6), so any entry still here was lost (F02).
  function void check_phase(uvm_phase phase);
    if (in_step) track_fill();
    if (model.size() != 0)
      `uvm_error("SB_LEFTOVER", $sformatf("%0d entries never read after the drain (F02); oldest = %h",
                                          model.size(), model[0]))
  endfunction

  // Summary line for the log.
  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf({"writes=%0d reads=%0d mismatches=%0d overflows=%0d underflows=%0d unknown=%0d ",
                               "max_fill=%0d min_fill=%0d crossings_full=%0d crossings_empty=%0d ",
                               "concurrent_at_1=%0d concurrent_at_depth_m1=%0d concurrent_other=%0d leftover=%0d"},
                              n_writes, n_reads, n_mismatch, n_overflow, n_underflow, n_unknown,
                              max_fill, min_fill, n_full_x, n_empty_x,
                              n_conc_at_one, n_conc_at_depth_m1, n_conc_other, model.size()), UVM_LOW)
  endfunction
endclass
