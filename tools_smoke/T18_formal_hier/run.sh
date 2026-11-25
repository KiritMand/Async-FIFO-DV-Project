#!/usr/bin/env bash
# T18 (M7): harness structure for the FIFO proof (t18_hier.sv, t18.sby, multiclock on).
# PASS = a (* gclk *) register in two modules works (the submodule's gclk assertion runs: BREAK
# fails by its hierarchical label), $rose/$changed of a design clock work in a gclk block,
# k-induction and abc pdr prove with the assumption, abc pdr fails without it (pdr honors
# assumptions), the cover is reached, and a hierarchical reference is NOT a real reference:
# Yosys makes an implicit undriven wire (warning only; the assertion through it fails), and
# `default_nettype none turns it into an error. So: no hierarchical references; export signals.
source "$(dirname "$0")/../env.sh"; ts_init T18
HERE=$(cd "$(dirname "$0")" && pwd)

# Run every task in OUT; keep each log and exit code.
cp "$HERE/t18_hier.sv" "$HERE/t18.sby" "$OUT/"
declare -A RC
for t in prove pdr pdr_noasm break cover hier hier_strict; do
  RC[$t]=0; (cd "$OUT" && sby -f t18.sby $t) > "$OUT/$t.log" 2>&1 || RC[$t]=$?
  echo "  $t: rc=${RC[$t]} $(grep -o 'DONE (.*)' "$OUT/$t.log" | tail -1)"
done

# Verdicts, one per finding.
[[ ${RC[prove]} == 0 && ${RC[pdr]} == 0 ]] || fail "prove/pdr should pass with the assumption"
[[ ${RC[pdr_noasm]} == 2 ]] && grep -q 'failed assertion t18_top.ast_cap' "$OUT/pdr_noasm.log" || fail "abc pdr ignored the assumption"
[[ ${RC[break]} == 2 ]] && grep -q 'failed assertion t18_top.u.ast_sub_on_edge' "$OUT/break.log" || fail "submodule gclk block not active"
[[ ${RC[cover]} == 0 ]] && grep -q 'Reached cover.*cov_sub_two' "$OUT/cover.log" || fail "cover not reached"
grep -q "Identifier .*u.c' is implicitly declared\." "$OUT/hier.log" && [[ ${RC[hier]} == 2 ]] || fail "hierarchical reference behavior changed: re-evaluate plan R5"
grep -q "implicitly declared and .default_nettype is set to none" "$OUT/hier_strict.log" || fail "default_nettype none did not reject it"
pass "gclk in two modules, \$rose(clk) on gclk, pdr honors assume; hier ref = silent undriven wire (error under default_nettype none)"
