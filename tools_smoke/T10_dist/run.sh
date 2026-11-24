#!/usr/bin/env bash
# T10 (M3): Verilator constrained-random distributions, as fifo_env_cfg uses them. PASS = `dist`
# weights honored (bucket, integer share, gap classes) within about 3.5 standard deviations, no
# randomize() failure, inline `with` honored. Spread inside a range without `dist` (T_wclk, and
# rho inside B4) is printed for information only: fifo_env_cfg draws those numbers itself.
source "$(dirname "$0")/../env.sh"; ts_init T10
HERE=$(cd "$(dirname "$0")" && pwd)

# Build and run once (2000 randomizations); also record the run time (the solver is external).
verilator --binary --timing -j "$J" --top-module t10_top -Mdir "$OUT/obj" "$HERE/t10_dist.sv" \
  > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; fail "build"; }
start=$SECONDS
"$OUT/obj/Vt10_top" +verilator+seed+1 > "$OUT/run.log" 2>&1 || { tail "$OUT/run.log"; fail "run"; }
line=$(grep 'T10 RESULT' "$OUT/run.log") || fail "no result line"
echo "  ${line#T10 RESULT } ($((SECONDS - start)) s)"

# Judge with Python: expected share and allowed deviation for each measurement.
python3 - "$line" <<'EOF' || fail "a distribution is off (see above)"
import sys, re
v = {k: s for k, s in re.findall(r'(\w+)=([\d,]+)', sys.argv[1])}
n = int(v['n']); b = [int(x) for x in v['b'].split(',')]
def near(name, got, total, p):  # within 3.5 sigma of the expected share p
    sd = (p * (1 - p) / total) ** 0.5; ok = abs(got / total - p) <= 3.5 * sd
    print(f"  {name:10s} {got / total:6.3f} (expect {p:.2f} ± {3.5 * sd:.3f}) {'ok' if ok else 'OFF'}"); return ok
ok = int(v['bad']) == 0 and int(v['with']) == 1
ok &= all([near(f'bucket{i}', b[i], n, 0.2) for i in range(5)])
ok &= all([near('integer', int(v['k']), n, 0.2), near('gap=0', int(v['gap0']), n, 0.2),
           near('gap1..15', int(v['gap1_15']), n, 0.4)])
print('  info (not judged; uniform would be 0.50):')
near('w<11000', int(v['w_lo']), n, 0.5); near('B4 rho<3', int(v['b4arb_lo']), int(v['b4arb']), 0.5)
sys.exit(0 if ok else 1)
EOF
pass "dist weights and inline with{} honored; spread inside a plain range is NOT uniform (info lines)"
