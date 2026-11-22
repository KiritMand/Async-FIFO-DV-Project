#!/usr/bin/env bash
# T5 MCY: YosysHQ's bitcnt example (AppNote 400), unmodified, end to end:
# mcy init; mcy run -j4; mcy status. Runs in a copy under out/ (MCY writes database/ and tasks/).
# Proves the mutation-coverage tool works before M9 builds an MCY project for the FIFO.
source "$(dirname "$0")/../env.sh"; ts_init T5
HERE=$(cd "$(dirname "$0")" && pwd)

# Work on a copy so the vendored example under tools_smoke/ stays pristine.
cp -r "$HERE/bitcnt" "$OUT/bitcnt"; cd "$OUT/bitcnt"

# init: generate the mutation list; run: test every mutant (sim + equivalence check), 4 jobs.
mcy init > "$OUT/init.log" 2>&1 || { tail -20 "$OUT/init.log"; fail "mcy init"; }
start=$SECONDS
mcy run -j4 > "$OUT/run.log" 2>&1 || { tail -20 "$OUT/run.log"; fail "mcy run"; }
secs=$((SECONDS - start))

# status: print the tag counts and the config's [report] (the coverage score).
mcy status > "$OUT/status.log" 2>&1 || { cat "$OUT/status.log"; fail "mcy status"; }
cat "$OUT/status.log"

# tag <NAME>: number of mutations MCY tagged NAME. Verdict: a COVERED count and a score exist.
# (The exact score varies run to run: the example config sets no mutation seed.)
tag() { sed -nE "s/^Tagged ([0-9]+) mutations as \"$1\".*/\1/p" "$OUT/status.log" | head -1; }
cov=$(tag COVERED); unc=$(tag UNCOVERED); score=$(grep -oE 'Coverage: [0-9.]+%' "$OUT/status.log" || true)
[[ -n $cov && -n $score ]] || fail "status has no COVERED count / Coverage line"
pass "mcy run ${secs}s at -j4; COVERED=$cov UNCOVERED=${unc:-0}; $score"
