// Publish completed ROI results with their capture context.
module result_display_window #(
    parameter CLOCK_HZ = 50000000,
    MAX_INFLIGHT = 4,
    TRUSTED_MATCH_CONTEXT = 0
) (
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
    input wire [16:0] motion_count,
    input wire motion_known,
    input wire wire_done,
    input wire [159:0] packet_meta,
    input wire matched,
    input wire [31:0] matched_frame,
    matched_session,
    matched_request,
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
    output reg geometry_rejected,
    output wire [16:0] matched_motion,
    output wire matched_patrol,
    output wire timing_valid,
    output wire [15:0] transmit_ms,
    reply_ms,
    total_ms
);
    localparam IW = (MAX_INFLIGHT < 2) ? 1 : $clog2(MAX_INFLIGHT);
    localparam MT = (CLOCK_HZ < 1000) ? 1 : CLOCK_HZ / 1000;
    localparam MW = (MT < 2) ? 1 : $clog2(MT);
    reg [MW-1:0] tick;
    reg [  15:0] now_ms;
    reg pending, dirty;
    reg [31:0] epoch, psid, prid, pframe;
    reg [15:0] proi, started;
    reg [16:0] pmotion;
    reg pknown;
    reg [MAX_INFLIGHT-1:0] known_motion;
    reg [11:0] ax0, ay0, ax1, ay1;
    reg [MAX_INFLIGHT-1:0] valid;
    reg [31:0] ids[0:MAX_INFLIGHT-1], frames[0:MAX_INFLIGHT-1], wire_frames[0:MAX_INFLIGHT-1];
    reg [15:0] rois[0:MAX_INFLIGHT-1], starts[0:MAX_INFLIGHT-1], sends[0:MAX_INFLIGHT-1];
    reg [47:0] coords [0:MAX_INFLIGHT-1];
    reg [16:0] motions[0:MAX_INFLIGHT-1];
    reg hit, space;
    reg [IW-1:0] ri, wi;
    integer j;
    always @* begin
        hit = 0;
        space = 0;
        ri = 0;
        wi = 0;
        for (j = MAX_INFLIGHT - 1; j >= 0; j = j - 1) begin
            if (!valid[j]) begin
                space = 1;
                wi = j;
            end

            if(valid[j]&&ids[j]==matched_request&&matched_session==epoch&&
      (TRUSTED_MATCH_CONTEXT||(frames[j]==matched_frame&&rois[j]==matched_roi)))begin
                hit = 1;
                ri  = j;
            end
        end
    end
    wire [11:0] px0=coords[ri][11:0],py0=coords[ri][23:12],px1=coords[ri][35:24],py1=coords[ri][47:36];
    wire [16:0] cr = {1'b0, meta[95:80]} + {1'b0, meta[127:112]};
    wire [16:0] cb = {1'b0, meta[111:96]} + {1'b0, meta[143:128]};
    wire capture_ok=meta[31:0]!=0&&meta[63:48]==320&&meta[79:64]==240&&meta[127:112]!=0&&meta[143:128]!=0&&cr<=320&&cb<=240&&session_id==link_session_id&&request_id!=0&&!capture_error;
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
    wire [11:0] envelope_x1 = (px1 + 12'd4) >> 2, envelope_y1 = (py1 + 12'd3) / 12'd3;
    wire precise_ok=box_valid&&box_w!=0&&box_h!=0&&br<=320&&bb<=240&&box_x>=(px0>>2)&&box_y>=(py0/12'd3)&&br<=envelope_x1&&bb<=envelope_y1;
    wire real_bird=status==0&&decision==1&&confidence>=80&&confidence<=100&&flags==0;
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
        input [15:0] roi;
        input [31:0] sid, rid, fid;
        begin
            pack = {20'd0, roi, sid, rid, fid, y1, x1, y0, x0, conf, label, precise, 1'b1};
        end
    endfunction
    assign send = dirty && mailbox_ready;
    assign matched_motion = hit ? motions[ri] : 17'd0;
    assign matched_patrol = hit && known_motion[ri] && motions[ri] == 0;
    assign timing_valid = matched && hit;
    assign total_ms = hit ? now_ms - starts[ri] : 16'd0;
    assign transmit_ms = hit ? sends[ri] - starts[ri] : 16'd0;
    assign reply_ms = hit ? now_ms - sends[ri] : 16'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 0;
            now_ms <= 0;
            pending <= 0;
            dirty <= 0;
            payload <= 0;
            geometry_rejected <= 0;
            valid <= 0;
            epoch <= 0;
            psid <= 0;
            prid <= 0;
            pframe <= 0;
            proi <= 0;
            started <= 0;
            pmotion <= 0;
            pknown <= 0;
            known_motion <= 0;
            ax0 <= 0;
            ay0 <= 0;
            ax1 <= 0;
            ay1 <= 0;
            for (j = 0; j < MAX_INFLIGHT; j = j + 1) begin
                ids[j] <= 0;
                frames[j] <= 0;
                wire_frames[j] <= 0;
                rois[j] <= 0;
                starts[j] <= 0;
                sends[j] <= 0;
                coords[j] <= 0;
                motions[j] <= 0;
            end
        end else begin
            geometry_rejected <= 0;
            if (tick == MT - 1) begin
                tick   <= 0;
                now_ms <= now_ms + 1'b1;
            end else tick <= tick + 1'b1;
            if (send) dirty <= 0;
            if (pending && (transport_fault || capture_error)) begin
                pending <= 0;
                dirty   <= 1;
                payload <= pack(0, 4, 0, ax0, ay0, ax1, ay1, proi, psid, prid, pframe);
            end
            if ((matched || timed_out) && hit) begin
                valid[ri] <= 0;
                dirty <= 1;
                if (timed_out)
                    payload <= pack(
                        0, 3, 0, px0, py0, px1, py1, rois[ri], epoch, ids[ri], wire_frames[ri]
                    );
                else if (real_bird && precise_ok)
                    payload <= pack(
                        1,
                        1,
                        confidence[6:0],
                        box_x[8:0] * 12'd4,
                        box_y[7:0] * 12'd3,
                        br[8:0] * 12'd4 - 12'd1,
                        bb[8:0] * 12'd3 - 12'd1,
                        rois[ri],
                        epoch,
                        ids[ri],
                        wire_frames[ri]
                    );
                else begin
                    payload <= pack(
                        0,
                        result_label,
                        real_bird ? confidence[6:0] : 7'd0,
                        px0,
                        py0,
                        px1,
                        py1,
                        rois[ri],
                        epoch,
                        ids[ri],
                        wire_frames[ri]
                    );
                    if (real_bird && box_valid && !precise_ok) geometry_rejected <= 1;
                end
            end
            if (wire_done && pending && session_id == psid && request_id == prid) begin
                pending <= 0;
                if (wire_ok && space) begin
                    valid[wi] <= 1;
                    ids[wi] <= prid;
                    frames[wi] <= pframe;
                    wire_frames[wi] <= packet_meta[31:0];
                    rois[wi] <= proi;
                    coords[wi] <= {wy1, wx1, wy0, wx0};
                    starts[wi] <= started;
                    sends[wi] <= now_ms;
                    motions[wi] <= pmotion;
                    known_motion[wi] <= pknown;
                end else geometry_rejected <= 1;
            end
            if (captured) begin
                pending <= capture_ok;
                psid <= session_id;
                prid <= request_id;
                pframe <= meta[31:0];
                proi <= meta[47:32];
                started <= now_ms;
                pmotion <= motion_count;
                pknown <= motion_known;
                ax0 <= meta[88:80] * 12'd4;
                ay0 <= meta[103:96] * 12'd3;
                ax1 <= cr[8:0] * 12'd4 - 12'd1;
                ay1 <= cb[8:0] * 12'd3 - 12'd1;
                if (!capture_ok) geometry_rejected <= 1;
            end
            if(cancel||!mapping_valid||!link_session_valid||link_session_id==0||epoch!=link_session_id)begin
                pending <= 0;
                valid   <= 0;
                payload <= 0;
                epoch   <= link_session_id;
                if (payload[0] || matched || timed_out) dirty <= 1;

            end
        end
    end
    // synthesis translate_off
    initial if (MAX_INFLIGHT < 2 || MAX_INFLIGHT > 4) $fatal(1, "Invalid result window");
    // synthesis translate_on
endmodule
