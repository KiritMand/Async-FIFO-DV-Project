#!/usr/bin/env bash
# T3 SVA in simulation: the clean build passes; each BREAK_x build fails on exactly its label,
# with a non-zero exit code (so a regression would mark the test failed).
# Shared helpers and the pinned toolchain come from env.sh.
source "$(dirname "$0")/../env.sh"; ts_init T3
HERE=$(cd "$(dirname "$0")" && pwd)

# Expected outcome per build variant: the one label that must fire ("" = must pass).
declare -A EXPECT=([GOOD]="" [BREAK_A]=ast_a_cnt_inc [BREAK_B]=ast_b_req_ack [BREAK_C]=ast_c_ack_has_req)

# For each variant: build with --assert, run, and collect which assertion labels fired.
for v in GOOD BREAK_A BREAK_B BREAK_C; do
  verilator --binary --assert -j "$J" --top-module t3_top -Mdir "$OUT/obj_$v" +define+$v \
    "$HERE/t3_sva.sv" > "$OUT/build_$v.log" 2>&1 || { tail -20 "$OUT/build_$v.log"; fail "$v build"; }
  rc=0; "$OUT/obj_$v/Vt3_top" > "$OUT/run_$v.log" 2>&1 || rc=$?
  fired=$(grep -o 'Assertion failed in [^:]*' "$OUT/run_$v.log" | sed 's/.*\.//' | sort -u | tr '\n' ' ' || true)
  echo "  $v: exit=$rc fired=[${fired% }]"

  # Verdict: GOOD exits 0 with nothing fired; each BREAK exits non-zero on its own label only.
  if [[ -z ${EXPECT[$v]} ]]; then
    [[ $rc == 0 && -z $fired ]] && grep -q T3_END "$OUT/run_$v.log" || fail "$v should pass cleanly"
  else
    [[ $rc != 0 && ${fired% } == "${EXPECT[$v]}" ]] || fail "$v should fail on ${EXPECT[$v]} only"
  fi
done
pass "immediate+\$past, concurrent disable-iff/implication, bind: each detected alone, exit!=0"
