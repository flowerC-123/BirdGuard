module ccl_selfview #(
    parameter SOURCE_W  = 320,
    parameter SOURCE_H  = 240,
    parameter DISPLAY_W = 1280,
    parameter DISPLAY_H = 720
) (
    input wire clk,
    input wire rst_n,

    input wire [ 3:0] cclv_index,
    input wire [ 9:0] cclv_x0,
    input wire [ 9:0] cclv_x1,
    input wire [ 8:0] cclv_y0,
    input wire [ 8:0] cclv_y1,
    input wire [16:0] cclv_area,
    input wire        cclv_valid,
    input wire        cclv_done,
    input wire [ 3:0] cclv_count,

    input  wire         mailbox_ready,
    output reg          send,
    output reg  [596:0] payload
);

    wire    [ 11:0] dx0 = {cclv_x0, 2'b00};
    wire    [ 11:0] dx1 = {cclv_x1, 2'b00} + 12'd3;
    wire    [ 11:0] dy0 = cclv_y0 * 3;
    wire    [ 11:0] dy1 = cclv_y1 * 3 + 12'd2;
    wire    [ 15:0] tw = {6'd0, cclv_x1} - {6'd0, cclv_x0} + 16'd1;

    reg     [127:0] slot_q                                         [0:3];
    reg     [ 31:0] frame_cnt;
    reg             dirty;
    reg             done_d1;

    wire    [ 20:0] info_f = {1'b1, 16'd205, 4'd0};

    integer         i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) slot_q[i] <= 128'd0;
            frame_cnt <= 32'd0;
            dirty     <= 1'b0;
            send      <= 1'b0;
            done_d1   <= 1'b0;
            payload   <= 597'd0;
        end else begin
            if (send) dirty <= 1'b0;

            done_d1 <= cclv_done;
            if (done_d1) begin
                for (i = 0; i < 4; i = i + 1) slot_q[i] <= 128'd0;
            end

            if (cclv_valid && cclv_index < 4'd4) begin
                slot_q[cclv_index[1:0]] <= {
                    1'b0, frame_cnt, 7'd100, 3'd1, 3'd0, cclv_area, tw, dy1, dx1, dy0, dx0, 1'b1
                };
            end

            if (cclv_done) begin
                frame_cnt <= frame_cnt + 32'd1;
                dirty     <= 1'b1;
            end

            send    <= dirty && mailbox_ready && !send;
            payload <= {info_f, 32'd0, frame_cnt,
                        slot_q[3], slot_q[2], slot_q[1], slot_q[0]};
        end
    end
endmodule
