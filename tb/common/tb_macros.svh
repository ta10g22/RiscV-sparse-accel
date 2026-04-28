

`ifndef TB_MACROS_SVH
`define TB_MACROS_SVH

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

`endif
