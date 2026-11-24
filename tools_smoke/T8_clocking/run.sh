#!/usr/bin/env bash
# T8 (M3): clocking blocks, a combinational input gate and class-side virtual-interface access
# in Verilator --timing, as the UVM agents use them (plan M3 step 2). PASS = the self-check in
# t8_cb.sv prints T8_OK (sampling, drive timing, gate timing and counts all as expected).
source "$(dirname "$0")/../env.sh"; ts_init T8
HERE=$(cd "$(dirname "$0")" && pwd)

# Build with the default (fatal) warning set, as the UVM testbench does, then run once.
# Not -Wall: it flags every clocking-block signal UNDRIVEN/UNUSEDSIGNAL (docs/toolchain.md, T8).
verilator --binary --timing -j "$J" --top-module t8_top -Mdir "$OUT/obj" \
  "$HERE/t8_cb.sv" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; fail "build (see $OUT/build.log)"; }
"$OUT/obj/Vt8_top" > "$OUT/run.log" 2>&1 || { cat "$OUT/run.log"; fail "run exited non-zero"; }

# Verdict: the result line is printed either way; T8_OK only if every expectation held.
grep 'T8 RESULT' "$OUT/run.log" | sed 's/^/  /'
grep -q T8_OK "$OUT/run.log" || fail "clocking-block timing differs from IEEE 1800 (see $OUT/run.log)"
pass "#1step samples pre-edge, output #0 drive lands in the edge's time step, gate is race-free"
