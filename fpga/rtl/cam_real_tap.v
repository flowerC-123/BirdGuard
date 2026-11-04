module cam_real_tap #(
    parameter SRC_W = 1280,
    parameter SRC_H = 720,
    parameter DST_W = 320,
    parameter DST_H = 240
) (

    input wire        src_clk,
    input wire        src_rst_n,
    input wire [23:0] src_rgb,
    input wire        src_de,
    input wire        src_user,
    input wire        src_last,

    input  wire        dst_clk,
    input  wire        dst_rst_n,
    output reg  [23:0] cam_pixel,
    output reg         cam_valid,
    output reg         cam_frame_start,
    output reg         cam_frame_end
);

    localparam integer XCNT_W = $clog2(SRC_W);
    localparam integer YCNT_W = $clog2(SRC_H);
    localparam integer KX_W   = $clog2(DST_W);
    localparam integer KY_W   = $clog2(DST_H);

    reg [XCNT_W-1:0] x_cnt;
    reg [YCNT_W-1:0] y_cnt;
    reg [       1:0] y_mod3;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            x_cnt  <= {XCNT_W{1'b0}};
            y_cnt  <= {YCNT_W{1'b0}};
            y_mod3 <= 2'd0;
        end else if (src_user) begin
            x_cnt  <= {XCNT_W{1'b0}};
            y_cnt  <= {YCNT_W{1'b0}};
            y_mod3 <= 2'd0;
        end else if (src_de) begin
            if (src_last) begin
                x_cnt  <= {XCNT_W{1'b0}};
                y_cnt  <= y_cnt + 1'b1;
                y_mod3 <= (y_mod3 == 2'd2) ? 2'd0 : (y_mod3 + 2'd1);
            end else begin
                x_cnt <= x_cnt + 1'b1;
            end
        end
    end

    wire            keep_col = (x_cnt[1:0] == 2'b00);
    wire            keep_row = (y_mod3 == 2'd0);
    wire            keep = src_de && keep_col && keep_row;

    wire [KX_W-1:0] kx = x_cnt[XCNT_W-1:2];
    reg  [KY_W-1:0] ky;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            ky <= {KY_W{1'b0}};
        end else if (src_user) begin
            ky <= {KY_W{1'b0}};
        end else if (src_de && src_last && keep_row) begin
            ky <= ky + 1'b1;
        end
    end

    wire is_first = keep && (kx == {KX_W{1'b0}}) && (ky == {KY_W{1'b0}});
    wire is_last = keep && (kx == DST_W - 1) && (ky == DST_H - 1);

    wire [7:0] r_in = src_rgb[23:16];
    wire [7:0] g_in = src_rgb[15:8];
    wire [7:0] b_in = src_rgb[7:0];
    wire [15:0] gray_raw =
        ({8'd0, r_in} << 6) + ({8'd0, r_in} << 3) + ({8'd0, r_in} << 2) + {8'd0, r_in} +
        ({8'd0, g_in} << 7) + ({8'd0, g_in} << 4) + ({8'd0, g_in} << 2) + ({8'd0, g_in} << 1) +
        ({8'd0, b_in} << 4) + ({8'd0, b_in} << 3) + ({8'd0, b_in} << 2) +  {8'd0, b_in};
    wire [7:0] gray = gray_raw[15:8];

    wire [9:0] fifo_wdata = {gray, is_first, is_last};
    wire fifo_we = keep;

    wire [9:0] fifo_rdata;
    wire fifo_rd_valid;
    wire fifo_empty;
    wire fifo_re = !fifo_empty;

    soft_fifo_al_4057d6b76aa6 #(
        .DATA_WIDTH_W (10),
        .DATA_WIDTH_R (10),
        .ADDR_WIDTH_W (4),
        .ADDR_WIDTH_R (4),
        .AL_FULL_NUM  (14),
        .AL_EMPTY_NUM (1),
        .SHOW_AHEAD_EN(0),
        .OUTREG_EN    ("NOREG")
    ) u_cdc_fifo (
        .rst       (!src_rst_n || !dst_rst_n),
        .clkw      (src_clk),
        .clkr      (dst_clk),
        .we        (fifo_we),
        .di        (fifo_wdata),
        .re        (fifo_re),
        .dout      (fifo_rdata),
        .valid     (fifo_rd_valid),
        .full_flag (),
        .empty_flag(fifo_empty),
        .afull     (),
        .aempty    (),
        .wrusedw   (),
        .rdusedw   ()
    );

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            cam_pixel       <= 24'd0;
            cam_valid       <= 1'b0;
            cam_frame_start <= 1'b0;
            cam_frame_end   <= 1'b0;
        end else if (fifo_rd_valid) begin
            cam_pixel       <= {fifo_rdata[9:2], fifo_rdata[9:2], fifo_rdata[9:2]};
            cam_valid       <= 1'b1;
            cam_frame_start <= fifo_rdata[1];
            cam_frame_end   <= fifo_rdata[0];
        end else begin
            cam_valid       <= 1'b0;
            cam_frame_start <= 1'b0;
            cam_frame_end   <= 1'b0;
        end
    end

endmodule
