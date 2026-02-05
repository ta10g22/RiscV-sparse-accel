`timescale 1ns/1ps
`include "tb/common/tb_macros.svh"

/**
 * SoC Integration Testbench
 * 
 * Connects PicoRV32 + SpMM Accelerator + RAM
 * Loads firmware and runs end-to-end test
 *
 * Memory Map:
 *   0x00000000 - 0x0000FFFF : RAM (64KB) - firmware + data
 *   0x10000000 - 0x100000FF : Accelerator MMIO
 *
 * Compile order (ModelSim):
 *   vlog -sv tb/common/tb_pkg.sv
 *   vlog -sv tb/common/clk_reset.sv
 *   vlog ip/picorv32/picorv32.v
 *   vlog -sv rtl/accel_datapath.sv
 *   vlog -sv rtl/accel_ctrl.sv
 *   vlog -sv rtl/accel_top.sv
 *   vlog -sv tb/integ/soc_tb.sv
 * Run:
 *   vsim work.soc_tb +firmware=sw/driver/firmware.hex +WAVES
 *   run -all
 */

module soc_tb;

  import tb_pkg::*;

  // ============================================================
  // Parameters
  // ============================================================
  localparam int ADDR_WIDTH  = 32;
  localparam int DATA_WIDTH  = 32;
  localparam int RAM_SIZE    = 65536;  // 64KB
  localparam int RAM_WORDS   = RAM_SIZE / 4;

  // Memory map
  localparam logic [31:0] RAM_BASE   = 32'h0000_0000;
  localparam logic [31:0] RAM_END    = 32'h0000_FFFF;
  localparam logic [31:0] ACCEL_BASE = 32'h1000_0000;
  localparam logic [31:0] ACCEL_END  = 32'h1000_00FF;

  // Result address (where main() stores return value)
  localparam logic [31:0] RESULT_ADDR = 32'h0000_1000;

  // ============================================================
  // Clock and Reset
  // ============================================================
  logic clk, n_reset;
  clk_reset #(.TCLK(10ns)) u_cr (.clk(clk), .n_reset(n_reset));

  // ============================================================
  // PicoRV32 Signals
  // ============================================================
  logic        cpu_trap;
  logic        cpu_mem_valid;
  logic        cpu_mem_instr;
  logic        cpu_mem_ready;
  logic [31:0] cpu_mem_addr;
  logic [31:0] cpu_mem_wdata;
  logic [3:0]  cpu_mem_wstrb;
  logic [31:0] cpu_mem_rdata;

  // ============================================================
  // Accelerator Signals
  // ============================================================
  logic [31:0] accel_mmio_rdata;
  logic        accel_mmio_ready;
  logic        accel_ram_re;
  logic        accel_ram_we;
  logic [31:0] accel_ram_addr;
  logic [31:0] accel_ram_wdata;
  logic [31:0] accel_ram_rdata;
  logic [3:0]  accel_led;
  logic        accel_irq;

  // ============================================================
  // Address Decode
  // ============================================================
  logic sel_ram;
  logic sel_accel;

  assign sel_ram   = cpu_mem_valid && (cpu_mem_addr >= RAM_BASE) && (cpu_mem_addr <= RAM_END);
  assign sel_accel = cpu_mem_valid && (cpu_mem_addr >= ACCEL_BASE) && (cpu_mem_addr <= ACCEL_END);

  // ============================================================
  // RAM (64KB, byte-addressable, 1-cycle latency)
  // ============================================================
  logic [31:0] ram [0:RAM_WORDS-1];
  logic [31:0] ram_rdata_reg;
  logic        ram_read_pending;
  logic [31:0] ram_read_addr;

  // CPU RAM access
  always_ff @(posedge clk) begin
    if (!n_reset) begin
      ram_read_pending <= 1'b0;
      ram_rdata_reg    <= 32'h0;
    end else begin
      ram_read_pending <= sel_ram && (cpu_mem_wstrb == 4'b0000);  // Read request
      ram_read_addr    <= cpu_mem_addr;

      // Write with byte strobes
      if (sel_ram && (cpu_mem_wstrb != 4'b0000)) begin
        if (cpu_mem_wstrb[0]) ram[cpu_mem_addr[15:2]][7:0]   <= cpu_mem_wdata[7:0];
        if (cpu_mem_wstrb[1]) ram[cpu_mem_addr[15:2]][15:8]  <= cpu_mem_wdata[15:8];
        if (cpu_mem_wstrb[2]) ram[cpu_mem_addr[15:2]][23:16] <= cpu_mem_wdata[23:16];
        if (cpu_mem_wstrb[3]) ram[cpu_mem_addr[15:2]][31:24] <= cpu_mem_wdata[31:24];
      end

      // Read data
      if (sel_ram && (cpu_mem_wstrb == 4'b0000)) begin
        ram_rdata_reg <= ram[cpu_mem_addr[15:2]];
      end
    end
  end

  // Accelerator RAM access (directly from accel_top ram_* ports)
  always_ff @(posedge clk) begin
    if (!n_reset) begin
      accel_ram_rdata <= 32'h0;
    end else begin
      if (accel_ram_we) begin
        ram[accel_ram_addr[15:2]] <= accel_ram_wdata;
      end
      if (accel_ram_re) begin
        accel_ram_rdata <= ram[accel_ram_addr[15:2]];
      end
    end
  end

  // ============================================================
  // CPU Memory Interface Mux
  // ============================================================
  always_comb begin
    cpu_mem_ready = 1'b0;
    cpu_mem_rdata = 32'h0;

    if (sel_ram) begin
      // RAM: 1-cycle latency for reads, immediate for writes
      if (cpu_mem_wstrb != 4'b0000) begin
        cpu_mem_ready = 1'b1;  // Write completes immediately
      end else begin
        cpu_mem_ready = ram_read_pending;  // Read takes 1 cycle
        cpu_mem_rdata = ram_rdata_reg;
      end
    end else if (sel_accel) begin
      cpu_mem_ready = accel_mmio_ready;
      cpu_mem_rdata = accel_mmio_rdata;
    end else if (cpu_mem_valid) begin
      // Unmapped access - complete immediately with zero
      cpu_mem_ready = 1'b1;
      cpu_mem_rdata = 32'h0;
    end
  end

  // ============================================================
  // PicoRV32 CPU
  // ============================================================
  picorv32 #(
    .ENABLE_COUNTERS   (0),
    .ENABLE_COUNTERS64 (0),
    .ENABLE_REGS_16_31 (1),
    .ENABLE_REGS_DUALPORT (1),
    .LATCHED_MEM_RDATA (0),
    .TWO_STAGE_SHIFT   (1),
    .BARREL_SHIFTER    (0),
    .TWO_CYCLE_COMPARE (0),
    .TWO_CYCLE_ALU     (0),
    .COMPRESSED_ISA    (0),
    .CATCH_MISALIGN    (0),
    .CATCH_ILLINSN     (0),
    .ENABLE_PCPI       (0),
    .ENABLE_MUL        (1),  // Enable MUL for array indexing
    .ENABLE_FAST_MUL   (0),
    .ENABLE_DIV        (0),
    .ENABLE_IRQ        (0),
    .ENABLE_TRACE      (0),
    .REGS_INIT_ZERO    (1),
    .PROGADDR_RESET    (32'h0000_0000),
    .STACKADDR         (32'h0000_FFFC)
  ) u_cpu (
    .clk       (clk),
    .resetn    (n_reset),
    .trap      (cpu_trap),

    .mem_valid (cpu_mem_valid),
    .mem_instr (cpu_mem_instr),
    .mem_ready (cpu_mem_ready),
    .mem_addr  (cpu_mem_addr),
    .mem_wdata (cpu_mem_wdata),
    .mem_wstrb (cpu_mem_wstrb),
    .mem_rdata (cpu_mem_rdata),

    // Unused ports
    .mem_la_read  (),
    .mem_la_write (),
    .mem_la_addr  (),
    .mem_la_wdata (),
    .mem_la_wstrb (),
    .pcpi_valid   (),
    .pcpi_insn    (),
    .pcpi_rs1     (),
    .pcpi_rs2     (),
    .pcpi_wr      (1'b0),
    .pcpi_rd      (32'h0),
    .pcpi_wait    (1'b0),
    .pcpi_ready   (1'b0),
    .irq          (32'h0),
    .eoi          (),
    .trace_valid  (),
    .trace_data   ()
  );

  // ============================================================
  // SpMM Accelerator
  // ============================================================
  accel_top #(
    .M_MAX      (64),
    .TN         (8),
    .ADDR_WIDTH (32),
    .DATA_WIDTH (32)
  ) u_accel (
    .clk        (clk),
    .n_reset    (n_reset),

    // MMIO interface (directly from CPU)
    .mmio_addr  ({24'h0, cpu_mem_addr[7:0]}),  // Extend to 32 bits
    .mmio_wdata (cpu_mem_wdata),
    .mmio_we    (sel_accel && (cpu_mem_wstrb != 4'b0000)),
    .mmio_re    (sel_accel && (cpu_mem_wstrb == 4'b0000)),
    .mmio_wstrb (cpu_mem_wstrb),
    .mmio_valid (sel_accel),
    .mmio_rdata (accel_mmio_rdata),
    .mmio_ready (accel_mmio_ready),

    // RAM interface (accelerator's DMA to RAM)
    .ram_re     (accel_ram_re),
    .ram_we     (accel_ram_we),
    .ram_addr   (accel_ram_addr),
    .ram_wdata  (accel_ram_wdata),
    .ram_rdata  (accel_ram_rdata),

    .led        (accel_led),
    .irq        (accel_irq)
  );

  // ============================================================
  // Firmware Loading
  // ============================================================
  string firmware_file;

  initial begin
    // Get firmware file from plusarg
    if (!$value$plusargs("firmware=%s", firmware_file)) begin
      firmware_file = "firmware.hex";
    end

    // Initialize RAM to zero
    for (int i = 0; i < RAM_WORDS; i++) begin
      ram[i] = 32'h0;
    end

    // Load firmware
    $display("[SOC_TB] Loading firmware: %s", firmware_file);
    $readmemh(firmware_file, ram);
  end

  // ============================================================
  // Test Control
  // ============================================================
  int timeout_cycles = 1000000;  // 1M cycles max
  int cycle_count = 0;

  initial begin
    if (has_plusarg("WAVES")) begin
      $dumpfile("waves_soc.vcd");
      $dumpvars(0, soc_tb);
    end

    // Apply reset
    u_cr.apply_reset();

    // Run simulation
    $display("[SOC_TB] Starting simulation...");
    
    while (cycle_count < timeout_cycles) begin
      @(posedge clk);
      cycle_count++;

      // Check for CPU trap (indicates halt or error)
      if (cpu_trap) begin
        $display("[SOC_TB] CPU trapped at cycle %0d", cycle_count);
        break;
      end

      // Check if main() stored a result
      if (ram[RESULT_ADDR >> 2] !== 32'hxxxxxxxx && 
          ram[RESULT_ADDR >> 2] !== 32'h00000000 &&
          cycle_count > 100) begin
        // Result was written - check after a few more cycles
        repeat (10) @(posedge clk);
        break;
      end
    end

    // Check result
    if (cycle_count >= timeout_cycles) begin
      $display("[SOC_TB] TIMEOUT after %0d cycles", cycle_count);
      $finish(2);
    end

    // Read result from RAM
    $display("[SOC_TB] Simulation complete at cycle %0d", cycle_count);
    $display("[SOC_TB] Result value at 0x%08x = %0d", RESULT_ADDR, ram[RESULT_ADDR >> 2]);

    if (ram[RESULT_ADDR >> 2] == 32'h0) begin
      $display("");
      $display("========================================");
      $display("  SOC TEST PASSED");
      $display("========================================");
      $display("");
      $finish(0);
    end else begin
      $display("");
      $display("========================================");
      $display("  SOC TEST FAILED (result = %0d)", ram[RESULT_ADDR >> 2]);
      $display("========================================");
      $display("");
      $finish(1);
    end
  end

  // ============================================================
  // Debug: Print CPU activity
  // ============================================================
  always @(posedge clk) begin
    if (n_reset && cpu_mem_valid && cpu_mem_ready) begin
      if (cpu_mem_wstrb != 4'b0000) begin
        // Write
        if (sel_accel) begin
          $display("[SOC_TB] @%0t CPU WRITE ACCEL[0x%02x] = 0x%08x", 
                   $time, cpu_mem_addr[7:0], cpu_mem_wdata);
        end
      end else begin
        // Read
        if (sel_accel) begin
          $display("[SOC_TB] @%0t CPU READ  ACCEL[0x%02x] = 0x%08x", 
                   $time, cpu_mem_addr[7:0], cpu_mem_rdata);
        end
      end
    end
  end

endmodule
