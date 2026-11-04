module demosaic #(
    parameter IMG_HEIGHT          = 1080,
    parameter IMG_WIDTH           = 1920,
    parameter data_complete_delay = 50,
    parameter BAYER_MODE          = "BGGR"
) (
    input I_clk,
    input I_rst_n,

    input  [39:0] axi4s_video_tdata,
    input  [ 9:0] axi4s_video_tdest,
    input         axi4s_video_tlast,
    input         axi4s_video_tvalid,
    input         axi4s_video_tuser,
    output        axi4s_video_tready,

    output         O_tlast,
    output         O_tuser,
    output [127:0] O_tdata,
    output         O_tvalid,
    input          O_tready
);

    wire        demosaic_tlast;
    wire        demosaic_tuser;
    wire        demosaic_tvalid;
    wire        demosaic_tready;

    wire        bayer_ypos;
    wire [95:0] matrix_last_line;
    wire [95:0] matrix_cur_line;
    wire [95:0] matrix_next_line;

    raw_matrix_3x3_buffer #(
        .IMG_HEIGHT         (IMG_HEIGHT),
        .IMG_WIDTH          (IMG_WIDTH),
        .data_complete_delay(data_complete_delay)
    ) raw_matrix_3x3_buffer_d (
        .I_clk  (I_clk),
        .I_rst_n(I_rst_n),

        .axi4s_video_tdata (axi4s_video_tdata),
        .axi4s_video_tdest (axi4s_video_tdest),
        .axi4s_video_tlast (axi4s_video_tlast),
        .axi4s_video_tvalid(axi4s_video_tvalid),
        .axi4s_video_tuser (axi4s_video_tuser),
        .axi4s_video_tready(axi4s_video_tready),

        .O_tlast (demosaic_tlast),
        .O_tuser (demosaic_tuser),
        .O_tvalid(demosaic_tvalid),
        .O_tready(demosaic_tready),

        .bayer_ypos      (bayer_ypos),
        .matrix_last_line(matrix_last_line),
        .matrix_cur_line (matrix_cur_line),
        .matrix_next_line(matrix_next_line)
    );

    bilinear_interpolation #(
        .BAYER_MODE(BAYER_MODE)
    ) bilinear_interpolation_d (
        .I_clk  (I_clk),
        .I_rst_n(I_rst_n),

        .I_tlast (demosaic_tlast),
        .I_tuser (demosaic_tuser),
        .I_tvalid(demosaic_tvalid),
        .I_tready(demosaic_tready),

        .bayer_ypos      (bayer_ypos),
        .matrix_last_line(matrix_last_line),
        .matrix_cur_line (matrix_cur_line),
        .matrix_next_line(matrix_next_line),

        .O_tlast (O_tlast),
        .O_tuser (O_tuser),
        .O_tdata (O_tdata),
        .O_tvalid(O_tvalid),
        .O_tready(O_tready)

    );

endmodule
