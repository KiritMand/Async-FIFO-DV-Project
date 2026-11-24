#!/usr/bin/env bash
# T9 (M3): reset asserted at time 0 with random register init. PASS = styles A (initializer 1,
# then 0 in an initial block) and B (the same after #0) set their flop on every seed, and the
# never-reset register differs between seeds (random init is really on). Style C (no
# initializer) is reported only: it works on seeds where rc happens to start at 1.
source "$(dirname "$0")/../env.sh"; ts_init T9
HERE=$(cd "$(dirname "$0")" && pwd)

# Build once with random initial values, as the UVM testbench does.
verilator --binary --timing --x-initial unique --x-assign unique -j "$J" --top-module t9_top \
  -Mdir "$OUT/obj" "$HERE/t9_reset.sv" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; fail "build"; }

# Run six seeds; collect each result line.
for s in 1 2 3 4 5 6; do
  "$OUT/obj/Vt9_top" +verilator+rand+reset+2 +verilator+seed+$s > "$OUT/seed$s.log" 2>&1 || fail "seed $s run"
  echo "  seed $s: $(grep -o 'qa=.*' "$OUT/seed$s.log")"
done

# Verdict: A and B on every seed; at least two distinct junk values across the seeds.
[[ $(grep -l 'qa=ffff qb=ffff' "$OUT"/seed*.log | wc -l) == 6 ]] || fail "a time-0 reset was missed"
[[ $(grep -oh 'junk=[0-9a-f]*' "$OUT"/seed*.log | sort -u | wc -l) -ge 2 ]] || fail "random init not active"
pass "time-0 reset (styles A and B) fires on all 6 seeds; random init differs per seed"
