module pattern_bg #(
    parameter H_ACTIVE = 1280,
    parameter V_ACTIVE = 720,
    parameter FW       = 320,
    parameter FH       = 240,
    parameter BLK_W    = 40,
    parameter BLK_H    = 30
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        vs,
    input  wire [15:0] blk_x,
    output wire [23:0] rgb
);

    localparam [7:0] BG_GRAY = 8'h50;
    localparam [7:0] BLK_GRAY = 8'hC0;
    localparam [15:0] BLK_Y = (FH - BLK_H) / 2;

    reg [11:0] x_cnt;
    reg [ 9:0] y_cnt;
    reg [ 1:0] sub;
    reg [ 7:0] ly;
    reg        de_d;

    reg [15:0] bx_s1, bx_s2;
    reg [15:0] bx_lat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bx_s1  <= 16'd0;
            bx_s2  <= 16'd0;
            bx_lat <= 16'd0;
        end else begin
            bx_s1 <= blk_x;
            bx_s2 <= bx_s1;
            if (vs) bx_lat <= bx_s2;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 12'd0;
            y_cnt <= 10'd0;
            sub <= 2'd0;
            ly <= 8'd0;
            de_d <= 1'b0;
        end else begin
            de_d <= de;
            if (vs) begin
                x_cnt <= 12'd0;
                y_cnt <= 10'd0;
                sub <= 2'd0;
                ly <= 8'd0;
            end else if (de) begin
                x_cnt <= x_cnt + 12'd1;
            end else if (de_d) begin

                x_cnt <= 12'd0;
                if (y_cnt == V_ACTIVE - 1) y_cnt <= 10'd0;
                else y_cnt <= y_cnt + 10'd1;
                if (sub == 2'd2) begin
                    sub <= 2'd0;
                    ly  <= (ly == FH - 1) ? 8'd0 : ly + 8'd1;
                end else begin
                    sub <= sub + 2'd1;
                end
            end
        end
    end

    wire [8:0] lx = x_cnt[11:2];
    wire [15:0] lx_ext = {7'd0, lx};
    wire        in_blk  = (lx_ext >= bx_lat) && (lx_ext < bx_lat + BLK_W) &&
                          ({8'd0, ly} >= BLK_Y) && ({8'd0, ly} < BLK_Y + BLK_H);

    assign rgb = de ? (in_blk ? {BLK_GRAY, BLK_GRAY, BLK_GRAY}
                              : {BG_GRAY,  BG_GRAY,  BG_GRAY})
                    : 24'd0;

endmodule
