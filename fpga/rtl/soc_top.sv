`timescale 1ns / 1ps

module soc_top #(
  parameter M_MAX      = 64,
  parameter TN         = 8,
  parameter RAM_SIZE   = 65536,
  parameter MEM_INIT   = ""
)(
  input  logic        clk_50mhz,
  input  logic        n_reset,

  output logic [9:0]  led,

  input  logic [9:0]  sw,

  input  logic [3:1]  key,

  output logic [6:0]  hex0,
  output logic [6:0]  hex1,
  output logic [6:0]  hex2,
  output logic [6:0]  hex3,
  output logic [6:0]  hex4,
  output logic [6:0]  hex5,

  output logic        uart_tx,
  input  logic        uart_rx
);

  localparam ADDR_WIDTH = 32;
  localparam DATA_WIDTH = 32;

  logic        clk;
  logic        rst_n;
  logic [2:0]  reset_sync;

  logic        mem_valid;
  logic        mem_instr;
  logic        mem_ready;
  logic [31:0] mem_addr;
  logic [31:0] mem_wdata;
  logic [3:0]  mem_wstrb;
  logic [31:0] mem_rdata;

  logic        sel_ram;
  logic        sel_accel;
  logic        sel_gpio;
  logic        sel_uart;

  logic [31:0] ram_rdata;
  logic        ram_ready;

  logic [31:0] accel_rdata;
  logic        accel_ready;
  logic [31:0] accel_mem_addr;
  logic [31:0] accel_mem_rdata;
  logic        accel_mem_re;
  logic [31:0] accel_mem_wdata;
  logic        accel_mem_we;
  logic [3:0]  accel_led;

  logic [31:0] gpio_rdata;
  logic        gpio_ready;
  logic [31:0] gpio_out_reg;

  logic [31:0] uart_rdata;
  logic        uart_ready;
  logic        uart_bad_addr;

  logic        simpleuart_reg_div_sel;
  logic [31:0] simpleuart_reg_div_do;
  logic        simpleuart_reg_dat_sel;
  logic [31:0] simpleuart_reg_dat_do;
  logic        simpleuart_reg_dat_wait;

  assign clk = clk_50mhz;

  always_ff @(posedge clk or negedge n_reset) begin
    if (!n_reset) begin
      reset_sync <= 3'b000;
    end else begin
      reset_sync <= {reset_sync[1:0], 1'b1};
    end
  end
  assign rst_n = reset_sync[2];

  assign sel_ram   = (mem_addr[31:16] == 16'h0000);
  assign sel_accel = (mem_addr[31:8]  == 24'h100000);
  assign sel_gpio  = (mem_addr[31:4]  == 28'h2000000);
  assign sel_uart  = (mem_addr[31:8]  == 24'h200001);

  assign simpleuart_reg_div_sel = mem_valid && sel_uart && (mem_addr[7:0] == 8'h04);
  assign simpleuart_reg_dat_sel = mem_valid && sel_uart && (mem_addr[7:0] == 8'h08);

  assign uart_bad_addr = mem_valid && sel_uart && !simpleuart_reg_div_sel && !simpleuart_reg_dat_sel;
  assign uart_ready = simpleuart_reg_div_sel ||
                      (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait) ||
                      uart_bad_addr;

  always_comb begin
    if (simpleuart_reg_div_sel)
      uart_rdata = simpleuart_reg_div_do;
    else if (simpleuart_reg_dat_sel)
      uart_rdata = simpleuart_reg_dat_do;
    else
      uart_rdata = 32'h0000_0000;
  end

  picorv32 #(
    .ENABLE_COUNTERS      (1),
    .ENABLE_COUNTERS64    (0),
    .ENABLE_REGS_16_31    (1),
    .ENABLE_REGS_DUALPORT (1),
    .LATCHED_MEM_RDATA    (0),
    .TWO_STAGE_SHIFT      (0),
    .BARREL_SHIFTER       (1),
    .TWO_CYCLE_COMPARE    (0),
    .TWO_CYCLE_ALU        (0),
    .COMPRESSED_ISA       (0),
    .CATCH_MISALIGN       (0),
    .CATCH_ILLINSN        (0),
    .ENABLE_PCPI          (0),
    .ENABLE_MUL           (1),
    .ENABLE_FAST_MUL      (1),
    .ENABLE_DIV           (1),
    .ENABLE_IRQ           (0),
    .ENABLE_IRQ_QREGS     (0),
    .ENABLE_IRQ_TIMER     (0),
    .ENABLE_TRACE         (0),
    .REGS_INIT_ZERO       (1),
    .MASKED_IRQ           (32'h0000_0000),
    .LATCHED_IRQ          (32'hffff_ffff),
    .PROGADDR_RESET       (32'h0000_0000),
    .PROGADDR_IRQ         (32'h0000_0010),
    .STACKADDR            (32'h0000_FF00)
  ) u_cpu (
    .clk          (clk),
    .resetn       (rst_n),
    .trap         (),
    
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),

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
    .pcpi_rd      (32'b0),
    .pcpi_wait    (1'b0),
    .pcpi_ready   (1'b0),
    
    .irq          (32'b0),
    .eoi          (),
    
    .trace_valid  (),
    .trace_data   ()
  );

  assign mem_ready = (sel_ram   && ram_ready)   ||
                     (sel_accel && accel_ready) ||
                     (sel_gpio  && gpio_ready)  ||
                     (sel_uart  && uart_ready);
  
  always_comb begin
    if (sel_ram)
      mem_rdata = ram_rdata;
    else if (sel_accel)
      mem_rdata = accel_rdata;
    else if (sel_gpio)
      mem_rdata = gpio_rdata;
    else if (sel_uart)
      mem_rdata = uart_rdata;
    else
      mem_rdata = 32'hDEAD_BEEF;
  end

  logic        ram_read_pending;
  logic [31:0] ram_rdata_reg;
  logic [31:0] accel_rdata_reg;

  wire [13:0] ram_addr_a = mem_addr[15:2];
  wire [31:0] ram_wdata_a = mem_wdata;
  wire [3:0]  ram_byteena_a = mem_wstrb;
  wire        ram_wren_a = mem_valid && sel_ram && |mem_wstrb && !accel_mem_we;
  wire        ram_rden_a = mem_valid && sel_ram && ~|mem_wstrb;

  wire [13:0] ram_addr_b = accel_mem_addr[15:2];
  wire [31:0] ram_wdata_b = accel_mem_wdata;
  wire        ram_wren_b = accel_mem_we;

  altsyncram #(
    .operation_mode       ("BIDIR_DUAL_PORT"),
    .width_a              (32),
    .widthad_a            (14),
    .numwords_a           (16384),
    .width_b              (32),
    .widthad_b            (14),
    .numwords_b           (16384),
    .width_byteena_a      (4),
    .width_byteena_b      (1),
    .outdata_reg_a        ("UNREGISTERED"),
    .outdata_reg_b        ("UNREGISTERED"),
    .address_reg_b        ("CLOCK0"),
    .indata_reg_b         ("CLOCK0"),
    .wrcontrol_wraddress_reg_b ("CLOCK0"),
    .byteena_reg_b        ("CLOCK0"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .init_file            ("firmware.mif"),
    .lpm_type             ("altsyncram"),
    .intended_device_family ("Cyclone V")
  ) u_ram (
    .clock0      (clk),
    .address_a   (ram_addr_a),
    .data_a      (ram_wdata_a),
    .byteena_a   (ram_byteena_a),
    .wren_a      (ram_wren_a),
    .q_a         (ram_rdata_reg),
    .address_b   (ram_addr_b),
    .data_b      (ram_wdata_b),
    .byteena_b   (1'b1),
    .wren_b      (ram_wren_b),
    .q_b         (accel_rdata_reg),
    .aclr0       (1'b0),
    .aclr1       (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clock1      (1'b1),
    .clocken0    (1'b1),
    .clocken1    (1'b1),
    .clocken2    (1'b1),
    .clocken3    (1'b1),
    .eccstatus   (),
    .rden_a      (1'b1),
    .rden_b      (1'b1)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ram_read_pending <= 1'b0;
    end else begin
      ram_read_pending <= mem_valid && sel_ram && !ram_ready;
    end
  end
  
  assign ram_rdata = ram_rdata_reg;
  assign accel_mem_rdata = accel_rdata_reg;
  assign ram_ready = ram_read_pending;

  accel_top #(
    .M_MAX      (M_MAX),
    .TN         (TN),
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_accel (
    .clk        (clk),
    .n_reset    (rst_n),

    .mmio_addr  ({24'h0, mem_addr[7:0]}),
    .mmio_wdata (mem_wdata),
    .mmio_we    (sel_accel && mem_valid && (mem_wstrb != 4'b0000)),
    .mmio_re    (sel_accel && mem_valid && (mem_wstrb == 4'b0000)),
    .mmio_wstrb (mem_wstrb),
    .mmio_valid (sel_accel && mem_valid),
    .mmio_rdata (accel_rdata),
    .mmio_ready (accel_ready),

    .ram_addr   (accel_mem_addr),
    .ram_rdata  (accel_mem_rdata),
    .ram_re     (accel_mem_re),
    .ram_wdata  (accel_mem_wdata),
    .ram_we     (accel_mem_we),

    .led        (accel_led),
    .irq        ()
  );

  logic gpio_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gpio_out_reg <= 32'h0;
      gpio_pending <= 1'b0;
    end else begin
      gpio_pending <= 1'b0;

      if (mem_valid && sel_gpio && !gpio_ready) begin
        case (mem_addr[3:2])
          2'b00: begin
            if (|mem_wstrb) begin
              if (mem_wstrb[0]) gpio_out_reg[7:0]   <= mem_wdata[7:0];
              if (mem_wstrb[1]) gpio_out_reg[15:8]  <= mem_wdata[15:8];
              if (mem_wstrb[2]) gpio_out_reg[23:16] <= mem_wdata[23:16];
              if (mem_wstrb[3]) gpio_out_reg[31:24] <= mem_wdata[31:24];
            end
            gpio_rdata <= gpio_out_reg;
          end
          2'b01: begin
            gpio_rdata <= {22'h0, sw};
          end
          2'b10: begin
            gpio_rdata <= {29'h0, key};
          end
          default: begin
            gpio_rdata <= 32'h0;
          end
        endcase
        gpio_pending <= 1'b1;
      end
    end
  end

  assign gpio_ready = gpio_pending;

  assign led[5:0] = gpio_out_reg[5:0];
  assign led[9:6] = accel_led;

  function automatic [6:0] hex_decode(input [3:0] val);
    case (val)
      4'h0: hex_decode = 7'b1000000;
      4'h1: hex_decode = 7'b1111001;
      4'h2: hex_decode = 7'b0100100;
      4'h3: hex_decode = 7'b0110000;
      4'h4: hex_decode = 7'b0011001;
      4'h5: hex_decode = 7'b0010010;
      4'h6: hex_decode = 7'b0000010;
      4'h7: hex_decode = 7'b1111000;
      4'h8: hex_decode = 7'b0000000;
      4'h9: hex_decode = 7'b0010000;
      4'hA: hex_decode = 7'b0001000;
      4'hB: hex_decode = 7'b0000011;
      4'hC: hex_decode = 7'b1000110;
      4'hD: hex_decode = 7'b0100001;
      4'hE: hex_decode = 7'b0000110;
      4'hF: hex_decode = 7'b0001110;
    endcase
  endfunction
  
  assign hex0 = hex_decode(gpio_out_reg[3:0]);
  assign hex1 = hex_decode(gpio_out_reg[7:4]);
  assign hex2 = hex_decode(gpio_out_reg[11:8]);
  assign hex3 = hex_decode(gpio_out_reg[15:12]);
  assign hex4 = hex_decode(gpio_out_reg[19:16]);
  assign hex5 = hex_decode(gpio_out_reg[23:20]);

  simpleuart #(
    .DEFAULT_DIV (434)
  ) u_uart (
    .clk         (clk),
    .resetn      (rst_n),
    .ser_tx      (uart_tx),
    .ser_rx      (uart_rx),

    .reg_div_we  (simpleuart_reg_div_sel ? mem_wstrb : 4'b0000),
    .reg_div_di  (mem_wdata),
    .reg_div_do  (simpleuart_reg_div_do),

    .reg_dat_we  (simpleuart_reg_dat_sel ? mem_wstrb[0] : 1'b0),
    .reg_dat_re  (simpleuart_reg_dat_sel && !(|mem_wstrb)),
    .reg_dat_di  (mem_wdata),
    .reg_dat_do  (simpleuart_reg_dat_do),
    .reg_dat_wait(simpleuart_reg_dat_wait)
  );

endmodule
