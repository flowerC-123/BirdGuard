module roi_frame_snapshot #(
    parameter integer MAX_PIXELS = 5461,
    parameter integer READ_TIMEOUT_CYCLES = 7500000,
    parameter integer ROI_GAMMA_EN = 0,
    parameter integer GRAY_ONLY = 0,
    parameter integer DETAIL_RESIZE = 0
) (
    input wire clk,
    rst_n,
    input wire desc_valid,
    output wire desc_ready,
    input wire [31:0] session_id,
    request_id,
    input wire [159:0] crop_meta,
    input wire lease_valid,
    input wire [31:0] lease_frame_id,
    input wire [15:0] lease_width,
    lease_height,
    output reg lease_release,
    input wire reader_idle,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [31:0] mem_frame_id,
    mem_pixel_index,
    input wire mem_rsp_valid,
    input wire [23:0] mem_rgb,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    output reg reader_flush,
    input wire resend,
    release_snapshot,
    abort,
    output wire [7:0] out_data,
    output wire out_valid,
    out_last,
    input wire out_ready,
    output wire packet_done,
    output wire busy,
    output wire frozen,
    output reg error
);
    localparam IDLE = 0, REQ = 1, WAIT_RSP = 2, FROZEN = 3, DRAIN = 4;
    reg [2:0] state;
    reg [159:0] meta, packet_meta;
    reg [31:0] sid, rid, timeout_count;
    reg [15:0] col, row, wr_index, rd_index, total_pixels;
    reg [1:0] channel, read_wait;
    reg [2:0] scale;
    reg [1:0] sub_x, sub_y;
    reg [11:0] sum_r, sum_g, sum_b;
    reg [23:0] read_word;
    reg send_start;
    wire packet_busy, packet_reject, pixel_ready;
    wire [15:0] sw = crop_meta[63:48], sh = crop_meta[79:64];
    wire [15:0] x = crop_meta[95:80], y = crop_meta[111:96];
    wire [15:0] w = crop_meta[127:112], h = crop_meta[143:128];
    wire [31:0] area = {16'd0, w} * {16'd0, h};
    wire [16:0] right = {1'b0, x} + {1'b0, w}, bottom = {1'b0, y} + {1'b0, h};
    wire [15:0] w2 = ((right + 1) >> 1) - (x >> 1), h2 = ((bottom + 1) >> 1) - (y >> 1);
    wire [15:0] w4 = ((right + 3) >> 2) - (x >> 2), h4 = ((bottom + 3) >> 2) - (y >> 2);
    wire gray_format = crop_meta[151:144] == 1;
    wire [31:0] byte_pixel_limit = gray_format ? 32'd16384 : 32'd5461;
    wire fits0 = w <= 256 && h <= 256 && area <= MAX_PIXELS && area <= byte_pixel_limit;
    wire fits2=!sw[0]&&!sh[0]&&w2<=256&&h2<=256&&({16'd0,w2}*{16'd0,h2})<=MAX_PIXELS;
    wire fits4=sw[1:0]==0&&sh[1:0]==0&&w4<=256&&h4<=256&&({16'd0,w4}*{16'd0,h4})<=MAX_PIXELS;

    function [8:0] div5_coord;
        input [10:0] v;
        begin
            div5_coord = v / 11'd5;
        end
    endfunction
    wire [8:0] xq = div5_coord({x[8:0], 2'b00}), yq = div5_coord({y[8:0], 2'b00});
    wire [8:0] rq = div5_coord(
        {right[8:0], 2'b00} + 11'd4
    ), bq = div5_coord(
        {bottom[8:0], 2'b00} + 11'd4
    );
    wire [8:0] wq = rq - xq, hq = bq - yq;
    wire [8:0] xh = xq >> 1, yh = yq >> 1, rh = (rq + 9'd1) >> 1, bh = (bq + 9'd1) >> 1;
    wire [8:0] wh = rh - xh, hh = bh - yh;
    wire detail_board = DETAIL_RESIZE && gray_format && sw == 320 && sh == 240;
    wire [17:0] area_q = wq * hq, area_h = wh * hh;
    wire fitsq = detail_board && wq <= 256 && hq <= 256 && area_q <= MAX_PIXELS && area_q <= 16384;
    wire fitsh = detail_board && area_h <= MAX_PIXELS && area_h <= 16384;
    wire [2:0] chosen_scale = fits0 ? 0 : fitsq ? 4 : fits2 ? 1 : fitsh ? 3 : 2;
    wire [15:0] out_w = fits0 ? w : fitsq ? {7'd0, wq} : fits2 ? w2 : fitsh ? {7'd0, wh} : w4;
    wire [15:0] out_h = fits0 ? h : fitsq ? {7'd0, hq} : fits2 ? h2 : fitsh ? {7'd0, hh} : h4;
    wire [31:0] out_area = {16'd0, out_w} * {16'd0, out_h};
    wire resize_ok = fits0 || (gray_format && (fitsq || fits2 || fitsh || fits4));

    wire valid_desc=session_id!=0 && request_id!=0 && lease_valid &&
  lease_frame_id==crop_meta[31:0] && lease_width==sw && lease_height==sh && sw>0 && sw<=4096 && sh>0 && sh<=4096 &&
  w>0 && h>0 && area<=131071 && resize_ok && out_area<=byte_pixel_limit &&
  ({1'b0,x}+{1'b0,w})<={1'b0,sw} && ({1'b0,y}+{1'b0,h})<={1'b0,sh} &&
  (gray_format || (!GRAY_ONLY && crop_meta[151:144]==2)) && crop_meta[159:152]==0;
    wire is_gray = GRAY_ONLY || (meta[151:144] == 1);
    assign desc_ready = state == IDLE && reader_idle;
    assign busy = state != IDLE;
    assign frozen = state == FROZEN;
    assign mem_req_valid = state == REQ && lease_valid && lease_frame_id == meta[31:0];
    assign mem_frame_id = meta[31:0];
    function [15:0] binary_downscale;
        input [15:0] v;
        input [2:0] s;
        begin
            case (s)
                1: binary_downscale = v >> 1;
                2: binary_downscale = v >> 2;
                default: binary_downscale = v;
            endcase
        end
    endfunction
    wire [15:0] grid_x = packet_meta[95:80] + col, grid_y = packet_meta[111:96] + row;
    wire[15:0]native_x=(scale==4 ? grid_x+(grid_x>>2) : scale==3 ? (grid_x<<1)+(grid_x>>1) : (scale==0?grid_x:scale==1?grid_x<<1:grid_x<<2))+sub_x;
    wire[15:0]native_y=(scale==4 ? grid_y+(grid_y>>2) : scale==3 ? (grid_y<<1)+(grid_y>>1) : (scale==0?grid_y:scale==1?grid_y<<1:grid_y<<2))+sub_y;
    assign mem_pixel_index = {16'd0, native_y} * {16'd0, meta[63:48]} + {16'd0, native_x};
    wire[2:0]stride_x=scale==4 ? (grid_x[1:0]==3 ? 3'd2:3'd1) : scale==3 ? (grid_x[0]?3'd3:3'd2) : (scale==0?3'd1:scale==1?3'd2:3'd4);
    wire[2:0]stride_y=scale==4 ? (grid_y[1:0]==3 ? 3'd2:3'd1) : scale==3 ? (grid_y[0]?3'd3:3'd2) : (scale==0?3'd1:scale==1?3'd2:3'd4);
    wire last_sample = sub_x == stride_x - 1 && sub_y == stride_y - 1;
    wire [11:0] next_r = sum_r + {4'd0, mem_rgb[23:16]};
    wire [11:0] next_g = sum_g + {4'd0, mem_rgb[15:8]};
    wire [11:0] next_b = sum_b + {4'd0, mem_rgb[7:0]};
    function [7:0] sample_mean;
        input [11:0] sum;
        begin
            if (scale == 4)
                sample_mean=sum>>((stride_x==2?2'd1:2'd0)+(stride_y==2?2'd1:2'd0));
            else if (scale == 3) begin
                if (stride_x == 3 && stride_y == 3) sample_mean = sum / 12'd9;
                else if (stride_x == 3 || stride_y == 3) sample_mean = sum / 12'd6;
                else sample_mean = sum >> 2;
            end else sample_mean = scale == 0 ? sum[7:0] : scale == 1 ? sum[9:2] : sum[11:4];
        end
    endfunction
    wire [7:0] mean_r = sample_mean(
        next_r
    ), mean_g = sample_mean(
        next_g
    ), mean_b = sample_mean(
        next_b
    );
    assign mem_rsp_ready = state == WAIT_RSP;

    function [7:0] roi_gamma;
        input [7:0] v;
        begin
            case (v)
                8'd0: roi_gamma = 8'd0;
                8'd1: roi_gamma = 8'd21;
                8'd2: roi_gamma = 8'd28;
                8'd3: roi_gamma = 8'd34;
                8'd4: roi_gamma = 8'd39;
                8'd5: roi_gamma = 8'd43;
                8'd6: roi_gamma = 8'd46;
                8'd7: roi_gamma = 8'd50;
                8'd8: roi_gamma = 8'd53;
                8'd9: roi_gamma = 8'd56;
                8'd10: roi_gamma = 8'd59;
                8'd11: roi_gamma = 8'd61;
                8'd12: roi_gamma = 8'd64;
                8'd13: roi_gamma = 8'd66;
                8'd14: roi_gamma = 8'd68;
                8'd15: roi_gamma = 8'd70;
                8'd16: roi_gamma = 8'd72;
                8'd17: roi_gamma = 8'd74;
                8'd18: roi_gamma = 8'd76;
                8'd19: roi_gamma = 8'd78;
                8'd20: roi_gamma = 8'd80;
                8'd21: roi_gamma = 8'd82;
                8'd22: roi_gamma = 8'd84;
                8'd23: roi_gamma = 8'd85;
                8'd24: roi_gamma = 8'd87;
                8'd25: roi_gamma = 8'd89;
                8'd26: roi_gamma = 8'd90;
                8'd27: roi_gamma = 8'd92;
                8'd28: roi_gamma = 8'd93;
                8'd29: roi_gamma = 8'd95;
                8'd30: roi_gamma = 8'd96;
                8'd31: roi_gamma = 8'd98;
                8'd32: roi_gamma = 8'd99;
                8'd33: roi_gamma = 8'd101;
                8'd34: roi_gamma = 8'd102;
                8'd35: roi_gamma = 8'd103;
                8'd36: roi_gamma = 8'd105;
                8'd37: roi_gamma = 8'd106;
                8'd38: roi_gamma = 8'd107;
                8'd39: roi_gamma = 8'd109;
                8'd40: roi_gamma = 8'd110;
                8'd41: roi_gamma = 8'd111;
                8'd42: roi_gamma = 8'd112;
                8'd43: roi_gamma = 8'd114;
                8'd44: roi_gamma = 8'd115;
                8'd45: roi_gamma = 8'd116;
                8'd46: roi_gamma = 8'd117;
                8'd47: roi_gamma = 8'd118;
                8'd48: roi_gamma = 8'd119;
                8'd49: roi_gamma = 8'd120;
                8'd50: roi_gamma = 8'd122;
                8'd51: roi_gamma = 8'd123;
                8'd52: roi_gamma = 8'd124;
                8'd53: roi_gamma = 8'd125;
                8'd54: roi_gamma = 8'd126;
                8'd55: roi_gamma = 8'd127;
                8'd56: roi_gamma = 8'd128;
                8'd57: roi_gamma = 8'd129;
                8'd58: roi_gamma = 8'd130;
                8'd59: roi_gamma = 8'd131;
                8'd60: roi_gamma = 8'd132;
                8'd61: roi_gamma = 8'd133;
                8'd62: roi_gamma = 8'd134;
                8'd63: roi_gamma = 8'd135;
                8'd64: roi_gamma = 8'd136;
                8'd65: roi_gamma = 8'd137;
                8'd66: roi_gamma = 8'd138;
                8'd67: roi_gamma = 8'd139;
                8'd68: roi_gamma = 8'd140;
                8'd69: roi_gamma = 8'd141;
                8'd70: roi_gamma = 8'd142;
                8'd71: roi_gamma = 8'd143;
                8'd72: roi_gamma = 8'd144;
                8'd73: roi_gamma = 8'd144;
                8'd74: roi_gamma = 8'd145;
                8'd75: roi_gamma = 8'd146;
                8'd76: roi_gamma = 8'd147;
                8'd77: roi_gamma = 8'd148;
                8'd78: roi_gamma = 8'd149;
                8'd79: roi_gamma = 8'd150;
                8'd80: roi_gamma = 8'd151;
                8'd81: roi_gamma = 8'd151;
                8'd82: roi_gamma = 8'd152;
                8'd83: roi_gamma = 8'd153;
                8'd84: roi_gamma = 8'd154;
                8'd85: roi_gamma = 8'd155;
                8'd86: roi_gamma = 8'd156;
                8'd87: roi_gamma = 8'd156;
                8'd88: roi_gamma = 8'd157;
                8'd89: roi_gamma = 8'd158;
                8'd90: roi_gamma = 8'd159;
                8'd91: roi_gamma = 8'd160;
                8'd92: roi_gamma = 8'd160;
                8'd93: roi_gamma = 8'd161;
                8'd94: roi_gamma = 8'd162;
                8'd95: roi_gamma = 8'd163;
                8'd96: roi_gamma = 8'd164;
                8'd97: roi_gamma = 8'd164;
                8'd98: roi_gamma = 8'd165;
                8'd99: roi_gamma = 8'd166;
                8'd100: roi_gamma = 8'd167;
                8'd101: roi_gamma = 8'd167;
                8'd102: roi_gamma = 8'd168;
                8'd103: roi_gamma = 8'd169;
                8'd104: roi_gamma = 8'd170;
                8'd105: roi_gamma = 8'd170;
                8'd106: roi_gamma = 8'd171;
                8'd107: roi_gamma = 8'd172;
                8'd108: roi_gamma = 8'd173;
                8'd109: roi_gamma = 8'd173;
                8'd110: roi_gamma = 8'd174;
                8'd111: roi_gamma = 8'd175;
                8'd112: roi_gamma = 8'd175;
                8'd113: roi_gamma = 8'd176;
                8'd114: roi_gamma = 8'd177;
                8'd115: roi_gamma = 8'd178;
                8'd116: roi_gamma = 8'd178;
                8'd117: roi_gamma = 8'd179;
                8'd118: roi_gamma = 8'd180;
                8'd119: roi_gamma = 8'd180;
                8'd120: roi_gamma = 8'd181;
                8'd121: roi_gamma = 8'd182;
                8'd122: roi_gamma = 8'd182;
                8'd123: roi_gamma = 8'd183;
                8'd124: roi_gamma = 8'd184;
                8'd125: roi_gamma = 8'd184;
                8'd126: roi_gamma = 8'd185;
                8'd127: roi_gamma = 8'd186;
                8'd128: roi_gamma = 8'd186;
                8'd129: roi_gamma = 8'd187;
                8'd130: roi_gamma = 8'd188;
                8'd131: roi_gamma = 8'd188;
                8'd132: roi_gamma = 8'd189;
                8'd133: roi_gamma = 8'd190;
                8'd134: roi_gamma = 8'd190;
                8'd135: roi_gamma = 8'd191;
                8'd136: roi_gamma = 8'd192;
                8'd137: roi_gamma = 8'd192;
                8'd138: roi_gamma = 8'd193;
                8'd139: roi_gamma = 8'd194;
                8'd140: roi_gamma = 8'd194;
                8'd141: roi_gamma = 8'd195;
                8'd142: roi_gamma = 8'd195;
                8'd143: roi_gamma = 8'd196;
                8'd144: roi_gamma = 8'd197;
                8'd145: roi_gamma = 8'd197;
                8'd146: roi_gamma = 8'd198;
                8'd147: roi_gamma = 8'd199;
                8'd148: roi_gamma = 8'd199;
                8'd149: roi_gamma = 8'd200;
                8'd150: roi_gamma = 8'd200;
                8'd151: roi_gamma = 8'd201;
                8'd152: roi_gamma = 8'd202;
                8'd153: roi_gamma = 8'd202;
                8'd154: roi_gamma = 8'd203;
                8'd155: roi_gamma = 8'd203;
                8'd156: roi_gamma = 8'd204;
                8'd157: roi_gamma = 8'd205;
                8'd158: roi_gamma = 8'd205;
                8'd159: roi_gamma = 8'd206;
                8'd160: roi_gamma = 8'd206;
                8'd161: roi_gamma = 8'd207;
                8'd162: roi_gamma = 8'd207;
                8'd163: roi_gamma = 8'd208;
                8'd164: roi_gamma = 8'd209;
                8'd165: roi_gamma = 8'd209;
                8'd166: roi_gamma = 8'd210;
                8'd167: roi_gamma = 8'd210;
                8'd168: roi_gamma = 8'd211;
                8'd169: roi_gamma = 8'd212;
                8'd170: roi_gamma = 8'd212;
                8'd171: roi_gamma = 8'd213;
                8'd172: roi_gamma = 8'd213;
                8'd173: roi_gamma = 8'd214;
                8'd174: roi_gamma = 8'd214;
                8'd175: roi_gamma = 8'd215;
                8'd176: roi_gamma = 8'd215;
                8'd177: roi_gamma = 8'd216;
                8'd178: roi_gamma = 8'd217;
                8'd179: roi_gamma = 8'd217;
                8'd180: roi_gamma = 8'd218;
                8'd181: roi_gamma = 8'd218;
                8'd182: roi_gamma = 8'd219;
                8'd183: roi_gamma = 8'd219;
                8'd184: roi_gamma = 8'd220;
                8'd185: roi_gamma = 8'd220;
                8'd186: roi_gamma = 8'd221;
                8'd187: roi_gamma = 8'd221;
                8'd188: roi_gamma = 8'd222;
                8'd189: roi_gamma = 8'd223;
                8'd190: roi_gamma = 8'd223;
                8'd191: roi_gamma = 8'd224;
                8'd192: roi_gamma = 8'd224;
                8'd193: roi_gamma = 8'd225;
                8'd194: roi_gamma = 8'd225;
                8'd195: roi_gamma = 8'd226;
                8'd196: roi_gamma = 8'd226;
                8'd197: roi_gamma = 8'd227;
                8'd198: roi_gamma = 8'd227;
                8'd199: roi_gamma = 8'd228;
                8'd200: roi_gamma = 8'd228;
                8'd201: roi_gamma = 8'd229;
                8'd202: roi_gamma = 8'd229;
                8'd203: roi_gamma = 8'd230;
                8'd204: roi_gamma = 8'd230;
                8'd205: roi_gamma = 8'd231;
                8'd206: roi_gamma = 8'd231;
                8'd207: roi_gamma = 8'd232;
                8'd208: roi_gamma = 8'd232;
                8'd209: roi_gamma = 8'd233;
                8'd210: roi_gamma = 8'd233;
                8'd211: roi_gamma = 8'd234;
                8'd212: roi_gamma = 8'd234;
                8'd213: roi_gamma = 8'd235;
                8'd214: roi_gamma = 8'd235;
                8'd215: roi_gamma = 8'd236;
                8'd216: roi_gamma = 8'd236;
                8'd217: roi_gamma = 8'd237;
                8'd218: roi_gamma = 8'd237;
                8'd219: roi_gamma = 8'd238;
                8'd220: roi_gamma = 8'd238;
                8'd221: roi_gamma = 8'd239;
                8'd222: roi_gamma = 8'd239;
                8'd223: roi_gamma = 8'd240;
                8'd224: roi_gamma = 8'd240;
                8'd225: roi_gamma = 8'd241;
                8'd226: roi_gamma = 8'd241;
                8'd227: roi_gamma = 8'd242;
                8'd228: roi_gamma = 8'd242;
                8'd229: roi_gamma = 8'd243;
                8'd230: roi_gamma = 8'd243;
                8'd231: roi_gamma = 8'd244;
                8'd232: roi_gamma = 8'd244;
                8'd233: roi_gamma = 8'd245;
                8'd234: roi_gamma = 8'd245;
                8'd235: roi_gamma = 8'd246;
                8'd236: roi_gamma = 8'd246;
                8'd237: roi_gamma = 8'd247;
                8'd238: roi_gamma = 8'd247;
                8'd239: roi_gamma = 8'd248;
                8'd240: roi_gamma = 8'd248;
                8'd241: roi_gamma = 8'd249;
                8'd242: roi_gamma = 8'd249;
                8'd243: roi_gamma = 8'd249;
                8'd244: roi_gamma = 8'd250;
                8'd245: roi_gamma = 8'd250;
                8'd246: roi_gamma = 8'd251;
                8'd247: roi_gamma = 8'd251;
                8'd248: roi_gamma = 8'd252;
                8'd249: roi_gamma = 8'd252;
                8'd250: roi_gamma = 8'd253;
                8'd251: roi_gamma = 8'd253;
                8'd252: roi_gamma = 8'd254;
                8'd253: roi_gamma = 8'd254;
                8'd254: roi_gamma = 8'd255;
                8'd255: roi_gamma = 8'd255;
                default: roi_gamma = 8'd0;
            endcase
        end
    endfunction

    (* ram_style="dram" *) reg [7:0] gamma_curve[0:255];
    integer gamma_i;
    initial
        for (gamma_i = 0; gamma_i < 256; gamma_i = gamma_i + 1)
            gamma_curve[gamma_i] = roi_gamma(gamma_i[7:0]);
    reg [7:0] gamma_word;
    always @(posedge clk)
        if (state == FROZEN && rd_index < total_pixels)
            gamma_word <= gamma_curve[read_word[23:16]];
    wire [7:0] pixel_data=is_gray ? (ROI_GAMMA_EN ? gamma_word : read_word[23:16])
                     : (channel==0 ? read_word[23:16] : channel==1 ? read_word[15:8] : read_word[7:0]);
    wire pixel_valid = state == FROZEN && read_wait == 0 && rd_index < total_pixels;
    roi_packet_tx tx (
        .clk(clk),
        .rst_n(rst_n),
        .start(send_start),
        .session_id(sid),
        .request_id(rid),
        .crop_meta(packet_meta),
        .pixel_data(pixel_data),
        .pixel_valid(pixel_valid),
        .pixel_ready(pixel_ready),
        .out_data(out_data),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_last(out_last),
        .busy(packet_busy),
        .done(packet_done),
        .reject(packet_reject)
    );

    generate
        if (GRAY_ONLY) begin : g_gray_ram

            localparam BANKS = (MAX_PIXELS + 2047) / 2048;
            wire [7:0] bank_q[0:BANKS-1];
            reg [4:0] read_bank;
            wire write_enable=state==WAIT_RSP && mem_rsp_valid && !mem_rsp_error && lease_valid && lease_frame_id==meta[31:0] && last_sample;
            genvar bank;
            for (bank = 0; bank < BANKS; bank = bank + 1) begin : g_bank
                roi_gray_bank #(
                    .DEPTH(MAX_PIXELS - bank * 2048 < 2048 ? MAX_PIXELS - bank * 2048 : 2048)
                ) u_bank (
                    .clk(clk),
                    .we(write_enable && wr_index[15:11] == bank),
                    .waddr(wr_index[10:0]),
                    .wdata(mean_r),
                    .raddr(rd_index[10:0]),
                    .rdata(bank_q[bank])
                );
            end
            always @(posedge clk) read_bank <= rd_index[15:11];
            always @* read_word = {3{bank_q[read_bank]}};
        end else begin : g_rgb_ram
            reg [23:0] pixels[0:MAX_PIXELS-1];
            always @(posedge clk) begin
                if(state==WAIT_RSP && mem_rsp_valid && !mem_rsp_error && lease_valid && lease_frame_id==meta[31:0] && last_sample)
                    pixels[wr_index] <= {mean_r, mean_g, mean_b};
                if (state == FROZEN && rd_index < total_pixels) read_word <= pixels[rd_index];
            end
        end
    endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            meta <= 0;
            packet_meta <= 0;
            sid <= 0;
            rid <= 0;
            timeout_count <= 0;
            col <= 0;
            row <= 0;
            scale <= 0;
            sub_x <= 0;
            sub_y <= 0;
            sum_r <= 0;
            sum_g <= 0;
            sum_b <= 0;
            wr_index <= 0;
            rd_index <= 0;
            total_pixels <= 0;
            channel <= 0;
            read_wait <= 0;
            send_start <= 0;
            lease_release <= 0;
            reader_flush <= 0;
            error <= 0;
        end else begin
            send_start <= 0;
            lease_release <= 0;
            reader_flush <= 0;
            error <= 0;
            case (state)
                IDLE:
                if (desc_valid && desc_ready) begin
                    if (!valid_desc) begin
                        error <= 1;
                        lease_release <= lease_valid;
                    end else begin
                        meta <= crop_meta;
                        packet_meta <= crop_meta;
                        sid <= session_id;
                        rid <= request_id;
                        total_pixels <= out_area[15:0];
                        packet_meta[63:48]<=chosen_scale==4?16'd256:chosen_scale==3?16'd128:binary_downscale(
                            sw, chosen_scale
                        );
                        packet_meta[79:64]<=chosen_scale==4?16'd192:chosen_scale==3?16'd96:binary_downscale(
                            sh, chosen_scale
                        );
                        packet_meta[95:80]<=chosen_scale==4?{7'd0,xq}:chosen_scale==3?{7'd0,xh}:binary_downscale(
                            x, chosen_scale
                        );
                        packet_meta[111:96]<=chosen_scale==4?{7'd0,yq}:chosen_scale==3?{7'd0,yh}:binary_downscale(
                            y, chosen_scale
                        );
                        packet_meta[127:112] <= out_w;
                        packet_meta[143:128] <= out_h;
                        scale <= chosen_scale;
                        sub_x <= 0;
                        sub_y <= 0;
                        sum_r <= 0;
                        sum_g <= 0;
                        sum_b <= 0;
                        col <= 0;
                        row <= 0;
                        wr_index <= 0;
                        timeout_count <= 0;
                        state <= REQ;
                    end
                end
                REQ, WAIT_RSP: begin

                    if(abort || !lease_valid || lease_frame_id!=meta[31:0] || lease_width!=meta[63:48] || lease_height!=meta[79:64] || timeout_count>=READ_TIMEOUT_CYCLES-1) begin
                        state <= DRAIN;
                        reader_flush <= 1;
                        error <= 1;
                    end else begin
                        timeout_count <= timeout_count + 1;
                        if (state == REQ && mem_req_ready) state <= WAIT_RSP;
                        if (state == WAIT_RSP && mem_rsp_valid) begin
                            if (mem_rsp_error) begin
                                state <= DRAIN;
                                reader_flush <= 1;
                                error <= 1;
                            end else if (!last_sample) begin
                                sum_r <= next_r;
                                sum_g <= next_g;
                                sum_b <= next_b;
                                timeout_count <= 0;
                                state <= REQ;
                                if (sub_x == stride_x - 1) begin
                                    sub_x <= 0;
                                    sub_y <= sub_y + 1'b1;
                                end else sub_x <= sub_x + 1'b1;
                            end else if (wr_index + 1 == total_pixels) begin
                                state <= FROZEN;
                                lease_release <= 1;
                                rd_index <= 0;
                                channel <= 0;
                                read_wait <= 2;
                                send_start <= 1;
                            end else begin
                                sub_x <= 0;
                                sub_y <= 0;
                                sum_r <= 0;
                                sum_g <= 0;
                                sum_b <= 0;
                                wr_index <= wr_index + 1;
                                timeout_count <= 0;
                                state <= REQ;
                                if (col + 1 == packet_meta[127:112]) begin
                                    col <= 0;
                                    row <= row + 1;
                                end else col <= col + 1;
                            end
                        end
                    end
                end
                DRAIN:
                if (reader_idle) begin
                    state <= IDLE;
                    lease_release <= 1;
                end
                FROZEN: begin
                    if (read_wait != 0) read_wait <= read_wait - 1;
                    if (pixel_valid && pixel_ready) begin
                        if (channel == (is_gray ? 2'd0 : 2'd2)) begin
                            channel   <= 0;
                            rd_index  <= rd_index + 1;
                            read_wait <= 2;
                        end else channel <= channel + 1;
                    end
                    if (!packet_busy && !send_start && !packet_done) begin
                        if (release_snapshot) state <= IDLE;
                        else if (resend) begin
                            rd_index <= 0;
                            channel <= 0;
                            read_wait <= 2;
                            send_start <= 1;
                        end
                    end
                    if (packet_reject) error <= 1;
                end
                default: begin
                    state <= IDLE;
                    error <= 1;
                end
            endcase
        end
    end
endmodule

module roi_gray_bank #(
    parameter DEPTH = 2048
) (
    input wire clk,
    we,
    input wire [10:0] waddr,
    raddr,
    input wire [7:0] wdata,
    output reg [7:0] rdata
);
    (* ram_style="bram" *) reg [7:0] mem[0:DEPTH-1];
    integer i;
    initial for (i = 0; i < DEPTH; i = i + 1) mem[i] = 0;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
