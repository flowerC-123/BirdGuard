module a_display_bridge #(
    parameter SOURCE_W = 320,
    SOURCE_H = 240,
    DISPLAY_W = 1280,
    DISPLAY_H = 720,
    SLOTS = 4,
    LIVE_SCENE = 0
) (
    input wire scene_valid,
    input wire [31:0] scene_frame,
    scene_session,
    input wire [223:0] scene_boxes,
    input wire [11:0] scene_shapes,
    input wire clk,
    rst_n,
    mapping_valid,
    input captured,
    input wire [159:0] meta,
    input wire [31:0] session_id,
    request_id,
    input wire [16:0] motion_count,
    input wire motion_known,
    capture_error,
    input wire matched,
    input wire [31:0] matched_frame,
    input wire [15:0] matched_roi,
    input wire [7:0] status,
    decision,
    confidence,
    flags,
    input wire timed_out,
    transport_fault,
    cancel,
    input wire info_valid,
    state_valid,
    input wire [3:0] state_code,
    input wire voltage_known,
    input wire [15:0] voltage_mv,
    input wire mailbox_ready,
    output wire send,
    output wire [596:0] payload,
    output reg mapping_rejected
);
    reg [511:0] slots;
    reg [31:0] sid, fid;
    reg [20:0] info;
    reg [1:0] cur_roi;
    reg [31:0] cur_frame;
    reg dirty;
    reg [31:0] slot_frame[0:3];
    integer j;
    wire [31:0] right = {16'd0, meta[95:80]} + {16'd0, meta[127:112]};
    wire [31:0] bottom = {16'd0, meta[111:96]} + {16'd0, meta[143:128]};
    wire geom_ok=meta[63:48]==SOURCE_W && meta[79:64]==SOURCE_H &&
  meta[127:112]!=0 && meta[143:128]!=0 && right<=SOURCE_W && bottom<=SOURCE_H;

    wire [31:0] xx0 = ({16'd0, meta[95:80]} * DISPLAY_W) / SOURCE_W;
    wire [31:0] yy0 = ({16'd0, meta[111:96]} * DISPLAY_H) / SOURCE_H;
    wire [31:0] xx1 = (right * DISPLAY_W + SOURCE_W - 1) / SOURCE_W - 1;
    wire [31:0] yy1 = (bottom * DISPLAY_H + SOURCE_H - 1) / SOURCE_H - 1;

    wire [127:0] new_slot = {
        !motion_known,
        request_id,
        7'd0,
        (capture_error ? 3'd4 : 3'd0),
        3'd0,
        motion_count,
        meta[47:32],
        yy1[11:0],
        xx1[11:0],
        yy0[11:0],
        xx0[11:0],
        1'b1
    };
    wire [15:0] roi_w = meta[47:32];
    wire roi_ok = (roi_w < SLOTS) && (roi_w < 4);
    wire [1:0] roi_idx = roi_w[1:0];
    wire match_ok = (matched_roi < SLOTS) && (matched_roi < 4);
    wire [1:0] matched_idx = matched_roi[1:0];

    wire any_active = slots[0] || slots[128] || slots[256] || slots[384];
    assign payload = {info, sid, fid, slots};
    assign send = dirty && mailbox_ready;
    function [2:0] clean_shape;
        input [2:0] sh;
        begin
            case (sh)
                3'd1, 3'd2, 3'd3: clean_shape = sh;
                default: clean_shape = 3'd0;
            endcase
        end
    endfunction
    function [127:0] pack_scene;
        input [55:0] box;
        input [15:0] roi;
        input [2:0] shape;
        reg [31:0] x0, x1, y0, y1;
        begin
            if (DISPLAY_W % SOURCE_W == 0) begin
                x0 = box[10:1] * (DISPLAY_W / SOURCE_W);
                x1 = (box[20:11] + 32'd1) * (DISPLAY_W / SOURCE_W) - 1;
            end else begin
                x0 = ({22'd0, box[10:1]} * DISPLAY_W) / SOURCE_W;
                x1 = (({22'd0, box[20:11]} + 1) * DISPLAY_W + SOURCE_W - 1) / SOURCE_W - 1;
            end
            if (DISPLAY_H % SOURCE_H == 0) begin
                y0 = box[29:21] * (DISPLAY_H / SOURCE_H);
                y1 = (box[38:30] + 32'd1) * (DISPLAY_H / SOURCE_H) - 1;
            end else begin
                y0 = ({23'd0, box[29:21]} * DISPLAY_H) / SOURCE_H;
                y1 = (({23'd0, box[38:30]} + 1) * DISPLAY_H + SOURCE_H - 1) / SOURCE_H - 1;
            end
            pack_scene = 0;
            if(box[0]&&box[10:1]<=box[20:11]&&box[29:21]<=box[38:30]&&
      box[20:11]<SOURCE_W&&box[38:30]<SOURCE_H)
                pack_scene = {
                    1'b0,
                    32'd0,
                    7'd0,
                    3'd0,
                    shape,
                    box[55:39],
                    roi,
                    y1[11:0],
                    x1[11:0],
                    y0[11:0],
                    x0[11:0],
                    1'b1
                };
        end
    endfunction
    always @(posedge clk) begin
        if (!rst_n) begin
            slots <= 0;
            sid <= 0;
            fid <= 0;
            info <= {1'b0, 16'd0, 4'hf};
            dirty <= 0;
            mapping_rejected <= 0;
            cur_roi <= 0;
            cur_frame <= 0;
            for (j = 0; j < 4; j = j + 1) slot_frame[j] <= 0;
        end else begin
            mapping_rejected <= 0;
            if (send) dirty <= 0;
            if (info_valid) begin
                info  <= {voltage_known, (voltage_mv / 16'd10), (state_valid ? state_code : 4'hf)};
                dirty <= 1;
            end
            if (cancel) begin
                slots   <= 0;
                cur_roi <= 0;
                dirty   <= 1;
            end else begin
                if(any_active && matched && match_ok && slots[matched_idx*128] &&
                slots[matched_idx*128 + 49 +: 16]==matched_roi &&
                matched_frame==slot_frame[matched_idx])begin
                    slots[matched_idx*128+88+:7] <= 0;
                    dirty <= 1;
                    if (flags[0]) slots[matched_idx*128+85+:3] <= 5;
                    else if (status != 0) slots[matched_idx*128+85+:3] <= 4;
                    else if (decision == 0) slots[matched_idx*128+85+:3] <= 2;
                    else if (decision == 1 && confidence >= 80 && confidence <= 100) begin
                        slots[matched_idx*128+85+:3] <= 1;
                        slots[matched_idx*128+88+:7] <= confidence[6:0];
                    end else slots[matched_idx*128+85+:3] <= 0;
                end

                if(any_active && (timed_out || transport_fault) && slots[cur_roi*128] &&
       (!LIVE_SCENE || slot_frame[cur_roi]==cur_frame))begin
                    slots[cur_roi*128+88+:7] <= 0;
                    slots[cur_roi*128+85+:3] <= timed_out ? 3'd3 : 3'd4;
                    dirty <= 1;
                end
                if (captured) begin
                    if (mapping_valid && geom_ok && roi_ok) begin
                        cur_roi   <= roi_idx;
                        cur_frame <= meta[31:0];
                        if (!LIVE_SCENE) begin

                            if (sid != session_id || fid != meta[31:0]) slots <= 0;
                            sid <= session_id;
                            fid <= meta[31:0];
                            dirty <= 1;
                            slot_frame[roi_idx] <= meta[31:0];
                            slots[roi_idx*128+:128] <= new_slot;
                        end else if(sid==session_id&&slot_frame[roi_idx]==meta[31:0]&&slots[roi_idx*128])begin

                            slots[roi_idx*128+95+:32] <= request_id;
                            dirty <= 1;
                        end
                    end else begin
                        mapping_rejected <= 1;
                    end
                end
                if(LIVE_SCENE && scene_valid && mapping_valid && scene_frame!=0 && scene_session!=0)begin
                    sid   <= scene_session;
                    fid   <= scene_frame;
                    dirty <= 1;
                    for (j = 0; j < 4; j = j + 1) begin
                        slots[j*128+:128] <= pack_scene(
                            scene_boxes[j*56+:56], j, clean_shape(scene_shapes[j*3+:3])
                        );
                        slot_frame[j] <= scene_frame;
                    end
                end
            end

            if (!mapping_valid && any_active) begin
                slots <= 0;
                dirty <= 1;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(SOURCE_W<1 || SOURCE_H<1 || SOURCE_W>65535 || SOURCE_H>65535 ||
     DISPLAY_W<1 || DISPLAY_H<1 || DISPLAY_W>4096 || DISPLAY_H>4096 ||
     SLOTS<1 || SLOTS>4)
            $fatal(1, "Invalid a_display_bridge parameters");
    end
    // synthesis translate_on
endmodule
