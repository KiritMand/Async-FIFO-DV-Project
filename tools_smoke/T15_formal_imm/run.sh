#!/usr/bin/env bash
# T15 (M6): the FIFO property style in open-source SBY (t15_imm.sv, t15.sby, multiclock on).
# PASS = the file parses with the sim-only action-block macro and the keyword macro (Yosys
# rejects a plain `else $error`), bmc finds no failure in 20 steps, both covers are reached,
# and the BREAK build fails on ast_t15_step by label; ast_t15_past holds in bmc, so $past keeps
# history at every clka edge even inside a skipped if. The prove task is only recorded: k-induction
# of a $past on a design clock fails in the induction step (a free clock can stay idle for the
# whole window), which M7 must solve with invariants or gclk-based history.
source "$(dirname "$0")/../env.sh"; ts_init T15
HERE=$(cd "$(dirname "$0")" && pwd)

# Run every task in OUT (sby -f overwrites old task dirs); keep each log and exit code.
cp "$HERE/t15_imm.sv" "$HERE/t15.sby" "$OUT/"
declare -A RC
for t in bmc prove cover bad; do
  RC[$t]=0; (cd "$OUT" && sby -f t15.sby $t) > "$OUT/$t.log" 2>&1 || RC[$t]=$?
  echo "  $t: rc=${RC[$t]} $(grep -o 'DONE (.*)' "$OUT/$t.log" | tail -1)"
done
grep -q 'syntax error' "$OUT"/*.log && fail "parse error, see $OUT/bmc.log"

# Verdicts: bmc clean, both covers reached, BREAK caught by its label.
[[ ${RC[bmc]} == 0 ]] || fail "bmc should pass"
[[ ${RC[cover]} == 0 ]] && grep -q 'Reached cover.*cov_t15_five' "$OUT/cover.log" \
  && grep -q 'Reached cover.*cov_t15_q_five' "$OUT/cover.log" || fail "covers not reached"
[[ ${RC[bad]} == 2 ]] && grep -q 'failed assertion t15_imm.ast_t15_step' "$OUT/bad.log" || fail "BREAK not caught by label"

# Record (not judge) the induction result; a base-case failure would be a real error.
grep -q 'basecase: .*Assert failed' "$OUT/prove.log" && fail "prove base case failed"
ind=$(grep -q 'induction: .*Assert failed' "$OUT/prove.log" && echo "induction step fails (needs invariants)" || echo "proved")
pass "action-block macro + keyword macro parse, bmc clean, covers reached, BREAK caught; prove: $ind"
