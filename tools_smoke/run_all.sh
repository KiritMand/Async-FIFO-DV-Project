#!/usr/bin/env bash
# Rerun every capability experiment (do this after any tool upgrade) and print a summary.
# Usage: tools_smoke/run_all.sh [T1 T3 ...]   (default: all). Logs: out/tools_smoke/<T>.log
# Called by `make tools-smoke`. Exits non-zero if any experiment fails.

# Setup: no `set -e` here, so one failing experiment doesn't stop the others.
set -uo pipefail
cd "$(dirname "$0")"
LOG=../out/tools_smoke; mkdir -p "$LOG"
sel=("$@"); rc=0

# Run each T<n>_<name>/run.sh (or only the selected IDs); print verdict, time, last log line.
for d in T*_*/; do
  t=${d%%_*}; [[ ${#sel[@]} -eq 0 || " ${sel[*]} " == *" $t "* ]] || continue
  start=$SECONDS
  if "./${d}run.sh" > "$LOG/$t.log" 2>&1; then r=PASS; else r=FAIL; rc=1; fi
  printf '%-18s %s  (%ss)  %s\n' "${d%/}" "$r" $((SECONDS - start)) "$(tail -1 "$LOG/$t.log")"
done
exit $rc
