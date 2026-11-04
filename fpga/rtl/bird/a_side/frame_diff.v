module frame_diff #(
    parameter FRAME_W = 320,
    FRAME_H = 240,
    THRESHOLD = 8'd30
) (
    input wire clk,
    rst_n,
    input wire [23:0] curr_pixel,
    prev_pixel,
    input wire curr_valid,
    output reg motion_bit,
    motion_valid
);
    function [7:0] gray;
        input [23:0] p;
        reg [15:0] r, g, b, sum;
        begin
            r = {8'd0, p[23:16]};
            g = {8'd0, p[15:8]};
            b = {8'd0, p[7:0]};
            sum=(r<<6)+(r<<3)+(r<<2)+r+(g<<7)+(g<<4)+(g<<2)+(g<<1)+(b<<4)+(b<<3)+(b<<2)+b;
            gray = sum[15:8];
        end
    endfunction
    reg [7:0] cg, pg;
    reg v;
    wire [7:0] difference = cg > pg ? cg - pg : pg - cg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cg <= 0;
            pg <= 0;
            v <= 0;
            motion_valid <= 0;
            motion_bit <= 0;
        end else begin
            v <= curr_valid;
            if (curr_valid) begin
                cg <= gray(curr_pixel);
                pg <= gray(prev_pixel);
            end
            motion_valid <= v;
            if (v) motion_bit <= difference >= THRESHOLD;
        end
    end
endmodule
