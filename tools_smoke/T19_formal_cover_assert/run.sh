#!/usr/bin/env bash
# T19 (M8 bug matrix): what SBY cover mode does when an assertion fails. The matrix runs the
# cover task on planted bugs, which break assertions; their cover results are meaningful only if
# we know whether a failing assertion stops the search. Records: the verdict, which covers are
# reached, and whether the failing assertion is named. PASS = the run finished and the log
# answers all three (the behavior itself is recorded, not judged).
source "$(dirname "$0")/../env.sh"; ts_init T19
HERE=$(cd "$(dirname "$0")" && pwd)

# Run cover mode once; keep the log.
cp "$HERE/t19.sv" "$HERE/t19.sby" "$OUT/"
rc=0; (cd "$OUT" && sby -f t19.sby) > "$OUT/cover.log" 2>&1 || rc=$?
grep -q -E 'syntax error|Unused option|ERROR' "$OUT/cover.log" && fail "parse/config error, see $OUT/cover.log"
verdict=$(grep -o 'DONE ([A-Z]*' "$OUT/cover.log" | tail -1 | cut -c7-)
[[ -n "$verdict" ]] || fail "no verdict in $OUT/cover.log"

# Facts: covers reached, assertion named.
early=$(grep -q 'Reached cover.*cov_early' "$OUT/cover.log" && echo reached || echo "not reached")
late=$(grep -q 'Reached cover.*cov_late' "$OUT/cover.log" && echo reached || echo "not reached")
named=$(grep -q 'ast_small' "$OUT/cover.log" && echo "named" || echo "not named")
pass "cover mode with a failing assertion: verdict $verdict (rc=$rc), cov_early $early, cov_late $late, ast_small $named"
