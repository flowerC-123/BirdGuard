module osd_alg_tag #(
    parameter TAG_X  = 32,
    parameter TAG_Y0 = 660,
    parameter TAG_Y1 = 680,
    parameter BOX_X0 = 28,
    parameter BOX_Y0 = 656,
    parameter BOX_X1 = 132,
    parameter BOX_Y1 = 700
) (
    input wire        clk,
    input wire        rst_n,
    input wire [ 1:0] mode,
    input wire [15:0] lat_ms,
    input wire        lat_valid,

    input wire        de,
    input wire        hs,
    input wire        vs,
    input wire [23:0] rgb_in,

    output reg        de_o,
    output reg        hs_o,
    output reg        vs_o,
    output reg [23:0] rgb_o
);

    reg [11:0] xc, yc;
    reg de_d, vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xc   <= 12'd0;
            yc   <= 12'd0;
            de_d <= 1'b0;
            vs_d <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (vs && !vs_d) begin
                yc <= 12'd0;
                xc <= 12'd0;
            end else if (de) begin
                xc <= xc + 12'd1;
            end else if (de_d) begin
                xc <= 12'd0;
                yc <= yc + 12'd1;
            end
        end
    end

    reg [15:0] lat_s0, lat_s1;
    reg v_s0, v_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_s0 <= 16'd0;
            lat_s1 <= 16'd0;
            v_s0   <= 1'b0;
            v_s1   <= 1'b0;
        end else begin
            lat_s0 <= lat_ms;
            lat_s1 <= lat_s0;
            v_s0   <= lat_valid;
            v_s1   <= v_s0;
        end
    end

    wire [9:0] lat_c = (lat_s1 > 16'd999) ? 10'd999 : lat_s1[9:0];
    wire [6:0] lat_h = lat_c / 10'd100;
    wire [9:0] lat_r = lat_c - (lat_h * 10'd100);
    wire [3:0] lat_t = lat_r / 10'd10;
    wire [3:0] lat_o = lat_r - (lat_t * 10'd10);

    function [7:0] alg_ch;
        input [1:0] m;
        input [3:0] i;
        begin
            case (i)
                4'd0: alg_ch = m == 0 ? 8'd65 : m == 1 ? 8'd65 : 8'd65;
                4'd1: alg_ch = m == 0 ? 8'd76 : m == 1 ? 8'd76 : 8'd76;
                4'd2: alg_ch = m == 0 ? 8'd71 : m == 1 ? 8'd71 : 8'd71;
                4'd3: alg_ch = m == 0 ? 8'd58 : m == 1 ? 8'd58 : 8'd58;
                4'd4: alg_ch = m == 0 ? 8'd79 : m == 1 ? 8'd69 : 8'd71;
                4'd5: alg_ch = m == 0 ? 8'd82 : m == 1 ? 8'd68 : 8'd82;
                4'd6: alg_ch = m == 0 ? 8'd73 : m == 1 ? 8'd71 : 8'd65;
                4'd7: alg_ch = m == 0 ? 8'd71 : m == 1 ? 8'd69 : 8'd89;
                4'd8: alg_ch = m == 0 ? 8'd73 : m == 1 ? 8'd32 : 8'd32;
                4'd9: alg_ch = m == 0 ? 8'd78 : m == 1 ? 8'd66 : 8'd32;
                4'd10: alg_ch = m == 0 ? 8'd65 : m == 1 ? 8'd47 : 8'd32;
                4'd11: alg_ch = m == 0 ? 8'd76 : m == 1 ? 8'd87 : 8'd32;
                default: alg_ch = 8'd32;
            endcase
        end
    endfunction

    function [7:0] lat_ch;
        input [3:0] i;
        input [3:0] h, t, o;
        input ok;
        begin
            case (i)
                4'd0: lat_ch = 76;
                4'd1: lat_ch = 65;
                4'd2: lat_ch = 84;
                4'd3: lat_ch = 58;
                4'd4: lat_ch = ok ? (48 + h) : 45;
                4'd5: lat_ch = ok ? (48 + t) : 45;
                4'd6: lat_ch = ok ? (48 + o) : 45;
                4'd7: lat_ch = 32;
                4'd8: lat_ch = 109;
                4'd9: lat_ch = 115;
                default: lat_ch = 32;
            endcase
        end
    endfunction

    wire [11:0] dx = xc - TAG_X;
    wire [ 3:0] ci = dx[6:3];
    wire        in_col = (dx < 12'd96);
    wire        in_line0 = (yc >= TAG_Y0) && (yc < TAG_Y0 + 12'd16);
    wire        in_line1 = (yc >= TAG_Y1) && (yc < TAG_Y1 + 12'd16);
    wire [ 3:0] crow = in_line0 ? (yc - TAG_Y0) : (yc - TAG_Y1);

    reg  [ 7:0] chcode;
    always @* begin
        if (in_line0) chcode = alg_ch(mode, ci);
        else if (in_line1) chcode = lat_ch(ci, lat_h[3:0], lat_t, lat_o, v_s1);
        else chcode = 32;
    end

    wire [7:0] fbits;
    osd_font u_font (
        .code(chcode),
        .row (crow),
        .bits(fbits)
    );

    wire glyph_on = (in_line0 || in_line1) && in_col && fbits[3'd7-dx[2:0]];

    wire in_box = de && (xc >= BOX_X0) && (xc < BOX_X1) && (yc >= BOX_Y0) && (yc < BOX_Y1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_o  <= 1'b0;
            hs_o  <= 1'b0;
            vs_o  <= 1'b0;
            rgb_o <= 24'd0;
        end else begin
            de_o <= de;
            hs_o <= hs;
            vs_o <= vs;
            if (in_box) rgb_o <= glyph_on ? 24'h00FF00 : 24'h000000;
            else rgb_o <= rgb_in;
        end
    end

endmodule

module osd_status #(
    parameter TAG_X = 32,
    TAG_Y = 620
) (
    input wire clk,
    rst_n,
    input wire [6:0] applied_cfg,
    input wire [1:0] view_mode,
    input wire waiting,
    input wire lat_clk,
    lat_rst_n,
    input wire [15:0] lat_ms,
    input wire lat_valid,
    input wire de,
    hs,
    vs,
    input wire [23:0] rgb_in,
    output reg de_o,
    hs_o,
    vs_o,
    output reg [23:0] rgb_o
);
    wire common_reset_n = rst_n && lat_rst_n;
    reg [16:0] lat_hold, lat_received;
    reg lat_req, lat_ack;
    (* async_reg="true" *) reg ack1, ack2, req1, req2;
    always @(posedge lat_clk or negedge common_reset_n) begin
        if (!common_reset_n) begin
            lat_hold <= 0;
            lat_req <= 0;
            ack1 <= 0;
            ack2 <= 0;
        end else begin
            ack1 <= lat_ack;
            ack2 <= ack1;
            if (lat_req == ack2 && lat_hold != {lat_valid, lat_ms}) begin
                lat_hold <= {lat_valid, lat_ms};
                lat_req  <= ~lat_req;
            end
        end
    end
    always @(posedge clk or negedge common_reset_n) begin
        if (!common_reset_n) begin
            lat_received <= 0;
            lat_ack <= 0;
            req1 <= 0;
            req2 <= 0;
        end else begin
            req1 <= lat_req;
            req2 <= req1;
            if (req2 != lat_ack) begin
                lat_received <= lat_hold;
                lat_ack <= req2;
            end
        end
    end
    reg [11:0] xc, yc;
    reg de_d, vs_d;
    reg [6:0] cfg_q;
    reg [1:0] view_q;
    reg wait_q;
    reg [16:0] lat_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xc <= 0;
            yc <= 0;
            de_d <= 0;
            vs_d <= 0;
            cfg_q <= 7'h21;
            view_q <= 0;
            wait_q <= 0;
            lat_q <= 0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (vs && !vs_d) begin
                xc <= 0;
                yc <= 0;
                cfg_q <= applied_cfg;
                view_q <= view_mode;
                wait_q <= waiting;
                lat_q <= lat_received;
            end else if (de) xc <= xc + 1'b1;
            else if (de_d) begin
                xc <= 0;
                yc <= yc + 1'b1;
            end
        end
    end
    wire [  9:0] lat_c = lat_q[15:0] > 999 ? 10'd999 : lat_q[9:0];
    wire [  3:0] hundreds = lat_c / 100;
    wire [  6:0] remainder = lat_c - hundreds * 100;
    wire [  3:0] tens = remainder / 10, ones = remainder - tens * 10;
    reg  [159:0] line_text;
    wire [ 11:0] dx = xc - TAG_X, dy = yc - TAG_Y;
    wire [  1:0] line_no = dy < 20 ? 0 : dy < 40 ? 1 : dy < 60 ? 2 : 3;
    wire [  6:0] row_in_line = dy - (line_no == 0 ? 0 : line_no == 1 ? 20 : line_no == 2 ? 40 : 60);
    wire [  4:0] col = dx[7:3];

    always @* begin
        case (line_no)
            0: begin
                case (cfg_q[1:0])
                    0: line_text = "ALG: MOTION         ";
                    1: line_text = "ALG: BGMODEL        ";
                    2: line_text = "ALG: COLOR          ";
                    3: line_text = "ALG: MOT+COL        ";
                endcase
                if (wait_q) line_text[7:0] = "*";
            end
            1:
            case (view_q)
                0: line_text = "VIEW:ORIGINAL       ";
                1: line_text = "VIEW:EDGE B/W       ";
                default: line_text = "VIEW:GRAY           ";
            endcase
            2: begin
                case (cfg_q[4:2])
                    0: line_text = "COL:RED    F:VOTE3  ";
                    1: line_text = "COL:GREEN  F:VOTE3  ";
                    2: line_text = "COL:BLUE   F:VOTE3  ";
                    3: line_text = "COL:BRIGHT F:VOTE3  ";
                    4: line_text = "COL:DARK   F:VOTE3  ";
                    default: line_text = "COL:CHROMA F:VOTE3  ";
                endcase

                if (cfg_q[1:0] < 2) line_text = "COL:OFF    F:VOTE3  ";
                if (cfg_q[6:5] == 0) line_text[55:16] = "RAW  ";
                else if (cfg_q[6:5] == 2) line_text[55:16] = "VOTE5";
            end
            3: begin
                line_text = "LAT:--- ms          ";
                if (lat_q[16]) begin
                    line_text[127:120] = 48 + hundreds;
                    line_text[119:112] = 48 + tens;
                    line_text[111:104] = 48 + ones;
                end
            end
        endcase
    end
    wire [7:0] code = col < 20 ? line_text[(19-col)*8+:8] : 8'd32;
    wire [7:0] font_bits;
    osd_font font (
        .code(code),
        .row (row_in_line[3:0]),
        .bits(font_bits)
    );
    wire in_box = xc >= TAG_X - 4 && xc < TAG_X + 164 && yc >= TAG_Y - 4 && yc < TAG_Y + 80;
    wire glyph = dx < 160 && dy < 80 && row_in_line < 16 && font_bits[7-dx[2:0]];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_o  <= 0;
            hs_o  <= 0;
            vs_o  <= 0;
            rgb_o <= 0;
        end else begin
            de_o  <= de;
            hs_o  <= hs;
            vs_o  <= vs;
            rgb_o <= de && in_box ? (glyph ? 24'h00ff70 : 24'h081018) : rgb_in;
        end
    end
endmodule
