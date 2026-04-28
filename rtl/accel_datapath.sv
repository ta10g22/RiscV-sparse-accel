`timescale 1ns/1ps


module accel_datapath #(
    parameter int M_MAX      = 64,
    parameter int TN         = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                     clk,
    input  logic                     n_reset,


    input  logic                     clear_en,
    input  logic [$clog2(M_MAX)-1:0] clear_row,
    input  logic [$clog2(TN)-1:0]    clear_col,


    input  logic                     bseg_we,
    input  logic [$clog2(TN)-1:0]    bseg_idx,
    input  logic [DATA_WIDTH-1:0]    bseg_wdata,


    input  logic                     mac_en,
    input  logic [$clog2(M_MAX)-1:0] mac_row,
    input  logic [DATA_WIDTH-1:0]    mac_a,


    input  logic                     ctile_read_en,
    input  logic [$clog2(M_MAX)-1:0] ctile_read_row,
    input  logic [$clog2(TN)-1:0]    ctile_read_col,
    output logic [DATA_WIDTH-1:0]    ctile_read_data,


    input  logic                     relu_en,
    input  logic [3:0]               dtype,
    input  logic                     wb_en,
    input  logic [DATA_WIDTH-1:0]    wb_in,
    output logic [DATA_WIDTH-1:0]    wb_data_out
);


    logic signed [DATA_WIDTH-1:0] B_Seg  [TN-1:0];
    logic signed [DATA_WIDTH-1:0] C_Tile [M_MAX-1:0][TN-1:0];

    integer r, c;
    logic [31:0] bseg_base_u32;

    function automatic logic signed [DATA_WIDTH-1:0] signext_i8_from_word(
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

    always_comb begin
        bseg_base_u32 = 32'(bseg_idx);
    end

    always_ff @(posedge clk or negedge n_reset) begin
        if (!n_reset) begin
            for (c = 0; c < TN; c++) begin
                B_Seg[c] <= '0;
            end
            for (r = 0; r < M_MAX; r++) begin
                for (c = 0; c < TN; c++) begin
                    C_Tile[r][c] <= '0;
                end
            end
        end else begin

            if (clear_en) begin
                C_Tile[clear_row][clear_col] <= '0;
            end


            if (bseg_we) begin
                if (dtype[0]) begin

                    if (bseg_base_u32 < TN) begin
                        B_Seg[bseg_base_u32] <= signext_i8_from_word(bseg_wdata, 2'd0);
                    end
                    if ((bseg_base_u32 + 1) < TN) begin
                        B_Seg[bseg_base_u32 + 1] <= signext_i8_from_word(bseg_wdata, 2'd1);
                    end
                    if ((bseg_base_u32 + 2) < TN) begin
                        B_Seg[bseg_base_u32 + 2] <= signext_i8_from_word(bseg_wdata, 2'd2);
                    end
                    if ((bseg_base_u32 + 3) < TN) begin
                        B_Seg[bseg_base_u32 + 3] <= signext_i8_from_word(bseg_wdata, 2'd3);
                    end
                end else begin
                    B_Seg[bseg_idx] <= $signed(bseg_wdata);
                end
            end


            if (mac_en) begin

                for (c = 0; c < TN; c++) begin
                    C_Tile[mac_row][c] <=
                        $signed(C_Tile[mac_row][c]) +
                        ($signed(mac_a) * $signed(B_Seg[c]));
                end
            end
        end
    end


    always_comb begin
        if (ctile_read_en)
            ctile_read_data = C_Tile[ctile_read_row][ctile_read_col];
        else
            ctile_read_data = '0;
    end


    always_comb begin
        wb_data_out = wb_in;
        if (wb_en && relu_en) begin
            if ($signed(wb_in) < 0)
                wb_data_out = '0;
            else
                wb_data_out = wb_in;
        end
    end

endmodule
