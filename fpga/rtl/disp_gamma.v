module disp_gamma #(
    parameter ENHANCE  = 1,
    parameter CONTRAST = 20,
    parameter BRIGHT   = 0
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

    function [7:0] f_ct;
        input [7:0] v;
        reg signed [10:0] d;
        reg signed [14:0] p;
        begin
            d = $signed({3'd0, v}) - $signed(11'd128);
            p = 15'sd0;
            if (CONTRAST[0]) p = p + (d);
            if (CONTRAST[1]) p = p + (d <<< 1);
            if (CONTRAST[2]) p = p + (d <<< 2);
            if (CONTRAST[3]) p = p + (d <<< 3);
            if (CONTRAST[4]) p = p + (d <<< 4);
            p = (p >>> 4) + $signed(15'd128) + $signed({{7{BRIGHT[7]}}, BRIGHT});
            if (p[14]) f_ct = 8'd0;
            else if (p > 15'd255) f_ct = 8'd255;
            else f_ct = p[7:0];
        end
    endfunction

    function [15:0] f_seg;
        input [7:0] v;
        case (v[7:3])
            5'd0: f_seg = {8'd0, 8'd53};
            5'd1: f_seg = {8'd53, 8'd19};
            5'd2: f_seg = {8'd72, 8'd15};
            5'd3: f_seg = {8'd87, 8'd12};
            5'd4: f_seg = {8'd99, 8'd11};
            5'd5: f_seg = {8'd110, 8'd9};
            5'd6: f_seg = {8'd119, 8'd9};
            5'd7: f_seg = {8'd128, 8'd8};
            5'd8: f_seg = {8'd136, 8'd8};
            5'd9: f_seg = {8'd144, 8'd7};
            5'd10: f_seg = {8'd151, 8'd6};
            5'd11: f_seg = {8'd157, 8'd7};
            5'd12: f_seg = {8'd164, 8'd6};
            5'd13: f_seg = {8'd170, 8'd5};
            5'd14: f_seg = {8'd175, 8'd6};
            5'd15: f_seg = {8'd181, 8'd5};
            5'd16: f_seg = {8'd186, 8'd6};
            5'd17: f_seg = {8'd192, 8'd5};
            5'd18: f_seg = {8'd197, 8'd5};
            5'd19: f_seg = {8'd202, 8'd4};
            5'd20: f_seg = {8'd206, 8'd5};
            5'd21: f_seg = {8'd211, 8'd4};
            5'd22: f_seg = {8'd215, 8'd5};
            5'd23: f_seg = {8'd220, 8'd4};
            5'd24: f_seg = {8'd224, 8'd4};
            5'd25: f_seg = {8'd228, 8'd4};
            5'd26: f_seg = {8'd232, 8'd4};
            5'd27: f_seg = {8'd236, 8'd4};
            5'd28: f_seg = {8'd240, 8'd4};
            5'd29: f_seg = {8'd244, 8'd4};
            5'd30: f_seg = {8'd248, 8'd4};
            default: f_seg = {8'd252, 8'd4};
        endcase
    endfunction

    function [7:0] f_gamma;
        input [7:0] v;
        reg [15:0] s;
        reg [ 9:0] t;
        begin
            if (v < 8'd16) begin

                case (v[3:0])
                    4'd0: f_gamma = 8'd0;
                    4'd1: f_gamma = 8'd21;
                    4'd2: f_gamma = 8'd28;
                    4'd3: f_gamma = 8'd34;
                    4'd4: f_gamma = 8'd39;
                    4'd5: f_gamma = 8'd43;
                    4'd6: f_gamma = 8'd46;
                    4'd7: f_gamma = 8'd50;
                    4'd8: f_gamma = 8'd53;
                    4'd9: f_gamma = 8'd56;
                    4'd10: f_gamma = 8'd58;
                    4'd11: f_gamma = 8'd61;
                    4'd12: f_gamma = 8'd64;
                    4'd13: f_gamma = 8'd66;
                    4'd14: f_gamma = 8'd68;
                    default: f_gamma = 8'd70;
                endcase
            end else begin
                s = f_seg(v);
                t = {2'd0, s[15:8]} + (({7'd0, s[7:0]} * {7'd0, v[2:0]}) >> 3);
                f_gamma = t[9] ? 8'd255 : t[7:0];
            end
        end
    endfunction

    function [7:0] f_map;
        input [7:0] v;
        begin
            f_map = f_gamma(f_ct(v));
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_o <= 1'b0;
            hs_o <= 1'b0;
            vs_o <= 1'b0;
            dout <= 24'd0;
        end else begin
            de_o <= de;
            hs_o <= hs;
            vs_o <= vs;
            dout <= ENHANCE ? {f_map(din[23:16]), f_map(din[15:8]), f_map(din[7:0])} : din;
        end
    end

endmodule
