#!/usr/bin/env bash
# T2 coverage merge: two runs each hit about half the live bins; the merged database hits all.
# Shared helpers and the pinned toolchain come from env.sh.
source "$(dirname "$0")/../env.sh"; ts_init T2
HERE=$(cd "$(dirname "$0")" && pwd)

# Build once with --coverage-user (enables covergroup counting in Verilator).
verilator --binary --coverage-user --top-module t2_top -Mdir "$OUT/obj" "$HERE/t2_cov.sv" \
  > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; fail "build"; }

# Run each half with its own seed, writing a separate coverage database per run.
for h in 0 1; do
  "$OUT/obj/Vt2_top" +HALF=$h +verilator+seed+$((h + 11)) +verilator+coverage+file+"$OUT/cov$h.dat" \
    > "$OUT/run$h.log" 2>&1 || fail "run HALF=$h"
  grep GETCOV "$OUT/run$h.log"
done

# Merge the two databases — the operation SO-1 sign-off relies on across seeds and ratios.
verilator_coverage --write "$OUT/merged.dat" "$OUT/cov0.dat" "$OUT/cov1.dat" || fail "merge"

# holes <dat>: count live covergroup bins (skipping ignore/illegal) and how many have zero
# hits; prints "<live> <holes>". Verilator has no per-bin covergroup report, so parse the .dat.
holes() { python3 -I - "$1" <<'EOF'
import sys
live = holes = 0
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("C '"): continue
    key, count = line[3:].rsplit("' ", 1)
    kv = dict(f.split("\x02", 1) for f in key.split("\x01") if "\x02" in f)
    if kv.get("t") != "covergroup" or kv.get("Bt") in ("ignore", "illegal"): continue
    live += 1; holes += int(count) == 0
print(live, holes)
EOF
}

# Verdict: 13 live bins; each run alone has holes; the merge has none.
read l0 h0 < <(holes "$OUT/cov0.dat"); read l1 h1 < <(holes "$OUT/cov1.dat"); read lm hm < <(holes "$OUT/merged.dat")
echo "live bins: $l0/$l1/$lm  holes: run0=$h0 run1=$h1 merged=$hm"
[[ $l0 == 13 && $lm == 13 ]] || fail "expected 13 live bins (cp_a 4 + cp_b 2 + cross 8-1 ignored), got $l0/$lm"
(( h0 > 0 && h1 > 0 )) || fail "each run alone should leave holes"
(( hm == 0 )) || fail "merged database still has $hm holes"
pass "run0 holes=$h0, run1 holes=$h1, merged holes=0 over $lm live bins; ignore_bins excluded"
