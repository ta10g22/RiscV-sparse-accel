//This is the top level wrapper for the sparse matrix accelerator
//it instantiates the accel_ctrl and accel_datapath and wires all signals internally
//exposes ram interface from the ctrl block

module accel_top #(
    parameter int M_MAX      = 64,
    parameter int TN         = 8,
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
)( 
    
    input  logic                     clk,
    input  logic                     n_reset,

// --------- MMIO interface from CPU -----------
    input  logic                     mmio_cs,      // accelerator region selected
    input  logic                     mmio_we,      // write enable
    input  logic [ADDR_WIDTH-1:0]    mmio_addr,    // byte address within accel MMIO
    input  logic [DATA_WIDTH-1:0]    mmio_wdata,
    input  logic [DATA_WIDTH/8-1:0]  mmio_wstrb,
    output logic [DATA_WIDTH-1:0]    mmio_rdata,


    // ---------------- System RAM interface ----------------
    output logic                     ram_re,
    output logic                     ram_we,
    output logic [ADDR_WIDTH-1:0]    ram_addr,
    output logic [DATA_WIDTH-1:0]    ram_wdata,
    input  logic [DATA_WIDTH-1:0]    ram_rdata,

    // ---------------- Interrupt to CPU ----------------
    output logic                     irq_out
);


        // MMIO register map (byte offsets)
    localparam logic [ADDR_WIDTH-1:0] REG_CTRL        = 32'h00; // [0]=START (pulse), [1]=CLEAR (pulse), [2]=IRQ_EN
    localparam logic [ADDR_WIDTH-1:0] REG_STATUS      = 32'h04; // [0]=BUSY, [1]=DONE

    localparam logic [ADDR_WIDTH-1:0] REG_M           = 32'h10;
    localparam logic [ADDR_WIDTH-1:0] REG_N           = 32'h14;
    localparam logic [ADDR_WIDTH-1:0] REG_K           = 32'h18;
    localparam logic [ADDR_WIDTH-1:0] REG_NNZ         = 32'h1C;

    localparam logic [ADDR_WIDTH-1:0] REG_ROWPTR_BASE = 32'h20;
    localparam logic [ADDR_WIDTH-1:0] REG_COLIDX_BASE = 32'h24;
    localparam logic [ADDR_WIDTH-1:0] REG_VAL_BASE    = 32'h28;
    localparam logic [ADDR_WIDTH-1:0] REG_B_BASE      = 32'h2C;
    localparam logic [ADDR_WIDTH-1:0] REG_OUT_BASE    = 32'h30;

    localparam logic [ADDR_WIDTH-1:0] REG_RELU_DTYPE  = 32'h40; // [0]=RELU_EN, [7:4]=dtype


    // Config registers visible to accel_ctrl

    logic [31:0]              M_reg;
    logic [31:0]              N_reg;
    logic [31:0]              K_reg;
    logic [31:0]              NNZ_reg;

    logic [ADDR_WIDTH-1:0]    rowptr_base_reg;
    logic [ADDR_WIDTH-1:0]    colidx_base_reg;
    logic [ADDR_WIDTH-1:0]    val_base_reg;
    logic [ADDR_WIDTH-1:0]    B_base_reg;
    logic [ADDR_WIDTH-1:0]    out_base_reg;

    logic                     relu_en_reg;
    logic [3:0]               dtype_reg;
    logic                     irq_en_reg;

    // Pulses derived from MMIO writes
    logic start_pulse;
    logic clear_pulse;

    // Status from controller
    logic status_busy;
    logic status_done;

    // MMIO write path: update config regs and generate pulses

    // START and CLEAR as 1-cycle pulses on writes to REG_CTRL.
    // irq_en_reg is latched.

    always_ff @(posedge clk or negedge n_reset) begin
        if (!n_reset) begin
            M_reg           <= 32'd0;
            N_reg           <= 32'd0;
            K_reg           <= 32'd0;
            NNZ_reg         <= 32'd0;

            rowptr_base_reg <= '0;
            colidx_base_reg <= '0;
            val_base_reg    <= '0;
            B_base_reg      <= '0;
            out_base_reg    <= '0;

            relu_en_reg     <= 1'b0;
            dtype_reg       <= 4'd0;
            irq_en_reg      <= 1'b0;
        end
        else begin
            if (mmio_cs && mmio_we && (|mmio_wstrb)) begin
                unique case (mmio_addr)
                    REG_CTRL: begin
                        irq_en_reg <= mmio_wdata[2];
                        // bits [1:0] are used only for pulses, not latched
                    end

                    REG_M:           M_reg           <= mmio_wdata;
                    REG_N:           N_reg           <= mmio_wdata;
                    REG_K:           K_reg           <= mmio_wdata;
                    REG_NNZ:         NNZ_reg         <= mmio_wdata;

                    REG_ROWPTR_BASE: rowptr_base_reg <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_COLIDX_BASE: colidx_base_reg <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_VAL_BASE:    val_base_reg    <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_B_BASE:      B_base_reg      <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_OUT_BASE:    out_base_reg    <= mmio_wdata[ADDR_WIDTH-1:0];

                    REG_RELU_DTYPE: begin
                        relu_en_reg <= mmio_wdata[0];
                        dtype_reg   <= mmio_wdata[7:4];
                    end

                    default: ; // ignore writes to unknown offsets
                endcase
            end
        end
    end

    // Generate single-cycle pulses for START and CLEAR when CPU writes REG_CTRL.
    always_comb begin
        start_pulse = 1'b0;
        clear_pulse = 1'b0;

        if (mmio_cs && mmio_we && (|mmio_wstrb) && (mmio_addr == REG_CTRL)) begin
            start_pulse = mmio_wdata[0];
            clear_pulse = mmio_wdata[1];
        end
    end

    //  MMIO read path
    always_comb begin
        mmio_rdata = '0;

        if (mmio_cs && !mmio_we) begin
            unique case (mmio_addr)
                REG_CTRL: begin
                    mmio_rdata[2] = irq_en_reg;
                    // bits [1:0] read as 0 (pulses)
                end

                REG_STATUS: begin
                    mmio_rdata[0] = status_busy;
                    mmio_rdata[1] = status_done;
                end

                REG_M:           mmio_rdata = M_reg;
                REG_N:           mmio_rdata = N_reg;
                REG_K:           mmio_rdata = K_reg;
                REG_NNZ:         mmio_rdata = NNZ_reg;

                REG_ROWPTR_BASE: mmio_rdata = rowptr_base_reg;
                REG_COLIDX_BASE: mmio_rdata = colidx_base_reg;
                REG_VAL_BASE:    mmio_rdata = val_base_reg;
                REG_B_BASE:      mmio_rdata = B_base_reg;
                REG_OUT_BASE:    mmio_rdata = out_base_reg;

                REG_RELU_DTYPE: begin
                    mmio_rdata[0]   = relu_en_reg;
                    mmio_rdata[7:4] = dtype_reg;
                end

                default: mmio_rdata = '0;
            endcase
        end
    end



    // Wires between ctrl and datapath
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



             // accel_ctrl instance
     accel_ctrl #(
        .M_MAX      (M_MAX),
        .TN         (TN),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_accel_ctrl (
        .clk              (clk),
        .n_reset          (n_reset),

        // control + config
        .start_pulse      (start_pulse),
        .clear_pulse      (clear_pulse),
        .irq_en           (irq_en_reg),

        .M_reg            (M_reg),
        .N_reg            (N_reg),
        .K_reg            (K_reg),
        .NNZ_reg          (NNZ_reg),

        .rowptr_base_reg  (rowptr_base_reg),
        .colidx_base_reg  (colidx_base_reg),
        .val_base_reg     (val_base_reg),
        .B_base_reg       (B_base_reg),
        .out_base_reg     (out_base_reg),

        .relu_en_reg      (relu_en_reg),
        .dtype_reg        (dtype_reg),

        // status
        .status_busy      (status_busy),
        .status_done      (status_done),
        .irq_out          (irq_out),

        // system RAM interface
        .ram_re           (ram_re),
        .ram_we           (ram_we),
        .ram_addr         (ram_addr),
        .ram_wdata        (ram_wdata),
        .ram_rdata        (ram_rdata),

        // datapath control
        .dp_clear_en      (dp_clear_en),
        .dp_clear_row     (dp_clear_row),
        .dp_clear_col     (dp_clear_col),

        .dp_bseg_we       (dp_bseg_we),
        .dp_bseg_idx      (dp_bseg_idx),
        .dp_bseg_wdata    (dp_bseg_wdata),

        .dp_mac_en        (dp_mac_en),
        .dp_mac_row       (dp_mac_row),
        .dp_mac_col       (dp_mac_col),
        .dp_mac_a         (dp_mac_a),

        .dp_ctile_read_en (dp_ctile_read_en),
        .dp_ctile_read_row(dp_ctile_read_row),
        .dp_ctile_read_col(dp_ctile_read_col),
        .dp_ctile_read_data(dp_ctile_read_data),

        .dp_wb_en         (dp_wb_en),
        .dp_wb_in         (dp_wb_in),
        .dp_relu_en       (dp_relu_en),
        .dp_dtype         (dp_dtype),
        .dp_wb_data_out   (dp_wb_data_out)
    );

 
    // accel_datapath instance (we'll define this next) 
    accel_datapath #(
        .M_MAX      (M_MAX),
        .TN         (TN),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_accel_datapath (
        .clk               (clk),
        .rst_n             (n_reset),

        // tile clear
        .clear_en          (dp_clear_en),
        .clear_row         (dp_clear_row),
        .clear_col         (dp_clear_col),

        // B_seg load
        .bseg_we           (dp_bseg_we),
        .bseg_idx          (dp_bseg_idx),
        .bseg_wdata        (dp_bseg_wdata),

        // MAC
        .mac_en            (dp_mac_en),
        .mac_row           (dp_mac_row),
        .mac_col           (dp_mac_col),
        .mac_a             (dp_mac_a),

        // C_tile read for writeback
        .ctile_read_en     (dp_ctile_read_en),
        .ctile_read_row    (dp_ctile_read_row),
        .ctile_read_col    (dp_ctile_read_col),
        .ctile_read_data   (dp_ctile_read_data),

        // ReLU / dtype + final WB path
        .relu_en           (dp_relu_en),
        .dtype             (dp_dtype),
        .wb_en             (dp_wb_en),
        .wb_in             (dp_wb_in),
        .wb_data_out       (dp_wb_data_out)
    );


endmodule