// fifo_scoreboard.sv — reference model and end-to-end checks (plan M3 step 6; vplan F02–F07).
// A queue holds the expected contents, oldest first: accepted writes push, accepted reads pop and
// compare. Same-timestamp rule: overflow and underflow are judged on the fill at the *start* of
// the time step, so the order in which the two monitors deliver same-instant events can't hide
// an overflow or underflow (spec §5 coincident-edge rule).

// Analysis imps for the two monitors (macros must sit at package scope).
`uvm_analysis_imp_decl(_wr)
`uvm_analysis_imp_decl(_rd)

class fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fifo_scoreboard)

  uvm_analysis_imp_wr #(wr_item, fifo_scoreboard) wr_imp;  // accepted writes
  uvm_analysis_imp_rd #(rd_item, fifo_scoreboard) rd_imp;  // accepted reads

  // Model state: expected contents; the time step being processed and its starting fill.
  protected data_t model[$];
  protected bit    in_step;
  protected time   t_step;
  protected int    fill_at_start;

  // Results for the report (and for tests that check them).
  int unsigned n_writes, n_reads, n_mismatch, n_overflow, n_underflow, n_unknown;
  int          max_fill, min_fill;

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
    if (!$value$plusargs("SB_INJECT_ERROR=%d", inject_at) && $test$plusargs("SB_INJECT_ERROR"))
      inject_at = 1;
    if (inject_at != 0)
      `uvm_info("SB_INJECT", $sformatf("armed: read #%0d will be compared against a wrong value", inject_at), UVM_NONE)
  endfunction

  // True fill right now. Within a time step it may include only some of that step's events;
  // between time steps it is exact. Sequences read it after the NBA region (rd_until_empty_seq).
  function int fill();
    return model.size();
  endfunction

  // Called before each event. When simulation time has moved on, the previous step is complete:
  // record its final fill (max/min) and remember the new step's starting fill.
  protected function void begin_event(time t);
    if (!in_step || t != t_step) begin
      if (in_step) track_fill();
      in_step       = 1;
      t_step        = t;
      fill_at_start = model.size();
    end
  endfunction

  // Max/min over fills at time-step boundaries (never a transient inside a step).
  protected function void track_fill();
    if (model.size() > max_fill) max_fill = model.size();
    if (model.size() < min_fill) min_fill = model.size();
  endfunction

  // Accepted write: an overflow if the FIFO already held DEPTH entries at the start of this
  // time step (a same-instant read doesn't count, spec §5). Then push the data.
  function void write_wr(wr_item it);
    begin_event(it.t);
    n_writes++;
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
    `uvm_info("SB", $sformatf("writes=%0d reads=%0d mismatches=%0d overflows=%0d underflows=%0d unknown=%0d max_fill=%0d min_fill=%0d leftover=%0d",
                              n_writes, n_reads, n_mismatch, n_overflow, n_underflow, n_unknown,
                              max_fill, min_fill, model.size()), UVM_LOW)
  endfunction
endclass
