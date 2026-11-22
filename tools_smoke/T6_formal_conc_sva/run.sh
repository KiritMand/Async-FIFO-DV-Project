#!/usr/bin/env bash
# T6 (extra, supports DEC-002): does open-source formal accept concurrent SVA?
# Expected today: both the native Yosys reader and the bundled yosys-slang plugin REJECT
# `assert property (@(posedge clk) a |-> b)`. PASS = still rejected (DEC-002 holds);
# FAIL = support appeared — revisit DEC-002 (could allow concurrent SVA in formal).
source "$(dirname "$0")/../env.sh"; ts_init T6

# The smallest useful concurrent property: ack follows req by one cycle.
cat > "$OUT/conc.sv" <<'EOF'
module conc (input logic clk, req, output logic ack);
  always_ff @(posedge clk) ack <= req;
  ast_p: assert property (@(posedge clk) req |=> ack);
endmodule
EOF

# Try each frontend with a tiny generated SBY job; both must fail with an ERROR line.
for fe in native slang; do
  [[ $fe == native ]] && rd="read -formal conc.sv" || rd=$'plugin -i slang\nread_slang -D FORMAL conc.sv'
  printf '[options]\nmode bmc\ndepth 4\n[engines]\nsmtbmc yices\n[script]\n%s\nprep -top conc\n[files]\nconc.sv\n' "$rd" > "$OUT/$fe.sby"
  rc=0; (cd "$OUT" && sby -f "$fe.sby") > "$OUT/$fe.log" 2>&1 || rc=$?
  why=$(grep -m1 -oE 'ERROR: [^;]*' "$OUT/$fe.log" || true)
  echo "  $fe: rc=$rc ${why:-accepted}"
  [[ $rc != 0 && -n $why ]] || fail "$fe frontend now ACCEPTS concurrent SVA — revisit DEC-002"
done
pass "concurrent SVA rejected by native Yosys and yosys-slang (as recorded); DEC-002 style required"
