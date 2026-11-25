#!/usr/bin/env bash
# T14 (M6): immediate assertions and covers as the FIFO property files use them (t14_imm.sv).
# PASS = assertions run by default (no --assert needed) and --no-assert removes them; a failing
# `else $error` stops the run at the first failure with exit 1 and names the label; raising
# +verilator+error+limit continues but exits 0 (so negative tests must judge the log); a
# labeled immediate cover is a `t=user` record named by its label in coverage.dat; a
# declaration initializer gives no time-0 posedge; $past keeps history at every edge, even
# when its statement is skipped; a `coverage_off -file` on the cover's own file (how the FIFO
# flow scopes code coverage, T12) keeps the cover record and its count.
source "$(dirname "$0")/../env.sh"; ts_init T14
HERE=$(cd "$(dirname "$0")" && pwd)

# Three builds: Verilator's default, --no-assert, and line coverage switched off for this file by
# a .vlt (all with user coverage, warnings fatal).
build() { verilator --binary --coverage-user $2 --top-module t14_top -Mdir "$OUT/obj_$1" "$HERE/t14_imm.sv" \
            > "$OUT/build_$1.log" 2>&1 || { grep -E '%(Error|Warning)' "$OUT/build_$1.log" | head; fail "build $1"; }; }
printf '`verilator_config\ncoverage_off -file "*/t14_imm.sv"\n' > "$OUT/scope.vlt"
build dflt ""; build noassert --no-assert; build scoped "--coverage-line $OUT/scope.vlt"

# run <build> <name> [plusargs]: run in OUT, keep the log, record the exit code in RC.
run() { local b=$1 n=$2; shift 2; RC=0
        (cd "$OUT" && "$OUT/obj_$b/Vt14_top" +verilator+coverage+file+cov_$n.dat "$@") > "$OUT/run_$n.log" 2>&1 || RC=$?
        echo "  $n: exit=$RC errors=$(grep -c '%Error' "$OUT/run_$n.log" || true)"; }

# Clean run: exits 0, reaches the end, no error; the cover counts the 5 even values of n;
# rst_n rises once, at t=20 (no edge from the declaration initializer); ast_t14_past, which runs
# only at odd n >= 7, holds, so $past keeps history at every edge.
run dflt clean
[[ $RC == 0 ]] && grep -q 'T14 END' "$OUT/run_clean.log" && ! grep -q '%Error' "$OUT/run_clean.log" || fail "clean run"
cnt=$(grep 'cov_t14_even' "$OUT/cov_clean.dat" | tr '\001\002' '|=' | grep -o "t=user.*h=t14_top.cov_t14_even' [0-9]*" | awk '{print $NF}')
[[ $cnt == 5 ]] || fail "cover count '$cnt', expected 5 (t=user record named by label)"
[[ $(grep -c 'T14 RST_ROSE' "$OUT/run_clean.log") == 1 ]] && grep -q 'RST_ROSE t=20$' "$OUT/run_clean.log" || fail "rst_n edges"

# +BREAK: the first failure (n=3) ends the run with exit 1, message names the label.
run dflt break +BREAK
[[ $RC == 1 ]] && grep -q 'Assertion failed in t14_top.ast_t14_n: ast_t14_n: n=3' "$OUT/run_break.log" \
  && ! grep -q 'n=5' "$OUT/run_break.log" || fail "break run should stop at the first failure"

# +BREAK with a raised error limit: both failures reported, but the exit code is 0.
run dflt limit +BREAK +verilator+error+limit+10
[[ $RC == 0 ]] && grep -q 'n=3' "$OUT/run_limit.log" && grep -q 'n=5' "$OUT/run_limit.log" || fail "error-limit run"

# --no-assert: the same break passes silently.
run noassert noassert +BREAK
[[ $RC == 0 ]] && ! grep -q '%Error' "$OUT/run_noassert.log" || fail "--no-assert should disable the assertion"
# Scoped build: the cover record survives coverage_off -file with the same count; no line points.
run scoped scoped
cnt=$(grep 'cov_t14_even' "$OUT/cov_scoped.dat" | tr '\001\002' '|=' | grep -o "t=user.*' [0-9]*" | awk '{print $NF}')
[[ $cnt == 5 ]] || fail "cover count '$cnt' under coverage_off -file, expected 5"
grep -q 'page=v_line' "$OUT/cov_scoped.dat" && fail "line coverage not switched off by the .vlt"
pass "asserts on by default, stop at first failure (exit 1), error limit continues with exit 0, cover = t=user record, kept under coverage_off -file"
