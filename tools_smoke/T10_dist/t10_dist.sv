// T10 (M3): which Verilator constrained-random distributions can fifo_env_cfg rely on? Checks
// `dist` weights on categorical choices, the period-ratio constraints, and inline `with`; also
// measures (for information) how evenly values spread inside a range with no `dist`.
// Prints measured shares; run.sh judges them against expected values.

// Cut-down fifo_env_cfg: bucket, integer/arbitrary kind, periods, reset gap. The bucket needs an
// explicit dist: without one, the first run gave 72% B0 and 0% B3 (docs/toolchain.md, T10).
class t10_cfg;
  rand int unsigned b, w, r, gap; rand bit k;
  constraint c_main { b dist {0 := 1, 1 := 1, 2 := 1, 3 := 1, 4 := 1}; k dist {1 := 20, 0 := 80};
    w inside {[2000:20000]}; w % 8 == 0; r % 2 == 0;
    gap dist {0 :/ 20, [1:15] :/ 40, [16:48] :/ 40}; }
  constraint c_ratio { k -> (b == 4 -> r == 4 * w) && (b == 0 -> 4 * r == w);
    !k -> (b == 4 -> r > 2 * w && r < 4 * w) && (b == 0 -> 4 * r > w && 2 * r < w);
    b inside {[1:3]} -> r == w; }  // B1–B3 pinned to keep the experiment short
endclass

// Randomize N times and print counts: per bucket, integer share, gap classes, spread checks.
module t10_top;
  initial begin
    automatic t10_cfg c = new; automatic int n = 2000, nb[5], nk, g0, g1, wlo, b4a, b4lo, bad, with_ok;
    for (int i = 0; i < n; i++) begin
      if (c.randomize() != 1) bad++;
      nb[c.b]++; nk += c.k; g0 += (c.gap == 0); g1 += (c.gap inside {[1:15]});
      wlo += (c.w < 11000);
      if (c.b == 4 && !c.k) begin b4a++; b4lo += (c.r < 3 * c.w); end
    end
    with_ok = int'((c.randomize() with { b == 3; } == 1) && c.b == 3);
    $display("T10 RESULT n=%0d bad=%0d b=%0d,%0d,%0d,%0d,%0d k=%0d gap0=%0d gap1_15=%0d w_lo=%0d b4arb=%0d b4arb_lo=%0d with=%0d",
             n, bad, nb[0], nb[1], nb[2], nb[3], nb[4], nk, g0, g1, wlo, b4a, b4lo, with_ok);
    $finish;
  end
endmodule
