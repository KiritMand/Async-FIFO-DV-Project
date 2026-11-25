# async_fifo — coverage closure log (M5)

How the vplan §3 coverage model (150 bins) was closed: each regression iteration, the holes and
weak spots it showed, their root causes, and the fix. Rule followed throughout: a hole is fixed
by stimulus or by a corrected testbench, never by removing or relaxing a bin or a check (no §8
exclusion was needed). Numbers come from `out/async_fifo/cov/functional.json` and
`out/async_fifo/regress/results.json` of each iteration; `docs/vplan_status.md` shows the
latest.

**Method.** A bin that closes once by chance is not closed. After each iteration:
- list the thinnest bins, not just the holes;
- explain each one from the stimulus;
- cross-check the covergroup sample totals against counters the scoreboard and monitors keep
  on their own.

The cross-checks were:
- `cg_cfg` and `cg_reset` samples = runs;
- `cg_concurrent` `at_one` / `at_depth_m1` = the scoreboard's `concurrent_at_1` /
  `concurrent_at_depth_m1`;
- `cg_attempts` samples = blocked writes + blocked reads from the monitors;
- `cp_winc_in_reset` / `cp_rinc_in_reset` hits = runs whose monitor saw `winc` / `rinc` in
  reset.

They matched exactly in every iteration.

## Iterations

| It. | Command | Runs | Result | Planned bins hit | Thinnest bins | Findings |
|---|---|---|---|---|---|---|
| 0 | `make regress N=3` | 21 | 21 PASS | 108/150 | — | H01 |
| 1 | `make regress N=50` | 350 | 350 PASS | 150/150 | `<at_depth_m1,B0>` = 1, `<at_one,B2>` = 2, `<at_depth_m1,B2>` = 3 | H02, H04 |
| 2 | `make regress N=50` (+ directed entries) | 550 | 549 PASS, 1 FAIL | 150/150 | `<at_depth_m1,B0>` = 26, `<at_one,B4>` = 33 | H03 |
| 3 | `make regress N=50` | 550 | 550 PASS | 150/150 | `<at_depth_m1,B0>` = 26, `<w_first,full>` = 30 | none |
| Sign-off | `make regress RECHECK=3` (N = 200 + directed) | 1,600 | 1,600 PASS | 150/150 | `<at_depth_m1,B0>` = 40, `<at_one,B4>` = 52 | none |

Sign-off summary: [`signoff/2026-11-24_m5_summary.md`](signoff/2026-11-24_m5_summary.md). In
iteration 3 every thrash run had at least 35 crossings in its window, against the `THRASH_WEAK`
limit of 20 (lowest: aligned 1:4 `thrash_empty`, the worst case DEC-009 analysed). Code
coverage of `rtl/async_fifo.sv` was 100% line (17), branch (10) and toggle (448) from
iteration 0 on. It is secondary evidence (plan M5 step 6).

## Findings

### H01 — every test drew the same configuration for the same seed

- **Seen.** Iteration 0: 21 runs, yet `cg_cfg.cp_bucket` missed B2. With 21 independent draws
  over 5 buckets that has a 1% chance. The `[CFG]` lines showed that seed *s* gave the same
  clock and reset configuration in all five non-thrash tests, and another shared one in the
  two thrash tests (whose 50% integer share changes the draw).
- **Root cause.** The configuration depends only on the simulator seed: `fifo_env_cfg` is the
  first thing randomized in every test.
  - At N = 200 the 1,400 sign-off runs would have held only about 400 distinct configurations.
  - Per-test confidence (vplan §7) was unaffected, because each test's seeds are independent.
  - Diversity across tests was wasted.
- **Fix.** `fifo_base_test.reseed_per_test()` mixes a hash of the test's type name into the
  process's random state before the cfg object is created:
  `process::self().srandom($urandom ^ h)`. Toolchain T13 shows that both `$urandom` and a later
  object's `randomize()` follow the reseed.
  - A run is still a pure function of (test, seed), so rerun commands still reproduce.
  - No distribution changed.
- **Result.** Iteration 1: 350 distinct clock configurations in 350 runs, 7 per seed.

### H02 — boundary concurrency × bucket closed by luck

- **Seen.** Iteration 1 closed all 150 bins, but `cg_concurrent.x_concurrent_bucket` had
  `<at_depth_m1,B0>` = 1, `<at_one,B2>` = 2 and `<at_depth_m1,B2>` = 3. Per test and bucket
  (scoreboard counters):
  - `thrash_full_test` produced `at_depth_m1` only in B1, B3 and B4 (the write clock faster);
  - `thrash_empty_test` produced `at_one` in B0, B1, B3 and B4, but not B2;
  - the other hits came from chance coincidences in `random_rates_test` and `random_mix_test`.
- **Root cause.** F16 needs an accepted write and an accepted read in the same time step.
  - That requires exactly coincident edges: an integer ratio with `rphase = 0`.
  - Only 25% of thrash runs have that (50% integer × 50% aligned), about 5% per bucket: 2.5
    runs per bucket per thrash test at N = 50.
  - In iteration 1 all three B2 integer thrash runs drew a random phase.
  - In the "wrong" direction (`at_depth_m1` with a fast reader, `at_one` with a fast writer),
    the refill rarely lands on the other side's next operation, so even aligned runs give few
    hits.
- **Probe.** `thrash_{full,empty}_test` with `+BUCKET=<b> +KIND=int +RPHASE_PS=0`, 2 seeds each:
  - natural direction: 20–28 concurrent steps per run (B4 full, B0 empty);
  - other buckets: 0–4 per run;
  - weakest: `<at_one,B4>`, about 0.5 per run.
- **Fix.** Ten directed entries in `regress/tests.toml`: `thrash_full_aligned_b0..b4` and
  `thrash_empty_aligned_b0..b4`, 20 seeds each, 200 runs of under a second.
  - About 10 expected hits for the weakest bin, so a miss has probability around 5·10⁻⁵.
  - Adds stimulus only (D2). vplan F16's Stimulus cell names them (v0.3).
- **Result.** Iteration 2: `<at_depth_m1,B0>` = 26, `<at_one,B4>` = 33; every other bin ≥ 37.

### H03 — `THRASH_WEAK` in a long reset gap (testbench bug, not the DUT)

- **Seen.** Iteration 2, `thrash_empty_aligned_b0` seed 18, `THRASH_WEAK`: 14 crossings at the
  empty boundary, 20 required.
  - Scoreboard clean: 65 writes, 65 reads, 0 mismatches, overflows and underflows.
  - Configuration: B0 1:4 aligned, write side released first, gap 38 write-clock cycles.
  - Rerun: `make sim TEST=thrash_empty_test SEED=18 PLUSARGS='+BUCKET=0 +KIND=int +RPHASE_PS=0' RUN=thrash_empty_aligned_b0`
- **Root cause.** `vseq_thrash_empty` started its paced writes (57% per write-clock edge in B0)
  as soon as the fill reached 1, while the read side was still in reset.
  - The FIFO filled to 16 during the gap (the window shows fill in [0, 16]).
  - That used about a third of the 64-write budget before any thrashing at 0/1.
  - The check was right: this run's thrash phase was weak.
  - M4 had noted that thrash tests start before the late side leaves reset. It did not foresee
    that a long gap in B0 starves the measured phase. `vseq_thrash_full` has the same structure,
    with a milder effect: its budget counts accepted reads, which wait for the read side's
    release.
- **Fix.** Both thrash sequences still seek their starting fill right away, so writes during
  the read side's reset remain (F17 stimulus). They then `wait_both_released()` before opening
  the measured window and starting the paced traffic. The check, its threshold (20), d and the
  run length are unchanged.
- **Result.** The failing seed reruns with the same configuration (B0, write side first, gap
  38) and passes: the window's fill stays in [0, 1], with 35 crossings. Iteration 3 and the
  sign-off run: no failure. `cg_reset.x_order_writes.<w_first,full>` fell from 37 to 30 hits
  at N = 50, because the thrash tests no longer overfill during the gap. The other tests still
  give a wide margin (117 hits at sign-off).

### H04 — `cp_phase.aligned` does not mean coincident edges (observation, no change)

The vplan defines `aligned` as the first rising `rclk` edge within 5% of T_wclk of a `wclk`
edge. Integer runs with a random phase of 258 ps or 701 ps count as aligned but have no
coincident edges, so they produce no F16 concurrency. The bin does what the vplan says.
Evidence of coincident edges is `cg_concurrent` (H02), not `cp_phase`. Recorded in vplan §3
(v0.3). Changing the bin would change the coverage model, which is the owner's decision.
