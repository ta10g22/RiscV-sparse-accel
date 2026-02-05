// tb/unit/accel_ctrl_tb.sv
// Compile order (Questa/ModelSim example):
//   vlog -sv tb/common/tb_pkg.sv
//   vlog -sv tb/common/clk_reset.sv
//   vlog -sv rtl/accel_ctrl.sv
//   vlog -sv tb/unit/accel_ctrl_tb.sv
// Run:
//   vsim work.accel_ctrl_tb +TEST=ctrl_smoke +WAVES
//   run -all

`timescale 1ns/1ps
`include "tb/common/tb_macros.svh"

// ------------------------------------------------------------
// 1) RAM model module (SYNC read: rdata valid 1 cycle after re)
// ------------------------------------------------------------
module ram_model_sync #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int WORDS      = 8192
)(
  input  logic                   clk,
  input  logic                   n_reset,

  input  logic                   re,
  input  logic                   we,
  input  logic [ADDR_WIDTH-1:0]  addr,
  input  logic [DATA_WIDTH-1:0]  wdata,
  output logic [DATA_WIDTH-1:0]  rdata
);

  logic [DATA_WIDTH-1:0] mem [0:WORDS-1];

  logic                  re_d;
  logic [ADDR_WIDTH-1:0] addr_d;

  function automatic int unsigned addr_to_word_idx(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1:2];
  endfunction

  // Same-cycle commit for writes
  always_ff @(posedge clk) begin
    if (we) begin
      if (addr[1:0] !== 2'b00) begin
        $error("[RAM] Unaligned WRITE addr=0x%08x @t=%0t", addr, $time);
      end
      if (addr_to_word_idx(addr) >= WORDS) begin
        $error("[RAM] OOB WRITE addr=0x%08x (word_idx=%0d) @t=%0t",
               addr, addr_to_word_idx(addr), $time);
      end else begin
        mem[addr_to_word_idx(addr)] <= wdata;
      end
    end
  end

  // Sync read: 1-cycle latency - data valid on cycle after re
  always_ff @(posedge clk) begin
    if (!n_reset) begin
      re_d   <= 1'b0;
      addr_d <= '0;
      rdata  <= '0;
    end else begin
      re_d   <= re;
      addr_d <= addr;

      if (re) begin
        if (addr[1:0] !== 2'b00) begin
          $error("[RAM] Unaligned READ addr=0x%08x @t=%0t", addr, $time);
          rdata <= '0;
        end else if (addr_to_word_idx(addr) >= WORDS) begin
          $error("[RAM] OOB READ addr=0x%08x (word_idx=%0d) @t=%0t",
                 addr, addr_to_word_idx(addr), $time);
          rdata <= '0;
        end else begin
          rdata <= mem[addr_to_word_idx(addr)];
        end
      end
    end
  end

  // TB helpers (hierarchical calls: u_ram.poke_word(...))
  task automatic poke_word(input int unsigned word_idx, input logic [DATA_WIDTH-1:0] val);
    if (word_idx >= WORDS) $error("[RAM] poke_word OOB word_idx=%0d", word_idx);
    else mem[word_idx] = val;
  endtask

  task automatic peek_word(input int unsigned word_idx, output logic [DATA_WIDTH-1:0] val);
    if (word_idx >= WORDS) begin
      $error("[RAM] peek_word OOB word_idx=%0d", word_idx);
      val = '0;
    end else begin
      val = mem[word_idx];
    end
  endtask

  task automatic clear_all();
    int i;
    for (i = 0; i < WORDS; i++) mem[i] = '0;
  endtask

endmodule

// ------------------------------------------------------------
// 2) Datapath stub module
// ------------------------------------------------------------
module datapath_stub #(
  parameter int DATA_WIDTH = 32
)(
  input  logic                  ctile_read_en,
  input  logic [DATA_WIDTH-1:0] forced_read_data,
  output logic [DATA_WIDTH-1:0] ctile_read_data,

  input  logic                  wb_en,
  input  logic [DATA_WIDTH-1:0] wb_in,
  output logic [DATA_WIDTH-1:0] wb_data_out
);
  always_comb begin
    ctile_read_data = forced_read_data;
    wb_data_out     = wb_in;
  end
endmodule

// ------------------------------------------------------------
// 3) TB top
// ------------------------------------------------------------
module accel_ctrl_tb;

  import tb_pkg::*;

  localparam int M_MAX      = 64;
  localparam int TN         = 8;
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 32;

  logic clk, n_reset;
  clk_reset u_cr(.clk(clk), .n_reset(n_reset));

  // DUT inputs
  logic start_pulse, clear_pulse, irq_en;

  logic [31:0] M_reg, N_reg, K_reg, NNZ_reg;

  logic [ADDR_WIDTH-1:0] rowptr_base_reg, colidx_base_reg, val_base_reg, B_base_reg, out_base_reg;

  logic relu_en_reg;
  logic [3:0] dtype_reg;

  // DUT outputs
  logic status_busy, status_done, irq_out;

  // RAM interface
  logic                   ram_re, ram_we;
  logic [ADDR_WIDTH-1:0]  ram_addr;
  logic [DATA_WIDTH-1:0]  ram_wdata;
  logic [DATA_WIDTH-1:0]  ram_rdata;

  // ctrl -> datapath interface
  logic                      dp_clear_en;
  logic [$clog2(M_MAX)-1:0]  dp_clear_row;
  logic [$clog2(TN)-1:0]     dp_clear_col;

  logic                      dp_bseg_we;
  logic [$clog2(TN)-1:0]     dp_bseg_idx;
  logic [DATA_WIDTH-1:0]     dp_bseg_wdata;

  logic                      dp_mac_en;
  logic [$clog2(M_MAX)-1:0]  dp_mac_row;
  logic [$clog2(TN)-1:0]     dp_mac_col;
  logic [DATA_WIDTH-1:0]     dp_mac_a;

  logic                      dp_ctile_read_en;
  logic [$clog2(M_MAX)-1:0]  dp_ctile_read_row;
  logic [$clog2(TN)-1:0]     dp_ctile_read_col;
  logic [DATA_WIDTH-1:0]     dp_ctile_read_data;

  logic                      dp_wb_en;
  logic [DATA_WIDTH-1:0]     dp_wb_in;
  logic                      dp_relu_en;
  logic [3:0]                dp_dtype;
  logic [DATA_WIDTH-1:0]     dp_wb_data_out;

  // RAM model
  ram_model_sync #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .WORDS(8192)
  ) u_ram (
    .clk    (clk),
    .n_reset(n_reset),
    .re     (ram_re),
    .we     (ram_we),
    .addr   (ram_addr),
    .wdata  (ram_wdata),
    .rdata  (ram_rdata)
  );

  // Datapath stub
  logic [DATA_WIDTH-1:0] forced_ctile_read_data;
  datapath_stub #(.DATA_WIDTH(DATA_WIDTH)) u_dp_stub (
    .ctile_read_en    (dp_ctile_read_en),
    .forced_read_data (forced_ctile_read_data),
    .ctile_read_data  (dp_ctile_read_data),
    .wb_en            (dp_wb_en),
    .wb_in            (dp_wb_in),
    .wb_data_out      (dp_wb_data_out)
  );

  // DUT
  accel_ctrl #(
    .M_MAX(M_MAX),
    .TN(TN),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk(clk),
    .n_reset(n_reset),

    .start_pulse(start_pulse),
    .clear_pulse(clear_pulse),
    .irq_en(irq_en),

    .M_reg(M_reg),
    .N_reg(N_reg),
    .K_reg(K_reg),
    .NNZ_reg(NNZ_reg),

    .rowptr_base_reg(rowptr_base_reg),
    .colidx_base_reg(colidx_base_reg),
    .val_base_reg(val_base_reg),
    .B_base_reg(B_base_reg),
    .out_base_reg(out_base_reg),

    .relu_en_reg(relu_en_reg),
    .dtype_reg(dtype_reg),

    .status_busy(status_busy),
    .status_done(status_done),
    .irq_out(irq_out),

    .ram_re(ram_re),
    .ram_we(ram_we),
    .ram_addr(ram_addr),
    .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata),

    .dp_clear_en(dp_clear_en),
    .dp_clear_row(dp_clear_row),
    .dp_clear_col(dp_clear_col),

    .dp_bseg_we(dp_bseg_we),
    .dp_bseg_idx(dp_bseg_idx),
    .dp_bseg_wdata(dp_bseg_wdata),

    .dp_mac_en(dp_mac_en),
    .dp_mac_row(dp_mac_row),
    .dp_mac_col(dp_mac_col),
    .dp_mac_a(dp_mac_a),

    .dp_ctile_read_en(dp_ctile_read_en),
    .dp_ctile_read_row(dp_ctile_read_row),
    .dp_ctile_read_col(dp_ctile_read_col),
    .dp_ctile_read_data(dp_ctile_read_data),

    .dp_wb_en(dp_wb_en),
    .dp_wb_in(dp_wb_in),
    .dp_relu_en(dp_relu_en),
    .dp_dtype(dp_dtype),
    .dp_wb_data_out(dp_wb_data_out)
  );

  // Cheap protocol checks
  always_ff @(posedge clk) begin
    if (!n_reset) begin
      `TB_CHECK(!ram_re && !ram_we, "RAM activity during reset")
    end else begin
      if (ram_re || ram_we) begin
        `TB_CHECK(ram_addr[1:0] == 2'b00, $sformatf("Unaligned RAM addr=0x%08x", ram_addr))
      end
    end
  end

  // Helpers
  task automatic drive_defaults();
    start_pulse = 1'b0;
    clear_pulse = 1'b0;
    irq_en      = 1'b0;

    M_reg   = 32'd0;
    N_reg   = 32'd0;
    K_reg   = 32'd0;
    NNZ_reg = 32'd0;

    rowptr_base_reg = '0;
    colidx_base_reg = '0;
    val_base_reg    = '0;
    B_base_reg      = '0;
    out_base_reg    = '0;

    relu_en_reg = 1'b0;
    dtype_reg   = 4'h0;

    forced_ctile_read_data = 32'h0;
  endtask

  task automatic pulse_start();
    @(posedge clk);
    start_pulse <= 1'b1;
    @(posedge clk);
    start_pulse <= 1'b0;
  endtask

  function automatic int unsigned word_idx_from_addr(input logic [31:0] a);
    return a[31:2];
  endfunction

  task automatic preload_rowptr_all_zero(input logic [31:0] base_addr, input int unsigned m);
    int unsigned i;
    for (i = 0; i <= m; i++) begin
      u_ram.poke_word(word_idx_from_addr(base_addr) + i, 32'd0);
    end
  endtask

  // Test
  task automatic test_ctrl_smoke();
    int unsigned timeout;

    u_cr.apply_reset();
    drive_defaults();
    u_ram.clear_all();

    irq_en      = 1'b1;
    relu_en_reg = 1'b0;
    dtype_reg   = 4'h0;

    M_reg   = 32'd2;
    N_reg   = 32'd1;
    K_reg   = 32'd1;
    NNZ_reg = 32'd0;

    rowptr_base_reg = 32'h0000_0100;
    colidx_base_reg = 32'h0000_0200;
    val_base_reg    = 32'h0000_0300;
    B_base_reg      = 32'h0000_0400;
    out_base_reg    = 32'h0000_0800;

    preload_rowptr_all_zero(rowptr_base_reg, int'(M_reg)); // safe cast

    pulse_start();

    timeout = 0;
    while (!status_busy && timeout < 2000) begin
      @(posedge clk);
      timeout++;
    end
    `TB_CHECK(status_busy, "status_busy never asserted after start")

    timeout = 0;
    while (!status_done && timeout < 200000) begin
      @(posedge clk);
      timeout++;
    end
    `TB_CHECK(status_done, "status_done never asserted (ctrl likely stuck)")

    `TB_CHECK(irq_out === 1'b1, "irq_out not asserted on done with irq_en=1 (adjust if irq is pulsed)")

    $display("[PASS] test_ctrl_smoke");
  endtask

  // Main
  initial begin
    string testname;
    int seed = get_plusarg_int("SEED", 1);
    void'($urandom(seed));

    if (!$value$plusargs("TEST=%s", testname)) testname = "ctrl_smoke";

    if (has_plusarg("WAVES")) begin
      $dumpfile("waves_ctrl.vcd");
      $dumpvars(0, accel_ctrl_tb);
    end

    drive_defaults();

    case (testname)
      "ctrl_smoke": test_ctrl_smoke();
      default: `TB_FATAL($sformatf("Unknown TEST=%s", testname))
    endcase

    $finish(0);
  end

endmodule
