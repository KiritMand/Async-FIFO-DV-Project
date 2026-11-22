#!/usr/bin/env bash
# T4 two-clock formal: prove (k-induction) and cover pass; the BREAK build fails on the
# labeled assert; the cover trace is a valid VCD (open it in GTKWave/Surfer by hand).
# Shared helpers and the pinned toolchain come from env.sh.
source "$(dirname "$0")/../env.sh"; ts_init T4
HERE=$(cd "$(dirname "$0")" && pwd)

# run_task <task>: run one SBY task with its work dir under out/ (keeps the source tree clean);
# sets RC and writes $OUT/<task>.log.
run_task() {
  RC=0; (cd "$HERE" && sby -f -d "$OUT/$1" t4.sby "$1") > "$OUT/$1.log" 2>&1 || RC=$?
  echo "  $1: rc=$RC $(grep -m1 -oE 'DONE \([A-Z]+, rc=[0-9]+\)' "$OUT/$1.log" || true)"
}

# prove must pass by induction (an unbounded proof, not just a bounded check).
run_task prove
[[ $RC == 0 ]] && grep -q 'Temporal induction successful' "$OUT/prove.log" || fail "prove (k-induction)"

# cover must reach the labeled cover and leave a trace that converts cleanly (valid VCD).
run_task cover
[[ $RC == 0 ]] && grep -q 'reached cover statement t4_cdc.cov_T4_q2_rose_twice' "$OUT/cover.log" || fail "cover"
VCD="$OUT/cover/engine_0/trace0.vcd"
vcd2fst "$VCD" "$OUT/cover_trace.fst" > /dev/null 2>&1 && grep -q 'q2' "$VCD" || fail "cover trace not a valid VCD"

# The BREAK build must fail, and SBY must name the failing assertion by its label.
run_task bad
[[ $RC != 0 ]] && grep -q 'failed assertion t4_cdc.ast_T4_q2_from_q1' "$OUT/bad.log" || fail "BREAK not caught by label"
pass "multiclock+gclk: prove by induction, cover reached, BREAK caught as ast_T4_q2_from_q1; trace: ${VCD#$REPO/}"
