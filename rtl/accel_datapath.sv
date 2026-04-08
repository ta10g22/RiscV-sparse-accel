`timescale 1ns/1ps

//This datapath module is responsible for the multiply and accumulate functionality
// of the fsm. it get's data and control from accel_ctrl module

module accel_datapath #(
    parameter int M_MAX      = 64,
    parameter int TN         = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                     clk,
    input  logic                     n_reset,

    // tile clear
    input  logic                     clear_en,
    input  logic [$clog2(M_MAX)-1:0] clear_row,
    input  logic [$clog2(TN)-1:0]    clear_col,

    // B_seg load
    input  logic                     bseg_we,
    input  logic [$clog2(TN)-1:0]    bseg_idx,
    input  logic [DATA_WIDTH-1:0]    bseg_wdata,

    // MAC
    input  logic                     mac_en,
    input  logic [$clog2(M_MAX)-1:0] mac_row,
    input  logic [DATA_WIDTH-1:0]    mac_a,

    // C_tile read for writeback
    input  logic                     ctile_read_en,
    input  logic [$clog2(M_MAX)-1:0] ctile_read_row,
    input  logic [$clog2(TN)-1:0]    ctile_read_col,
    output logic [DATA_WIDTH-1:0]    ctile_read_data,

    // Postprocess / WB pipe
    input  logic                     relu_en,
    input  logic [3:0]               dtype,       // not used yet
    input  logic                     wb_en,
    input  logic [DATA_WIDTH-1:0]    wb_in,
    output logic [DATA_WIDTH-1:0]    wb_data_out
);

    // Local buffers (signed so negatives work correctly)
    logic signed [DATA_WIDTH-1:0] B_Seg  [TN-1:0];
    logic signed [DATA_WIDTH-1:0] C_Tile [M_MAX-1:0][TN-1:0];

    integer r, c;

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
            // ctile clear when clear_en is active
            if (clear_en) begin
                C_Tile[clear_row][clear_col] <= '0;
            end

            // write into bseg
            if (bseg_we) begin
                B_Seg[bseg_idx] <= $signed(bseg_wdata);
            end

            // multiply and accumulate logic
            if (mac_en) begin
                // One nonzero in A updates the full output tile row in parallel.
                for (c = 0; c < TN; c++) begin
                    C_Tile[mac_row][c] <=
                        $signed(C_Tile[mac_row][c]) +
                        ($signed(mac_a) * $signed(B_Seg[c]));
                end
            end
        end
    end

    // read tile index
    always_comb begin
        if (ctile_read_en)
            ctile_read_data = C_Tile[ctile_read_row][ctile_read_col];
        else
            ctile_read_data = '0;
    end

    // processing of relu on wb_in
    always_comb begin
        wb_data_out = wb_in;  // default passthrough
        if (wb_en && relu_en) begin
            if ($signed(wb_in) < 0)
                wb_data_out = '0;
            else
                wb_data_out = wb_in;
        end
    end

endmodule
