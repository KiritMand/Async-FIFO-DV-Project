#!/usr/bin/env bash
# T16 (M6, D2): concurrent SVA in Verilator as sva/async_fifo_sva_concurrent.sv uses it (t16_conc.sv):
# bind with .* into a module, [*N] with a parameter count, a ##1 antecedent, $stable/$past, a
# two-term disable iff. PASS = the clean build passes; BREAK fails on cast_hold only and BREAK2
# on cast_step only, each with exit 1 and a message the `assertion` pattern of
# common/sim/verilator.patterns parses ("[t] %Error: f:l: Assertion failed in <scope>.<label>").
source "$(dirname "$0")/../env.sh"; ts_init T16
HERE=$(cd "$(dirname "$0")" && pwd)

# Expected first failing label per variant ("" = must pass).
declare -A EXPECT=([GOOD]="" [BREAK]=cast_hold [BREAK2]=cast_step)

# Build each variant (default warnings, fatal), run it, collect the labels that failed.
for v in GOOD BREAK BREAK2; do
  verilator --binary --timing --top-module t16_top -Mdir "$OUT/obj_$v" +define+$v "$HERE/t16_conc.sv" \
    > "$OUT/build_$v.log" 2>&1 || { grep -E '%(Error|Warning)' "$OUT/build_$v.log" | head; fail "$v build"; }
  rc=0; "$OUT/obj_$v/Vt16_top" > "$OUT/run_$v.log" 2>&1 || rc=$?
  fired=$(grep -oE '^\[[0-9]+\] %Error: \S+:[0-9]+: Assertion failed in \S+' "$OUT/run_$v.log" | sed 's/.*\.//; s/:$//' | sort -u | tr '\n' ' ' || true)
  echo "  $v: exit=$rc fired=[${fired% }]"
  if [[ -z ${EXPECT[$v]} ]]; then
    [[ $rc == 0 && -z $fired ]] && grep -q 'T16 END' "$OUT/run_$v.log" || fail "$v should pass cleanly"
  else
    [[ $rc == 1 && ${fired% } == "${EXPECT[$v]}" ]] || fail "$v should fail on ${EXPECT[$v]} only"
  fi
done
pass "bind .*, [*N] with a parameter, ##1 antecedent, \$stable/\$past, disable iff: each break caught by its label"
