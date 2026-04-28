`timescale 1ns/1ps


module accel_ctrl #(
    parameter int M_MAX      = 64,
    parameter int TN         = 8,
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
)
(
    input  logic                     clk,
    input  logic                     n_reset,


    input  logic                     start_pulse,
    input  logic                     clear_pulse,
    input  logic                     irq_en,

    input  logic [31:0]              M_reg,
    input  logic [31:0]              N_reg,
    input  logic [31:0]              K_reg,
    input  logic [31:0]              NNZ_reg,

    input  logic [ADDR_WIDTH-1:0]    rowptr_base_reg,
    input  logic [ADDR_WIDTH-1:0]    colidx_base_reg,
    input  logic [ADDR_WIDTH-1:0]    val_base_reg,
    input  logic [ADDR_WIDTH-1:0]    B_base_reg,
    input  logic [ADDR_WIDTH-1:0]    out_base_reg,

    input  logic                     relu_en_reg,
    input  logic [3:0]               dtype_reg,


    output logic                     status_busy,
    output logic                     status_done,
    output logic                     irq_out,


    output logic                     ram_re,
    output logic                     ram_we,
    output logic [ADDR_WIDTH-1:0]    ram_addr,
    output logic [DATA_WIDTH-1:0]    ram_wdata,
    input  logic [DATA_WIDTH-1:0]    ram_rdata,


    output logic                      dp_clear_en,
    output logic [$clog2(M_MAX)-1:0]  dp_clear_row,
    output logic [$clog2(TN)-1:0]     dp_clear_col,


    output logic                      dp_bseg_we,
    output logic [$clog2(TN)-1:0]     dp_bseg_idx,
    output logic [DATA_WIDTH-1:0]     dp_bseg_wdata,


    output logic                      dp_mac_en,
    output logic [$clog2(M_MAX)-1:0]  dp_mac_row,
    output logic [DATA_WIDTH-1:0]     dp_mac_a,


    output logic                      dp_ctile_read_en,
    output logic [$clog2(M_MAX)-1:0]  dp_ctile_read_row,
    output logic [$clog2(TN)-1:0]     dp_ctile_read_col,
    input  logic [DATA_WIDTH-1:0]     dp_ctile_read_data,

    output logic                      dp_wb_en,
    output logic [DATA_WIDTH-1:0]     dp_wb_in,
    output logic                      dp_relu_en,
    output logic [3:0]                dp_dtype,
    input  logic [DATA_WIDTH-1:0]     dp_wb_data_out
);


    typedef enum logic [2:0] {
        IDLE,
        INIT_TILE_CLEAR,
        ROW_LOAD,
        NZ_FETCH,
        MAC,
        NEXT_ROW,
        WRITE_TILE,
        DONE
    } state_t;

    typedef enum logic [1:0] {
        ROW_PHASE_0,
        ROW_PHASE_1,
        ROW_PHASE_2
    } row_phase_t;

    typedef enum logic [2:0] {
        NZ_PHASE_0,
        NZ_PHASE_1,
        NZ_PHASE_2,
        NZ_PHASE_3,
        NZ_PHASE_4
    } nz_phase_t;

    state_t      present_state, next_state;
    row_phase_t  present_row_phase, next_row_phase;
    nz_phase_t   present_nz_phase,  next_nz_phase;


    logic busy_reg, busy_reg_next;
    logic done_reg, done_reg_next;


    logic [31:0]                j0, j0_next;
    logic [$clog2(M_MAX)-1:0]    i, i_next;
    logic [$clog2(M_MAX)-1:0]    i_clear, i_clear_next;
    logic [$clog2(TN)-1:0]       t_clear, t_clear_next;
    logic [$clog2(M_MAX)-1:0]    i_wb, i_wb_next;
    logic [$clog2(TN)-1:0]       t_wb, t_wb_next;


    logic [31:0] p_start, p_start_next;
    logic [31:0] p_end,   p_end_next;
    logic [31:0] p,       p_next;


    logic [31:0]           k_reg, k_reg_next;
    logic [DATA_WIDTH-1:0] a_reg, a_reg_next;


    logic [$clog2(TN)-1:0] b_idx, b_idx_next;
    logic                  b_seg_ready, b_seg_ready_next;


    localparam int WORD_BYTES = (DATA_WIDTH/8);
    localparam int ADDR_SHIFT = $clog2(WORD_BYTES);

    function automatic logic [ADDR_WIDTH-1:0] idx_to_byte_addr(input logic [ADDR_WIDTH-1:0] base,
                                                               input logic [31:0] idx);
        idx_to_byte_addr = base + ADDR_WIDTH'(idx << ADDR_SHIFT);
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] idx2_to_byte_addr(input logic [ADDR_WIDTH-1:0] base,
                                                                input logic [31:0] idx);
        idx2_to_byte_addr = base + ADDR_WIDTH'(idx << ADDR_SHIFT);
    endfunction

    function automatic logic [DATA_WIDTH-1:0] signext_i8_from_word(
        input logic [DATA_WIDTH-1:0] word,
        input logic [1:0]            byte_sel
    );
        logic signed [7:0] q8;
        begin
            unique case (byte_sel)
                2'd0: q8 = word[7:0];
                2'd1: q8 = word[15:8];
                2'd2: q8 = word[23:16];
                default: q8 = word[31:24];
            endcase
            signext_i8_from_word = DATA_WIDTH'($signed(q8));
        end
    endfunction


    always_ff @(posedge clk or negedge n_reset)
    begin : SEQ
        if(!n_reset)
        begin
            present_state     <= IDLE;
            present_row_phase <= ROW_PHASE_0;
            present_nz_phase  <= NZ_PHASE_0;

            busy_reg          <= 1'b0;
            done_reg          <= 1'b0;

            j0                <= '0;
            i                 <= '0;
            i_clear           <= '0;
            t_clear           <= '0;
            i_wb              <= '0;
            t_wb              <= '0;

            p_start           <= '0;
            p_end             <= '0;
            p                 <= '0;

            k_reg             <= '0;
            a_reg             <= '0;

            b_idx             <= '0;
            b_seg_ready       <= 1'b0;
        end

        else
        begin
            present_state     <= next_state;
            present_row_phase <= next_row_phase;
            present_nz_phase  <= next_nz_phase;

            busy_reg          <= busy_reg_next;
            done_reg          <= done_reg_next;

            j0                <= j0_next;
            i                 <= i_next;
            i_clear           <= i_clear_next;
            t_clear           <= t_clear_next;
            i_wb              <= i_wb_next;
            t_wb              <= t_wb_next;

            p_start           <= p_start_next;
            p_end             <= p_end_next;
            p                 <= p_next;

            k_reg             <= k_reg_next;
            a_reg             <= a_reg_next;

            b_idx             <= b_idx_next;
            b_seg_ready       <= b_seg_ready_next;
        end
    end


    always_comb
    begin : COM
        next_state       = present_state;
        next_row_phase   = present_row_phase;
        next_nz_phase    = present_nz_phase;

        busy_reg_next    = busy_reg;
        done_reg_next    = done_reg;

        j0_next          = j0;
        i_next           = i;
        i_clear_next     = i_clear;
        t_clear_next     = t_clear;
        i_wb_next        = i_wb;
        t_wb_next        = t_wb;

        p_start_next     = p_start;
        p_end_next       = p_end;
        p_next           = p;

        k_reg_next       = k_reg;
        a_reg_next       = a_reg;

        b_idx_next       = b_idx;
        b_seg_ready_next = b_seg_ready;


        ram_addr         = '0;
        ram_re           = 1'b0;
        ram_we           = 1'b0;
        ram_wdata        = '0;

        dp_clear_en      = 1'b0;
        dp_clear_row     = i_clear;
        dp_clear_col     = t_clear;

        dp_bseg_we       = 1'b0;
        dp_bseg_idx      = b_idx;
        dp_bseg_wdata    = '0;

        dp_mac_en        = 1'b0;
        dp_mac_row       = i;
        dp_mac_a         = a_reg;

        dp_ctile_read_en   = 1'b0;
        dp_ctile_read_row  = i_wb;
        dp_ctile_read_col  = t_wb;

        dp_wb_en        = 1'b0;
        dp_wb_in        = dp_ctile_read_data;
        dp_relu_en      = relu_en_reg;
        dp_dtype        = dtype_reg;

        status_busy     = busy_reg;
        status_done     = done_reg;
        irq_out         = irq_en && done_reg;


        unique case (present_state)
            IDLE:  begin
                if (start_pulse && !busy_reg)
                begin
                    if (M_reg == 0 || N_reg == 0)
                    begin
                        done_reg_next = 1'b1;
                        next_state    = DONE;
                    end
                    else
                    begin
                        busy_reg_next  = 1'b1;
                        done_reg_next  = 1'b0;
                        j0_next        = '0;
                        i_clear_next   = '0;
                        t_clear_next   = '0;
                        next_state     = INIT_TILE_CLEAR;
                    end
                end
            end

            INIT_TILE_CLEAR: begin
                dp_clear_en  = 1'b1;
                dp_clear_row = i_clear;
                dp_clear_col = t_clear;

                if (t_clear == TN-1) begin
                    t_clear_next = '0;
                    if (i_clear == M_reg - 1) begin
                        i_clear_next = '0;
                        i_next       = '0;
                        next_state   = ROW_LOAD;
                    end
                    else begin
                        i_clear_next = i_clear + 1;
                    end
                end
                else begin
                    t_clear_next = t_clear + 1;
                end
            end

            ROW_LOAD: begin
                case (present_row_phase)
                    ROW_PHASE_0: begin
                        ram_addr        = idx2_to_byte_addr(rowptr_base_reg, i);
                        ram_re          = 1'b1;
                        next_row_phase  = ROW_PHASE_1;
                    end

                    ROW_PHASE_1: begin
                        p_start_next    = ram_rdata;
                        ram_addr        = idx_to_byte_addr(rowptr_base_reg, (i + 1));
                        ram_re          = 1'b1;
                        next_row_phase  = ROW_PHASE_2;
                    end

                    ROW_PHASE_2: begin
                        p_end_next      = ram_rdata;
                        next_row_phase  = ROW_PHASE_0;

                        if (p_start == ram_rdata) begin
                            next_state = NEXT_ROW;
                        end
                        else begin
                            p_next        = p_start;
                            next_nz_phase = NZ_PHASE_0;
                            next_state    = NZ_FETCH;
                        end
                    end

                    default: begin
                        next_row_phase = ROW_PHASE_0;
                    end
                endcase
            end

            NZ_FETCH:
            begin
                case (present_nz_phase)
                    NZ_PHASE_0: begin
                        ram_addr      = idx_to_byte_addr(colidx_base_reg, p);
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_1;
                    end
                    NZ_PHASE_1: begin
                        k_reg_next    = ram_rdata;
                        if (dtype_reg[0]) begin
                            ram_addr  = idx_to_byte_addr(val_base_reg, (p >> 2));
                        end else begin
                            ram_addr  = idx_to_byte_addr(val_base_reg, p);
                        end
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_2;
                    end
                    NZ_PHASE_2: begin
                        if (dtype_reg[0]) begin
                            a_reg_next    = signext_i8_from_word(ram_rdata, p[1:0]);
                        end else begin
                            a_reg_next    = ram_rdata;
                        end
                        b_idx_next        = '0;
                        b_seg_ready_next  = 1'b0;
                        next_nz_phase     = NZ_PHASE_3;
                    end


                    NZ_PHASE_3: begin
                        if (dtype_reg[0]) begin
                            ram_addr  = idx_to_byte_addr(
                                            B_base_reg,
                                            (((k_reg * N_reg) + (j0 + b_idx)) >> 2)
                                        );
                        end else begin
                            ram_addr  = idx_to_byte_addr(
                                            B_base_reg,
                                            (k_reg * N_reg) + (j0 + b_idx)
                                        );
                        end
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_4;
                    end


                    NZ_PHASE_4: begin
                        dp_bseg_we    = 1'b1;
                        dp_bseg_idx   = b_idx;
                        dp_bseg_wdata = ram_rdata;

                        if (dtype_reg[0]) begin

                            if ((32'(b_idx) + 32'd3) >= (TN - 1)) begin
                                b_idx_next       = b_idx;
                                b_seg_ready_next = 1'b1;
                                next_nz_phase    = NZ_PHASE_0;
                                next_state       = MAC;
                            end
                            else begin
                                b_idx_next       = b_idx + 4;
                                next_nz_phase    = NZ_PHASE_3;
                            end
                        end else begin
                            if (b_idx == TN-1) begin
                                b_idx_next       = b_idx;
                                b_seg_ready_next = 1'b1;
                                next_nz_phase    = NZ_PHASE_0;
                                next_state       = MAC;
                            end
                            else begin
                                b_idx_next       = b_idx + 1;
                                next_nz_phase    = NZ_PHASE_3;
                            end
                        end
                    end

                    default: begin
                        next_nz_phase = NZ_PHASE_0;
                    end
                endcase
            end

            MAC:
            begin
                dp_mac_en  = 1'b1;
                dp_mac_row = i;
                dp_mac_a   = a_reg;


                if (p + 1 < p_end) begin
                    p_next        = p + 1;
                    next_nz_phase = NZ_PHASE_0;
                    next_state    = NZ_FETCH;
                end
                else begin
                    next_state = NEXT_ROW;
                end
            end

            NEXT_ROW:
            begin
                if (i + 1 < M_reg) begin
                    i_next     = i + 1;
                    next_state = ROW_LOAD;
                end
                else begin
                    i_wb_next  = '0;
                    t_wb_next  = '0;
                    next_state = WRITE_TILE;
                end
            end

            WRITE_TILE:
            begin
                dp_ctile_read_en  = 1'b1;
                dp_ctile_read_row = i_wb;
                dp_ctile_read_col = t_wb;

                dp_wb_en          = 1'b1;
                dp_wb_in          = dp_ctile_read_data;

                ram_addr  = idx_to_byte_addr(
                                out_base_reg,
                                (i_wb * N_reg) + (j0 + t_wb)
                            );
                ram_we    = 1'b1;
                ram_wdata = dp_wb_data_out;

                if (t_wb == TN-1) begin
                    t_wb_next = '0;

                    if (i_wb == M_reg - 1) begin
                        if (j0 + TN < N_reg) begin
                            j0_next      = j0 + TN;
                            i_clear_next = '0;
                            t_clear_next = '0;
                            next_state   = INIT_TILE_CLEAR;
                        end
                        else begin
                            next_state = DONE;
                        end
                    end
                    else begin
                        i_wb_next = i_wb + 1;
                    end
                end
                else begin
                    t_wb_next = t_wb + 1;
                end
            end

            DONE:begin
                busy_reg_next = 1'b0;
                done_reg_next = 1'b1;

                if (clear_pulse)
                begin
                    done_reg_next  = 1'b0;
                    next_state     = IDLE;
                end
            end

        endcase
    end

endmodule
