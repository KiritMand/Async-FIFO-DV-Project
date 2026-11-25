#!/usr/bin/env bash
# T11 (M5): covergroup constructs for fifo_coverage (vplan §3 implementation rules). PASS = every
# bin record in coverage.dat has exactly the hand-computed count: range bins, `iff`, 3-value
# transition bins, a transition × bucket cross, `ignore_bins` on a cross in the `!binsof` and
# `&&` forms (ignored bins carry Bt=ignore and no live cross bin), and type-level counting
# (two instances add into one record, named by type, so runs merge).
source "$(dirname "$0")/../env.sh"; ts_init T11
HERE=$(cd "$(dirname "$0")" && pwd)

# Build with user coverage (warnings fatal, the default) and run once.
verilator --binary --coverage-user --top-module t11_top -Mdir "$OUT/obj" "$HERE/t11_cov.sv" \
  > "$OUT/build.log" 2>&1 || { grep -E '%(Error|Warning)' "$OUT/build.log" | head; fail "build"; }
(cd "$OUT" && ./obj/Vt11_top +verilator+coverage+file+cov.dat > run.log 2>&1) || fail "run"
grep 'T11 GETCOV' "$OUT/run.log" | sed 's/^/  /'

# Compare each record (keyed by its hierarchical bin name) with the expected count; any missing,
# extra or miscounted record fails. Expected counts follow the sample list in t11_cov.sv.
python3 -I - "$OUT/cov.dat" <<'EOF' || fail "bin counts differ (see above)"
import sys
exp = {"cp_f.zero": 1, "cp_f.one": 2, "cp_f.mid": 2, "cp_f.af": 2, "cp_f.full": 2,
       "cp_t.full_bounce": 1, "cp_t.empty_bounce": 1,
       "cp_b.b[0]": 1, "cp_b.b[1]": 0, "cp_b.b[2]": 3, "cp_b.b[3]": 4, "cp_b.b[4]": 1,
       "cp_p.unal": 6, "cp_p.al": 3, "cp_l.l0": 1, "cp_l.l1": 2,
       "x_b2p.<b[2],al>": 2, "x_b2p.<b[2],unal>": 1, "x_b2p.not_b2": 6,
       "x_bp.<b[0],unal>": 1, "x_bp.<b[2],al>": 2, "x_bp.<b[2],unal>": 1, "x_bp.<b[3],unal>": 4,
       "x_bp.<b[4],al>": 1, "x_bp.b0_al": 0}
for b in range(5):  # cross bins not listed above are expected at 0
    for t in ("full_bounce", "empty_bounce"): exp.setdefault(f"x_tb.<{t},b[{b}]>", 1 if (t, b) in (("full_bounce", 3), ("empty_bounce", 2)) else 0)
    for p in ("al", "unal"):
        if (b, p) != (0, "al"): exp.setdefault(f"x_bp.<b[{b}],{p}>", 0)
got, ignored = {}, set()
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("C '"): continue
    key, count = line[3:].rsplit("' ", 1)
    kv = dict(f.split("\x02", 1) for f in key.split("\x01") if "\x02" in f)
    if kv.get("t") != "covergroup": continue
    assert kv["h"].startswith("t11_pkg::cov_c::cg."), kv["h"]  # type-level name, no instance
    h = kv["h"].split("cg.", 1)[1]; got[h] = got.get(h, 0) + int(count)
    if kv.get("Bt") == "ignore": ignored.add(h)
bad = [f"{h}: got {got.get(h)} expected {exp.get(h)}" for h in sorted(set(exp) | set(got)) if got.get(h) != exp.get(h)]
bad += [f"{h}: not marked ignore" for h in ("x_b2p.not_b2", "x_bp.b0_al") if h not in ignored]
print("\n".join("  " + b for b in bad) or f"  {len(got)} records, {len(got) - len(ignored)} live, all counts as expected")
sys.exit(1 if bad else 0)
EOF
pass "iff, transition bins, transition x bucket cross, ignore_bins on crosses, type-level merge of two instances"
