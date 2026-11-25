// T13 (M5): per-test reseeding for fifo_base_test. After process::self().srandom(s), both
// $urandom and the randomize() of an object created afterwards must follow s: same seed and
// name -> same values; same seed, different +NAME -> different values.
module t13_top;
  // Stand-in for fifo_env_cfg: one rand field drawn by randomize().
  class cfg_c; rand int unsigned x; endclass
  // Mix the run seed (first $urandom) with a hash of +NAME, reseed, then draw both ways.
  initial begin
    static string name = "";
    static int unsigned h = 0;
    static cfg_c c;
    void'($value$plusargs("NAME=%s", name));
    foreach (name[i]) h = h * 31 + int'(name[i]);
    process::self().srandom($urandom ^ h);
    c = new();
    if (c.randomize() != 1) $fatal(1, "randomize failed");
    $display("T13 RESULT name=%s obj=%0d urandom=%0d", name, c.x, $urandom);
  end
endmodule
