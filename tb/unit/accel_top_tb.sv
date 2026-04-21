// tb/unit/accel_top_tb.sv
// Integration testbench for accel_top (MMIO + ctrl + datapath)

// Compile order (ModelSim):
//   vlog -sv tb/common/tb_pkg.sv
//   vlog -sv tb/common/clk_reset.sv
//   vlog -sv rtl/accel_datapath.sv
//   vlog -sv rtl/accel_ctrl.sv
//   vlog -sv rtl/accel_top.sv
//   vlog -sv tb/unit/accel_top_tb.sv

// Run:
//   vsim work.accel_top_tb +TEST=all +WAVES
//   vsim work.accel_top_tb +TEST=random_configs +SEED=42
//   run -all

`timescale 1ns/1ps
`include "tb/common/tb_macros.svh"


// ----------------------------------------------------------------
// MMIO interface — declared outside the module so classes can
// hold a virtual handle (virtual accel_mmio_interface) to live DUT
// signals.  A virtual handle is a reference, not a copy.
// ----------------------------------------------------------------
interface accel_mmio_interface(input logic clk);
  logic [31:0]  mmio_addr;
  logic [31:0]  mmio_wdata;
  logic         mmio_we;
  logic         mmio_re;
  logic [3:0]   mmio_wstrb;
  logic         mmio_valid;
  logic [31:0]  mmio_rdata;
  logic         mmio_ready;
endinterface


module accel_top_tb;

  import tb_pkg::*;

  // ---------- parameters -------------------------------------------------
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

  // ---------- clock / reset ----------------------------------------------
  logic clk, n_reset;
  clk_reset u_cr(.clk(clk), .n_reset(n_reset));

  // ---------- DUT signals ------------------------------------------------
  logic                  ram_re, ram_we;
  logic [ADDR_WIDTH-1:0] ram_addr;
  logic [DATA_WIDTH-1:0] ram_wdata, ram_rdata;
  logic [3:0]            led;
  logic                  irq;

  // ---------- synchronous RAM model (1-cycle read latency = DE1-SoC BRAM) -
  localparam int RAM_WORDS = 16384;
  logic [DATA_WIDTH-1:0] ram_mem [0:RAM_WORDS-1];

  function automatic int unsigned addr_to_word(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1:2];
  endfunction

  always_ff @(posedge clk) begin
    if (!n_reset) begin
      ram_rdata <= '0;
    end else begin
      if (ram_we) ram_mem[addr_to_word(ram_addr)] <= ram_wdata;
      if (ram_re) ram_rdata <= ram_mem[addr_to_word(ram_addr)];
    end
  end

  task automatic ram_clear();
    for (int i = 0; i < RAM_WORDS; i++) ram_mem[i] = '0;
  endtask

  task automatic ram_poke(input int word_idx, input logic [31:0] val);
    ram_mem[word_idx] = val;
  endtask

  function automatic logic [31:0] ram_peek(input int word_idx);
    return ram_mem[word_idx];
  endfunction

  // ---------- interface instance + DUT -----------------------------------
  accel_mmio_interface vint(.clk(clk));

  accel_top #(
    .M_MAX     (M_MAX),
    .TN        (TN),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk        (clk),
    .n_reset    (n_reset),
    .mmio_addr  (vint.mmio_addr),
    .mmio_wdata (vint.mmio_wdata),
    .mmio_we    (vint.mmio_we),
    .mmio_re    (vint.mmio_re),
    .mmio_wstrb (vint.mmio_wstrb),
    .mmio_valid (vint.mmio_valid),
    .mmio_rdata (vint.mmio_rdata),
    .mmio_ready (vint.mmio_ready),
    .ram_re     (ram_re),
    .ram_we     (ram_we),
    .ram_addr   (ram_addr),
    .ram_wdata  (ram_wdata),
    .ram_rdata  (ram_rdata),
    .led        (led),
    .irq        (irq)
  );


  // ================================================================
  //  CONCURRENT SVA ASSERTIONS
  //
  //  These are NOT tests — they are passive monitors that fire on
  //  every clock edge for the entire simulation, regardless of which
  //  directed or random test is running.  A failing assertion stops
  //  simulation immediately and reports the time it fired.
  //
  //  SVA operator primer:
  //    |->        overlapping implication: if A this cycle, check B this cycle
  //    |=>        non-overlapping:         if A this cycle, check B next cycle
  //    ##N        exactly N cycles later
  //    ##[M:N]    between M and N cycles later
  //    $rose(s)   s transitions 0->1 this cycle
  //    $fell(s)   s transitions 1->0 this cycle
  //    disable iff (cond)  assertion vacuously passes when cond is true
  //                        (used to suppress checks during reset)
  // ================================================================

  // ----------------------------------------------------------------
  // 1. RAM protocol — read and write cannot fire simultaneously.
  //    The DE1-SoC BRAM is single-port; both strobes high at once is
  //    a design error regardless of addresses.
  // ----------------------------------------------------------------
  property p_ram_no_simul_rw;
    @(posedge clk) disable iff (!n_reset)
    !(ram_re && ram_we);
  endproperty
  ast_ram_no_simul_rw: assert property (p_ram_no_simul_rw)
    else $error("[SVA FAIL] ram_re and ram_we both high at t=%0t", $time);

  // ----------------------------------------------------------------
  // 2. RAM address alignment — every access must be 32-bit word-aligned
  //    (bottom two address bits = 00).  An unaligned address means the
  //    address generation logic has a bug.
  // ----------------------------------------------------------------
  property p_ram_addr_aligned;
    @(posedge clk) disable iff (!n_reset)
    (ram_re || ram_we) |-> (ram_addr[1:0] == 2'b00);
  endproperty
  ast_ram_addr_aligned: assert property (p_ram_addr_aligned)
    else $error("[SVA FAIL] unaligned RAM access: addr=0x%08x at t=%0t",
                ram_addr, $time);

  // ----------------------------------------------------------------
  // 3. Reset isolation — the accelerator must not touch RAM while
  //    n_reset is low.  Note: no 'disable iff' here because reset IS
  //    the condition being checked.
  // ----------------------------------------------------------------
  property p_no_ram_in_reset;
    @(posedge clk)
    !n_reset |-> (!ram_re && !ram_we);
  endproperty
  ast_no_ram_in_reset: assert property (p_no_ram_in_reset)
    else $error("[SVA FAIL] RAM access during reset at t=%0t", $time);

  // ----------------------------------------------------------------
  // 4. FSM mutual exclusion — BUSY and DONE must never both be high.
  //    These are internal FSM signals reached via hierarchical reference
  //    (dut.signal_name).  If this fires the FSM has entered an
  //    illegal combined state.
  // ----------------------------------------------------------------
  property p_busy_done_mutex;
    @(posedge clk) disable iff (!n_reset)
    !(dut.status_busy && dut.status_done);
  endproperty
  ast_busy_done_mutex: assert property (p_busy_done_mutex)
    else $error("[SVA FAIL] status_busy and status_done both high at t=%0t",
                $time);

  // ----------------------------------------------------------------
  // 5. Liveness — once BUSY rises it must eventually fall.
  //    Catches FSM deadlocks: if the accelerator hangs in BUSY forever,
  //    this assertion fires at cycle 1,000,000 after the stuck edge
  //    rather than letting the simulation hang silently.
  // ----------------------------------------------------------------
  property p_busy_resolves;
    @(posedge clk) disable iff (!n_reset)
    $rose(dut.status_busy) |-> ##[1:1_000_000] $fell(dut.status_busy);
  endproperty
  ast_busy_resolves: assert property (p_busy_resolves)
    else $error("[SVA FAIL] BUSY never deasserted — FSM deadlock at t=%0t",
                $time);


  // ================================================================
  //  CLASS: SpmmConfig
  //
  //  Constrained-random stimulus descriptor.
  //
  //  Key concepts:
  //    rand    — field whose value is solved by the SV constraint engine
  //              each time randomize() is called.
  //    constraint — a named block of Boolean equations the solver must
  //              satisfy.  All constraints are ANDed together.
  //    covergroup — a sampling structure that records which (M, N, relu)
  //              combinations have actually been exercised.  Call
  //              sample() after each randomize() to record the point.
  //              get_coverage() returns 0.0–100.0% of bins hit.
  //
  //  This class has NO knowledge of the DUT or the interface.  It is
  //  purely a "what to test" container.  The driver class below is
  //  "how to drive it".
  // ================================================================
  class SpmmConfig;

    // rand fields — solved fresh on every randomize() call
    rand int unsigned M;        // rows of A and C
    rand int unsigned N;        // columns of B and C (must be multiple of TN)
    rand int unsigned K;        // columns of A / rows of B
    rand bit          relu_en;  // whether to activate ReLU on writeback

    // ---- constraints ---------------------------------------------------
    // c_M, c_N, c_K kept small so simulation completes quickly.
    // N is restricted to multiples of TN=8 (the accelerator tile width).
    constraint c_M    { M inside {[1:4]}; }
    constraint c_N    { N inside {8, 16}; }
    constraint c_K    { K inside {[1:4]}; }
    // dist: weighted random — relu_en=0 gets 70% probability, 1 gets 30%.
    constraint c_relu { relu_en dist {1'b0 := 70, 1'b1 := 30}; }

    // ---- covergroup ----------------------------------------------------
    // Declared inside the class; instantiated with cg_config = new() in
    // the constructor below.  Each coverpoint defines named bins.
    // cross coverage tracks every (N, relu_en) combination.
    covergroup cg_config;
      cp_M:    coverpoint M { bins small = {[1:2]}; bins large = {[3:4]}; }
      cp_N:    coverpoint N { bins n8 = {8}; bins n16 = {16}; }
      cp_relu: coverpoint relu_en;
      cx_N_relu: cross cp_N, cp_relu;  // 4 cross bins: (8,0),(8,1),(16,0),(16,1)
    endgroup

    function new();
      cg_config = new();   // must be constructed explicitly
    endfunction

    // Call once per randomize() to record coverage
    function void sample();
      cg_config.sample();
    endfunction

    // Returns percentage of coverage bins hit (0.0 – 100.0)
    function real coverage();
      return cg_config.get_coverage();
    endfunction

  endclass  // SpmmConfig


  // ================================================================
  //  CLASS: accel_drivers
  //
  //  Wraps the MMIO protocol in class methods.  The virtual interface
  //  handle (vint) is a live reference to the DUT signals — changes
  //  made through it appear on the actual wires in simulation.
  //
  //  Note: localparams defined in the module (STATUS_OFFSET etc.) are
  //  NOT visible inside a class.  That is why wait_done uses the
  //  literal address 32'h04 rather than STATUS_OFFSET.
  // ================================================================
  class accel_drivers;

    virtual accel_mmio_interface vint;

    function new(virtual accel_mmio_interface vint);
      this.vint = vint;
    endfunction

    task automatic mmio_write(input logic [31:0] addr, input logic [31:0] data);
      @(posedge vint.clk);
      vint.mmio_addr  <= addr;
      vint.mmio_wdata <= data;
      vint.mmio_we    <= 1'b1;
      vint.mmio_re    <= 1'b0;
      vint.mmio_wstrb <= 4'hF;
      vint.mmio_valid <= 1'b1;
      @(posedge vint.clk);
      vint.mmio_we    <= 1'b0;
      vint.mmio_valid <= 1'b0;
    endtask

    task automatic mmio_read(input logic [31:0] addr, output logic [31:0] data);
      @(posedge vint.clk);
      vint.mmio_addr  <= addr;
      vint.mmio_we    <= 1'b0;
      vint.mmio_re    <= 1'b1;
      vint.mmio_wstrb <= 4'h0;
      vint.mmio_valid <= 1'b1;
      @(posedge vint.clk);
      data            = vint.mmio_rdata;
      vint.mmio_re    <= 1'b0;
      vint.mmio_valid <= 1'b0;
    endtask

    task automatic drive_mmio_defaults();
      vint.mmio_addr  = '0;
      vint.mmio_wdata = '0;
      vint.mmio_we    = 1'b0;
      vint.mmio_re    = 1'b0;
      vint.mmio_wstrb = 4'h0;
      vint.mmio_valid = 1'b0;
    endtask

    task automatic wait_done(input int timeout_cycles);
      logic [31:0] status;
      int cnt = 0;
      // Use literal 32'h04 — module localparams are not visible inside a class
      while (cnt < timeout_cycles) begin
        mmio_read(32'h04, status);  // STATUS_OFFSET = 0x04
        if (status[1]) return;      // STATUS_DONE_BIT = 1
        cnt++;
      end
      `TB_FATAL("Timeout waiting for DONE")
    endtask

  endclass  // accel_drivers


  // ================================================================
  //  Module-level handles — declared here, constructed in initial block
  //  after the interface instance (vint) exists.
  // ================================================================
  accel_drivers drv;
  SpmmConfig    cfg;


  // ================================================================
  //  DIRECTED TEST: verify every MMIO register retains its value
  // ================================================================
  task automatic test_mmio_regs();
    logic [31:0] rdata;
    $display("[TEST] test_mmio_regs");
    u_cr.apply_reset();
    drv.drive_mmio_defaults();
    ram_clear();

    drv.mmio_write(M_OFFSET, 32'd42);
    drv.mmio_read (M_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd42, $sformatf("M_reg mismatch: got %0d", rdata))

    drv.mmio_write(N_OFFSET, 32'd100);
    drv.mmio_read (N_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd100, $sformatf("N_reg mismatch: got %0d", rdata))

    drv.mmio_write(K_OFFSET, 32'd200);
    drv.mmio_read (K_OFFSET, rdata);
    `TB_CHECK(rdata == 32'd200, $sformatf("K_reg mismatch: got %0d", rdata))

    drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_1000);
    drv.mmio_read (A_VAL_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_1000, "A_val_base mismatch")

    drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_2000);
    drv.mmio_read (A_ROW_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_2000, "A_row_base mismatch")

    drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_3000);
    drv.mmio_read (A_COL_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_3000, "A_col_base mismatch")

    drv.mmio_write(B_BASE_OFFSET, 32'h0000_4000);
    drv.mmio_read (B_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_4000, "B_base mismatch")

    drv.mmio_write(C_BASE_OFFSET, 32'h0000_5000);
    drv.mmio_read (C_BASE_OFFSET, rdata);
    `TB_CHECK(rdata == 32'h0000_5000, "C_base mismatch")

    drv.mmio_write(CTRL_OFFSET, 32'h0000_000C);  // IRQ_EN + RELU
    drv.mmio_read (CTRL_OFFSET, rdata);
    `TB_CHECK(rdata[CTRL_IRQ_EN_BIT] == 1'b1, "IRQ_EN not set")
    `TB_CHECK(rdata[CTRL_RELU_BIT]   == 1'b1, "RELU not set")

    $display("[PASS] test_mmio_regs");
  endtask


  // ================================================================
  //  DIRECTED TEST: NNZ=0 — must reach DONE immediately, C stays zero
  // ================================================================
  task automatic test_empty_matrix();
    logic [31:0] status;
    $display("[TEST] test_empty_matrix");
    u_cr.apply_reset();
    drv.drive_mmio_defaults();
    ram_clear();

    drv.mmio_write(M_OFFSET,          32'd2);
    drv.mmio_write(N_OFFSET,          32'd8);
    drv.mmio_write(K_OFFSET,          32'd2);
    drv.mmio_write(NNZ_OFFSET,        32'd0);
    drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    drv.mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    drv.mmio_write(C_BASE_OFFSET,     32'h0000_0800);

    // rowptr = [0, 0, 0] — both rows empty
    ram_poke(32'h100 >> 2, 32'd0);
    ram_poke(32'h104 >> 2, 32'd0);
    ram_poke(32'h108 >> 2, 32'd0);

    drv.mmio_write(CTRL_OFFSET, (1 << CTRL_IRQ_EN_BIT));
    drv.mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT) | (1 << CTRL_IRQ_EN_BIT));

    drv.wait_done(50000);

    drv.mmio_read(STATUS_OFFSET, status);
    `TB_CHECK(status[STATUS_DONE_BIT] == 1'b1, "DONE not set")
    `TB_CHECK(irq == 1'b1, "IRQ not asserted")

    drv.mmio_write(CTRL_OFFSET, (1 << CTRL_CLEAR_BIT));
    drv.mmio_read (STATUS_OFFSET, status);
    `TB_CHECK(status[STATUS_DONE_BIT] == 1'b0, "DONE not cleared")

    $display("[PASS] test_empty_matrix");
  endtask


  // ================================================================
  //  DIRECTED TEST: hand-computed 2x2 SpMM, N=8
  //
  //  A = | 2  0 |   B = | 4  5  0 0 0 0 0 0 |
  //      | 0  3 |       | 6  7  0 0 0 0 0 0 |
  //
  //  C = A*B:  row0 = [8, 10, 0..0]   row1 = [18, 21, 0..0]
  // ================================================================
  task automatic test_simple_spmm();
    logic [31:0] c_val;
    int i;
    $display("[TEST] test_simple_spmm");
    u_cr.apply_reset();
    drv.drive_mmio_defaults();
    ram_clear();

    // CSR arrays
    ram_poke(32'h100 >> 2, 32'd0);   // rowptr[0]
    ram_poke(32'h104 >> 2, 32'd1);   // rowptr[1]
    ram_poke(32'h108 >> 2, 32'd2);   // rowptr[2]
    ram_poke(32'h200 >> 2, 32'd0);   // colidx[0] = col 0
    ram_poke(32'h204 >> 2, 32'd1);   // colidx[1] = col 1
    ram_poke(32'h300 >> 2, 32'd2);   // values[0] = 2
    ram_poke(32'h304 >> 2, 32'd3);   // values[1] = 3

    // B matrix rows
    ram_poke((32'h400 >> 2) + 0, 32'd4);
    ram_poke((32'h400 >> 2) + 1, 32'd5);
    for (i = 2; i < 8; i++) ram_poke((32'h400 >> 2) + i, 32'd0);
    ram_poke((32'h400 >> 2) + 8, 32'd6);
    ram_poke((32'h400 >> 2) + 9, 32'd7);
    for (i = 2; i < 8; i++) ram_poke((32'h400 >> 2) + 8 + i, 32'd0);

    drv.mmio_write(M_OFFSET,          32'd2);
    drv.mmio_write(N_OFFSET,          32'd8);
    drv.mmio_write(K_OFFSET,          32'd2);
    drv.mmio_write(NNZ_OFFSET,        32'd2);
    drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    drv.mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    drv.mmio_write(C_BASE_OFFSET,     32'h0000_0800);
    drv.mmio_write(CTRL_OFFSET,       (1 << CTRL_IRQ_EN_BIT));
    drv.mmio_write(CTRL_OFFSET,       (1 << CTRL_START_BIT) | (1 << CTRL_IRQ_EN_BIT));

    drv.wait_done(100000);

    c_val = ram_peek((32'h800 >> 2) + 0);
    `TB_CHECK(c_val == 32'd8,  $sformatf("C[0,0] wrong: got %0d exp 8",  c_val))
    c_val = ram_peek((32'h800 >> 2) + 1);
    `TB_CHECK(c_val == 32'd10, $sformatf("C[0,1] wrong: got %0d exp 10", c_val))
    c_val = ram_peek((32'h800 >> 2) + 8);
    `TB_CHECK(c_val == 32'd18, $sformatf("C[1,0] wrong: got %0d exp 18", c_val))
    c_val = ram_peek((32'h800 >> 2) + 9);
    `TB_CHECK(c_val == 32'd21, $sformatf("C[1,1] wrong: got %0d exp 21", c_val))

    $display("[PASS] test_simple_spmm");
  endtask


  // ================================================================
  //  DIRECTED TEST: ReLU clamps negative partial sum to zero
  //
  //  A = |-2|  B = |5 0 0 0 0 0 0 0|   C without relu = |-10 0..0|
  //  With relu=1: C[0,0] must be clamped to 0
  // ================================================================
  task automatic test_relu_activation();
    logic [31:0] c_val;
    $display("[TEST] test_relu_activation");
    u_cr.apply_reset();
    drv.drive_mmio_defaults();
    ram_clear();

    ram_poke(32'h100 >> 2, 32'd0);          // rowptr[0]
    ram_poke(32'h104 >> 2, 32'd1);          // rowptr[1]
    ram_poke(32'h200 >> 2, 32'd0);          // colidx[0] = 0
    ram_poke(32'h300 >> 2, 32'hFFFF_FFFE); // values[0] = -2 (two's complement)
    ram_poke(32'h400 >> 2, 32'd5);          // B[0,0] = 5

    drv.mmio_write(M_OFFSET,          32'd1);
    drv.mmio_write(N_OFFSET,          32'd8);
    drv.mmio_write(K_OFFSET,          32'd1);
    drv.mmio_write(NNZ_OFFSET,        32'd1);
    drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    drv.mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    drv.mmio_write(C_BASE_OFFSET,     32'h0000_0800);
    drv.mmio_write(CTRL_OFFSET,       (1 << CTRL_IRQ_EN_BIT) | (1 << CTRL_RELU_BIT));
    drv.mmio_write(CTRL_OFFSET,       (1 << CTRL_START_BIT)  |
                                      (1 << CTRL_IRQ_EN_BIT) | (1 << CTRL_RELU_BIT));
    drv.wait_done(50000);

    c_val = ram_peek(32'h800 >> 2);
    `TB_CHECK(c_val == 32'd0, $sformatf("ReLU failed: got 0x%08x exp 0", c_val))

    $display("[PASS] test_relu_activation");
  endtask


  // ================================================================
  //  DIRECTED TEST: LED[0] mirrors BUSY status bit
  // ================================================================
  task automatic test_led_busy();
    logic [31:0] status;
    int cnt;
    $display("[TEST] test_led_busy");
    u_cr.apply_reset();
    drv.drive_mmio_defaults();
    ram_clear();

    drv.mmio_write(M_OFFSET,          32'd1);
    drv.mmio_write(N_OFFSET,          32'd8);
    drv.mmio_write(K_OFFSET,          32'd1);
    drv.mmio_write(NNZ_OFFSET,        32'd0);
    drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
    drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
    drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
    drv.mmio_write(B_BASE_OFFSET,     32'h0000_0400);
    drv.mmio_write(C_BASE_OFFSET,     32'h0000_0800);
    ram_poke(32'h100 >> 2, 32'd0);
    ram_poke(32'h104 >> 2, 32'd0);

    `TB_CHECK(led[0] == 1'b0, "LED on before start")

    drv.mmio_write(CTRL_OFFSET, (1 << CTRL_START_BIT));

    cnt = 0;
    while (cnt < 100) begin
      @(posedge clk);
      drv.mmio_read(STATUS_OFFSET, status);
      if (status[STATUS_BUSY_BIT]) begin
        `TB_CHECK(led[0] == 1'b1, "LED not on while busy")
        break;
      end
      cnt++;
    end

    drv.wait_done(50000);
    $display("[PASS] test_led_busy");
  endtask


  // ================================================================
  //  CONSTRAINED-RANDOM TEST: test_random_configs
  //
  //  This is where the class structure pays off.
  //
  //  Each iteration:
  //    1. cfg.randomize()  — the SV constraint solver picks a fresh
  //                          (M, N, K, relu_en) satisfying all constraints
  //    2. cfg.sample()     — records this point in the covergroup
  //    3. Drive DUT with NNZ=0 (empty matrix) — golden output is trivially
  //                          C=all-zeros for any (M,N,K,relu_en), so we get
  //                          correctness checking without a software SpMM model
  //    4. Verify C=0 for every element
  //
  //  Run with: vsim work.accel_top_tb +TEST=random_configs +SEED=42
  //            vsim work.accel_top_tb +TEST=random_configs +SEED=99
  //  Different seeds explore different configuration combinations.
  //  Watch cfg.coverage() climb toward 100% as more bins are hit.
  // ================================================================
  task automatic test_random_configs(input int num_iters = 20);
    logic [31:0] c_val;
    logic [31:0] ctrl_val;

    $display("[TEST] test_random_configs (%0d iterations)", num_iters);

    for (int iter = 0; iter < num_iters; iter++) begin

      // --- generate stimulus -------------------------------------------
      // randomize() returns 1 on success, 0 if constraints are unsatisfiable
      if (!cfg.randomize())
        `TB_FATAL("cfg.randomize() failed — constraint system unsatisfiable")

      // record this (M, N, relu_en) point in the covergroup bins
      cfg.sample();

      // --- set up DUT --------------------------------------------------
      u_cr.apply_reset();
      drv.drive_mmio_defaults();
      ram_clear();

      // rowptr: M+1 entries, all zero (every row is empty)
      for (int r = 0; r <= int'(cfg.M); r++)
        ram_poke((32'h100 >> 2) + r, 32'd0);

      drv.mmio_write(M_OFFSET,          cfg.M);
      drv.mmio_write(N_OFFSET,          cfg.N);
      drv.mmio_write(K_OFFSET,          cfg.K);
      drv.mmio_write(NNZ_OFFSET,        32'd0);
      drv.mmio_write(A_ROW_BASE_OFFSET, 32'h0000_0100);
      drv.mmio_write(A_COL_BASE_OFFSET, 32'h0000_0200);
      drv.mmio_write(A_VAL_BASE_OFFSET, 32'h0000_0300);
      drv.mmio_write(B_BASE_OFFSET,     32'h0000_0400);
      drv.mmio_write(C_BASE_OFFSET,     32'h0000_0800);

      // cfg.relu_en is 1-bit; cast to 32-bit before shifting to avoid
      // the shift result being truncated to 1 bit.
      ctrl_val = (1 << CTRL_IRQ_EN_BIT) | (32'(cfg.relu_en) << CTRL_RELU_BIT);
      drv.mmio_write(CTRL_OFFSET, ctrl_val);
      drv.mmio_write(CTRL_OFFSET, ctrl_val | (1 << CTRL_START_BIT));

      drv.wait_done(50000);

      // --- verify: golden C = all-zero (NNZ=0, so no MACs were issued) --
      for (int r = 0; r < int'(cfg.M); r++) begin
        for (int c = 0; c < int'(cfg.N); c++) begin
          c_val = ram_peek((32'h800 >> 2) + r * int'(cfg.N) + c);
          `TB_CHECK(c_val == 32'd0,
            $sformatf("iter=%0d M=%0d N=%0d K=%0d relu=%0b: C[%0d,%0d]=%0d exp 0",
                      iter, cfg.M, cfg.N, cfg.K, cfg.relu_en, r, c, c_val))
        end
      end

      $display("[iter %2d] M=%0d N=%0d K=%0d relu=%0b   coverage=%.1f%%",
               iter, cfg.M, cfg.N, cfg.K, cfg.relu_en, cfg.coverage());
    end

    $display("[PASS] test_random_configs   final coverage=%.1f%%", cfg.coverage());
  endtask


  // ================================================================
  //  Main
  // ================================================================
  initial begin
    string testname;
    int seed;

    // Construct driver and stimulus objects.
    // drv wraps the live interface; cfg holds the rand fields.
    drv = new(vint);
    cfg = new();

    seed = get_plusarg_int("SEED", 1);
    void'($urandom(seed));

    if (!$value$plusargs("TEST=%s", testname)) testname = "all";

    if (has_plusarg("WAVES")) begin
      $dumpfile("waves_top.vcd");
      $dumpvars(0, accel_top_tb);
    end

    drv.drive_mmio_defaults();

    case (testname)
      "mmio_regs":       test_mmio_regs();
      "empty_matrix":    test_empty_matrix();
      "simple_spmm":     test_simple_spmm();
      "relu_activation": test_relu_activation();
      "led_busy":        test_led_busy();
      "random_configs":  test_random_configs();
      "all": begin
        test_mmio_regs();
        test_empty_matrix();
        test_simple_spmm();
        test_relu_activation();
        test_led_busy();
        test_random_configs();
      end
      default: `TB_FATAL($sformatf("Unknown TEST=%s", testname))
    endcase

    $display("\n========================================");
    $display("  ALL TOP-LEVEL TESTS PASSED");
    $display("========================================\n");
    $finish(0);
  end

endmodule
