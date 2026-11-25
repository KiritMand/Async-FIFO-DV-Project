// T11 (M5): the covergroup constructs fifo_coverage needs, inside a class in a package: sample()
// with arguments, range bins, `iff`, 3-value transition bins, a cross of a transition coverpoint,
// `ignore_bins` on a cross (both `!binsof` and `&&` forms), type-level options, two instances.
package t11_pkg;
  // Collector class; vplan-style bins on a DEPTH = 16 fill value f, bucket b, phase p, lap l.
  class cov_c;
    covergroup cg with function sample(int f, int b, bit p, bit l);
      option.per_instance = 0;
      cp_f:  coverpoint f { bins zero = {0}; bins one = {1}; bins mid = {[2:14]}; bins af = {15}; bins full = {16}; }
      cp_t:  coverpoint f { bins full_bounce = (15 => 16 => 15); bins empty_bounce = (1 => 0 => 1); }
      cp_b:  coverpoint b { bins b[] = {[0:4]}; }
      cp_p:  coverpoint p { bins unal = {0}; bins al = {1}; }
      cp_l:  coverpoint l iff (f == 0 || f == 16) { bins l0 = {0}; bins l1 = {1}; }
      x_tb:  cross cp_t, cp_b;
      x_b2p: cross cp_b, cp_p { ignore_bins not_b2 = !binsof(cp_b) intersect {2}; }
      x_bp:  cross cp_b, cp_p { ignore_bins b0_al = binsof(cp_b) intersect {0} && binsof(cp_p.al); }
    endgroup
    // Constructor: the embedded covergroup must be created here.
    function new(); cg = new(); endfunction
  endclass
endpackage

// Drive a fixed sample sequence (expected counts are in run.sh) through instance a, plus one
// sample through instance b: type-level coverage must add both into the same bins.
module t11_top;
  import t11_pkg::*;
  initial begin
    static cov_c a = new(), b = new();
    static int s[][4] = '{'{15,3,0,0}, '{16,3,0,1}, '{15,3,0,1}, '{1,2,1,0}, '{0,2,0,0}, '{1,2,1,0}, '{5,4,1,1}, '{5,0,0,1}};
    foreach (s[i]) a.cg.sample(s[i][0], s[i][1], 1'(s[i][2]), 1'(s[i][3]));
    b.cg.sample(16, 3, 0, 1);
    $display("T11 GETCOV cg=%0.2f cp_t=%0.2f x_b2p=%0.2f", a.cg.get_coverage(), a.cg.cp_t.get_inst_coverage(),
             a.cg.x_b2p.get_inst_coverage());
    $finish;
  end
endmodule
