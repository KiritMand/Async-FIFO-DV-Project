// fifo_vseqs.sv — virtual sequences that coordinate both agents (M3: base, drain, smoke). M4 adds
// fill-to-full, drain-to-empty, thrash and random-rate sequences here.

// Base: gives every virtual sequence typed access to the virtual sequencer's handles.
class fifo_base_vseq extends uvm_sequence;
  `uvm_object_utils(fifo_base_vseq)
  `uvm_declare_p_sequencer(fifo_vsequencer)

  // Constructor (UVM factory signature).
  function new(string name = "fifo_base_vseq");
    super.new(name);
  endfunction
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
    rd_until_empty_seq r = rd_until_empty_seq::type_id::create("drain");
    r.sb     = p_sequencer.sb;
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
    wr_attempt_seq     w = wr_attempt_seq::type_id::create("smoke_wr");
    rd_until_empty_seq r = rd_until_empty_seq::type_id::create("smoke_rd");

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
