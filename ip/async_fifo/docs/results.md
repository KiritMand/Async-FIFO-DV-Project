# async_fifo — results

Reviewer-facing summary of the verification results. M10 will generate this page from `out/`
(`make results`). Until then each module adds its own section by hand from its sign-off run.

---

## Formal (M7, sign-off SO-3)

Open-source SymbiYosys 0.71 (OSS CAD Suite 2026-11-21), `multiclock on`, yosys-smtbmc + yices,
and ABC PDR. DSIZE = 4. Free clocks (any interleaving, A04); assumptions A01, A02 and A05
(vplan §5). Host: 8-core WSL2 machine, 8 GB. One SBY job at a time, except the ASIZE=4 stretch
runs, which overlapped the sign-off set (at most four solver processes on eight cores).
Reproduce the ASIZE 2/3 table with `make formal-signoff TIMEOUT=1800`, and one cell with
`make formal TASK=<task> ASIZE=<n>`. Method and invariants: `docs/formal_notes.md`.

### Sign-off set

| Task | What it shows | ASIZE=2 | ASIZE=3 | ASIZE=4 (stretch) |
|---|---|---|---|---|
| `prove` | Every assertion (25 spec + 25 `inv_` invariants) holds unbounded: k-induction, depth 6 | **PASS**, 1.3 s | **PASS**, 2.5 s | **PASS**, 6.2 s |
| `cover` | Every cover reached (22: 15 shared with simulation, 7 formal-only) | **22/22**, 84.5 s | **22/22**, 17.2 s | **22/22**, 106.9 s (depth 180) |
| `pdr` | Same assertions, ABC PDR (finds its own invariants) | **PASS**, 102.4 s | **PASS**, 521.8 s | TIMEOUT at 1800 s |
| `bmc` | Bounded check, depth 40 formal steps | PASS, 31.7 s | PASS, 50.5 s | PASS, 76.5 s |

SO-3 (vplan §7) asks for `prove` and `cover` at ASIZE 2 and 3, plus the assumption audit: met.
The ASIZE=4 PDR timeout is recorded, not chased (DEC-011 D4: 30 minutes per task).

### Cross-checks

| Task | What it shows | ASIZE=2 | ASIZE=3 |
|---|---|---|---|
| `prove_noinv` | k-induction without the hand-written invariants | UNKNOWN (induction fails on `ast_F06_wfull_not_optimistic`), 1.8 s | UNKNOWN (same label), 1.2 s |
| `pdr_noinv` | PDR without the hand-written invariants: proves the spec properties on its own | **PASS**, 303.4 s | TIMEOUT at 1800 s (recorded) |
| `audit_a01` | Drop A01 (resets asserted at power-up): bmc, spec properties only | FAIL, 17 assertions (F02–F08, F09a, F10, F12, F14), 4.2 s | FAIL, same 17, 4.0 s |
| `audit_a02` | Drop A02 (reset released on its own clock): k-induction | **PASS**, 1.5 s | **PASS**, 1.7 s |
| `audit_a05` | Drop A05 (no reset after power-up): bmc, spec properties only | FAIL, 11 assertions (F02, F03, F06, F07, F09b, F11, F12, F14), 191.7 s | FAIL, same 11, 505.7 s |

- **The invariants are needed, and they do not hide anything.** Without them k-induction
  fails. PDR, which builds its own invariants, proves the same spec properties without them.
- **A01 and A05 are necessary.** Dropping either breaks the end-to-end safety properties F06
  and F07, as vplan §5 predicted. **A02 is not needed by any property**: the logic tolerates any
  release timing. The physical requirement stays, because an asynchronous release near an edge
  can go metastable, which no RTL model represents (plan R11). Whether the formal assumption is
  retired is the owner's decision.
- **Planted bug (preview of M8).** B05 (`rempty` computed from the current read pointer): at
  ASIZE=3 `bmc_spec` fails `ast_F14_rdata_stable_gclk` at step 11 (2.4 s), and `prove` no longer
  passes (UNKNOWN).

### Figures

Cover traces drawn by `common/scripts/vcd2svg.py` (`make formal-figures`, ASIZE=2), one column
per formal step:

- `docs/figures/formal_fill_full_drain_a2.svg`: `cov_F12_empty_after_full`. Both resets are
  released at step 1. The writer fills the FIFO, and `wfull` rises in the step where fill reaches
  DEPTH (F12: no read yet). The writer keeps asserting `winc` while full (blocked writes, F04)
  while the reader drains. `wfull` falls only after the reads have crossed the synchronizer (the
  lag F08 bounds), and `rempty` rises at fill 0.
- `docs/figures/formal_pointer_wrap_a2.svg`: `cov_F13_two_wraps`. Both pointers wrap twice
  (4·DEPTH reads), with the gray codes alongside.
