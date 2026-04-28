

`ifndef TB_REGMAP_SVH
`define TB_REGMAP_SVH


`define REG_CTRL           32'h00
`define REG_STATUS         32'h04
`define REG_M              32'h08
`define REG_N              32'h0C
`define REG_K              32'h10
`define REG_A_VAL_BASE     32'h14
`define REG_A_ROW_BASE     32'h18
`define REG_A_COL_BASE     32'h1C
`define REG_B_BASE         32'h20
`define REG_C_BASE         32'h24
`define REG_NNZ            32'h28


`define CTRL_START_BIT     0
`define CTRL_CLEAR_BIT     1
`define CTRL_IRQ_EN_BIT    2
`define CTRL_RELU_BIT      3


`define STATUS_BUSY_BIT    0
`define STATUS_DONE_BIT    1

`endif
