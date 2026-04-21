// tb/common/tb_regmap.svh
// Shared MMIO register-map definitions for the SpMM accelerator.
// Include with `include "tb/common/tb_regmap.svh"` in any testbench
// that drives or checks the accelerator's MMIO front-end.
//
// These addresses and bit positions MUST match rtl/accel_top.sv.
// Keeping them centralised prevents the drift that occurs when each
// testbench redeclares its own copy.

`ifndef TB_REGMAP_SVH
`define TB_REGMAP_SVH

// ---------------- Register byte offsets ----------------
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

// ---------------- CTRL bit positions --------------------
`define CTRL_START_BIT     0
`define CTRL_CLEAR_BIT     1
`define CTRL_IRQ_EN_BIT    2
`define CTRL_RELU_BIT      3

// ---------------- STATUS bit positions ------------------
`define STATUS_BUSY_BIT    0
`define STATUS_DONE_BIT    1

`endif  // TB_REGMAP_SVH
