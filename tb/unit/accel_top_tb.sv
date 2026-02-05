// tb/unit/accel_top_tb.sv
// Integration testbench for accel_top (MMIO + ctrl + datapath)
//
// Compile order (ModelSim):
//   vlog -sv tb/common/tb_pkg.sv
//   vlog -sv tb/common/clk_reset.sv
//   vlog -sv rtl/accel_datapath.sv
//   vlog -sv rtl/accel_ctrl.sv
//   vlog -sv rtl/accel_top.sv
//   vlog -sv tb/unit/accel_top_tb.sv
// Run:
//   vsim work.accel_top_tb +TEST=all +WAVES
//   run -all

`timescale 1ns/1ps
`include "tb/common/tb_macros.svh"

module accel_top_tb;

  import tb_pkg::*;

  // Parameters
  localparam int M_MAX      = 64;
  localparam int TN         = 8;
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 32;

  // MMIO register offsets (must match accel_top.sv)
  localparam logic [31:0] CTRL_OFFSET       = 32'h00;
  localparam logic [31:0] STATUS_OFFSET     = 32'h04;
  localparam logic [31:0] M_OFFSET          = 32'h08;
  localparam logic [31:0] N_OFFSET          = 32'h0C;
  localparam logic [31:0] K_OFFSET          = 32'h10;
  localparam logic [31:0] A_VAL_BASE_OFFSET = 32'h14;
  localparam logic [31:0] A_ROW_BASE_OFFSET = 32'h18;
  localparam logic [31:0] A_COL_BASE_OFFSET = 32'h1C;
  localparam logic [31:0] B_BASE_OFFSET     = 32'h20;
  localparam logic [31:0] C_BASE_OFFSET     = 32'h24;
  localparam logic [31:0] NNZ_OFFSET        = 32'h28;

  // CTRL bits
  localparam int CTRL_START_BIT  = 0;
  localparam int CTRL_CLEAR_BIT  = 1;
  localparam int CTRL_IRQ_EN_BIT = 2;
  localparam int CTRL_RELU_BIT   = 3;

  // STATUS bits
  localparam int STATUS_BUSY_BIT = 0;
  localparam int STATUS_DONE_BIT = 1;

  // Clock/reset
  logic clk, n_reset;
  clk_reset u_cr(.clk(clk), .n_reset(n_reset));

  // DUT MMIO interface
  logic [ADDR_WIDTH-1:0]   mmio_addr;
  logic [DATA_WIDTH-1:0]   mmio_wdata;
  logic                    mmio_we;
  logic                    mmio_re;
  logic [DATA_WIDTH/8-1:0] mmio_wstrb;
  logic                    mmio_valid;
  logic [DATA_WIDTH-1:0]   mmio_rdata;
  logic                    mmio_ready;

  // DUT RAM interface
  logic                    ram_re;
  logic                    ram_we;
  logic [ADDR_WIDTH-1:0]   ram_addr;
  logic [DATA_WIDTH-1:0]   ram_wdata;
  logic [DATA_WIDTH-1:0]   ram_rdata;

  // DUT outputs
  logic [3:0]              led;
  logic                    irq;

  // ============================================================
  // RAM model (same as in accel_ctrl_tb)
  // ============================================================
  localparam int RAM_WORDS = 16384;
  logic [DATA_WIDTH-1:0] ram_mem [0:RAM_WORDS-1];

  logic                  ram_re_d;
  logic [ADDR_WIDTH-1:0] ram_addr_d;

  function automatic int unsigned addr_to_word(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1:2];
  endfunction

  always_ff @(posedge clk) begin
    if (!n_reset) begin
      ram_re_d   <= 1'b0;
      ram_addr_d <= '0;
      ram_rdata  <= '0;
    end else begin
      // Write
      if (ram_we) begin
        ram_mem[addr_to_word(ram_addr)] <= ram_wdata;
      end
      // Sync read
      ram_re_d   <= ram_re;
      ram_addr_d <= ram_addr;
      if (ram_re_d) begin
        ram_rdata <= ram_mem[addr_to_word(ram_addr_d)];
      end
    end
  end

  task automatic ram_clear();
    int i;
    for (i = 0; i < RAM_WORDS; i++) ram_mem[i] = '0;
  endtask

  task automatic ram_poke(input int word_idx, input logic [31:0] val);
    ram_mem[word_idx] = val;
  endtask

  function automatic logic [31:0] ram_peek(input int word_idx);
    return ram_mem[word_idx];
  endfunction

  // ============================================================
  // DUT instantiation
  // ============================================================
  accel_top #(
    .M_MAX     (M_MAX),
    .TN        (TN),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk        (clk),
    .n_reset    (n_reset),
    .mmio_addr  (mmio_addr),
    .mmio_wdata (mmio_wdata),
    .mmio_we    (mmio_we),
    .mmio_re    (mmio_re),
    .mmio_wstrb (mmio_wstrb),
    .mmio_valid (mmio_valid),
    .mmio_rdata (mmio_rdata),
    .mmio_ready (mmio_ready),
    .ram_re     (ram_re),
    .ram_we     (ram_we),
    .ram_addr   (ram_addr),
    .ram_wdata  (ram_wdata),
    .ram_rdata  (ram_rdata),
    .led        (led),
    .irq        (irq)
  );

  // ============================================================
  // MMIO helper tasks
  // ============================================================
  task automatic mmio_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    mmio_addr  <= addr;
    mmio_wdata <= data;
    mmio_we    <= 1'b1;
    mmio_re    <= 1'b0;
    mmio_wstrb <= 4'hF;
    mmio_valid <= 1'b1;
    @(posedge clk);
    mmio_we    <= 1'b0;
    mmio_valid <= 1'b0;
  endtask

  task automatic mmio_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    mmio_addr  <= addr;
    mmio_we    <= 1'b0;
    mmio_re    <= 1'b1;
    mmio_wstrb <= 4'h0;
    mmio_valid <= 1'b1;
    @(posedge clk);
    data = mmio_rdata;
    mmio_re    <= 1'b0;
    mmio_valid <= 1'b0;
  endtask

  task automatic drive_mmio_defaults();
    mmio_addr  = '0;
    mmio_wdata = '0;
    mmio_we    = 1'b0;
    mmio_re    = 1'b0;
    mmio_wstrb = 4'h0;
    mmio_valid = 1'b0;
  endtask

  task automatic wait_done(input int timeout_cycles);
    logic [31:0] status;
    int cnt = 0;
    while (cnt < timeout_cycles) begin
      mmio_read(STATUS_OFFSET, status);
      if (status[STATUS_DONE_BIT]) return;
      cnt++;
    end
    `TB_FATAL("Timeout waiting for DONE")
  endtask

  // ============================================================
  // Test: MMIO register read/write
  // ============================================================
  task automatic test_mmio_regs();
    logic [31:0] rdata;

    $display("[TEST] test_mmio_regs");
    u_cr.apply_reset();
    drive_mmio_defaults();
    ram_clear();

    // Write and read back M
    mmio_write(M_OFFSET, 32'd42);
    mmio_read(M_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd42, $sformatf("M_reg mismatch: got %0d", rdata))

    // Write and read back N
    mmio_write(N_OFFSET, 32'd100);
    mmio_read(N_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd100, $sformatf("N_reg mismatch: got %0d", rdata))

    // Write and read back K
    mmio_write(K_OFFSET, 32'd200);
    mmio_read(K_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd200, $sformatf("K_reg mismatch: got %0d", rdata))

    // Write base addresses
    mmio_write(A_VAL_BASE_OFFSET, 32'h0000_1000);
    mmio_read(A_VAL_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_1000, "A_val_base mismatch")

    mmio_write(A_ROW_BASE_OFFSET, 32'h0000_2000);
    mmio_read(A_ROW_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_2000, "A_row_base mismatch")

    mmio_write(A_COL_BASE_OFFSET, 32'h0000_3000);
    mmio_read(A_COL_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_3000, "A_col_base mismatch")

    mmio_write(B_BASE_OFFSET, 32'h0000_4000);
    mmio_read(B_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_4000, "B_base mismatch")

    mmio_write(C_BASE_OFFSET, 32'h0000_5000);
    mmio_read(C_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_5000, "C_base mismatch")

    // CTRL register bits
    mmio_write(CTRL_OFFSET, 32'h0000_000C);  // IRQ_EN + RELU
    mmio_read(CTRL_OFFSET, rdata);
    `TB_CHECK(rdata[CTRL_IRQ_EN_BIT] == 1'b1, "IRQ_EN not set")
    `TB_CHECK(rdata[CTRL_RELU_BIT] == 1'b1, "RELU not set")

    $display("[PASS] test_mmio_regs");
  endtask

  // ============================================================
  // Test: Empty matrix (no NZ) - should complete immediately
  // ============================================================
  task automatic test_empty_matrix();
    logic [31:0] status;

    $display("[TEST] test_empty_matrix");
    u_cr.apply_reset();
    drive_mmio_defaults();
    ram_clear();

    // Configure: 2x8 matrix with 0 non-zeros (N=8 to match TN)
    mmio_write(M_OFFSET, 32'd2);
    mmio_write(N_OFFSET, 32'd8);
    mmio_write(K_OFFSET, 32'd2);
    mmio_write(NNZ_OFFSET, 32'd0);

    // Addresses
    mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    mmio_write(C_BASE_OFFSET,     32'h0000_0800);

    // Row pointers: all zeros (empty rows)
    // rowptr = [0, 0, 0] -> both rows have 0 NZ
    ram_poke(32'h100 >> 2, 32'd0);
    ram_poke(32'h104 >> 2, 32'd0);
    ram_poke(32'h108 >> 2, 32'd0);

    // Enable IRQ
    mmio_write(CTRL_OFFSET, (1 << CTRL_IRQ_EN_BIT));

    // Start
    mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT) | (1 << CTRL_IRQ_EN_BIT));

    // Wait for done
    wait_done(50000);

    // Check status
    mmio_read(STATUS_OFFSET, status);
    `TB_CHECK(status[STATUS_DONE_BIT] == 1'b1, "DONE not set")
    `TB_CHECK(irq == 1'b1, "IRQ not asserted")

    // Clear done
    mmio_write(CTRL_OFFSET, (1 << CTRL_CLEAR_BIT));
    mmio_read(STATUS_OFFSET, status);
    `TB_CHECK(status[STATUS_DONE_BIT] == 1'b0, "DONE not cleared")

    $display("[PASS] test_empty_matrix");
  endtask

  // ============================================================
  // Test: Simple 2x8 SpMM (N must be >= TN=8 for proper tiling)
  // ============================================================
  task automatic test_simple_spmm();
    logic [31:0] status, c_val;
    int i;

    // A (CSR) 2x2 sparse = | 2  0 |  -> rowptr = [0, 1, 2]
    //                      | 0  3 |     colidx = [0, 1]
    //                                   values = [2, 3]
    //
    // B 2x8 dense (row-major), first 2 cols have data:
    // B = | 4  5  0  0  0  0  0  0 |
    //     | 6  7  0  0  0  0  0  0 |
    //
    // C = A * B (2x8):
    // C[0,:] = 2 * B[0,:] = | 8  10  0  0  0  0  0  0 |
    // C[1,:] = 3 * B[1,:] = | 18 21  0  0  0  0  0  0 |

    $display("[TEST] test_simple_spmm");
    u_cr.apply_reset();
    drive_mmio_defaults();
    ram_clear();

    // Row pointers (M+1 = 3 entries)
    ram_poke(32'h100 >> 2, 32'd0);  // row 0 starts at NZ index 0
    ram_poke(32'h104 >> 2, 32'd1);  // row 1 starts at NZ index 1
    ram_poke(32'h108 >> 2, 32'd2);  // end (2 NZ total)

    // Column indices (2 NZ)
    ram_poke(32'h200 >> 2, 32'd0);  // NZ 0: A[0,0]
    ram_poke(32'h204 >> 2, 32'd1);  // NZ 1: A[1,1]

    // Values (2 NZ)
    ram_poke(32'h300 >> 2, 32'd2);  // A[0,0] = 2
    ram_poke(32'h304 >> 2, 32'd3);  // A[1,1] = 3

    // B matrix 2x8 (row-major): B[row][col] at B_base + (row*N + col)*4
    // Row 0: [4, 5, 0, 0, 0, 0, 0, 0]
    ram_poke((32'h400 >> 2) + 0, 32'd4);   // B[0,0]
    ram_poke((32'h400 >> 2) + 1, 32'd5);   // B[0,1]
    for (i = 2; i < 8; i++) ram_poke((32'h400 >> 2) + i, 32'd0);
    // Row 1: [6, 7, 0, 0, 0, 0, 0, 0]
    ram_poke((32'h400 >> 2) + 8, 32'd6);   // B[1,0]
    ram_poke((32'h400 >> 2) + 9, 32'd7);   // B[1,1]
    for (i = 2; i < 8; i++) ram_poke((32'h400 >> 2) + 8 + i, 32'd0);

    // Configure accelerator
    mmio_write(M_OFFSET, 32'd2);      // 2 rows in A and C
    mmio_write(N_OFFSET, 32'd8);      // 8 cols in B and C (must be >= TN)
    mmio_write(K_OFFSET, 32'd2);      // 2 cols in A, 2 rows in B
    mmio_write(NNZ_OFFSET, 32'd2);    // 2 non-zeros in A

    mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    mmio_write(C_BASE_OFFSET,     32'h0000_0800);

    // Enable IRQ, no ReLU
    mmio_write(CTRL_OFFSET, (1 << CTRL_IRQ_EN_BIT));

    // Start
    mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT) | (1 << CTRL_IRQ_EN_BIT));

    // Wait for done
    wait_done(100000);

    // Read results from RAM: C is 2x8, row-major at 0x800
    // C[row][col] at C_base + (row*N + col)*4

    // Row 0: C[0,:] = 2 * B[0,:] = [8, 10, 0, 0, 0, 0, 0, 0]
    c_val = ram_peek((32'h800 >> 2) + 0);  // C[0,0]
    `TB_CHECK(c_val == 32'd8, $sformatf("C[0,0] wrong: got %0d, exp 8", c_val))

    c_val = ram_peek((32'h800 >> 2) + 1);  // C[0,1]
    `TB_CHECK(c_val == 32'd10, $sformatf("C[0,1] wrong: got %0d, exp 10", c_val))

    // Row 1: C[1,:] = 3 * B[1,:] = [18, 21, 0, 0, 0, 0, 0, 0]
    c_val = ram_peek((32'h800 >> 2) + 8);  // C[1,0] (row 1, col 0 = offset 1*8+0 = 8)
    `TB_CHECK(c_val == 32'd18, $sformatf("C[1,0] wrong: got %0d, exp 18", c_val))

    c_val = ram_peek((32'h800 >> 2) + 9);  // C[1,1]
    `TB_CHECK(c_val == 32'd21, $sformatf("C[1,1] wrong: got %0d, exp 21", c_val))

    $display("[PASS] test_simple_spmm");
  endtask

  // ============================================================
  // Test: ReLU activation
  // ============================================================
  task automatic test_relu_activation();
    logic [31:0] status, c_val;

    // A = | -2 |  (1x1 sparse, but N must be >= TN=8)
    // B = | 5  0  0  0  0  0  0  0 |  (1x8)
    // C = A * B = | -10 ... | -> with ReLU = | 0 ... |

    $display("[TEST] test_relu_activation");
    u_cr.apply_reset();
    drive_mmio_defaults();
    ram_clear();

    // Row pointers (M=1, so 2 entries)
    ram_poke(32'h100 >> 2, 32'd0);  // row 0 starts at 0
    ram_poke(32'h104 >> 2, 32'd1);  // end

    // Column indices
    ram_poke(32'h200 >> 2, 32'd0);  // NZ at A[0,0]

    // Values: -2 in two's complement
    ram_poke(32'h300 >> 2, 32'hFFFF_FFFE);

    // B matrix (1x8): only first element is 5
    ram_poke(32'h400 >> 2, 32'd5);
    // Rest are 0 (already cleared)

    // Configure (N=8 to match TN)
    mmio_write(M_OFFSET, 32'd1);
    mmio_write(N_OFFSET, 32'd8);
    mmio_write(K_OFFSET, 32'd1);
    mmio_write(NNZ_OFFSET, 32'd1);

    mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    mmio_write(C_BASE_OFFSET,     32'h0000_0800);

    // Enable IRQ AND ReLU
    mmio_write(CTRL_OFFSET, (1 << CTRL_IRQ_EN_BIT) | (1 << CTRL_RELU_BIT));

    // Start
    mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT) | (1 << CTRL_IRQ_EN_BIT) | (1 << CTRL_RELU_BIT));

    wait_done(50000);

    // Check result: should be clamped to 0 by ReLU
    c_val = ram_peek(32'h800 >> 2);
    `TB_CHECK(c_val == 32'd0, $sformatf("ReLU failed: got 0x%08x, exp 0", c_val))

    $display("[PASS] test_relu_activation");
  endtask

  // ============================================================
  // Test: LED indicates busy
  // ============================================================
  task automatic test_led_busy();
    logic [31:0] status;
    int cnt;

    $display("[TEST] test_led_busy");
    u_cr.apply_reset();
    drive_mmio_defaults();
    ram_clear();

    // Setup small matrix (N=8 to match TN)
    mmio_write(M_OFFSET, 32'd1);
    mmio_write(N_OFFSET, 32'd8);
    mmio_write(K_OFFSET, 32'd1);
    mmio_write(NNZ_OFFSET, 32'd0);

    mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    mmio_write(C_BASE_OFFSET,     32'h0000_0800);

    ram_poke(32'h100 >> 2, 32'd0);
    ram_poke(32'h104 >> 2, 32'd0);

    // Before start: LED should be off
    `TB_CHECK(led[0] == 1'b0, "LED on before start")

    // Start
    mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT));

    // Check LED is on while busy
    cnt = 0;
    while (cnt < 100) begin
      @(posedge clk);
      mmio_read(STATUS_OFFSET, status);
      if (status[STATUS_BUSY_BIT]) begin
        `TB_CHECK(led[0] == 1'b1, "LED not on while busy")
        break;
      end
      cnt++;
    end

    wait_done(50000);

    $display("[PASS] test_led_busy");
  endtask

  // ============================================================
  // Main
  // ============================================================
  initial begin
    string testname;
    int seed = get_plusarg_int("SEED", 1);
    void'($urandom(seed));

    if (!$value$plusargs("TEST=%s", testname)) testname = "all";

    if (has_plusarg("WAVES")) begin
      $dumpfile("waves_top.vcd");
      $dumpvars(0, accel_top_tb);
    end

    drive_mmio_defaults();

    case (testname)
      "mmio_regs":        test_mmio_regs();
      "empty_matrix":     test_empty_matrix();
      "simple_spmm":      test_simple_spmm();
      "relu_activation":  test_relu_activation();
      "led_busy":         test_led_busy();
      "all": begin
        test_mmio_regs();
        test_empty_matrix();
        test_simple_spmm();
        test_relu_activation();
        test_led_busy();
      end
      default: `TB_FATAL($sformatf("Unknown TEST=%s", testname))
    endcase

    $display("\n========================================");
    $display("  ALL TOP-LEVEL TESTS PASSED");
    $display("========================================\n");
    $finish(0);
  end

endmodule
