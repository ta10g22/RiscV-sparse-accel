`timescale 1ns/1ps

//this is the control functionality of the SpMM accelerator
//it works with accel_datapath for full functionality

module accel_ctrl #(
    parameter int M_MAX      = 64,   // the maximum length m can be is 64 (N is capped at TN per write)
    parameter int TN         = 8,    // tile length
    parameter int ADDR_WIDTH = 32,   // 2^32 address spaces
    parameter int DATA_WIDTH = 32    // 32 bit memory at each address
)
(
    input  logic                     clk,
    input  logic                     n_reset,

    // control + config for top
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

    // status outputs to top
    output logic                     status_busy,
    output logic                     status_done,
    output logic                     irq_out,

    // system ram interface (SYNC read: ram_rdata valid next cycle after ram_re)
    output logic                     ram_re,
    output logic                     ram_we,
    output logic [ADDR_WIDTH-1:0]    ram_addr,
    output logic [DATA_WIDTH-1:0]    ram_wdata,
    input  logic [DATA_WIDTH-1:0]    ram_rdata,

    // -- control interface to datapath --

    // tile clear
    output logic                      dp_clear_en,
    output logic [$clog2(M_MAX)-1:0]  dp_clear_row,
    output logic [$clog2(TN)-1:0]     dp_clear_col,

    //B_seg load
    output logic                      dp_bseg_we,
    output logic [$clog2(TN)-1:0]     dp_bseg_idx,
    output logic [DATA_WIDTH-1:0]     dp_bseg_wdata,

    //MAC
    output logic                      dp_mac_en,
    output logic [$clog2(M_MAX)-1:0]  dp_mac_row,
    output logic [DATA_WIDTH-1:0]     dp_mac_a,

    // tile read + WB
    output logic                      dp_ctile_read_en,
    output logic [$clog2(M_MAX)-1:0]  dp_ctile_read_row,
    output logic [$clog2(TN)-1:0]     dp_ctile_read_col,
    input  logic [DATA_WIDTH-1:0]     dp_ctile_read_data,

    output logic                      dp_wb_en,
    output logic [DATA_WIDTH-1:0]     dp_wb_in,       // usually dp_ctile_read_data
    output logic                      dp_relu_en,
    output logic [3:0]                dp_dtype,
    input  logic [DATA_WIDTH-1:0]     dp_wb_data_out  // goes to ram_wdata during WRITE_TILE
);

//
//    STATES & PHASES
//

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
        NZ_PHASE_3,   // B read
        NZ_PHASE_4    // B write into B_seg (using ram_rdata from previous cycle)
    } nz_phase_t;

    state_t      present_state, next_state;
    row_phase_t  present_row_phase, next_row_phase;
    nz_phase_t   present_nz_phase,  next_nz_phase;

    // High-level flags
    logic busy_reg, busy_reg_next;
    logic done_reg, done_reg_next;

    // Tiling / loops
    logic [31:0]                j0, j0_next;          // tile start col
    logic [$clog2(M_MAX)-1:0]    i, i_next;
    logic [$clog2(M_MAX)-1:0]    i_clear, i_clear_next;
    logic [$clog2(TN)-1:0]       t_clear, t_clear_next;
    logic [$clog2(M_MAX)-1:0]    i_wb, i_wb_next;
    logic [$clog2(TN)-1:0]       t_wb, t_wb_next;

    // CSR indices
    logic [31:0] p_start, p_start_next;
    logic [31:0] p_end,   p_end_next;
    logic [31:0] p,       p_next;

    // Current NZ (k, a)
    logic [31:0]           k_reg, k_reg_next;
    logic [DATA_WIDTH-1:0] a_reg, a_reg_next;

    // B load helper
    logic [$clog2(TN)-1:0] b_idx, b_idx_next;
    logic                  b_seg_ready, b_seg_ready_next;

    // Address scaling: byte addressed RAM, 32-bit words => shift by 2
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

    // Combinational part of the fsm machine
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

        // default outputs
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

        // ---- FSM: same pattern as your vending machine ----
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

            INIT_TILE_CLEAR: begin          //clear c tile storage in accelerator Bram
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
                    ROW_PHASE_0: begin                           // load the p_start value from the rowptr memory
                        ram_addr        = idx2_to_byte_addr(rowptr_base_reg, i);
                        ram_re          = 1'b1;
                        next_row_phase  = ROW_PHASE_1;
                    end

                    ROW_PHASE_1: begin
                        p_start_next    = ram_rdata;               //save the p_start value for this row
                        ram_addr        = idx_to_byte_addr(rowptr_base_reg, (i + 1)); //load the p_end index from the row ptr memory
                        ram_re          = 1'b1;
                        next_row_phase  = ROW_PHASE_2;
                    end

                    ROW_PHASE_2: begin                             // save the p_end value for this row
                        p_end_next      = ram_rdata;               // if row empty move to next_row
                        next_row_phase  = ROW_PHASE_0;             // if row not empty the let's fetch the non-zero's

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
                case (present_nz_phase)                            //    Read column idx "p" from memory location
                    NZ_PHASE_0: begin
                        ram_addr      = idx_to_byte_addr(colidx_base_reg, p);
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_1;
                    end
                    NZ_PHASE_1: begin                               //.  store column idx value in k register
                        k_reg_next    = ram_rdata;                  //.  then load value idx p from memory location
                        if (dtype_reg[0]) begin
                            ram_addr  = idx_to_byte_addr(val_base_reg, (p >> 2));
                        end else begin
                            ram_addr  = idx_to_byte_addr(val_base_reg, p);
                        end
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_2;
                    end
                    NZ_PHASE_2: begin                                // store value index data in a register
                        if (dtype_reg[0]) begin
                            a_reg_next    = signext_i8_from_word(ram_rdata, p[1:0]);
                        end else begin
                            a_reg_next    = ram_rdata;
                        end
                        b_idx_next        = '0;
                        b_seg_ready_next  = 1'b0;
                        next_nz_phase     = NZ_PHASE_3;
                    end

                    // SYNC RAM: first issue B read
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
                                        );  //load b row to work on from memory
                        end
                        ram_re        = 1'b1;
                        next_nz_phase = NZ_PHASE_4;
                    end

                    // Next cycle: ram_rdata valid -> write into B_Seg
                    NZ_PHASE_4: begin
                        dp_bseg_we    = 1'b1;
                        dp_bseg_idx   = b_idx;
                        dp_bseg_wdata = ram_rdata;

                        if (b_idx == TN-1) begin                       // if b_idx is = last element in tile
                            b_idx_next       = b_idx;
                            b_seg_ready_next = 1'b1;
                            next_nz_phase    = NZ_PHASE_0;
                            next_state       = MAC;
                        end
                        else begin
                            b_idx_next       = b_idx + 1;
                            next_nz_phase    = NZ_PHASE_3;             // go read next B element
                        end
                    end

                    default: begin
                        next_nz_phase = NZ_PHASE_0;
                    end
                endcase
            end

            MAC:
            begin                                                      // give datapath the stuff it needs
                dp_mac_en  = 1'b1;
                dp_mac_row = i;
                dp_mac_a   = a_reg;

                // Datapath performs TN MACs in parallel, so one cycle per nonzero.
                if (p + 1 < p_end) begin                               // if there's another non zero  in the row then back to NZ_FETCH
                    p_next        = p + 1;
                    next_nz_phase = NZ_PHASE_0;
                    next_state    = NZ_FETCH;
                end
                else begin                                             // if that was the last non zero value then to NEXT_ROW
                    next_state = NEXT_ROW;
                end
            end

            NEXT_ROW:
            begin
                if (i + 1 < M_reg) begin                               //if more rows are left the go back to ROW_LOAD
                    i_next     = i + 1;
                    next_state = ROW_LOAD;
                end
                else begin                                             //if we've done all the rows of B then go to WRITE_TILE
                    i_wb_next  = '0;
                    t_wb_next  = '0;
                    next_state = WRITE_TILE;
                end
            end

            WRITE_TILE:
            begin                                                          //configure datapath to write row i, column t of tile c
                dp_ctile_read_en  = 1'b1;                                  //back to memory
                dp_ctile_read_row = i_wb;
                dp_ctile_read_col = t_wb;

                dp_wb_en          = 1'b1;                                   // enable writeback to pipeline for further processing of c
                dp_wb_in          = dp_ctile_read_data;                     // this takes the value of c into the pipe to then produce "dp_wb_data_out"

                ram_addr  = idx_to_byte_addr(
                                out_base_reg,
                                (i_wb * N_reg) + (j0 + t_wb)
                            );                                             // storage address
                ram_we    = 1'b1;                                          // enable write to ram
                ram_wdata = dp_wb_data_out;                                // final output to store after Relu or other post processsing on output

                if (t_wb == TN-1) begin                                    //if we're done writing all the columns then set back to 0
                    t_wb_next = '0;

                    if (i_wb == M_reg - 1) begin                           //if we're done writing all the rows but we still have more tiles
                        if (j0 + TN < N_reg) begin                         //then move j0 to start of next tile and go to TILE_CLEAR
                            j0_next      = j0 + TN;
                            i_clear_next = '0;
                            t_clear_next = '0;
                            next_state   = INIT_TILE_CLEAR;
                        end
                        else begin                                         //if we've done all tiles for B and c then do to DONE
                            next_state = DONE;
                        end
                    end
                    else begin
                        i_wb_next = i_wb + 1;                               //if not then go to next row
                    end
                end
                else begin
                    t_wb_next = t_wb + 1;                                   //if not done then go to next column
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
