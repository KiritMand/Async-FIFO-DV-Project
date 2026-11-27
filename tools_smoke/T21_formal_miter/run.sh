#!/usr/bin/env bash
# T21 (M9): the constructs of MCY's equivalence harness (ip/async_fifo/mcy/test_eq/, used as is).
# PASS = (a) `chformal -assert -cover -remove *async_fifo_e2e_props*` matches the checker's derived
# ($paramod...) module and leaves exactly its five asm_ cells plus the miter's three asserts
# (Yosys 0.71 keeps immediate properties as $check cells; chformal acts on them by flavor);
# (b) fmcombine accepts two copies of the two-clock netlist (async-reset flops, a $mem_v2);
# (c) abc pdr under multiclock proves two identical copies equal, with no depth bound, and
# (d) finds the difference when one copy carries a mutation (a wdata bit inverted, as in T20).
source "$(dirname "$0")/../env.sh"; ts_init T21
IP="$REPO/ip/async_fifo"; cd "$OUT"

# Netlist with one mutation behind mutsel = 1 (the T20 recipe).
yosys -q -p "read_verilog -sv $IP/rtl/async_fifo.sv; chparam -set ASIZE 2 -set DSIZE 4 async_fifo; prep -top async_fifo; write_rtlil design.il; mutate -list 1 -seed 1 -mode inv -wire wdata -o mut.txt"
mut=$(head -1 mut.txt); yosys -q -p "read_rtlil design.il; mutate -ctrl mutsel 8 1 ${mut#mutate }; write_rtlil mutated.il"

# (a) Formal cells left after the template's chformal step.
yosys -q -p "read -formal $IP/mcy/test_eq/miter.sv $IP/sva/async_fifo_e2e_props.sv; read_rtlil mutated.il; chparam -set MUTSEL 1 miter; prep -top miter; chformal -assert -cover -remove *async_fifo_e2e_props*; tee -q -o cells.txt select -list t:\$check"
[[ $(wc -l < cells.txt) == 8 && $(grep -c '/asm_A0[125]_' cells.txt) == 5 && $(grep -c '^miter/mcy_eq_' cells.txt) == 3 ]] || fail "unexpected formal cells after chformal: $(tr '\n' ' ' < cells.txt)"

# (b)-(d) The template as mcy_task.py fills it, for mutsel 0 (identical copies) and 1.
files=$(printf '%s\n' "$OUT/mutated.il" "$IP/mcy/test_eq/miter.sv" "$IP/sva/async_fifo_e2e_props.sv")
for sel in 0 1; do
  t=$(< "$IP/mcy/test_eq/test_eq.sby"); t=${t//@MUTSEL@/$sel}; t=${t//@ASIZE@/2}; t=${t//@DSIZE@/4}; t=${t//@TIMEOUT@/600}
  printf '%s\n' "${t//@FILES@/$files}" > eq$sel.sby
  rc=0; sby -f eq$sel.sby > eq$sel.log 2>&1 || rc=$?; echo "  mutsel=$sel: $(grep -o 'DONE (.*)' eq$sel.log)"
done
grep -q 'DONE (PASS' eq0.log || fail "identical copies not proven equal, see $OUT/eq0.log"
grep -q 'DONE (FAIL' eq1.log && grep -q 'failed assertion miter.mcy_eq_rdata' eq1.log || fail "mutation not found as an rdata difference, see $OUT/eq1.log"
pass "chformal keeps the 5 asm_ cells + 3 miter asserts; fmcombine OK; pdr: identical copies PASS (unbounded), wdata mutation FAIL on mcy_eq_rdata"
