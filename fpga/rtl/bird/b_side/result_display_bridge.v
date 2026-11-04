module result_display_bridge (
    input wire clk,
    rst_n,
    cancel,
    mapping_valid,
    link_session_valid,
    input wire [31:0] link_session_id,
    input wire captured,
    capture_error,
    input wire [159:0] meta,
    input wire [31:0] session_id,
    request_id,
    input wire wire_done,
    input wire [159:0] packet_meta,
    input wire matched,
    input wire [31:0] matched_frame,
    input wire [15:0] matched_roi,
    input wire [7:0] status,
    decision,
    confidence,
    flags,
    input wire box_valid,
    input wire [15:0] box_x,
    box_y,
    box_w,
    box_h,
    input wire timed_out,
    transport_fault,
    mailbox_ready,
    output wire send,
    output reg [191:0] payload,
    output reg geometry_rejected
);
    reg pending, sent, dirty;
    reg [31:0] psid, prid, pframe, wire_frame;
    reg [15:0] proi;
    reg [11:0] px0, py0, px1, py1;
    wire [16:0] cr = {1'b0, meta[95:80]} + {1'b0, meta[127:112]};
    wire [16:0] cb = {1'b0, meta[111:96]} + {1'b0, meta[143:128]};
    wire capture_ok=meta[31:0]!=0 && meta[63:48]==320 && meta[79:64]==240 &&
  meta[127:112]!=0 && meta[143:128]!=0 && cr<=320 && cb<=240 &&
  session_id!=0 && request_id!=0 && !capture_error;
    wire [16:0] wr = {1'b0, packet_meta[95:80]} + {1'b0, packet_meta[127:112]};
    wire [16:0] wb = {1'b0, packet_meta[111:96]} + {1'b0, packet_meta[143:128]};
    wire grid_legacy = packet_meta[63:48] == 320 && packet_meta[79:64] == 240;
    reg [2:0] grid_mode;
    reg grid_ok;
    always @* begin
        grid_mode = 0;
        grid_ok   = 1;
        case ({
            packet_meta[63:48], packet_meta[79:64]
        })
            {16'd1280, 16'd720} : grid_mode = 0;
            {16'd640, 16'd360} : grid_mode = 1;
            {16'd512, 16'd288} : grid_mode = 2;
            {16'd384, 16'd216} : grid_mode = 3;
            {16'd320, 16'd180} : grid_mode = 4;
            {16'd256, 16'd144} : grid_mode = 5;
            {16'd160, 16'd90} : grid_mode = 6;
            {16'd320, 16'd240} : grid_mode = 4;
            default: grid_ok = 0;
        endcase
    end

    function [11:0] native_edge;
        input [10:0] q;
        input [2:0] m;
        input ceiling;
        reg [13:0] t;
        begin
            case (m)
                0: native_edge = {1'b0, q};
                1: native_edge = {q, 1'b0};
                2: begin
                    t = ({3'd0, q} << 2) + q + (ceiling ? 14'd1 : 14'd0);
                    native_edge = t >> 1;
                end
                3: begin
                    t = ({3'd0, q} << 3) + ({3'd0, q} << 1) + (ceiling ? 14'd2 : 14'd0);
                    native_edge = t / 14'd3;
                end
                4: native_edge = {q, 2'b0};
                5: native_edge = ({1'b0, q} << 2) + q;
                default: native_edge = {q, 3'b0};
            endcase
        end
    endfunction
    wire wire_ok=grid_ok && packet_meta[31:0]!=0 && packet_meta[127:112]!=0 && packet_meta[143:128]!=0 &&
  wr<={1'b0,packet_meta[63:48]} && wb<={1'b0,packet_meta[79:64]} && packet_meta[47:32]==proi;
    wire [11:0] wx0 = native_edge(packet_meta[90:80], grid_mode, 1'b0);
    wire [11:0] wx1 = native_edge(wr[10:0], grid_mode, 1'b1) - 12'd1;
    wire [11:0] wy0 = grid_legacy ? packet_meta[103:96] * 12'd3 : native_edge(
        packet_meta[106:96], grid_mode, 1'b0
    );
    wire [11:0] wy1 = grid_legacy ? wb[8:0] * 12'd3 - 12'd1 : native_edge(
        wb[10:0], grid_mode, 1'b1
    ) - 12'd1;
    wire [16:0] br = {1'b0, box_x} + {1'b0, box_w}, bb = {1'b0, box_y} + {1'b0, box_h};

    wire [11:0] envelope_x1 = (px1 + 12'd4) >> 2;
    wire [11:0] envelope_y1 = (py1 + 12'd3) / 12'd3;
    wire precise_ok=box_valid && box_w!=0 && box_h!=0 && br<=320 && bb<=240 &&
  box_x>=(px0>>2) && box_y>=(py0/12'd3) && br<=envelope_x1 && bb<=envelope_y1;
    wire same_pending=pending && session_id==psid && request_id==prid &&
  matched_frame==pframe && matched_roi==proi;
    wire real_bird=status==0 && decision==1 && confidence>=80 && confidence<=100 && flags==0;
    reg [2:0] result_label;
    always @* begin
        if (flags == 1) result_label = 5;
        else if (status != 0 || (flags & 8'hfe) != 0) result_label = 4;
        else if (decision == 0) result_label = 2;
        else if (real_bird) result_label = 1;
        else result_label = 0;
    end
    function [191:0] pack;
        input precise;
        input [2:0] label;
        input [6:0] conf;
        input [11:0] x0, y0, x1, y1;
        begin
            pack = {
                20'd0, proi, psid, prid, wire_frame, y1, x1, y0, x0, conf, label, precise, 1'b1
            };
        end
    endfunction
    assign send = dirty && mailbox_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending <= 0;
            sent <= 0;
            dirty <= 0;
            payload <= 0;
            geometry_rejected <= 0;
            psid <= 0;
            prid <= 0;
            pframe <= 0;
            wire_frame <= 0;
            proi <= 0;
            px0 <= 0;
            py0 <= 0;
            px1 <= 0;
            py1 <= 0;
        end else begin
            geometry_rejected <= 0;
            if (send) dirty <= 0;
            if (matched && same_pending && sent) begin
                pending <= 0;
                dirty   <= 1;
                if (real_bird && precise_ok)
                    payload <= pack(
                        1'b1,
                        3'd1,
                        confidence[6:0],
                        box_x[8:0] * 12'd4,
                        box_y[7:0] * 12'd3,
                        br[8:0] * 12'd4 - 12'd1,
                        bb[8:0] * 12'd3 - 12'd1
                    );
                else begin

                    payload <= pack(
                        1'b0, result_label, real_bird ? confidence[6:0] : 7'd0, px0, py0, px1, py1
                    );
                    if (real_bird && box_valid && !precise_ok) geometry_rejected <= 1;
                end
            end
            if ((timed_out || transport_fault) && pending) begin
                pending <= 0;
                dirty   <= 1;
                payload <= pack(1'b0, timed_out ? 3'd3 : 3'd4, 7'd0, px0, py0, px1, py1);
            end
            if (wire_done && pending && session_id == psid && request_id == prid) begin
                sent <= wire_ok;
                if (wire_ok) begin
                    px0 <= wx0;
                    py0 <= wy0;
                    px1 <= wx1;
                    py1 <= wy1;
                    wire_frame <= packet_meta[31:0];
                end else geometry_rejected <= 1;
            end
            if (captured) begin
                pending <= capture_ok;
                sent <= 0;
                psid <= session_id;
                prid <= request_id;
                pframe <= meta[31:0];
                proi <= meta[47:32];
                wire_frame <= meta[31:0];
                px0 <= meta[88:80] * 12'd4;
                py0 <= meta[103:96] * 12'd3;
                px1 <= cr[8:0] * 12'd4 - 12'd1;
                py1 <= cb[8:0] * 12'd3 - 12'd1;
                if (!capture_ok) geometry_rejected <= 1;
            end

            if(cancel || !mapping_valid || !link_session_valid || link_session_id==0 ||
      (pending && link_session_id!=psid) || (payload[0] && payload[155:124]!=link_session_id))begin
                pending <= 0;
                sent <= 0;
                payload <= 0;
                if(payload[0] || (matched && same_pending && sent) || ((timed_out || transport_fault) && pending))
                    dirty <= 1;
            end
        end
    end
endmodule
