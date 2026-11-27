#!/usr/bin/env bash
# T20 (M9): can Verilator simulate the netlist an MCY test script gets? Yosys writes a mutated
# async_fifo (prep at ASIZE=2/DSIZE=4 plus memory_map, as config.mcy does; `mutate -ctrl mutsel 8
# 1`; write_verilog -norename, as MCY's create_mutated.sh does). PASS = the netlist has an 8-bit
# mutsel port and no parameters; Verilator's default (fatal) warnings reject it for WIDTHEXPAND
# only; a file-scoped lint_off in a .vlt fixes that; mutsel=0 returns every word intact and
# mutsel=1 (a wdata bit inverted) does not. Also records why config.mcy maps the memory: without
# memory_map, a mutation of the $mem_v2 async read port's RD_SRST makes write_verilog assert.
source "$(dirname "$0")/../env.sh"; ts_init T20
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$OUT"

# Without memory_map: a mutated RD_SRST of the asynchronous read port cannot be written as Verilog.
rc=0; yosys -q -p "read_verilog -sv $REPO/ip/async_fifo/rtl/async_fifo.sv; chparam -set ASIZE 2 -set DSIZE 4 async_fifo; prep -top async_fifo; mutate -ctrl mutsel 8 1 -mode const1 -module async_fifo -cell mem -port RD_SRST -portbit 0; write_verilog srst.v" > srst.log 2>&1 || rc=$?
[[ $rc != 0 ]] && grep -q 'port.srst == State::S0' srst.log || fail "write_verilog now accepts a mutated RD_SRST (rc=$rc): memory_map in config.mcy may be unnecessary"

# The design as MCY's [script] prepares it, and one mutation that inverts a wdata bit.
yosys -q -p "read_verilog -sv $REPO/ip/async_fifo/rtl/async_fifo.sv; chparam -set ASIZE 2 -set DSIZE 4 async_fifo; prep -top async_fifo; memory_map; opt_clean; write_rtlil design.il; mutate -list 1 -seed 1 -mode inv -wire wdata -o mut.txt"
mut=$(head -1 mut.txt); echo "  mutation: $mut"
yosys -q -p "read_rtlil design.il; mutate -ctrl mutsel 8 1 ${mut#mutate }; write_verilog -norename mutated.v"
grep -q 'input \[7:0\] mutsel;' mutated.v || fail "no 8-bit mutsel port in mutated.v"
! grep -q 'parameter' mutated.v || fail "mutated.v still has parameters (tb_top would need them)"

# Default warnings: expected to fail, and only on WIDTHEXPAND.
rc=0; verilator --binary --timing -Mdir obj_def "$HERE/t20_tb.sv" mutated.v > build_default.log 2>&1 || rc=$?
warns=$(grep -o "%Warning-[A-Z]*" build_default.log | sort -u | tr "\n" " " || true)
[[ $rc != 0 && $warns == "%Warning-WIDTHEXPAND " ]] || fail "default warnings: rc=$rc, warnings '$warns' (expected a failure on WIDTHEXPAND only)"

# With the .vlt waiver: builds; mutsel=0 is the original design, mutsel=1 corrupts data.
verilator --binary --timing -Mdir obj_vlt "$HERE/t20.vlt" "$HERE/t20_tb.sv" mutated.v > build_vlt.log 2>&1 || fail "build with t20.vlt failed, see $OUT/build_vlt.log"
obj_vlt/Vt20_tb +mutsel=0 > run0.log; obj_vlt/Vt20_tb +mutsel=1 > run1.log
grep -q 'T20 mutsel=0 bad=0' run0.log || fail "mutsel=0 is not the original design: $(cat run0.log)"
grep -q 'T20 mutsel=1 bad=[1-9]' run1.log || fail "mutsel=1 had no effect: $(cat run1.log)"
pass "RD_SRST mutation needs memory_map; mutsel port, no parameters; default warnings fail on WIDTHEXPAND only, a file-scoped .vlt lint_off fixes it; mutsel=0 intact, mutsel=1 $(grep -o 'bad=[0-9]*' run1.log)"
