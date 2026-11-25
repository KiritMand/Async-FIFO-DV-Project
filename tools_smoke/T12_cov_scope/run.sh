#!/usr/bin/env bash
# T12 (M5): limit code coverage (line, branch, toggle) to the design with a .vlt file, as the
# UVM build needs (UVM and testbench code must not be instrumented). PASS = with t12.vlt, every
# line/branch/toggle point is in t12_dut.sv, the testbench covergroup is still recorded, and the
# DUT's untaken else branch shows as a 0-count point. Info: the global-off form records nothing.
source "$(dirname "$0")/../env.sh"; ts_init T12
HERE=$(cd "$(dirname "$0")" && pwd)
FLAGS="--binary --timing --coverage-line --coverage-branch --coverage-toggle --coverage-user --top-module t12_tb"

# build_run <name> [vlt]: build with the given config file (if any), run once, write <name>.dat.
build_run() { verilator $FLAGS -Mdir "$OUT/obj_$1" ${2:-} "$HERE/t12_dut.sv" "$HERE/t12_tb.sv" \
                > "$OUT/build_$1.log" 2>&1 || { grep -E '%(Error|Warning)' "$OUT/build_$1.log" | head; fail "build $1"; }
              (cd "$OUT" && "./obj_$1/Vt12_tb" +verilator+coverage+file+"$1.dat" > "run_$1.log" 2>&1) || fail "run $1"; }

# count <dat>: one line per (coverage type, source file) with its number of points and of 0-count points.
count() { python3 -I - "$1" <<'PY'
import sys, collections
n = collections.Counter(); z = collections.Counter()
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("C '"): continue
    key, cnt = line[3:].rsplit("' ", 1)
    kv = dict(f.split("\x02", 1) for f in key.split("\x01") if "\x02" in f)
    k = (kv.get("page", "").split("/")[0], kv.get("f", "").split("/")[-1]); n[k] += 1; z[k] += int(cnt) == 0
for k in sorted(n): print(*k, n[k], z[k])
PY
}

# The scoped build: the judged result.
build_run scoped "$HERE/t12.vlt"
count "$OUT/scoped.dat" | tee "$OUT/scoped.txt" | sed 's/^/  scoped: /'
! grep -E '^v_(line|branch|toggle) ' "$OUT/scoped.txt" | grep -qv ' t12_dut.sv ' || fail "testbench code still instrumented"
grep -q '^v_covergroup t12_tb.sv 1 0$' "$OUT/scoped.txt" || fail "covergroup bin lost or not hit"
grep -qE '^v_branch t12_dut.sv 2 1$' "$OUT/scoped.txt" || fail "expected 2 DUT branch points, 1 of them (else) at 0"

# Info only: the global-off form (`coverage_off` then `coverage_on -file`) — how many points survive.
printf '`verilator_config\ncoverage_off\ncoverage_on -file "*/t12_dut.sv"\n' > "$OUT/global_off.vlt"
build_run global "$OUT/global_off.vlt"
echo "  info: global coverage_off + coverage_on -file keeps only: $(count "$OUT/global.dat" | awk '{print $1 "/" $2}' | paste -sd ' ')"
pass "coverage_off -file scopes line/branch/toggle to the DUT and keeps covergroups"
