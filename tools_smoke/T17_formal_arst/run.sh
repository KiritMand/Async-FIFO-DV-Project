#!/usr/bin/env bash
# T17 (M7, DEC-011 D3): async-reset release in the same formal step as a rising clock edge
# (multiclock on). PASS = under the vplan's A02 wording (SAME: release only with a clk rise) the
# coincident release with inc high is reachable (cov_edge_inc) and the flop still acts as in reset
# at that edge (ast_release_holds, ast_agree hold in bmc), as in simulation; so the RTL-style and
# checker-style counters never disagree. The free-release (A02 dropped) and LATE results are
# recorded; LATE must also cover both events and prove by k-induction.
source "$(dirname "$0")/../env.sh"; ts_init T17
HERE=$(cd "$(dirname "$0")" && pwd)

# Run every task in OUT; keep each log and exit code.
cp "$HERE/t17_arst.sv" "$HERE/t17.sby" "$OUT/"
declare -A RC
for t in same free late same_cover late_cover late_prove; do
  RC[$t]=0; (cd "$OUT" && sby -f t17.sby $t) > "$OUT/$t.log" 2>&1 || RC[$t]=$?
  echo "  $t: rc=${RC[$t]} $(grep -o 'DONE (.*)' "$OUT/$t.log" | tail -1)"
done
grep -q -E 'syntax error|Unused option' "$OUT"/*.log && fail "parse/config error, see $OUT"

# Verdicts: the decisive case is reachable and safe; LATE is not vacuous and proves.
[[ ${RC[same]} == 0 ]] || fail "SAME bmc: the flop captured at a coincident release edge"
[[ ${RC[same_cover]} == 0 ]] && grep -q 'Reached cover.*cov_edge_inc' "$OUT/same_cover.log" \
  || fail "coincident release with inc=1 not reachable (experiment vacuous)"
[[ ${RC[late]} == 0 && ${RC[late_cover]} == 0 && ${RC[late_prove]} == 0 ]] || fail "LATE bmc/cover/prove"
free=$([[ ${RC[free]} == 0 ]] && echo "free release also safe" || echo "free release FAILS")
pass "coincident release: flop stays in reset at that edge (as in simulation); $free"
