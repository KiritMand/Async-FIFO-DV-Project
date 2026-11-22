#!/usr/bin/env bash
# T7 (M1): does an elaboration-time parameter guard — `if (P < 2) $error(...)` in a generate
# scope — stop elaboration in Verilator and Yosys? rtl/async_fifo.sv relies on it (spec §2).
# PASS = both tools reject ASIZE=1 and accept ASIZE=2. Verilator reports it only as warning
# USERERROR, so it also checks that -Wno-fatal lets it through and -Werror-USERERROR restores it.
source "$(dirname "$0")/../env.sh"; ts_init T7

# Minimal module carrying the guard (no %d in the message: Yosys prints format specs verbatim).
cat > "$OUT/guard.sv" <<'EOF'
module guard #(parameter int ASIZE = 4) (input logic [ASIZE:0] a, output logic [ASIZE:0] y);
  if (ASIZE < 2) begin : g_asize_check $error("guard: ASIZE must be >= 2"); end
  assign y = a;
endmodule
EOF

# expect <ok|err> <tag> <cmd...>: run one tool; ok = exit 0, err = non-zero exit plus message.
expect() { local want=$1 tag=$2 rc=0 msg; shift 2
  (cd "$OUT" && "$@") > "$OUT/$tag.log" 2>&1 || rc=$?
  msg=$(grep -m1 -o 'ASIZE must be >= 2' "$OUT/$tag.log" || true)
  echo "  $tag: rc=$rc${msg:+ (message printed)}"
  [[ ($want == ok && $rc == 0) || ($want == err && $rc != 0 && -n $msg) ]] || fail "$tag: expected $want, got rc=$rc"; }

# Legal (2) and illegal (1) value in each tool; Yosys via chparam and via hierarchy -chparam.
for a in 2 1; do w=$([[ $a == 2 ]] && echo ok || echo err)
  expect "$w" "verilator_A$a" verilator --lint-only -Wall -GASIZE=$a guard.sv
  expect "$w" "yosys_chparam_A$a" yosys -q -p "read_verilog -sv guard.sv; chparam -set ASIZE $a guard; prep -top guard"
  expect "$w" "yosys_hier_A$a" yosys -q -p "read_verilog -sv guard.sv; hierarchy -top guard -chparam ASIZE $a; proc"
done

# Verilator hazard: with -Wno-fatal the guard is only a warning; -Werror-USERERROR makes it stick.
expect ok  verilator_A1_nofatal verilator --lint-only -Wall -Wno-fatal -GASIZE=1 guard.sv
expect err verilator_A1_werror  verilator --lint-only -Wall -Wno-fatal -Werror-USERERROR -GASIZE=1 guard.sv
pass "generate-if \$error stops ASIZE=1 in Yosys and Verilator (Verilator: keep -Werror-USERERROR)"
