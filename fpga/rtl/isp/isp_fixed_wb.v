module isp_fixed_wb #(
    parameter IMG_HEIGHT = 720,
    parameter IMG_WIDTH  = 1280,

    parameter R_GAIN = 333,
    parameter G_GAIN = 256,
    parameter B_GAIN = 358,

    parameter BYPASS = 0
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
        reg [18:0] p;
        begin
            p = v * g;
            p = p >> 8;
            f_apply = (p > 19'd255) ? 8'hFF : p[7:0];
        end
    endfunction

    function [23:0] f_pixel;
        input [23:0] px;
        input byp;
        reg [7:0] r, g, b;
        begin
            r = px[16+:8];
            g = px[8+:8];
            b = px[0+:8];
            if (byp) f_pixel = px;
            else
                f_pixel = {
                    f_apply(r, R_GAIN[9:0]), f_apply(g, G_GAIN[9:0]), f_apply(b, B_GAIN[9:0])
                };
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
        end else begin : g_wb

            wire [23:0] px0 = f_pixel(I_tdata[23:0], 1'b0);
            wire [23:0] px1 = f_pixel(I_tdata[47:24], 1'b0);
            wire [23:0] px2 = f_pixel(I_tdata[71:48], 1'b0);
            wire [23:0] px3 = f_pixel(I_tdata[95:72], 1'b0);

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
        end
    endgenerate

    assign I_tready = O_tready;

endmodule
