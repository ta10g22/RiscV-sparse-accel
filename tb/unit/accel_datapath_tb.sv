// tb/unit/accel_datapath_tb.sv
// Unit testbench for accel_datapath module
//
// Compile order (ModelSim):
//   vlog -sv tb/common/tb_pkg.sv
//   vlog -sv tb/common/clk_reset.sv
//   vlog -sv rtl/accel_datapath.sv
//   vlog -sv tb/unit/accel_datapath_tb.sv
// Run:
//   vsim work.accel_datapath_tb +TEST=all +WAVES
//   run -all

`timescale 1ns/1ps

module accel_datapath_tb;

  import tb_pkg::*;

  // Parameters (match DUT defaults)
  localparam int M_MAX      = 64;
  localparam int TN         = 8;
  localparam int DATA_WIDTH = 32;

  // Clock/reset
  logic clk, n_reset;
  clk_reset u_cr(.clk(clk), .n_reset(n_reset));

  // DUT signals
  logic                     clear_en;
  logic [$clog2(M_MAX)-1:0] clear_row;
  logic [$clog2(TN)-1:0]    clear_col;

  logic                     bseg_we;
  logic [$clog2(TN)-1:0]    bseg_idx;
  logic [DATA_WIDTH-1:0]    bseg_wdata;

  logic                     mac_en;
  logic [$clog2(M_MAX)-1:0] mac_row;
  logic [$clog2(TN)-1:0]    mac_col;
  logic [DATA_WIDTH-1:0]    mac_a;

  logic                     ctile_read_en;
  logic [$clog2(M_MAX)-1:0] ctile_read_row;
  logic [$clog2(TN)-1:0]    ctile_read_col;
  logic [DATA_WIDTH-1:0]    ctile_read_data;

  logic                     relu_en;
  logic [3:0]               dtype;
  logic                     wb_en;
  logic [DATA_WIDTH-1:0]    wb_in;
  logic [DATA_WIDTH-1:0]    wb_data_out;

  // DUT instantiation
  accel_datapath #(
    .M_MAX(M_MAX),
    .TN(TN),
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk            (clk),
    .n_reset        (n_reset),
    .clear_en       (clear_en),
    .clear_row      (clear_row),
    .clear_col      (clear_col),
    .bseg_we        (bseg_we),
    .bseg_idx       (bseg_idx),
    .bseg_wdata     (bseg_wdata),
    .mac_en         (mac_en),
    .mac_row        (mac_row),
    .mac_col        (mac_col),
    .mac_a          (mac_a),
    .ctile_read_en  (ctile_read_en),
    .ctile_read_row (ctile_read_row),
    .ctile_read_col (ctile_read_col),
    .ctile_read_data(ctile_read_data),
    .relu_en        (relu_en),
    .dtype          (dtype),
    .wb_en          (wb_en),
    .wb_in          (wb_in),
    .wb_data_out    (wb_data_out)
  );

  // ============================================================
  // Helper tasks
  // ============================================================

  task automatic drive_defaults();
    clear_en       = 1'b0;
    clear_row      = '0;
    clear_col      = '0;
    bseg_we        = 1'b0;
    bseg_idx       = '0;
    bseg_wdata     = '0;
    mac_en         = 1'b0;
    mac_row        = '0;
    mac_col        = '0;
    mac_a          = '0;
    ctile_read_en  = 1'b0;
    ctile_read_row = '0;
    ctile_read_col = '0;
    relu_en        = 1'b0;
    dtype          = 4'h0;
    wb_en          = 1'b0;
    wb_in          = '0;
  endtask

  // Load a value into B_Seg[idx]
  task automatic load_bseg(input int idx, input logic [DATA_WIDTH-1:0] val);
    @(posedge clk);
    bseg_we    <= 1'b1;
    bseg_idx   <= idx[$clog2(TN)-1:0];
    bseg_wdata <= val;
    @(posedge clk);
    bseg_we    <= 1'b0;
  endtask

  // Perform one MAC operation: C[row][col] += a * B_Seg[col]
  task automatic do_mac(input int row, input int col, input logic [DATA_WIDTH-1:0] a);
    @(posedge clk);
    mac_en  <= 1'b1;
    mac_row <= row[$clog2(M_MAX)-1:0];
    mac_col <= col[$clog2(TN)-1:0];
    mac_a   <= a;
    @(posedge clk);
    mac_en  <= 1'b0;
  endtask

  // Clear C_Tile[row][col]
  task automatic do_clear(input int row, input int col);
    @(posedge clk);
    clear_en  <= 1'b1;
    clear_row <= row[$clog2(M_MAX)-1:0];
    clear_col <= col[$clog2(TN)-1:0];
    @(posedge clk);
    clear_en  <= 1'b0;
  endtask

  // Read C_Tile[row][col]
  task automatic read_ctile(input int row, input int col, output logic [DATA_WIDTH-1:0] val);
    ctile_read_en  = 1'b1;
    ctile_read_row = row[$clog2(M_MAX)-1:0];
    ctile_read_col = col[$clog2(TN)-1:0];
    #1; // combinational read
    val = ctile_read_data;
    ctile_read_en  = 1'b0;
  endtask

  // Test writeback with/without ReLU
  task automatic check_wb(input logic [DATA_WIDTH-1:0] in_val, input bit use_relu, output logic [DATA_WIDTH-1:0] out_val);
    wb_en   = 1'b1;
    wb_in   = in_val;
    relu_en = use_relu;
    #1;
    out_val = wb_data_out;
    wb_en   = 1'b0;
    relu_en = 1'b0;
  endtask

  // ============================================================
  // Test: B_Seg load and read back via MAC
  // ============================================================
  task automatic test_bseg_load();
    logic [DATA_WIDTH-1:0] read_val;
    
    $display("[TEST] test_bseg_load");
    u_cr.apply_reset();
    drive_defaults();
    
    // Load B_Seg with known values
    load_bseg(0, 32'd10);
    load_bseg(1, 32'd20);
    load_bseg(2, 32'd30);
    load_bseg(7, 32'd70);
    
    // Verify by doing MAC with a=1 and reading result
    // C[0][0] = 0 + 1*B_Seg[0] = 10
    do_mac(0, 0, 32'd1);
    @(posedge clk); // wait for register update
    read_ctile(0, 0, read_val);
    `TB_CHECK(read_val == 32'd10, $sformatf("B_Seg[0] mismatch: got %0d, exp 10", read_val))
    
    // C[0][1] = 0 + 1*B_Seg[1] = 20
    do_mac(0, 1, 32'd1);
    @(posedge clk);
    read_ctile(0, 1, read_val);
    `TB_CHECK(read_val == 32'd20, $sformatf("B_Seg[1] mismatch: got %0d, exp 20", read_val))
    
    $display("[PASS] test_bseg_load");
  endtask

  // ============================================================
  // Test: MAC accumulation
  // ============================================================
  task automatic test_mac_accumulate();
    logic [DATA_WIDTH-1:0] read_val;
    
    $display("[TEST] test_mac_accumulate");
    u_cr.apply_reset();
    drive_defaults();
    
    // Load B_Seg[0] = 5
    load_bseg(0, 32'd5);
    
    // MAC 3 times: C[1][0] = 0 + 2*5 + 3*5 + 4*5 = 45
    do_mac(1, 0, 32'd2);
    do_mac(1, 0, 32'd3);
    do_mac(1, 0, 32'd4);
    
    @(posedge clk);
    read_ctile(1, 0, read_val);
    `TB_CHECK(read_val == 32'd45, $sformatf("MAC accumulate fail: got %0d, exp 45", read_val))
    
    $display("[PASS] test_mac_accumulate");
  endtask

  // ============================================================
  // Test: Clear C_Tile entry
  // ============================================================
  task automatic test_clear();
    logic [DATA_WIDTH-1:0] read_val;
    
    $display("[TEST] test_clear");
    u_cr.apply_reset();
    drive_defaults();
    
    // Accumulate something
    load_bseg(0, 32'd10);
    do_mac(2, 0, 32'd5);
    @(posedge clk);
    read_ctile(2, 0, read_val);
    `TB_CHECK(read_val == 32'd50, "Pre-clear value wrong")
    
    // Clear it
    do_clear(2, 0);
    @(posedge clk);
    read_ctile(2, 0, read_val);
    `TB_CHECK(read_val == 32'd0, $sformatf("Clear failed: got %0d, exp 0", read_val))
    
    $display("[PASS] test_clear");
  endtask

  // ============================================================
  // Test: ReLU activation
  // ============================================================
  task automatic test_relu();
    logic [DATA_WIDTH-1:0] out_val;
    
    $display("[TEST] test_relu");
    u_cr.apply_reset();
    drive_defaults();
    
    // Positive value -> unchanged
    check_wb(32'd100, 1'b1, out_val);
    `TB_CHECK(out_val == 32'd100, $sformatf("ReLU pos fail: got %0d", out_val))
    
    // Zero -> unchanged
    check_wb(32'd0, 1'b1, out_val);
    `TB_CHECK(out_val == 32'd0, $sformatf("ReLU zero fail: got %0d", out_val))
    
    // Negative value -> clamped to 0
    check_wb(32'hFFFF_FFF0, 1'b1, out_val);  // -16 in two's complement
    `TB_CHECK(out_val == 32'd0, $sformatf("ReLU neg fail: got 0x%08x, exp 0", out_val))
    
    // ReLU disabled -> pass through negative
    check_wb(32'hFFFF_FFF0, 1'b0, out_val);
    `TB_CHECK(out_val == 32'hFFFF_FFF0, $sformatf("ReLU disabled fail: got 0x%08x", out_val))
    
    $display("[PASS] test_relu");
  endtask

  // ============================================================
  // Test: Signed multiply (negative values)
  // ============================================================
  task automatic test_signed_mac();
    logic [DATA_WIDTH-1:0] read_val;
    logic signed [DATA_WIDTH-1:0] signed_val;
    
    $display("[TEST] test_signed_mac");
    u_cr.apply_reset();
    drive_defaults();
    
    // B_Seg[0] = -5
    load_bseg(0, 32'hFFFF_FFFB);  // -5 in two's complement
    
    // C[3][0] = 0 + (-3) * (-5) = 15
    do_mac(3, 0, 32'hFFFF_FFFD);  // -3 in two's complement
    @(posedge clk);
    read_ctile(3, 0, read_val);
    `TB_CHECK(read_val == 32'd15, $sformatf("Signed MAC fail: got %0d, exp 15", $signed(read_val)))
    
    // C[4][0] = 0 + 3 * (-5) = -15
    do_mac(4, 0, 32'd3);
    @(posedge clk);
    read_ctile(4, 0, read_val);
    signed_val = $signed(read_val);
    `TB_CHECK(signed_val == -15, $sformatf("Signed MAC neg result fail: got %0d, exp -15", signed_val))
    
    $display("[PASS] test_signed_mac");
  endtask

  // ============================================================
  // Test: Full tile operation (small 2x2 SpMM)
  // ============================================================
  task automatic test_small_spmm();
    logic [DATA_WIDTH-1:0] read_val;
    int i, j;
    
    // Simulating: A (sparse) * B (dense) = C
    // A = | 1  0 |    B = | 2  3 |    C = | 2   3 |
    //     | 0  4 |        | 5  6 |        | 20 24 |
    //
    // Row 0: A[0,0]=1 -> MAC with B row 0
    // Row 1: A[1,1]=4 -> MAC with B row 1
    
    $display("[TEST] test_small_spmm");
    u_cr.apply_reset();
    drive_defaults();
    
    // Clear C_Tile[0:1][0:1]
    for (i = 0; i < 2; i++) begin
      for (j = 0; j < 2; j++) begin
        do_clear(i, j);
      end
    end
    
    // Process row 0 of A: NZ at col 0, value = 1
    // Load B row 0 into B_Seg: [2, 3]
    load_bseg(0, 32'd2);
    load_bseg(1, 32'd3);
    // MAC: C[0][j] += 1 * B_Seg[j]
    do_mac(0, 0, 32'd1);
    do_mac(0, 1, 32'd1);
    
    // Process row 1 of A: NZ at col 1, value = 4
    // Load B row 1 into B_Seg: [5, 6]
    load_bseg(0, 32'd5);
    load_bseg(1, 32'd6);
    // MAC: C[1][j] += 4 * B_Seg[j]
    do_mac(1, 0, 32'd4);
    do_mac(1, 1, 32'd4);
    
    @(posedge clk);
    
    // Verify results
    read_ctile(0, 0, read_val);
    `TB_CHECK(read_val == 32'd2, $sformatf("C[0][0] wrong: got %0d, exp 2", read_val))
    
    read_ctile(0, 1, read_val);
    `TB_CHECK(read_val == 32'd3, $sformatf("C[0][1] wrong: got %0d, exp 3", read_val))
    
    read_ctile(1, 0, read_val);
    `TB_CHECK(read_val == 32'd20, $sformatf("C[1][0] wrong: got %0d, exp 20", read_val))
    
    read_ctile(1, 1, read_val);
    `TB_CHECK(read_val == 32'd24, $sformatf("C[1][1] wrong: got %0d, exp 24", read_val))
    
    $display("[PASS] test_small_spmm");
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
      $dumpfile("waves_datapath.vcd");
      $dumpvars(0, accel_datapath_tb);
    end

    drive_defaults();

    case (testname)
      "bseg_load":      test_bseg_load();
      "mac_accumulate": test_mac_accumulate();
      "clear":          test_clear();
      "relu":           test_relu();
      "signed_mac":     test_signed_mac();
      "small_spmm":     test_small_spmm();
      "all": begin
        test_bseg_load();
        test_mac_accumulate();
        test_clear();
        test_relu();
        test_signed_mac();
        test_small_spmm();
      end
      default: `TB_FATAL($sformatf("Unknown TEST=%s", testname))
    endcase

    $display("\n========================================");
    $display("  ALL DATAPATH TESTS PASSED");
    $display("========================================\n");
    $finish(0);
  end

endmodule
