// Capture a source-resolution crop through a clock-domain handshake.
module roi_hires_snapshot #(
    parameter integer CAPTURE_TIMEOUT_CYCLES = 5000000,
    parameter integer ROI_GAMMA_EN = 0,
    parameter integer DEFER_TX = 0,
    parameter integer BLANK_TH = 1024
) (
    input wire clk,
    rst_n,
    input wire send_enable,
    input wire vin_clk,
    vin_rst_n,
    vin_de,
    input wire [23:0] vin_rgb,
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
    reader_flush,
    input wire resend,
    release_snapshot,
    abort,
    output wire [7:0] out_data,
    output wire out_valid,
    out_last,
    input wire out_ready,
    output wire packet_done,
    output wire [159:0] debug_packet_meta,
    output wire busy,
    frozen,
    output reg error
);
    localparam IDLE=0,CAPTURE=1,FROZEN=2,DRAIN=3,GEOM_SCALE=4,GEOM_SIZE=5,GEOM_AREA=6,GEOM_SELECT=7;
    localparam P_IDLE = 0, P_SETTLE = 1, P_ARMED = 2, P_CAPTURE = 3, P_DONE = 4, P_DRAIN = 5;
    reg [2:0] state;
    reg [2:0] pstate;

    function [15:0] grid_down;
        input [15:0] v;
        input [2:0] mode;
        input ceiling;
        reg [17:0] t;
        begin
            case (mode)
                0: grid_down = v;
                1: grid_down = ({1'b0, v} + (ceiling ? 17'd1 : 17'd0)) >> 1;
                2: begin
                    t = ({2'b0, v} << 1) + (ceiling ? 18'd4 : 18'd0);
                    grid_down = t / 18'd5;
                end
                3: begin
                    t = ({2'b0, v} << 1) + {2'b0, v} + (ceiling ? 18'd9 : 18'd0);
                    grid_down = t / 18'd10;
                end
                4: grid_down = ({2'b0, v} + (ceiling ? 18'd3 : 18'd0)) >> 2;
                5: grid_down = ({2'b0, v} + (ceiling ? 18'd4 : 18'd0)) / 18'd5;
                default: grid_down = ({3'b0, v} + (ceiling ? 19'd7 : 19'd0)) >> 3;
            endcase
        end
    endfunction
    function [15:0] grid_native;
        input [15:0] v;
        input [2:0] mode;
        reg [13:0] t;
        reg [10:0] a;
        begin

            a = v[10:0];
            case (mode)
                0: grid_native = {5'd0, a};
                1: grid_native = {5'd0, a} << 1;
                2: grid_native = ({5'd0, a} << 1) + (a >> 1);
                3: begin
                    t = ({3'b0, a} << 3) + ({3'b0, a} << 1);
                    grid_native = t / 14'd3;
                end
                4: grid_native = {5'd0, a} << 2;
                5: grid_native = ({5'd0, a} << 2) + a;
                default: grid_native = {5'd0, a} << 3;
            endcase
        end
    endfunction
    function [15:0] grid_width;
        input [2:0] m;
        begin
            case (m)
                0: grid_width = 1280;
                1: grid_width = 640;
                2: grid_width = 512;
                3: grid_width = 384;
                4: grid_width = 320;
                5: grid_width = 256;
                default: grid_width = 160;
            endcase
        end
    endfunction
    function [15:0] grid_height;
        input [2:0] m;
        begin
            case (m)
                0: grid_height = 720;
                1: grid_height = 360;
                2: grid_height = 288;
                3: grid_height = 216;
                4: grid_height = 180;
                5: grid_height = 144;
                default: grid_height = 90;
            endcase
        end
    endfunction
    wire [16:0] det_right = {1'b0, crop_meta[95:80]} + {1'b0, crop_meta[127:112]};
    wire [16:0] det_bottom = {1'b0, crop_meta[111:96]} + {1'b0, crop_meta[143:128]};
    wire valid_desc=session_id!=0 && request_id!=0 && lease_valid &&
  crop_meta[31:0]==lease_frame_id && lease_width==320 && lease_height==240 &&
  crop_meta[63:48]==320 && crop_meta[79:64]==240 &&
  crop_meta[127:112]!=0 && crop_meta[143:128]!=0 &&
  det_right<=320 && det_bottom<=240 && crop_meta[151:144]==1 && crop_meta[159:152]==0;

    reg [10:0] prep_x, prep_r;
    reg [9:0] prep_y, prep_b;
    reg [2:0] geom_mode;
    reg [10:0] geom_x, geom_r, geom_w;
    reg [9:0] geom_y, geom_b, geom_h;
    reg [17:0] geom_area;
    reg geom_fits;
    always @(posedge clk) begin
        if (state == GEOM_SCALE) begin
            geom_x <= grid_down({5'd0, prep_x}, geom_mode, 1'b0);
            geom_y <= grid_down({6'd0, prep_y}, geom_mode, 1'b0);
            geom_r <= grid_down({5'd0, prep_r}, geom_mode, 1'b1);
            geom_b <= grid_down({6'd0, prep_b}, geom_mode, 1'b1);
        end
        if (state == GEOM_SIZE) begin
            geom_w <= geom_r - geom_x;
            geom_h <= geom_b - geom_y;
        end
        if (state == GEOM_AREA) begin
            geom_area <= geom_w[8:0] * geom_h[8:0];
            geom_fits <= geom_w != 0 && geom_h != 0 && geom_w <= 256 && geom_h <= 256;
        end
    end

    reg [2:0] cmd_mode;
    reg [15:0] cmd_x, cmd_y, cmd_w, cmd_h;
    reg [14:0] cmd_total;
    reg [159:0] cmd_meta, packet_meta;
    reg send_pending;
    assign debug_packet_meta = packet_meta;
    reg [31:0] sid, rid;
    reg req_toggle, release_toggle;
    reg [31:0] timeout_count;
    reg [1:0] done_settle;
    reg done_seen;
    reg [14:0] rd_index, total_pixels;
    reg [1:0] read_wait;
    reg send_start, cancel_pending;
    wire packet_busy, packet_reject, pixel_ready;
    (* async_reg="true" *) reg [1:0] sys_reset_sync, vin_reset_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sys_reset_sync <= 0;
        else sys_reset_sync <= {sys_reset_sync[0], 1'b1};
    wire sys_ready = sys_reset_sync[1];
    wire common_reset_n = rst_n && vin_rst_n;
    always @(posedge vin_clk or negedge common_reset_n)
        if (!common_reset_n) vin_reset_sync <= 0;
        else vin_reset_sync <= {vin_reset_sync[0], 1'b1};
    wire pixel_reset_n = vin_reset_sync[1];

    reg peer_fault = 1'b1;
    (* async_reg="true" *) reg [1:0] vin_alive_sync;
    always @(posedge clk or negedge pixel_reset_n)
        if (!pixel_reset_n) vin_alive_sync <= 0;
        else vin_alive_sync <= {vin_alive_sync[0], 1'b1};
    always @(posedge clk or negedge vin_rst_n)
        if (!vin_rst_n) peer_fault <= 1;
        else if (!sys_ready) peer_fault <= 0;
    assign desc_ready=state==IDLE && sys_ready && reader_idle && vin_alive_sync[1] && !peer_fault && !abort;
    assign busy = state != IDLE;
    assign frozen = state == FROZEN;
    assign mem_req_valid = 1'b0;
    assign mem_frame_id = 32'd0;
    assign mem_pixel_index = 32'd0;
    assign mem_rsp_ready = 1'b0;
    assign reader_flush = 1'b0;

    (* async_reg="true" *) reg req_sync1, req_sync2, release_sync1, release_sync2;
    reg req_seen, release_seen, release_ack, done_toggle, done_error;
    reg [31:0] done_frame;
    (* async_reg="true" *) reg done_sync1, done_sync2, release_ack1, release_ack2;
    always @(posedge clk or negedge sys_ready) begin
        if (!sys_ready) begin
            done_sync1   <= 0;
            done_sync2   <= 0;
            release_ack1 <= 0;
            release_ack2 <= 0;
        end else begin
            done_sync1   <= done_toggle;
            done_sync2   <= done_sync1;
            release_ack1 <= release_ack;
            release_ack2 <= release_ack1;
        end
    end
    always @(posedge vin_clk or negedge pixel_reset_n) begin
        if (!pixel_reset_n) begin
            req_sync1 <= 0;
            req_sync2 <= 0;
            release_sync1 <= 0;
            release_sync2 <= 0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
            release_sync1 <= release_toggle;
            release_sync2 <= release_sync1;
        end
    end

    reg de_d, source_open, geometry_bad;
    reg [15:0] blank_count, col, row;
    reg [31:0] source_frame;
    wire row_start = vin_de && !de_d;
    wire sof = row_start && blank_count >= BLANK_TH;
    wire row_end = !vin_de && de_d;
    wire eof = source_open && !vin_de && blank_count >= BLANK_TH - 1;
    wire [15:0] row_now = sof ? 16'd0 : row;
    wire [15:0] col_now = row_start ? 16'd0 : col;
    wire geometry_complete = row_end ? (row == 719 && col == 1280) : row == 720;
    reg [1:0] request_settle;
    reg [2:0] mode_p;
    reg [15:0] gx_p, gy_p, w_p, h_p;
    reg [15:0] left_p, right_p, top_p, bottom_p;
    reg [14:0] expected_p, produced_count;
    reg [8:0] out_col, out_row;
    reg [15:0] bin_x0, bin_x1, bin_y0, bin_y1;
    reg [10:0] horizontal_sum;
    (* ram_style="dram" *) reg [13:0] vertical_sum[0:255];
    wire [15:0] gray_sum=
  ({8'd0,vin_rgb[23:16]}<<6)+({8'd0,vin_rgb[23:16]}<<3)+({8'd0,vin_rgb[23:16]}<<2)+{8'd0,vin_rgb[23:16]}+
  ({8'd0,vin_rgb[15:8]}<<7)+({8'd0,vin_rgb[15:8]}<<4)+({8'd0,vin_rgb[15:8]}<<2)+({8'd0,vin_rgb[15:8]}<<1)+
  ({8'd0,vin_rgb[7:0]}<<4)+({8'd0,vin_rgb[7:0]}<<3)+({8'd0,vin_rgb[7:0]}<<2)+{8'd0,vin_rgb[7:0]};
    wire [7:0] gray_pixel = gray_sum[15:8];
    wire [10:0] horizontal_next = horizontal_sum + {3'd0, gray_pixel};
    wire [13:0] box_next=(row_now==bin_y0?14'd0:vertical_sum[out_col[7:0]])+{3'd0,horizontal_next};
    wire capture_pixel=(pstate==P_CAPTURE || (pstate==P_ARMED && sof)) && vin_de &&
  row_now>=top_p && row_now<bottom_p && col_now>=left_p && col_now<right_p;
    wire bin_end = capture_pixel && col_now == bin_x1 - 1'b1;
    wire box_end = bin_end && row_now == bin_y1 - 1'b1;
    wire [3:0] bin_w = bin_x1 - bin_x0, bin_h = bin_y1 - bin_y0;
    wire [7:0] box_area = bin_w * bin_h;

    reg mean_valid, write_valid;
    reg [13:0] mean_sum, mean_addr, write_addr;
    reg [7:0] mean_area, write_gray;
    function [7:0] box_mean;
        input [13:0] s;
        input [7:0] a;
        begin
            case (a)
                1: box_mean = s[7:0];
                4: box_mean = s >> 2;
                6: box_mean = s / 14'd6;
                9: box_mean = s / 14'd9;
                12: box_mean = s / 14'd12;
                16: box_mean = s >> 4;
                25: box_mean = s / 14'd25;
                64: box_mean = s >> 6;
                default: box_mean = 0;
            endcase
        end
    endfunction
    always @(posedge vin_clk) begin
        if (bin_end && pstate != P_DONE && pstate != P_IDLE && pstate != P_SETTLE)
            vertical_sum[out_col[7:0]] <= box_next;
    end
    always @(posedge vin_clk or negedge pixel_reset_n) begin
        if (!pixel_reset_n) begin
            de_d <= 0;
            source_open <= 0;
            geometry_bad <= 0;
            blank_count <= 0;
            col <= 0;
            row <= 0;
            source_frame <= 0;
            pstate <= P_IDLE;
            req_seen <= 0;
            release_seen <= 0;
            release_ack <= 0;
            done_toggle <= 0;
            done_error <= 0;
            done_frame <= 0;
            request_settle <= 0;
            mode_p <= 0;
            gx_p <= 0;
            gy_p <= 0;
            w_p <= 0;
            h_p <= 0;
            left_p <= 0;
            right_p <= 0;
            top_p <= 0;
            bottom_p <= 0;
            expected_p <= 0;
            produced_count <= 0;
            out_col <= 0;
            out_row <= 0;
            bin_x0 <= 0;
            bin_x1 <= 0;
            bin_y0 <= 0;
            bin_y1 <= 0;
            horizontal_sum <= 0;
            mean_valid <= 0;
            write_valid <= 0;
            mean_sum <= 0;
            mean_area <= 0;
            mean_addr <= 0;
            write_addr <= 0;
            write_gray <= 0;
        end else begin
            de_d <= vin_de;
            if (vin_de) begin
                blank_count <= 0;
                if (col != 65535) col <= col_now + 1'b1;
            end else begin
                col <= 0;
                if (blank_count != 65535) blank_count <= blank_count + 1'b1;
            end
            if (sof) begin
                source_open <= 1;
                geometry_bad <= 0;
                row <= 0;
                if (source_frame != 32'hffffffff) source_frame <= source_frame + 1'b1;
            end else if (row_end) begin
                if (row != 65535) row <= row + 1'b1;
                if (source_open && (col != 1280 || row >= 720)) geometry_bad <= 1;
            end
            if (eof) source_open <= 0;
            mean_valid  <= 0;
            write_valid <= mean_valid;
            if (mean_valid) begin
                write_gray <= box_mean(mean_sum, mean_area);
                write_addr <= mean_addr;
            end
            if (!vin_de) begin
                horizontal_sum <= 0;
                out_col <= 0;
                bin_x0 <= left_p;
                bin_x1 <= grid_native(gx_p + 16'd1, mode_p);
            end
            if (bin_end) begin
                horizontal_sum <= 0;
                if (out_col + 1'b1 < w_p) begin
                    out_col <= out_col + 1'b1;
                    bin_x0  <= bin_x1;
                    bin_x1  <= grid_native(gx_p + out_col + 16'd2, mode_p);
                end
                if (box_end && produced_count < expected_p && produced_count < 16384) begin
                    mean_valid <= 1;
                    mean_sum <= box_next;
                    mean_area <= box_area;
                    mean_addr <= produced_count[13:0];
                    produced_count <= produced_count + 1'b1;
                end
            end else if (capture_pixel) horizontal_sum <= horizontal_next;
            if(row_end && pstate==P_CAPTURE && row>=top_p && row<bottom_p && row==bin_y1-1'b1)begin
                out_row <= out_row + 1'b1;
                bin_y0  <= bin_y1;
                bin_y1  <= grid_native(gy_p + out_row + 16'd2, mode_p);
            end
            if (release_sync2 != release_seen) begin

                release_seen <= release_sync2;
                pstate <= P_DRAIN;
                request_settle <= 2;
                mean_valid <= 0;
                write_valid <= 0;
                horizontal_sum <= 0;
            end else
                case (pstate)
                    P_DRAIN: begin

                        if (request_settle != 0) request_settle <= request_settle - 1'b1;
                        else begin
                            req_seen <= req_sync2;
                            release_ack <= release_seen;
                            pstate <= P_IDLE;
                        end
                    end
                    P_IDLE:
                    if (req_sync2 != req_seen) begin
                        req_seen <= req_sync2;
                        request_settle <= 2;
                        pstate <= P_SETTLE;
                    end
                    P_SETTLE: begin
                        if (request_settle != 0) request_settle <= request_settle - 1'b1;
                        else begin
                            mode_p <= cmd_mode;
                            gx_p <= cmd_x;
                            gy_p <= cmd_y;
                            w_p <= cmd_w;
                            h_p <= cmd_h;
                            expected_p <= cmd_total;
                            left_p <= grid_native(cmd_x, cmd_mode);
                            right_p <= grid_native(cmd_x + cmd_w, cmd_mode);
                            top_p <= grid_native(cmd_y, cmd_mode);
                            bottom_p <= grid_native(cmd_y + cmd_h, cmd_mode);
                            bin_x0 <= grid_native(cmd_x, cmd_mode);
                            bin_x1 <= grid_native(cmd_x + 16'd1, cmd_mode);
                            bin_y0 <= grid_native(cmd_y, cmd_mode);
                            bin_y1 <= grid_native(cmd_y + 16'd1, cmd_mode);
                            produced_count <= 0;
                            out_row <= 0;
                            out_col <= 0;
                            horizontal_sum <= 0;
                            pstate <= P_ARMED;
                        end
                    end
                    P_ARMED:
                    if (sof) begin
                        if (source_frame == 32'hffffffff) begin
                            done_error <= 1;
                            done_frame <= 0;
                            done_toggle <= ~done_toggle;
                            pstate <= P_DONE;
                        end else begin
                            done_frame <= source_frame + 1'b1;
                            done_error <= 0;
                            pstate <= P_CAPTURE;
                        end
                    end
                    P_CAPTURE:
                    if (eof) begin

                        done_error<=geometry_bad || !geometry_complete || produced_count!=expected_p;
                        done_toggle <= ~done_toggle;
                        pstate <= P_DONE;
                        mean_valid <= 0;
                        write_valid <= 0;
                    end
                    default: begin
                    end
                endcase
        end
    end

    wire [7:0] bank_q[0:7];
    reg [2:0] read_bank;
    genvar bank;
    generate
        for (bank = 0; bank < 8; bank = bank + 1) begin : g_snapshot_bank
            roi_hires_gray_bank u_bank (
                .wclk(vin_clk),
                .we(write_valid && write_addr[13:11] == bank),
                .waddr(write_addr[10:0]),
                .wdata(write_gray),
                .rclk(clk),
                .raddr(rd_index[10:0]),
                .rdata(bank_q[bank])
            );
        end
    endgenerate
    always @(posedge clk) read_bank <= rd_index[13:11];
    wire [7:0] read_gray = bank_q[read_bank];
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
    always @(posedge clk) gamma_word <= gamma_curve[read_gray];
    wire [7:0] pixel_data = ROI_GAMMA_EN ? gamma_word : read_gray;
    wire pixel_valid = state == FROZEN && read_wait == 0 && rd_index < total_pixels;
    roi_packet_tx tx (
        .clk(clk),
        .rst_n(sys_ready),
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
    always @(posedge clk or negedge sys_ready) begin
        if (!sys_ready) begin
            state <= IDLE;
            geom_mode <= 0;
            prep_x <= 0;
            prep_y <= 0;
            prep_r <= 0;
            prep_b <= 0;
            cmd_mode <= 0;
            cmd_x <= 0;
            cmd_y <= 0;
            cmd_w <= 0;
            cmd_h <= 0;
            cmd_total <= 0;
            cmd_meta <= 0;
            packet_meta <= 0;
            sid <= 0;
            rid <= 0;
            req_toggle <= 0;
            release_toggle <= 0;
            timeout_count <= 0;
            done_settle <= 0;
            done_seen <= 0;
            rd_index <= 0;
            total_pixels <= 0;
            read_wait <= 0;
            send_start <= 0;
            send_pending <= 0;
            cancel_pending <= 0;
            lease_release <= 0;
            error <= 0;
        end else begin
            send_start <= 0;
            lease_release <= 0;
            error <= 0;
            case (state)
                IDLE: begin
                    done_seen <= done_sync2;
                    cancel_pending <= 0;
                    send_pending <= 0;
                    if (desc_valid && desc_ready) begin
                        if (!valid_desc) begin
                            error <= 1;
                            lease_release <= lease_valid;
                        end else begin

                            prep_x <= {crop_meta[88:80], 2'b0};
                            prep_r <= {det_right[8:0], 2'b0};
                            prep_y <= ({2'd0, crop_meta[103:96]} << 1) + {2'd0, crop_meta[103:96]};
                            prep_b <= ({2'd0, det_bottom[7:0]} << 1) + {2'd0, det_bottom[7:0]};
                            geom_mode <= 0;
                            cmd_meta <= crop_meta;
                            sid <= session_id;
                            rid <= request_id;
                            timeout_count <= 0;
                            done_settle <= 0;
                            state <= GEOM_SCALE;
                        end
                    end
                end
                GEOM_SCALE, GEOM_SIZE, GEOM_AREA, GEOM_SELECT: begin

                    if(abort||peer_fault||!vin_alive_sync[1]||!lease_valid||lease_frame_id!=cmd_meta[31:0])begin
                        error <= 1;
                        lease_release <= 1;
                        state <= IDLE;
                    end else
                        case (state)
                            GEOM_SCALE: state <= GEOM_SIZE;
                            GEOM_SIZE:  state <= GEOM_AREA;
                            GEOM_AREA:  state <= GEOM_SELECT;
                            GEOM_SELECT: begin
                                if (geom_fits && geom_area <= 16384) begin
                                    cmd_mode <= geom_mode;
                                    cmd_x <= {5'd0, geom_x};
                                    cmd_y <= {6'd0, geom_y};
                                    cmd_w <= {5'd0, geom_w};
                                    cmd_h <= {6'd0, geom_h};
                                    cmd_total <= geom_area[14:0];
                                    req_toggle <= ~req_toggle;
                                    timeout_count <= 0;
                                    done_settle <= 0;
                                    state <= CAPTURE;
                                end else if (geom_mode == 6) begin
                                    error <= 1;
                                    lease_release <= 1;
                                    state <= IDLE;
                                end else begin
                                    geom_mode <= geom_mode + 1'b1;
                                    state <= GEOM_SCALE;
                                end
                            end
                        endcase
                end
                CAPTURE: begin
                    timeout_count <= timeout_count + 1'b1;
                    if(abort || peer_fault || !vin_alive_sync[1] || timeout_count>=CAPTURE_TIMEOUT_CYCLES-1 || !lease_valid || lease_frame_id!=cmd_meta[31:0])begin
                        error <= 1;
                        lease_release <= 1;
                        release_toggle <= ~release_toggle;
                        state <= DRAIN;
                        done_settle <= 0;
                    end else if (done_settle != 0) begin
                        done_settle <= done_settle - 1'b1;
                        if (done_settle == 1) begin
                            lease_release <= 1;
                            if (done_error || done_frame == 0) begin
                                error <= 1;
                                release_toggle <= ~release_toggle;
                                state <= DRAIN;
                            end else begin
                                packet_meta <= cmd_meta;
                                packet_meta[31:0] <= done_frame;
                                packet_meta[63:48] <= grid_width(cmd_mode);
                                packet_meta[79:64] <= grid_height(cmd_mode);
                                packet_meta[95:80] <= cmd_x;
                                packet_meta[111:96] <= cmd_y;
                                packet_meta[127:112] <= cmd_w;
                                packet_meta[143:128] <= cmd_h;
                                total_pixels <= cmd_total;
                                rd_index <= 0;
                                read_wait <= 2;
                                send_pending <= 1;
                                state <= FROZEN;
                            end
                        end
                    end else if (done_sync2 != done_seen) begin
                        done_seen   <= done_sync2;
                        done_settle <= 2;
                    end
                end
                FROZEN: begin
                    if (abort || peer_fault || !vin_alive_sync[1]) begin
                        cancel_pending <= 1;
                        if (!cancel_pending) error <= 1;
                    end
                    if (read_wait != 0) read_wait <= read_wait - 1'b1;
                    if (pixel_valid && pixel_ready) begin
                        rd_index  <= rd_index + 1'b1;
                        read_wait <= 2;
                    end
                    if (!packet_busy && !send_start && !packet_done) begin

                        if (release_snapshot || abort || cancel_pending || peer_fault) begin
                            send_pending <= 0;
                            release_toggle <= ~release_toggle;
                            state <= DRAIN;
                        end else if (resend || send_pending) begin
                            if (!DEFER_TX || send_enable) begin
                                rd_index <= 0;
                                read_wait <= 2;
                                send_start <= 1;
                                send_pending <= 0;
                            end else send_pending <= 1;
                        end
                    end
                    if (packet_reject) begin
                        error <= 1;
                        cancel_pending <= 1;
                    end
                end
                DRAIN:
                if (release_ack2 == release_toggle) begin
                    state <= IDLE;
                    done_seen <= done_sync2;
                end
                default: begin
                    state <= DRAIN;
                    error <= 1;
                end
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if (BLANK_TH < 8 || BLANK_TH > 65534 || CAPTURE_TIMEOUT_CYCLES < 16)
            $fatal(1, "Unsupported roi_hires_snapshot parameters");
    end
    // synthesis translate_on
endmodule

module roi_hires_gray_bank (
    input wire wclk,
    we,
    input wire [10:0] waddr,
    input wire [7:0] wdata,
    input wire rclk,
    input wire [10:0] raddr,
    output reg [7:0] rdata
);
    (* ram_style="bram" *) reg [7:0] mem[0:2047];
    always @(posedge wclk) if (we) mem[waddr] <= wdata;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
