module roi_packet_tx (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [31:0] session_id,
    request_id,
    input wire [159:0] crop_meta,
    input wire [7:0] pixel_data,
    input wire pixel_valid,
    output wire pixel_ready,
    output reg [7:0] out_data,
    output wire out_valid,
    input wire out_ready,
    output wire out_last,
    output reg busy,
    output reg done,
    output reg reject
);
    function [15:0] crc_byte;
        input [15:0] c;
        input [7:0] b;
        reg [15:0] t;
        integer k;
        begin
            t = c ^ {b, 8'h00};
            for (k = 0; k < 8; k = k + 1) t = t[15] ? (t << 1) ^ 16'h1021 : (t << 1);
            crc_byte = t;
        end
    endfunction
    wire [15:0] sw = crop_meta[63:48], sh = crop_meta[79:64];
    wire [15:0] x = crop_meta[95:80], y = crop_meta[111:96];
    wire [15:0] w = crop_meta[127:112], h = crop_meta[143:128];
    wire [7:0] fmt = crop_meta[151:144];
    wire [31:0] area = {16'd0, w} * {16'd0, h};
    wire [31:0] bytes_needed = (fmt == 2) ? area * 32'd3 : area;
    wire valid_meta=session_id!=0 && request_id!=0 &&
  sw>0 && sw<=4096 && sh>0 && sh<=4096 &&
  w>0 && w<=256 && h>0 && h<=256 &&
  ({1'b0,x}+{1'b0,w})<={1'b0,sw} &&
  ({1'b0,y}+{1'b0,h})<={1'b0,sh} &&
  (fmt==1 || fmt==2) && crop_meta[159:152]==0 &&
  bytes_needed>0 && bytes_needed<=16384;
    reg [31:0] sid, rid;
    reg [159:0] meta;
    reg [15:0] body_len, total_len, pos, header_crc, frame_crc;
    wire payload = pos >= 36 && pos < total_len - 2;
    assign out_valid = busy && (!payload || pixel_valid);
    assign pixel_ready = busy && payload && out_ready;
    assign out_last = busy && pos == total_len - 1;
    always @* begin
        out_data = 0;
        if (pos == 0) out_data = 8'haa;
        else if (pos == 1) out_data = 8'h55;
        else if (pos == 2 || pos == 3) out_data = 1;
        else if (pos >= 4 && pos <= 7) out_data = sid >> ((pos - 4) * 8);
        else if (pos >= 8 && pos <= 11) out_data = rid >> ((pos - 8) * 8);
        else if (pos == 12) out_data = body_len[7:0];
        else if (pos == 13) out_data = body_len[15:8];
        else if (pos == 14) out_data = header_crc[7:0];
        else if (pos == 15) out_data = header_crc[15:8];
        else if (pos >= 16 && pos <= 35) out_data = meta >> ((pos - 16) * 8);
        else if (payload) out_data = pixel_data;
        else if (pos == total_len - 2) out_data = frame_crc[7:0];
        else if (pos == total_len - 1) out_data = frame_crc[15:8];
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0;
            done <= 0;
            reject <= 0;
            pos <= 0;
            sid <= 0;
            rid <= 0;
            meta <= 0;
            body_len <= 0;
            total_len <= 0;
            header_crc <= 16'hffff;
            frame_crc <= 16'hffff;
        end else begin
            done   <= 0;
            reject <= 0;
            if (!busy) begin
                if (start) begin
                    if (!valid_meta) reject <= 1;
                    else begin
                        busy <= 1;
                        sid <= session_id;
                        rid <= request_id;
                        meta <= crop_meta;
                        body_len <= bytes_needed[15:0] + 16'd20;
                        total_len <= bytes_needed[15:0] + 16'd38;
                        pos <= 0;
                        header_crc <= 16'hffff;
                        frame_crc <= 16'hffff;
                    end
                end
            end else if (out_valid && out_ready) begin
                if (pos >= 2 && pos <= 13) header_crc <= crc_byte(header_crc, out_data);
                if (pos >= 2 && pos < total_len - 2) frame_crc <= crc_byte(frame_crc, out_data);
                if (out_last) begin
                    busy <= 0;
                    done <= 1;
                end else pos <= pos + 1'b1;
            end
        end
    end
endmodule
