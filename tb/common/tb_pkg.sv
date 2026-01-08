package tb_pkg;

  `define TB_FATAL(MSG) begin \
    $error("[TB_FATAL] %s @t=%0t", MSG, $time); \
    $finish(2); \
  end

  `define TB_CHECK(COND, MSG) begin \
    if (!(COND)) begin \
      $error("[TB_CHECK] %s @t=%0t", MSG, $time); \
      $finish(2); \
    end \
  end

  function automatic int get_plusarg_int(string name, int default_val);
    int v;
    if ($value$plusargs({name, "=%d"}, v)) return v;
    return default_val;
  endfunction

  function automatic bit has_plusarg(string name);
    return $test$plusargs(name);
  endfunction

endpackage
