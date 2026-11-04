module roi_result_rx #(
    parameter GAP_CYCLES = 18750000,
    PACKET_CYCLES = 187500000
) (
    input wire clk,
    rst_n,
    clear,
    byte_valid,
    byte_error,
    input wire [7:0] byte_data,
    output reg reply_valid,
    packet_error,
    partial_timeout,
    output reg [31:0] reply_session,
    reply_request,
    processing_ms,
    output reg [7:0] reply_status,
    reply_decision,
    reply_confidence,
    reply_flags,
    output reg reply_box_valid,
    output reg [15:0] reply_box_x,
    reply_box_y,
    reply_box_w,
    reply_box_h
);
    reg [5:0] pos;
    reg [4:0] body_len;
    reg [15:0] box_x, box_y, box_w, box_h;
    wire [5:0] body_last = {1'b0, body_len} + 6'd15;
    wire [5:0] frame_crc_lo = {1'b0, body_len} + 6'd16;
    wire [5:0] frame_crc_hi = {1'b0, body_len} + 6'd17;
    reg [31:0] gap, total, sid, rid, ms;
    reg [7:0] status, decision, confidence, flags;
    reg [15:0] hcrc, fcrc;
    reg [7:0] low_crc;
    function [15:0] crc;
        input [15:0] c;
        input [7:0] b;
        reg [15:0] t;
        integer k;
        begin
            t = c ^ {b, 8'd0};
            for (k = 0; k < 8; k = k + 1) t = t[15] ? (t << 1) ^ 16'h1021 : t << 1;
            crc = t;
        end
    endfunction
    wire semantic=sid!=0 && rid!=0 && (flags & 8'hfe)==0 && status<=5 &&
  ((status==0 && ((decision==1 && confidence<=100)||(decision==0 && confidence==255))) ||
   (status!=0 && decision==255 && confidence==255));
    wire bad_prefix=(pos==2 && byte_data!=1)||(pos==3 && byte_data!=8'h81)||
                 (pos==12 && byte_data!=8 && byte_data!=16)||(pos==13 && byte_data!=0);
    always @(posedge clk) begin
        if (!rst_n) begin
            pos <= 0;
            gap <= 0;
            total <= 0;
            sid <= 0;
            rid <= 0;
            ms <= 0;
            status <= 0;
            decision <= 0;
            confidence <= 0;
            flags <= 0;
            hcrc <= 16'hffff;
            fcrc <= 16'hffff;
            low_crc <= 0;
            body_len <= 8;
            box_x <= 0;
            box_y <= 0;
            box_w <= 0;
            box_h <= 0;
            reply_box_valid <= 0;
            reply_box_x <= 0;
            reply_box_y <= 0;
            reply_box_w <= 0;
            reply_box_h <= 0;
            reply_valid <= 0;
            packet_error <= 0;
            partial_timeout <= 0;
            reply_session <= 0;
            reply_request <= 0;
            processing_ms <= 0;
            reply_status <= 0;
            reply_decision <= 0;
            reply_confidence <= 0;
            reply_flags <= 0;
        end else begin
            reply_valid <= 0;
            packet_error <= 0;
            partial_timeout <= 0;
            reply_box_valid <= 0;
            reply_box_x <= 0;
            reply_box_y <= 0;
            reply_box_w <= 0;
            reply_box_h <= 0;
            if (clear || byte_error) begin
                pos <= 0;
                gap <= 0;
                total <= 0;
                packet_error <= byte_error;
            end
   else if(pos!=0 && (total>=PACKET_CYCLES-1 || (!byte_valid && gap>=GAP_CYCLES-1))) begin
                pos <= 0;
                gap <= 0;
                total <= 0;
                partial_timeout <= 1;
                packet_error <= 1;
            end else begin
                if (pos != 0) begin
                    gap   <= gap + 1'b1;
                    total <= total + 1'b1;
                end
                if (byte_valid) begin
                    gap <= 0;
                    if (pos == 0) begin
                        if (byte_data == 8'haa) begin
                            pos   <= 1;
                            total <= 0;
                        end
                    end else if (pos == 1) begin
                        if (byte_data == 8'h55) begin
                            pos <= 2;
                            hcrc <= 16'hffff;
                            fcrc <= 16'hffff;
                            sid <= 0;
                            rid <= 0;
                            ms <= 0;
                            body_len <= 8;
                            box_x <= 0;
                            box_y <= 0;
                            box_w <= 0;
                            box_h <= 0;
                        end else if (byte_data == 8'haa) pos <= 1;
                        else pos <= 0;
                    end else if (bad_prefix) begin
                        pos <= byte_data == 8'haa ? 1 : 0;
                        total <= 0;
                        packet_error <= 1;
                    end else begin
                        pos <= pos + 1'b1;
                        if (pos >= 2 && pos <= 13) hcrc <= crc(hcrc, byte_data);
                        if (pos >= 2 && pos <= body_last) fcrc <= crc(fcrc, byte_data);
                        if (pos >= 4 && pos <= 7) sid[(pos-4)*8+:8] <= byte_data;
                        if (pos >= 8 && pos <= 11) rid[(pos-8)*8+:8] <= byte_data;
                        if (pos == 12) body_len <= byte_data[4:0];
                        if (pos == 14 || pos == frame_crc_lo) low_crc <= byte_data;
                        if (pos == 15 && {byte_data, low_crc} != hcrc) begin
                            pos <= byte_data == 8'haa ? 1 : 0;
                            total <= 0;
                            packet_error <= 1;
                        end
                        case (pos)
                            16: status <= byte_data;
                            17: decision <= byte_data;
                            18: confidence <= byte_data;
                            19: flags <= byte_data;
                            20, 21, 22, 23: ms[(pos-20)*8+:8] <= byte_data;
                            default: begin
                            end
                        endcase
                        if (body_len == 16) begin
                            case (pos)
                                24, 25: box_x[(pos-24)*8+:8] <= byte_data;
                                26, 27: box_y[(pos-26)*8+:8] <= byte_data;
                                28, 29: box_w[(pos-28)*8+:8] <= byte_data;
                                30, 31: box_h[(pos-30)*8+:8] <= byte_data;
                                default: begin
                                end
                            endcase
                        end
                        if (pos == frame_crc_hi) begin
                            pos   <= 0;
                            total <= 0;
                            if ({byte_data, low_crc} == fcrc && semantic) begin
                                reply_valid <= 1;
                                reply_session <= sid;
                                reply_request <= rid;
                                processing_ms <= ms;
                                reply_status <= status;
                                reply_decision <= decision;
                                reply_confidence <= confidence;
                                reply_flags <= flags;
                                if(body_len==16 && status==0 && decision==1 && confidence>=80 && confidence<=100 &&
            flags==0 && box_w!=0 && box_h!=0)begin
                                    reply_box_valid <= 1;
                                    reply_box_x <= box_x;
                                    reply_box_y <= box_y;
                                    reply_box_w <= box_w;
                                    reply_box_h <= box_h;
                                end
                            end else begin
                                packet_error <= 1;
                                if (byte_data == 8'haa) pos <= 1;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
