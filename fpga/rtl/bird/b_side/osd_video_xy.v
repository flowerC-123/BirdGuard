module osd_video_xy #(
    parameter VS_ACTIVE = 1
) (
    input wire clk,
    rst_n,
    vs,
    de,
    output wire frame_start,
    output wire [11:0] x,
    y
);
    reg vs_d, de_d;
    reg [11:0] xx, yy;
    assign frame_start = (vs == VS_ACTIVE) && (vs_d != VS_ACTIVE);
    assign x = xx;
    assign y = yy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d <= !VS_ACTIVE;
            de_d <= 0;
            xx   <= 0;
            yy   <= 0;
        end else begin
            vs_d <= vs;
            de_d <= de;
            if (frame_start) begin
                xx <= 0;
                yy <= 0;
            end else if (de) xx <= xx + 1'b1;
            else if (de_d) begin
                xx <= 0;
                yy <= yy + 1'b1;
            end
        end
    end
endmodule
