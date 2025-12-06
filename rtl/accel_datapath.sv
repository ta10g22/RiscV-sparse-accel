//this is the heart of the accelerator doing the matrix multiplication and storing results

module accel_datapath #(
    parameter int M_MAX      = 64,
    parameter int TN         = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,

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
    input  logic [$clog2(TN)-1:0]    mac_col,
    input  logic [DATA_WIDTH-1:0]    mac_a,

    // C_tile read for writeback
    input  logic                     ctile_read_en,
    input  logic [$clog2(M_MAX)-1:0] ctile_read_row,
    input  logic [$clog2(TN)-1:0]    ctile_read_col,
    output logic [DATA_WIDTH-1:0]    ctile_read_data,

    // ReLU / dtype + final WB path
    input  logic                     relu_en,
    input  logic [3:0]               dtype,
    input  logic                     wb_en,
    input  logic [DATA_WIDTH-1:0]    wb_in,
    output logic [DATA_WIDTH-1:0]    wb_data_out
);

    // C_tile storage: M_MAX x TN
    logic [DATA_WIDTH-1:0] C_tile [0:M_MAX-1][0:TN-1];

    // B segment storage: TN
    logic [DATA_WIDTH-1:0] B_seg  [0:TN-1];

    int r, c;

    // Sequential updates
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < M_MAX; r = r + 1) begin
                for (c = 0; c < TN; c = c + 1) begin
                    C_tile[r][c] <= '0;
                end
            end
            for (c = 0; c < TN; c = c + 1) begin
                B_seg[c] <= '0;
            end
        end
        else begin
            if (clear_en)
                C_tile[clear_row][clear_col] <= '0;

            if (bseg_we)
                B_seg[bseg_idx] <= bseg_wdata;

            if (mac_en)
                C_tile[mac_row][mac_col] <= C_tile[mac_row][mac_col] + mac_a * B_seg[mac_col];
        end
    end

    // C_tile read for writeback (combinational)
    always_comb begin
        if (ctile_read_en)
            ctile_read_data = C_tile[ctile_read_row][ctile_read_col];
        else
            ctile_read_data = '0;
    end

    // ReLU + dtype handling (for now: ignore dtype, just optional ReLU)
    always_comb begin
        logic [DATA_WIDTH-1:0] tmp;
        tmp = wb_in;

        if (relu_en && tmp[DATA_WIDTH-1])
            tmp = '0;

        wb_data_out = tmp;
    end

endmodule
