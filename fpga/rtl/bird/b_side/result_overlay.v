module result_overlay #(
    parameter WIDTH = 1280,
    HEIGHT = 720,
    MAX_HOLD_FRAMES = 120,
    PANEL_LAYOUT = 0
) (
    input wire pixel_clk,
    rst_n,
    in_de,
    input wire [11:0] in_x,
    in_y,
    input wire frame_start,
    input wire meta_valid,
    input wire [191:0] meta_payload,
    output wire meta_take,
    output reg out_cover,
    output reg [23:0] out_rgb,
    output wire [15:0] result_age,
    output wire result_fresh,
    output reg out_text
);
    reg [191:0] active;
    reg known;
    reg [15:0] age;
    assign meta_take = frame_start && !in_de && meta_valid;
    assign result_age = age;
    assign result_fresh = known && active[0] && age < MAX_HOLD_FRAMES;
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0;
            known <= 0;
            age <= 16'hffff;
        end else if (frame_start && !in_de) begin
            if (meta_valid) begin
                active <= meta_payload;
                known  <= 1;

                if (!known || active[155:92] != meta_payload[155:92]) age <= 0;
                else if (age != 16'hffff) age <= age + 1'b1;
            end else if (age != 16'hffff) age <= age + 1'b1;
        end
    end
    wire [2:0] label=(active[4:2]==1 && (active[11:5]<80 || active[11:5]>100)) ? 3'd0 : active[4:2];
    wire [11:0] x0 = active[23:12], y0 = active[35:24], x1 = active[47:36], y1 = active[59:48];
    wire geom_ok=result_fresh && x0<=x1 && y0<=y1 && x1<WIDTH && y1<HEIGHT &&
               active[155:124]!=0 && active[123:92]!=0 && (!active[1] || label==1);
    wire [23:0] color=label==1 ? 24'h70ff90 : label==2 ? 24'h80c8ff :
                   label==4 ? 24'hff7070 : 24'hffdc70;

    localparam PANEL_MODE = PANEL_LAYOUT != 0 && WIDTH >= 960 && HEIGHT >= 160;
    wire [11:0] lx = PANEL_MODE ? (WIDTH - 176) / 2 : x0 > WIDTH - 176 ? WIDTH - 176 : x0;
    wire [11:0] raw_ly = y0 >= 36 ? y0 - 12'd34 : y0 + 12'd2;
    wire [11:0] ly = PANEL_MODE ? HEIGHT - 48 : raw_ly > HEIGHT - 32 ? HEIGHT - 32 : raw_ly;
    wire [11:0] dx = in_x - lx, dy = in_y - ly;
    wire text_hit=geom_ok && in_x>=lx && in_x<lx+12'd176 && in_y>=ly && in_y<ly+12'd32;
    wire edge_v = in_x - x0 < 12'd2 || x1 - in_x < 12'd2;
    wire edge_h = in_y - y0 < 12'd2 || y1 - in_y < 12'd2;

    wire border=geom_ok && in_x>=x0 && in_x<=x1 && in_y>=y0 && in_y<=y1 &&
             (PANEL_MODE ? (in_y>=68 && in_y<HEIGHT-96 &&
                            ((edge_v&&!in_y[3]) || (edge_h&&!in_x[3]))) : (edge_v||edge_h));

    function [7:0] hexchar;
        input [3:0] n;
        begin
            hexchar = n < 10 ? 8'd48 + n : 8'd55 + n;
        end
    endfunction
    function [7:0] statuschar;
        input [2:0] lb;
        input [3:0] ci;
        begin
            statuschar = 32;
            case (lb)
                1:
                case (ci)
                    0: statuschar = 66;
                    1: statuschar = 73;
                    2: statuschar = 82;
                    3: statuschar = 68;
                endcase
                2:
                case (ci)
                    0: statuschar = 78;
                    1: statuschar = 79;
                    3: statuschar = 66;
                    4: statuschar = 73;
                    5: statuschar = 82;
                    6: statuschar = 68;
                endcase
                3:
                case (ci)
                    0: statuschar = 84;
                    1: statuschar = 73;
                    2: statuschar = 77;
                    3: statuschar = 69;
                    4: statuschar = 79;
                    5: statuschar = 85;
                    6: statuschar = 84;
                endcase
                4:
                case (ci)
                    0: statuschar = 69;
                    1: statuschar = 82;
                    2: statuschar = 82;
                    3: statuschar = 79;
                    4: statuschar = 82;
                endcase
                5:
                case (ci)
                    0: statuschar = 77;
                    1: statuschar = 79;
                    2: statuschar = 67;
                    3: statuschar = 75;
                endcase
                default:
                case (ci)
                    0: statuschar = 85;
                    1: statuschar = 78;
                    2: statuschar = 75;
                    3: statuschar = 78;
                    4: statuschar = 79;
                    5: statuschar = 87;
                    6: statuschar = 78;
                endcase
            endcase
        end
    endfunction

    reg fill_run;
    reg [5:0] fill_index;
    reg [7:0] chars[0:63];
    reg [7:0] fill_char;
    wire [4:0] ci = fill_index[4:0];
    always @* begin
        fill_char = 32;
        if (!fill_index[5]) begin
            case (ci)
                0: fill_char = 83;
                1: fill_char = 78;
                2: fill_char = 65;
                3: fill_char = 80;
                5: fill_char = active[1] ? 66 : 82;
                6: fill_char = 79;
                7: fill_char = active[1] ? 88 : 73;
                default: begin
                    if (ci >= 9 && ci <= 15) fill_char = statuschar(label, ci - 5'd9);
                    if (label == 1)
                        case (ci)
                            14: fill_char = active[11:5] == 100 ? 49 : 48;
                            15: fill_char = 48 + ((active[11:5] / 10) % 10);
                            16: fill_char = 48 + (active[11:5] % 10);
                            17: fill_char = 37;
                        endcase
                end
            endcase
        end else begin
            case (ci)
                0:  fill_char = 70;
                1:  fill_char = 58;
                11: fill_char = 82;
                12: fill_char = 58;
                default: begin
                    if (ci >= 2 && ci <= 9) fill_char = hexchar(active[60+((9-ci)<<2)+:4]);
                    if (ci >= 13 && ci <= 20) fill_char = hexchar(active[92+((20-ci)<<2)+:4]);
                end
            endcase
        end
    end
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_run   <= 0;
            fill_index <= 0;
        end else if (frame_start && !in_de) begin
            fill_run   <= 1;
            fill_index <= 0;
        end else if (fill_run) begin
            fill_index <= fill_index + 1'b1;
            if (fill_index == 63) fill_run <= 0;
        end
    end
    always @(posedge pixel_clk) if (fill_run) chars[fill_index] <= fill_char;

    reg [2:0] col_q;
    reg text_q, border_q, de_q;
    reg  [23:0] color_q;
    wire [ 7:0] font_bits;

    osd_font_sync font (
        .clk (pixel_clk),
        .code(chars[{dy[4], dx[7:3]}]),
        .row (dy[3:0]),
        .bits(font_bits)
    );
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            col_q <= 0;
            text_q <= 0;
            border_q <= 0;
            de_q <= 0;
            color_q <= 0;
            out_cover <= 0;
            out_rgb <= 0;
            out_text <= 0;
        end else begin
            col_q <= dx[2:0];
            text_q <= text_hit;
            border_q <= border;
            de_q <= in_de;
            color_q <= color;
            out_cover <= de_q && (text_q || border_q);
            out_text <= de_q && text_q;
            out_rgb <= text_q ? (font_bits[7-col_q] ? color_q : 24'h101820) : color_q;
        end
    end
    // synthesis translate_off
    initial
        if (WIDTH < 320 || HEIGHT < 64 || MAX_HOLD_FRAMES < 1 || MAX_HOLD_FRAMES > 65535)
            $fatal(1, "Invalid result_overlay geometry/TTL parameters");
    // synthesis translate_on
endmodule
