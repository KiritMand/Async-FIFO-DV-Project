// T15 (M6): the FIFO property style in open-source formal (read -formal, multiclock on):
// a sim-only action block through a macro (Yosys rejects `else` on assert, first T15 run), a
// keyword macro as the verb (assume here), $past in a block clocked by a design clock (not
// gclk), async-reset flops, labeled covers, a second clock; $past sampled at every clka edge even
// inside an if that skips some edges (ast_t15_past fails if history were kept only when executed).
// -DBREAK makes the counter skip a value, so ast_t15_step must fail by label.
`define T15_ASM assume
`ifdef FORMAL
  `define T15_ELSE(msg)
`else
  `define T15_ELSE(msg) else $error msg
`endif
module t15_imm (input wire clka, input wire clkb, input wire rst_n, input wire a);
  // Counter on clka (async reset), copied into the clkb domain; past-valid flag on clka.
  reg [2:0] cnt; reg [2:0] q; reg pv;
  always @(posedge clka or negedge rst_n) if (!rst_n) begin cnt <= 0; pv <= 0; end
    else begin pv <= 1'b1; cnt <= cnt + ((a && `ifdef BREAK cnt == 3'd2 `else 1'b0 `endif) ? 3'd2 : {2'b0, a}); end
  always @(posedge clkb) q <= cnt;
  initial assume (!rst_n);
  // Clocked properties: the assumption caps cnt at 5 (so ast_t15_max needs it), the step
  // check uses $past, and two covers show the clka and clkb sides can both reach 5.
  always @(posedge clka) if (rst_n) begin
    asm_t15_cap: `T15_ASM (!(a && cnt == 3'd5));
    ast_t15_max: assert (cnt <= 3'd5) `T15_ELSE(("cnt=%0d", cnt));
    if (pv) ast_t15_step: assert (cnt == $past(cnt) || cnt == $past(cnt) + 3'd1) `T15_ELSE(("step %0d", cnt));
    if (pv && cnt[0]) ast_t15_past: assert ($past(cnt) == cnt || $past(cnt) == cnt - 3'd1);
    cov_t15_five: cover (cnt == 3'd5);
  end
  always @(posedge clkb) cov_t15_q_five: cover (q == 3'd5);
endmodule
