module motion_bbox #(
    parameter FRAME_W = 320,
    parameter FRAME_H = 240
) (
    input wire clk,
    input wire rst_n,

    input wire motion_bit,
    input wire pixel_valid,
    input wire frame_start,

    output reg [ 9:0] min_x,
    output reg [ 9:0] max_x,
    output reg [ 8:0] min_y,
    output reg [ 8:0] max_y,
    output reg [16:0] motion_count,
    output reg        bbox_valid
);

    reg  [ 9:0] x_cnt;
    reg  [ 8:0] y_cnt;

    reg  [ 9:0] int_min_x;
    reg  [ 9:0] int_max_x;
    reg  [ 8:0] int_min_y;
    reg  [ 8:0] int_max_y;
    reg  [16:0] int_count;
    reg         found_any;

    wire        is_last_pixel = (x_cnt == FRAME_W - 1) && (y_cnt == FRAME_H - 1) && pixel_valid;

    wire [ 9:0] px = frame_start ? 10'd0 : x_cnt;
    wire [ 8:0] py = frame_start ? 9'd0 : y_cnt;

    wire [ 9:0] eff_min_x = frame_start ? (FRAME_W - 1) : int_min_x;
    wire [ 9:0] eff_max_x = frame_start ? 10'd0 : int_max_x;
    wire [ 8:0] eff_min_y = frame_start ? (FRAME_H - 1) : int_min_y;
    wire [ 8:0] eff_max_y = frame_start ? 9'd0 : int_max_y;
    wire [16:0] eff_count = frame_start ? 17'd0 : int_count;

    reg         last_pix_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 10'd0;
            y_cnt <= 9'd0;
        end else begin
            if (frame_start) begin
                x_cnt <= pixel_valid ? 10'd1 : 10'd0;
                y_cnt <= 9'd0;
            end else if (pixel_valid) begin
                if (x_cnt == FRAME_W - 1) begin
                    x_cnt <= 10'd0;
                    if (y_cnt == FRAME_H - 1) y_cnt <= 9'd0;
                    else y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_min_x    <= 10'd0;
            int_max_x    <= 10'd0;
            int_min_y    <= 9'd0;
            int_max_y    <= 9'd0;
            int_count    <= 17'd0;
            found_any    <= 1'b0;
            min_x        <= 10'd0;
            max_x        <= 10'd0;
            min_y        <= 9'd0;
            max_y        <= 9'd0;
            motion_count <= 17'd0;
            bbox_valid   <= 1'b0;
            last_pix_d   <= 1'b0;
        end else begin
            bbox_valid <= 1'b0;
            last_pix_d <= is_last_pixel;

            if (frame_start) begin
                int_min_x <= FRAME_W - 1;
                int_max_x <= 10'd0;
                int_min_y <= FRAME_H - 1;
                int_max_y <= 9'd0;
                int_count <= 17'd0;
                found_any <= 1'b0;
            end

            if (pixel_valid && motion_bit) begin
                int_count <= eff_count + 1'b1;
                found_any <= 1'b1;

                if (px < eff_min_x) int_min_x <= px;
                if (px > eff_max_x) int_max_x <= px;
                if (py < eff_min_y) int_min_y <= py;
                if (py > eff_max_y) int_max_y <= py;
            end

            if (last_pix_d) begin
                if (found_any) begin
                    min_x        <= int_min_x;
                    max_x        <= int_max_x;
                    min_y        <= int_min_y;
                    max_y        <= int_max_y;
                    motion_count <= int_count;
                end else begin

                    min_x        <= 10'd0;
                    max_x        <= 10'd0;
                    min_y        <= 9'd0;
                    max_y        <= 9'd0;
                    motion_count <= 17'd0;
                end
                bbox_valid <= 1'b1;
            end
        end
    end

endmodule
