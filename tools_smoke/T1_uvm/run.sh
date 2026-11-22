#!/usr/bin/env bash
# T1 UVM: build once, run two seeds; values must differ, constraints hold, summary parses.
# Shared helpers (ts_init, pass, fail, uvm_count) and the pinned toolchain come from env.sh.
source "$(dirname "$0")/../env.sh"; ts_init T1
HERE=$(cd "$(dirname "$0")" && pwd)

# Build: UVM library + its DPI C code + the test, into one executable. /usr/bin/time records
# build time and peak memory (UVM builds are the slowest step in the whole flow).
/usr/bin/time -f "build: %e s, peak RSS %M KB" -o "$OUT/build_time.txt" \
  verilator --binary --vpi -j "$J" --top-module t1_top -Mdir "$OUT/obj" \
    +incdir+"$UVM_HOME" "$UVM_HOME/uvm_pkg.sv" "$UVM_HOME/dpi/uvm_dpi.cc" \
    "$HERE/t1_uvm.sv" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; fail "build (see $OUT/build.log)"; }
cat "$OUT/build_time.txt"

# Run the same executable with two seeds; each run must end with a clean UVM report summary
# (zero UVM_ERROR and UVM_FATAL) and print all 8 values.
for s in 1 2; do
  "$OUT/obj/Vt1_top" +verilator+seed+$s +UVM_NO_RELNOTES > "$OUT/seed$s.log" 2>&1 || true
  grep -q -- '--- UVM Report Summary ---' "$OUT/seed$s.log" || fail "seed $s: no UVM report summary"
  e=$(uvm_count "$OUT/seed$s.log" UVM_ERROR); f=$(uvm_count "$OUT/seed$s.log" UVM_FATAL)
  [[ $e == 0 && $f == 0 ]] || fail "seed $s: UVM_ERROR=$e UVM_FATAL=$f"
  [[ $(grep -c 'VAL data=' "$OUT/seed$s.log") == 8 ]] || fail "seed $s: expected 8 values"
done

# Different seeds must give different random values, otherwise seeding doesn't work.
cmp -s <(grep -o 'VAL .*' "$OUT/seed1.log") <(grep -o 'VAL .*' "$OUT/seed2.log") \
  && fail "seeds 1 and 2 produced identical values"
pass "8 constrained items/seed, seeds differ, UVM_ERROR=0 UVM_FATAL=0; $(cat "$OUT/build_time.txt")"
