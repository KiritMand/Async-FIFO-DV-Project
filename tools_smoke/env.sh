# Sourced by tools_smoke/*/run.sh: strict mode, paths, pinned toolchain (docs/toolchain.md).
# Keeps every experiment independent of how the calling shell was set up.

# Strict mode (stop on errors/unset vars) and repo-relative paths.
set -euo pipefail
TS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TS_ROOT/.." && pwd)

# Toolchain: put the pinned OSS CAD Suite first on PATH and point at the pinned UVM sources.
# Override OSS_CAD_SUITE / UVM_HOME / J from the environment if installed elsewhere.
OSS_CAD_SUITE=${OSS_CAD_SUITE-$HOME/tools/oss-cad-suite}
if [[ -n $OSS_CAD_SUITE && -x $OSS_CAD_SUITE/bin/yosys ]]; then export PATH="$OSS_CAD_SUITE/bin:$PATH"; fi
UVM_HOME=${UVM_HOME:-$HOME/tools/uvm-2020-3.2/src}
J=${J:-$(nproc)}

# ts_init <test-id>: set TID and a fresh output dir OUT=out/tools_smoke/<id>, and print the
# reproduction command. The guard refuses to delete anything outside out/tools_smoke/.
ts_init() { TID=${1:?test id}; OUT="$REPO/out/tools_smoke/$TID"
            [[ -n $TID && $OUT == "$REPO"/out/tools_smoke/T* ]] || { echo "bad OUT=$OUT" >&2; exit 2; }
            rm -rf -- "$OUT"; mkdir -p "$OUT"
            echo "== $TID  (repro: ${BASH_SOURCE[1]#$REPO/})  out: ${OUT#$REPO/}"; }

# pass/fail: print the one-line verdict run_all.sh shows, and exit 0 / 1.
pass() { echo "$TID PASS${1:+ — $1}"; exit 0; }
fail() { echo "$TID FAIL — $1" >&2; exit 1; }

# uvm_count <log> <SEVERITY>: number from the UVM report summary ("UVM_ERROR :    0")
uvm_count() { sed -n "s/^$2 *: *\([0-9][0-9]*\)\$/\1/p" "$1" | tail -1; }
