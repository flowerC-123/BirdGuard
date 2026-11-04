module disp_denoise #(
    parameter IMG_W  = 1280,
    parameter ENABLE = 1
) (
    input wire clk,
    input wire rst_n,

    input wire        de,
    input wire        hs,
    input wire        vs,
    input wire [23:0] din,

    output reg        de_o,
    output reg        hs_o,
    output reg        vs_o,
    output reg [23:0] dout
);

    generate
        if (ENABLE == 0) begin : g_bypass
            reg [23:0] d_d;
            reg de_d, hs_d, vs_d;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    de_d <= 1'b0;
                    hs_d <= 1'b0;
                    vs_d <= 1'b0;
                    d_d  <= 24'd0;
                end else begin
                    de_d <= de;
                    hs_d <= hs;
                    vs_d <= vs;
                    d_d  <= din;
                end
            end
            always @(*) begin
                de_o = de_d;
                hs_o = hs_d;
                vs_o = vs_d;
                dout = d_d;
            end
        end else begin : g_dn

            wire [ 7:0] y_c = {2'd0, din[23:18]} + {1'b0, din[15:9]} + {2'd0, din[7:2]};

            reg  [10:0] xcnt;
            reg         de_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    xcnt <= 11'd0;
                    de_r <= 1'b0;
                end else begin
                    de_r <= de;
                    if (de) xcnt <= (xcnt == IMG_W - 1) ? 11'd0 : xcnt + 11'd1;
                    else xcnt <= 11'd0;
                end
            end

            reg row_par, previous_row_valid, vs_seen;
            reg [3:0] row_valid_delay;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    row_par <= 0;
                    previous_row_valid <= 0;
                    vs_seen <= 0;
                    row_valid_delay <= 0;
                end else begin
                    vs_seen <= vs;
                    row_valid_delay <= {row_valid_delay[2:0], previous_row_valid};
                    if (vs != vs_seen) begin
                        row_par <= 0;
                        previous_row_valid <= 0;
                    end else if (de_r && !de) begin
                        row_par <= ~row_par;
                        previous_row_valid <= 1;
                    end
                end
            end

            reg [ 7:0] y_r;
            reg [10:0] x_r;

            (* ram_style = "bram" *)
            reg [ 7:0] line_buf[0:2*IMG_W-1];

            localparam [11:0] W12 = IMG_W;
            wire [11:0] addr_c = {1'b0, xcnt};
            wire [11:0] wr_addr = addr_c + (row_par ? W12 : 12'd0);
            wire [11:0] rd_addr = addr_c + (row_par ? 12'd0 : W12);

            reg  [ 7:0] rd_data;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    y_r <= 8'd0;
                    x_r <= 11'd0;
                end else begin
                    y_r <= y_c;
                    x_r <= xcnt;

                    if (de) begin
                        line_buf[wr_addr] <= y_c;
                        rd_data <= line_buf[rd_addr];
                    end
                end
            end

            reg [7:0] cur_a;
            reg [7:0] prv_a;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cur_a <= 8'd0;
                    prv_a <= 8'd0;
                end else begin
                    cur_a <= y_r;
                    prv_a <= rd_data;
                end
            end

            reg [7:0] cur_s0, cur_s1, cur_s2;
            reg [7:0] prv_s0, prv_s1, prv_s2;
            reg [10:0] x_s1;
            reg [10:0] x_d1, x_d2;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    {cur_s0, cur_s1, cur_s2} <= 24'd0;
                    {prv_s0, prv_s1, prv_s2} <= 24'd0;
                    x_s1 <= 11'd0;
                    x_d1 <= 11'd0;
                    x_d2 <= 11'd0;
                end else begin
                    cur_s0 <= cur_a;
                    cur_s1 <= cur_s0;
                    cur_s2 <= cur_s1;
                    prv_s0 <= prv_a;
                    prv_s1 <= prv_s0;
                    prv_s2 <= prv_s1;
                    x_d1   <= x_r;
                    x_d2   <= x_d1;
                    x_s1   <= x_d2;
                end
            end

            reg [23:0] rgb_d1, rgb_d2, rgb_d3, rgb_d4;
            reg de_d1, de_d2, de_d3, de_d4;
            reg hs_d1, hs_d2, hs_d3, hs_d4;
            reg vs_d1, vs_d2, vs_d3, vs_d4;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    {rgb_d1, rgb_d2, rgb_d3, rgb_d4} <= 96'd0;
                    de_d1 <= 1'b0;
                    de_d2 <= 1'b0;
                    de_d3 <= 1'b0;
                    de_d4 <= 1'b0;
                    hs_d1 <= 1'b0;
                    hs_d2 <= 1'b0;
                    hs_d3 <= 1'b0;
                    hs_d4 <= 1'b0;
                    vs_d1 <= 1'b0;
                    vs_d2 <= 1'b0;
                    vs_d3 <= 1'b0;
                    vs_d4 <= 1'b0;
                end else begin
                    rgb_d1 <= din;
                    rgb_d2 <= rgb_d1;
                    rgb_d3 <= rgb_d2;
                    rgb_d4 <= rgb_d3;
                    de_d1  <= de;
                    de_d2  <= de_d1;
                    de_d3  <= de_d2;
                    de_d4  <= de_d3;
                    hs_d1  <= hs;
                    hs_d2  <= hs_d1;
                    hs_d3  <= hs_d2;
                    hs_d4  <= hs_d3;
                    vs_d1  <= vs;
                    vs_d2  <= vs_d1;
                    vs_d3  <= vs_d2;
                    vs_d4  <= vs_d3;
                end
            end

            wire [7:0] p_l = (x_s1 == 11'd0) ? prv_s1 : prv_s2;
            wire [7:0] c_l = (x_s1 == 11'd0) ? cur_s1 : cur_s2;
            wire [7:0] p_r = (x_s1 == IMG_W - 1) ? prv_s1 : prv_s0;
            wire [7:0] c_r = (x_s1 == IMG_W - 1) ? cur_s1 : cur_s0;

            wire [10:0] sum6 = {3'd0, p_l} + {3'd0, prv_s1} + {3'd0, p_r}
                         + {3'd0, c_l} + {3'd0, cur_s1} + {3'd0, c_r};

            wire [15:0] avg6 = sum6 * 8'd43;
            wire signed [9:0] err = $signed({3'd0, avg6[15:8]}) - $signed({3'd0, cur_s1});

            wire [1:0] shift = cur_s1[7:6];
            wire signed [9:0] e0 = (shift == 2'd0) ? err :
                              (shift == 2'd1) ? (err >>> 1) :
                              (shift == 2'd2) ? (err >>> 2) : (err >>> 3);

            function [7:0] f_add_sat;
                input [7:0] v;
                input signed [9:0] e;
                reg signed [10:0] t;
                begin
                    t = $signed({2'd0, v}) + e;
                    if (t < 0) f_add_sat = 8'd0;
                    else if (t > 255) f_add_sat = 8'd255;
                    else f_add_sat = t[7:0];
                end
            endfunction

            wire [23:0] rgb_app = {
                f_add_sat(rgb_d4[23:16], e0),
                f_add_sat(rgb_d4[15:8], e0),
                f_add_sat(rgb_d4[7:0], e0)
            };

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    de_o <= 1'b0;
                    hs_o <= 1'b0;
                    vs_o <= 1'b0;
                    dout <= 24'd0;
                end else begin
                    de_o <= de_d4;
                    hs_o <= hs_d4;
                    vs_o <= vs_d4;
                    dout <= row_valid_delay[3] ? rgb_app : rgb_d4;
                end
            end

        end
    endgenerate

endmodule
