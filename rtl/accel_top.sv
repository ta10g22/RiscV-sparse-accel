`timescale 1ns/1ps


module accel_top #(
    parameter int M_MAX       = 64,
    parameter int TN          = 8,
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32
)(
    input  logic                     clk,
    input  logic                     n_reset,

    input  logic [ADDR_WIDTH-1:0]    mmio_addr,
    input  logic [DATA_WIDTH-1:0]    mmio_wdata,
    input  logic                     mmio_we,
    input  logic                     mmio_re,
    input  logic [DATA_WIDTH/8-1:0]  mmio_wstrb,
    input  logic                     mmio_valid,
    output logic [DATA_WIDTH-1:0]    mmio_rdata,
    output logic                     mmio_ready,

    output logic                     ram_re,
    output logic                     ram_we,
    output logic [ADDR_WIDTH-1:0]    ram_addr,
    output logic [DATA_WIDTH-1:0]    ram_wdata,
    input  logic [DATA_WIDTH-1:0]    ram_rdata,

    output logic [3:0]               led,
    output logic                     irq
);


    localparam logic [ADDR_WIDTH-1:0] CTRL_OFFSET       = 32'h00;
    localparam logic [ADDR_WIDTH-1:0] STATUS_OFFSET     = 32'h04;
    localparam logic [ADDR_WIDTH-1:0] M_OFFSET          = 32'h08;
    localparam logic [ADDR_WIDTH-1:0] N_OFFSET          = 32'h0C;
    localparam logic [ADDR_WIDTH-1:0] K_OFFSET          = 32'h10;
    localparam logic [ADDR_WIDTH-1:0] A_VAL_BASE_OFFSET = 32'h14;
    localparam logic [ADDR_WIDTH-1:0] A_ROW_BASE_OFFSET = 32'h18;
    localparam logic [ADDR_WIDTH-1:0] A_COL_BASE_OFFSET = 32'h1C;
    localparam logic [ADDR_WIDTH-1:0] B_BASE_OFFSET     = 32'h20;
    localparam logic [ADDR_WIDTH-1:0] C_BASE_OFFSET     = 32'h24;
    localparam logic [ADDR_WIDTH-1:0] NNZ_OFFSET        = 32'h28;


    localparam int CTRL_START_BIT  = 0;
    localparam int CTRL_CLEAR_BIT  = 1;
    localparam int CTRL_IRQ_EN_BIT = 2;
    localparam int CTRL_RELU_BIT   = 3;
    localparam int CTRL_INT8_BIT   = 4;

    localparam int STATUS_BUSY_BIT = 0;
    localparam int STATUS_DONE_BIT = 1;


    logic [DATA_WIDTH-1:0] ctrl_reg;
    logic [DATA_WIDTH-1:0] M_reg, N_reg, K_reg;
    logic [DATA_WIDTH-1:0] A_val_base_reg;
    logic [DATA_WIDTH-1:0] A_row_base_reg;
    logic [DATA_WIDTH-1:0] A_col_base_reg;
    logic [DATA_WIDTH-1:0] B_base_reg;
    logic [DATA_WIDTH-1:0] C_base_reg;
    logic [DATA_WIDTH-1:0] NNZ_reg;


    logic start_pulse, clear_pulse;
    logic status_busy, status_done;
    logic irq_out, irq_en;


    logic                      dp_clear_en;
    logic [$clog2(M_MAX)-1:0]  dp_clear_row;
    logic [$clog2(TN)-1:0]     dp_clear_col;

    logic                      dp_bseg_we;
    logic [$clog2(TN)-1:0]     dp_bseg_idx;
    logic [DATA_WIDTH-1:0]     dp_bseg_wdata;

    logic                      dp_mac_en;
    logic [$clog2(M_MAX)-1:0]  dp_mac_row;
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


    assign mmio_ready = 1'b1;
    assign irq_en     = ctrl_reg[CTRL_IRQ_EN_BIT];
    assign irq        = irq_out;


    assign led = {3'b000, status_busy};


    always_ff @(posedge clk or negedge n_reset) begin
        if (!n_reset) begin
            ctrl_reg       <= '0;
            M_reg          <= '0;
            N_reg          <= '0;
            K_reg          <= '0;
            A_val_base_reg <= '0;
            A_row_base_reg <= '0;
            A_col_base_reg <= '0;
            B_base_reg     <= '0;
            C_base_reg     <= '0;
            NNZ_reg        <= '0;
        end else if (mmio_we && mmio_valid && (|mmio_wstrb)) begin
            unique case (mmio_addr)
                CTRL_OFFSET: begin
                    ctrl_reg[CTRL_IRQ_EN_BIT] <= mmio_wdata[CTRL_IRQ_EN_BIT];
                    ctrl_reg[CTRL_RELU_BIT]   <= mmio_wdata[CTRL_RELU_BIT];
                    ctrl_reg[CTRL_INT8_BIT]   <= mmio_wdata[CTRL_INT8_BIT];
                end
                M_OFFSET:          M_reg          <= mmio_wdata;
                N_OFFSET:          N_reg          <= mmio_wdata;
                K_OFFSET:          K_reg          <= mmio_wdata;
                A_VAL_BASE_OFFSET: A_val_base_reg <= mmio_wdata;
                A_ROW_BASE_OFFSET: A_row_base_reg <= mmio_wdata;
                A_COL_BASE_OFFSET: A_col_base_reg <= mmio_wdata;
                B_BASE_OFFSET:     B_base_reg     <= mmio_wdata;
                C_BASE_OFFSET:     C_base_reg     <= mmio_wdata;
                NNZ_OFFSET:        NNZ_reg        <= mmio_wdata;
                default: ;
            endcase
        end
    end


    always_comb begin
        start_pulse = 1'b0;
        clear_pulse = 1'b0;

        if (mmio_we && mmio_valid && (mmio_addr == CTRL_OFFSET) && (|mmio_wstrb)) begin
            start_pulse = mmio_wdata[CTRL_START_BIT];
            clear_pulse = mmio_wdata[CTRL_CLEAR_BIT];
        end
    end


    always_comb begin
        mmio_rdata = '0;
        if (mmio_re && mmio_valid) begin
            unique case (mmio_addr)
                CTRL_OFFSET: begin
                    mmio_rdata[CTRL_IRQ_EN_BIT] = ctrl_reg[CTRL_IRQ_EN_BIT];
                    mmio_rdata[CTRL_RELU_BIT]   = ctrl_reg[CTRL_RELU_BIT];
                    mmio_rdata[CTRL_INT8_BIT]   = ctrl_reg[CTRL_INT8_BIT];
                end
                STATUS_OFFSET: begin
                    mmio_rdata[STATUS_BUSY_BIT] = status_busy;
                    mmio_rdata[STATUS_DONE_BIT] = status_done;
                end
                M_OFFSET:          mmio_rdata = M_reg;
                N_OFFSET:          mmio_rdata = N_reg;
                K_OFFSET:          mmio_rdata = K_reg;
                A_VAL_BASE_OFFSET: mmio_rdata = A_val_base_reg;
                A_ROW_BASE_OFFSET: mmio_rdata = A_row_base_reg;
                A_COL_BASE_OFFSET: mmio_rdata = A_col_base_reg;
                B_BASE_OFFSET:     mmio_rdata = B_base_reg;
                C_BASE_OFFSET:     mmio_rdata = C_base_reg;
                NNZ_OFFSET:        mmio_rdata = NNZ_reg;
                default:           mmio_rdata = '0;
            endcase
        end
    end


    accel_ctrl #(
        .M_MAX      (M_MAX),
        .TN         (TN),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) ac1 (
        .clk              (clk),
        .n_reset          (n_reset),

        .start_pulse      (start_pulse),
        .clear_pulse      (clear_pulse),
        .irq_en           (irq_en),

        .M_reg            (M_reg),
        .N_reg            (N_reg),
        .K_reg            (K_reg),
        .NNZ_reg          (NNZ_reg),

        .rowptr_base_reg  (A_row_base_reg),
        .colidx_base_reg  (A_col_base_reg),
        .val_base_reg     (A_val_base_reg),
        .B_base_reg       (B_base_reg),
        .out_base_reg     (C_base_reg),

        .relu_en_reg      (ctrl_reg[CTRL_RELU_BIT]),
        .dtype_reg        ({3'b000, ctrl_reg[CTRL_INT8_BIT]}),

        .status_busy      (status_busy),
        .status_done      (status_done),
        .irq_out          (irq_out),

        .ram_re           (ram_re),
        .ram_we           (ram_we),
        .ram_addr         (ram_addr),
        .ram_wdata        (ram_wdata),
        .ram_rdata        (ram_rdata),

        .dp_clear_en      (dp_clear_en),
        .dp_clear_row     (dp_clear_row),
        .dp_clear_col     (dp_clear_col),

        .dp_bseg_we       (dp_bseg_we),
        .dp_bseg_idx      (dp_bseg_idx),
        .dp_bseg_wdata    (dp_bseg_wdata),

        .dp_mac_en        (dp_mac_en),
        .dp_mac_row       (dp_mac_row),
        .dp_mac_a         (dp_mac_a),

        .dp_ctile_read_en   (dp_ctile_read_en),
        .dp_ctile_read_row  (dp_ctile_read_row),
        .dp_ctile_read_col  (dp_ctile_read_col),
        .dp_ctile_read_data (dp_ctile_read_data),

        .dp_wb_en         (dp_wb_en),
        .dp_wb_in         (dp_wb_in),
        .dp_relu_en       (dp_relu_en),
        .dp_dtype         (dp_dtype),
        .dp_wb_data_out   (dp_wb_data_out)
    );


    accel_datapath #(
        .M_MAX      (M_MAX),
        .TN         (TN),
        .DATA_WIDTH (DATA_WIDTH)
    ) ad1 (
        .clk              (clk),
        .n_reset          (n_reset),

        .clear_en         (dp_clear_en),
        .clear_row        (dp_clear_row),
        .clear_col        (dp_clear_col),

        .bseg_we          (dp_bseg_we),
        .bseg_idx         (dp_bseg_idx),
        .bseg_wdata       (dp_bseg_wdata),

        .mac_en           (dp_mac_en),
        .mac_row          (dp_mac_row),
        .mac_a            (dp_mac_a),

        .ctile_read_en    (dp_ctile_read_en),
        .ctile_read_row   (dp_ctile_read_row),
        .ctile_read_col   (dp_ctile_read_col),
        .ctile_read_data  (dp_ctile_read_data),

        .relu_en          (dp_relu_en),
        .dtype            (dp_dtype),
        .wb_en            (dp_wb_en),
        .wb_in            (dp_wb_in),
        .wb_data_out      (dp_wb_data_out)
    );

endmodule
