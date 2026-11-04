module cam_pattern_gen #(
    parameter FW        = 320,
    parameter FH        = 240,
    parameter BLK_W     = 40,
    parameter BLK_H     = 30,
    parameter MOVE_STEP = 3,
    parameter PIX_DIV   = 22
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [23:0] cam_pixel,
    output reg         cam_valid,
    output reg         cam_frame_start,
    output reg         cam_frame_end
);

    localparam BG_GRAY   = 8'h50;
    localparam BLK_GRAY  = 8'hC0;
    localparam MAX_BLK_X = FW - BLK_W;
    localparam BLK_Y     = (FH - BLK_H) / 2;

    reg [15:0] x, y;
    reg [7:0] div;
    reg [15:0] frame_cnt;
    reg [15:0] blk_x;

    wire step = (div == 8'd0);
    wire last_pix = (x == FW - 1) && (y == FH - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_x <= 16'd0;
        end else if (cam_frame_end) begin
            if (blk_x + MOVE_STEP >= MAX_BLK_X) blk_x <= 16'd0;
            else blk_x <= blk_x + MOVE_STEP;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 16'd0;
            y <= 16'd0;
            div <= 8'd0;
            frame_cnt <= 16'd0;
            cam_valid <= 1'b0;
            cam_frame_start <= 1'b0;
            cam_frame_end <= 1'b0;
            cam_pixel <= 24'd0;
        end else begin
            cam_frame_start <= 1'b0;
            cam_frame_end   <= 1'b0;

            if (div == PIX_DIV - 1) div <= 8'd0;
            else div <= div + 8'd1;

            if (step) begin

                if ((x >= blk_x) && (x < blk_x + BLK_W) && (y >= BLK_Y) && (y < BLK_Y + BLK_H))
                    cam_pixel <= {BLK_GRAY, BLK_GRAY, BLK_GRAY};
                else cam_pixel <= {BG_GRAY, BG_GRAY, BG_GRAY};

                cam_valid <= 1'b1;

                if (x == 16'd0 && y == 16'd0) cam_frame_start <= 1'b1;

                if (last_pix) begin
                    cam_frame_end <= 1'b1;
                    frame_cnt <= frame_cnt + 16'd1;
                    x <= 16'd0;
                    y <= 16'd0;
                end else if (x == FW - 1) begin
                    x <= 16'd0;
                    y <= y + 16'd1;
                end else begin
                    x <= x + 16'd1;
                end
            end else begin
                cam_valid <= 1'b0;
            end
        end
    end

endmodule
