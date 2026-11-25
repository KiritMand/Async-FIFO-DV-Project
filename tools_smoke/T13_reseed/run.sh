#!/usr/bin/env bash
# T13 (M5): reseeding a process with process::self().srandom() so two tests at the same seed
# draw different configurations (seed decorrelation in fifo_base_test). PASS = for the same
# +verilator+seed, the same +NAME repeats both values exactly, and a different +NAME changes both
# the object's randomize() result and $urandom.
source "$(dirname "$0")/../env.sh"; ts_init T13
HERE=$(cd "$(dirname "$0")" && pwd)

# Build once (warnings fatal), then run three times: name a, name a again, name b.
verilator --binary --top-module t13_top -Mdir "$OUT/obj" "$HERE/t13_reseed.sv" \
  > "$OUT/build.log" 2>&1 || { grep -E '%(Error|Warning)' "$OUT/build.log" | head; fail "build"; }
r() { "$OUT/obj/Vt13_top" +verilator+seed+7 +NAME="$1" | grep 'T13 RESULT' | sed 's/.*name=[a-z]* //'; }
a1=$(r alpha); a2=$(r alpha); b=$(r beta)
echo "  alpha: $a1 | alpha again: $a2 | beta: $b"

# Verdict: repeatable per name, and both draws differ between names.
[[ -n $a1 && $a1 == "$a2" ]] || fail "same seed and name gave different values"
[[ ${a1%% *} != "${b%% *}" ]] || fail "object randomize() ignores the reseed"
[[ ${a1##* } != "${b##* }" ]] || fail "\$urandom ignores the reseed"
pass "process::self().srandom() reseeds \$urandom and later objects' randomize()"
