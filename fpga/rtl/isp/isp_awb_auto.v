module isp_awb_auto #(
    parameter IMG_HEIGHT = 720,
    parameter IMG_WIDTH  = 1280,

    parameter R_GAIN  = 333,
    parameter G_GAIN  = 256,
    parameter B_GAIN  = 358,
    parameter AUTO_EN = 1,

    parameter GAIN_MIN = 64,
    parameter GAIN_MAX = 512,

    parameter MIN_SUM = 32'h0001_0000,
    parameter BYPASS  = 0
) (
    input I_clk,
    input I_rst_n,

    input         I_tlast,
    input         I_tuser,
    input  [95:0] I_tdata,
    input         I_tvalid,
    output        I_tready,

    output        O_tlast,
    output        O_tuser,
    output [95:0] O_tdata,
    output        O_tvalid,
    input         O_tready
);

    function [7:0] f_apply;
        input [7:0] v;
        input [9:0] g;
        reg [17:0] p;
        begin
            p = v * g;
            f_apply = (p[17:8] > 8'd255) ? 8'hFF : p[15:8];
        end
    endfunction

    generate
        if (BYPASS != 0) begin : g_bypass
            reg v_d, l_d, u_d;
            reg [95:0] d_d;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    v_d <= 1'b0;
                    l_d <= 1'b0;
                    u_d <= 1'b0;
                    d_d <= 96'd0;
                end else begin
                    v_d <= I_tvalid;
                    l_d <= I_tlast;
                    u_d <= I_tuser;
                    d_d <= I_tdata;
                end
            end
            assign O_tvalid = v_d;
            assign O_tlast  = l_d;
            assign O_tuser  = u_d;
            assign O_tdata  = d_d;
            assign I_tready = O_tready;
        end else begin : g_awb

            reg [31:0] sum_r, sum_g, sum_b;
            wire [9:0] add_r = {2'd0, I_tdata[23:16]} + {2'd0, I_tdata[47:40]}
                         + {2'd0, I_tdata[71:64]} + {2'd0, I_tdata[95:88]};
            wire [9:0] add_g = {2'd0, I_tdata[15: 8]} + {2'd0, I_tdata[39:32]}
                         + {2'd0, I_tdata[63:56]} + {2'd0, I_tdata[87:80]};
            wire [9:0] add_b = {2'd0, I_tdata[ 7: 0]} + {2'd0, I_tdata[31:24]}
                         + {2'd0, I_tdata[55:48]} + {2'd0, I_tdata[79:72]};

            wire [31:0] sum_all = sum_r + sum_g + sum_b;
            wire sum_valid = (sum_r > MIN_SUM) && (sum_g > MIN_SUM) && (sum_b > MIN_SUM);

            reg [31:0] sum_r_l, sum_g_l, sum_b_l;
            wire [31:0] sum_all_l = sum_r_l + sum_g_l + sum_b_l;

            localparam DBITS = 38;
            reg [      1:0] div_state;
            reg [      1:0] div_ch;
            reg [DBITS-1:0] div_num;
            reg [     33:0] div_den;
            reg [     37:0] div_rem;
            reg [     11:0] div_quo;
            reg [      5:0] div_cnt;
            reg             calc_done;

            reg [9:0] smooth_r, smooth_g, smooth_b;
            reg [9:0] app_r, app_g, app_b;

            wire        div_run = (div_state == 2'd1);
            wire [38:0] rem_shift = {div_rem[36:0], div_num[DBITS-1-div_cnt[5:0]]};
            wire [38:0] den_ext = {5'd0, div_den};
            wire        ge = (rem_shift >= den_ext);
            wire [37:0] rem_sub = rem_shift[37:0] - {4'd0, div_den};

            function [9:0] f_clamp;
                input [11:0] q;
                begin
                    if (q > GAIN_MAX[11:0]) f_clamp = GAIN_MAX[9:0];
                    else if (q < GAIN_MIN[11:0]) f_clamp = GAIN_MIN[9:0];
                    else f_clamp = q[9:0];
                end
            endfunction

            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    sum_r <= 32'd0;
                    sum_g <= 32'd0;
                    sum_b <= 32'd0;
                    sum_r_l <= 32'd0;
                    sum_g_l <= 32'd0;
                    sum_b_l <= 32'd0;
                    div_state <= 2'd0;
                    div_ch <= 2'd0;
                    div_num <= 38'd0;
                    div_den <= 34'd0;
                    div_rem <= 38'd0;
                    div_quo <= 12'd0;
                    div_cnt <= 6'd0;
                    calc_done <= 1'b0;
                    smooth_r <= 10'd256;
                    smooth_g <= 10'd256;
                    smooth_b <= 10'd256;
                    app_r <= 10'd256;
                    app_g <= 10'd256;
                    app_b <= 10'd256;
                end else begin

                    if (I_tvalid) begin
                        sum_r <= sum_r + {22'd0, add_r};
                        sum_g <= sum_g + {22'd0, add_g};
                        sum_b <= sum_b + {22'd0, add_b};
`ifdef AWB_DBG
                        if (add_r != 10'd0)
                            $display(
                                "[%0t] acc: tvalid=%b tuser=%b add_r=%0d -> sum_r=%0d",
                                $time,
                                I_tvalid,
                                I_tuser,
                                add_r,
                                sum_r + {22'd0, add_r}
                            );
`endif
                    end

                    if (I_tuser) begin

                        if (calc_done) begin
                            app_r <= smooth_r;
                            app_g <= smooth_g;
                            app_b <= smooth_b;
                            calc_done <= 1'b0;
                        end

                        if (sum_valid) begin
                            sum_r_l   <= sum_r;
                            sum_g_l   <= sum_g;
                            sum_b_l   <= sum_b;
                            div_num   <= {sum_all[29:0], 8'd0};
                            div_den   <= {2'd0, sum_r, 1'b0} + {3'd0, sum_r};
                            div_ch    <= 2'd0;
                            div_cnt   <= 6'd0;
                            div_rem   <= 38'd0;
                            div_quo   <= 12'd0;
                            div_state <= 2'd1;
                        end
                        sum_r <= 32'd0;
                        sum_g <= 32'd0;
                        sum_b <= 32'd0;
                    end

                    case (div_state)
                        2'd1: begin
                            div_rem <= ge ? rem_sub : rem_shift[37:0];

                            if (ge && (div_cnt >= 6'd26)) div_quo[6'd37-div_cnt] <= 1'b1;
                            if (div_cnt == 6'd37) begin
                                div_cnt   <= 6'd0;
                                div_state <= 2'd2;
                            end else begin
                                div_cnt <= div_cnt + 6'd1;
                            end
                        end
                        2'd2: begin

                            case (div_ch)
                                2'd0:
                                smooth_r <= ({2'b00, f_clamp(
                                    div_quo
                                )} + {2'b00, smooth_r} * 3'd3) >> 2;
                                2'd1:
                                smooth_g <= ({2'b00, f_clamp(
                                    div_quo
                                )} + {2'b00, smooth_g} * 3'd3) >> 2;
                                default:
                                smooth_b <= ({2'b00, f_clamp(
                                    div_quo
                                )} + {2'b00, smooth_b} * 3'd3) >> 2;
                            endcase
                            if (div_ch == 2'd2) begin
                                div_state <= 2'd0;
                                calc_done <= 1'b1;
                            end else begin
                                div_ch <= div_ch + 2'd1;
                                if (div_ch == 2'd0) begin
                                    div_num <= {sum_all_l[29:0], 8'd0};
                                    div_den <= {2'd0, sum_g_l, 1'b0} + {3'd0, sum_g_l};
                                end else begin
                                    div_num <= {sum_all_l[29:0], 8'd0};
                                    div_den <= {2'd0, sum_b_l, 1'b0} + {3'd0, sum_b_l};
                                end
                                div_cnt   <= 6'd0;
                                div_rem   <= 38'd0;
                                div_quo   <= 12'd0;
                                div_state <= 2'd1;
                            end
                        end
                        default: ;
                    endcase
                end
            end

            wire [9:0] g_r = (AUTO_EN != 0) ? app_r : R_GAIN[9:0];
            wire [9:0] g_g = (AUTO_EN != 0) ? app_g : G_GAIN[9:0];
            wire [9:0] g_b = (AUTO_EN != 0) ? app_b : B_GAIN[9:0];

            wire [23:0] px0 = {
                f_apply(I_tdata[23:16], g_r),
                f_apply(I_tdata[15:8], g_g),
                f_apply(I_tdata[7:0], g_b)
            };
            wire [23:0] px1 = {
                f_apply(I_tdata[47:40], g_r),
                f_apply(I_tdata[39:32], g_g),
                f_apply(I_tdata[31:24], g_b)
            };
            wire [23:0] px2 = {
                f_apply(I_tdata[71:64], g_r),
                f_apply(I_tdata[63:56], g_g),
                f_apply(I_tdata[55:48], g_b)
            };
            wire [23:0] px3 = {
                f_apply(I_tdata[95:88], g_r),
                f_apply(I_tdata[87:80], g_g),
                f_apply(I_tdata[79:72], g_b)
            };

            reg v_d, l_d, u_d;
            reg [95:0] d_d;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    v_d <= 1'b0;
                    l_d <= 1'b0;
                    u_d <= 1'b0;
                    d_d <= 96'd0;
                end else begin
                    v_d <= I_tvalid;
                    l_d <= I_tlast;
                    u_d <= I_tuser;
                    d_d <= {px3, px2, px1, px0};
                end
            end
            assign O_tvalid = v_d;
            assign O_tlast  = l_d;
            assign O_tuser  = u_d;
            assign O_tdata  = d_d;
            assign I_tready = O_tready;
        end
    endgenerate

endmodule
