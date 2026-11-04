module ccl_result_tracker #(
    parameter CLOCK_HZ = 50000000,
    CONTEXT_PAD = 16,
    parameter TICK_CYCLES = CLOCK_HZ / 10,
    HOLD_TICKS = 80,
    parameter MATCH_MARGIN = 8,
    REPLACE_DISTANCE = 32,
    MIN_ROI_W = 73,
    MIN_ROI_H = 74,
    MAX_FRAME_GAP = 2
) (
    input wire clk,
    rst_n,
    cancel,
    mapping_valid,
    link_valid,
    input wire [31:0] link_session,
    input wire scene_valid,
    input wire [31:0] scene_frame,
    input wire [223:0] scene_boxes,
    input wire captured,
    capture_error,
    motion_known,
    input wire [16:0] motion_count,
    input wire [159:0] meta,
    input wire [31:0] session_id,
    request_id,
    input wire capture_frozen,
    wire_done,
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
    output reg [31:0] tracked_frame,
    tracked_session,
    output reg [11:0] labels,
    output reg [27:0] confidences,
    output reg [127:0] requests,
    output reg association_rejected
);

    localparam IDLE=0,MAP_ANCHOR=1,MAP_PREP=2,MAP_SCAN=3,MAP_DECIDE=4,MAP_APPLY=5,BUILD=6,PUBLISH=7;
    localparam TICK_W = (TICK_CYCLES < 2) ? 1 : $clog2(TICK_CYCLES);
    localparam AGE_W = (HOLD_TICKS < 2) ? 1 : $clog2(HOLD_TICKS + 1);
    reg [TICK_W-1:0] ticks;
    wire tick = ticks == TICK_CYCLES - 1;
    reg [31:0] epoch, live_frame, previous_frame;
    reg [139:0] live_boxes, previous_boxes;
    reg [1:0] cache_label[0:3], cache_slot[0:3];
    reg [6:0] cache_conf[0:3];
    reg [31:0] cache_request[0:3];
    reg [AGE_W-1:0] ttl[0:3];
    reg [3:0] valid;
    reg pending, sent, pending_bound, pending_sealed, map_crop_guard, pending_unique;
    reg [31:0] pending_frame, pending_session, pending_request, pending_scene;
    reg [15:0] pending_roi;
    reg [ 1:0] pending_slot;
    reg [34:0] pending_region, pending_support;

    reg queued_valid, queued_bound;
    reg [1:0] queued_label, queued_slot;
    reg [6:0] queued_conf;
    reg [31:0] queued_request, queued_scene;
    reg [3:0] revoked_current, revoked_previous;
    reg [2:0] state;
    reg need_build, dirty, direction, best_valid;
    reg [1:0] row_index, slot_index, best_slot, cache_index;
    reg [10:0] best_cost, second_cost;
    reg [34:0] anchor_box, projected_box;
    reg [7:0] forward_slots, reverse_slots;
    reg [15:0] weak_links;
    reg [3:0] forward_valid, reverse_valid, used_slots;
    reg [11:0] work_labels;
    reg [27:0] work_conf;
    reg [127:0] work_requests;
    integer k;
    function valid_box;
        input [38:0] b;
        begin
            valid_box=b[0] && b[10:1]<=b[20:11] && b[29:21]<=b[38:30] && b[20:11]<320 && b[38:30]<240;
        end
    endfunction
    function [34:0] compact_box;
        input [38:0] b;
        begin
            compact_box = {b[37:30], b[28:21], b[19:11], b[9:1], valid_box(b)};
        end
    endfunction
    function [38:0] external_box;
        input [34:0] b;
        begin
            external_box = {1'b0, b[34:27], 1'b0, b[26:19], 1'b0, b[18:10], 1'b0, b[9:1], b[0]};
        end
    endfunction

    function [34:0] project_compact;
        input [34:0] b;
        reg [8:0] w, x, r;
        reg [7:0] h, y, bt;
        reg [9:0] sx;
        reg [8:0] sy;
        begin
            w = b[18:10] - b[9:1] + 9'd1;
            h = b[34:27] - b[26:19] + 8'd1;
            if (w < MIN_ROI_W) w = MIN_ROI_W;
            if (h < MIN_ROI_H) h = MIN_ROI_H;
            sx = {1'b0, b[9:1]} + {1'b0, b[18:10]} + 10'd1;
            sy = {1'b0, b[26:19]} + {1'b0, b[34:27]} + 9'd1;
            x  = sx >= w ? (sx - w) >> 1 : 0;
            y  = sy >= h ? (sy - h) >> 1 : 0;
            if ({1'b0, x} + {1'b0, w} > 10'd320) x = 9'd320 - w;
            if ({1'b0, y} + {1'b0, h} > 9'd240) y = 8'd240 - h;
            r = x + w - 1'b1;
            bt = y + h - 1'b1;
            project_compact = {bt, y, r, x, b[0]};
        end
    endfunction

    function [38:0] project_roi;
        input [38:0] b;
        begin
            project_roi = external_box(project_compact(compact_box(b)));
        end
    endfunction
    function linked;
        input [34:0] a, b;
        reg [8:0] aw, bw, iw, left, right;
        reg [7:0] ah, bh, ih, top, bottom;
        reg [16:0] area_a, area_b, area_i;
        begin
            aw = a[18:10] - a[9:1] + 9'd1;
            bw = b[18:10] - b[9:1] + 9'd1;
            ah = a[34:27] - a[26:19] + 8'd1;
            bh = b[34:27] - b[26:19] + 8'd1;
            left = a[9:1] > b[9:1] ? a[9:1] : b[9:1];
            right = a[18:10] < b[18:10] ? a[18:10] : b[18:10];
            top = a[26:19] > b[26:19] ? a[26:19] : b[26:19];
            bottom = a[34:27] < b[34:27] ? a[34:27] : b[34:27];
            iw = right >= left ? right - left + 9'd1 : 9'd0;
            ih = bottom >= top ? bottom - top + 8'd1 : 8'd0;
            area_a = aw * ah;
            area_b = bw * bh;
            area_i = iw * ih;

            linked=a[0]&&b[0]&&{iw,1'b0}>=(aw<bw?aw:bw)&&{ih,1'b0}>=(ah<bh?ah:bh)&&
    {1'b0,aw}<={bw,1'b0}&&{1'b0,bw}<={aw,1'b0}&&{1'b0,ah}<={bh,1'b0}&&{1'b0,bh}<={ah,1'b0}&&
    {area_i,1'b0}>={1'b0,(area_a<area_b?area_a:area_b)};
        end
    endfunction
    function [8:0] distance;
        input [8:0] a, b;
        begin
            distance = a > b ? a - b : b - a;
        end
    endfunction
    function [10:0] cost;
        input [34:0] a, b;
        begin
            cost = {2'd0, distance(a[9:1], b[9:1])} + {2'd0, distance(a[18:10], b[18:10])} +
                {2'd0, distance({1'b0, a[26:19]}, {1'b0, b[26:19]})} +
                {2'd0, distance({1'b0, a[34:27]}, {1'b0, b[34:27]})};
        end
    endfunction
    function support_hit;
        input [34:0] a, b;
        reg [8:0] x0, x1;
        reg [7:0] y0, y1;
        begin
            x0 = a[9:1] == 0 ? 0 : a[9:1] + CONTEXT_PAD;
            x1 = a[18:10] == 319 ? 319 : a[18:10] - CONTEXT_PAD;
            y0 = a[26:19] == 0 ? 0 : a[26:19] + CONTEXT_PAD;
            y1 = a[34:27] == 239 ? 239 : a[34:27] - CONTEXT_PAD;
            support_hit=a[0]&&b[0]&&(a[18:10]==319||a[18:10]>=CONTEXT_PAD)&&
               (a[34:27]==239||a[34:27]>=CONTEXT_PAD)&&x0<=x1&&y0<=y1&&
               x0<=b[18:10]&&x1>=b[9:1]&&y0<=b[34:27]&&y1>=b[26:19];
        end
    endfunction

    wire crop_high_zero=!(|meta[95:89])&&!(|meta[127:121])&&!(|meta[111:104])&&!(|meta[143:136]);
    wire [9:0] crop_right = {1'b0, meta[88:80]} + {1'b0, meta[120:112]};
    wire [8:0] crop_bottom = {1'b0, meta[103:96]} + {1'b0, meta[135:128]};
    wire capture_ok=!capture_error&&meta[31:0]!=0&&meta[63:48]==320&&meta[79:64]==240&&
  crop_high_zero&&meta[120:112]!=0&&meta[135:128]!=0&&crop_right<=10'd320&&crop_bottom<=9'd240&&
  (meta[151:144]==1||meta[151:144]==2)&&meta[159:152]==0&&session_id==link_session&&request_id!=0;
    wire current_result=pending&&sent&&matched_frame==pending_frame&&matched_roi==pending_roi&&
  session_id==pending_session&&request_id==pending_request&&pending_session==link_session;
    wire terminal_event = pending && ((matched && current_result) || timed_out || transport_fault);
    wire box_high_zero = !(|box_x[15:9]) && !(|box_w[15:9]) && !(|box_y[15:8]) && !(|box_h[15:8]);
    wire [9:0] box_right = {1'b0, box_x[8:0]} + {1'b0, box_w[8:0]};
    wire [8:0] box_bottom = {1'b0, box_y[7:0]} + {1'b0, box_h[7:0]};
    wire [8:0] px0 = pending_region[9:1], px1 = pending_region[18:10];
    wire [7:0] py0 = pending_region[26:19], py1 = pending_region[34:27];

    wire precise_ok=box_high_zero&&box_w[8:0]!=0&&box_h[7:0]!=0&&box_right<=10'd320&&box_bottom<=9'd240&&
  box_x[8:0]>=(px0>2?px0-9'd2:9'd0)&&box_y[7:0]>=(py0>3?py0-8'd3:8'd0)&&
  box_right<=({1'b0,px1}+10'd3)&&box_bottom<=({1'b0,py1}+9'd4);
    wire real_positive=matched&&current_result&&!timed_out&&!transport_fault&&status==0&&flags==0&&
                    decision==1&&confidence>=80&&confidence<=100&&(!box_valid||precise_ok);
    wire real_negative=matched&&current_result&&!timed_out&&!transport_fault&&status==0&&flags==0&&decision==0&&confidence==255;

    function contained_support;
        input [34:0] b, crop;
        reg [8:0] x0, x1;
        reg [7:0] y0, y1;
        begin
            x0 = b[9:1] == 0 ? 0 : b[9:1] + CONTEXT_PAD;
            x1 = b[18:10] == 319 ? 319 : b[18:10] - CONTEXT_PAD;
            y0 = b[26:19] == 0 ? 0 : b[26:19] + CONTEXT_PAD;
            y1 = b[34:27] == 239 ? 239 : b[34:27] - CONTEXT_PAD;
            contained_support=b[0]&&crop[0]&&(b[18:10]==319||b[18:10]>=CONTEXT_PAD)&&
    (b[34:27]==239||b[34:27]>=CONTEXT_PAD)&&x0<=x1&&y0<=y1&&
    x0>=crop[9:1]&&x1<=crop[18:10]&&y0>=crop[26:19]&&y1<=crop[34:27];
        end
    endfunction

    function support_intersects;
        input [34:0] b, crop;
        reg [8:0] x0, x1;
        reg [7:0] y0, y1;
        begin
            x0 = b[9:1] == 0 ? 0 : b[9:1] + CONTEXT_PAD;
            x1 = b[18:10] == 319 ? 319 : b[18:10] - CONTEXT_PAD;
            y0 = b[26:19] == 0 ? 0 : b[26:19] + CONTEXT_PAD;
            y1 = b[34:27] == 239 ? 239 : b[34:27] - CONTEXT_PAD;
            support_intersects=b[0]&&crop[0]&&(b[18:10]==319||b[18:10]>=CONTEXT_PAD)&&
    (b[34:27]==239||b[34:27]>=CONTEXT_PAD)&&x0<=x1&&y0<=y1&&
    x0<=crop[18:10]&&x1>=crop[9:1]&&y0<=crop[34:27]&&y1>=crop[26:19];
        end
    endfunction
    function [34:0] support_union;
        input [34:0] a, b;
        begin
            support_union = {
                a[34:27] > b[34:27] ? a[34:27] : b[34:27],
                a[26:19] < b[26:19] ? a[26:19] : b[26:19],
                a[18:10] > b[18:10] ? a[18:10] : b[18:10],
                a[9:1] < b[9:1] ? a[9:1] : b[9:1],
                a[0] && b[0]
            };
        end
    endfunction

    wire map_busy = state >= MAP_ANCHOR && state <= MAP_APPLY;
    wire scene_order_ok=live_frame==0||(scene_frame>live_frame && ({1'b0,scene_frame}-{1'b0,live_frame})<=MAX_FRAME_GAP);

    function raw_overlap;
        input [34:0] a, b;
        reg [8:0] ax0, ax1, bx0, bx1;
        reg [7:0] ay0, ay1, by0, by1;
        begin
            ax0 = a[9:1] == 0 ? 0 : a[9:1] + CONTEXT_PAD;
            ax1 = a[18:10] == 319 ? 319 : a[18:10] - CONTEXT_PAD;
            bx0 = b[9:1] == 0 ? 0 : b[9:1] + CONTEXT_PAD;
            bx1 = b[18:10] == 319 ? 319 : b[18:10] - CONTEXT_PAD;
            ay0 = a[26:19] == 0 ? 0 : a[26:19] + CONTEXT_PAD;
            ay1 = a[34:27] == 239 ? 239 : a[34:27] - CONTEXT_PAD;
            by0 = b[26:19] == 0 ? 0 : b[26:19] + CONTEXT_PAD;
            by1 = b[34:27] == 239 ? 239 : b[34:27] - CONTEXT_PAD;
            raw_overlap=a[0]&&b[0]&&ax0<=ax1&&bx0<=bx1&&ay0<=ay1&&by0<=by1&&
    ax0<=bx1&&bx0<=ax1&&ay0<=by1&&by0<=ay1;
        end
    endfunction
    function [2:0] safe_map;
        input [1:0] old_slot;
        input [7:0] fslots, rslots;
        input [3:0] fvalid, rvalid;
        input [15:0] weak_mask;
        reg [1:0] dst;
        reg ok;
        integer j;
        begin
            dst = fslots[old_slot*2+:2];
            ok  = fvalid[old_slot] && rvalid[dst] && rslots[dst*2+:2] == old_slot;

            for (j = 0; j < 4; j = j + 1) begin
                if (j != old_slot && fvalid[j] && fslots[j*2+:2] == dst) ok = 0;
                if (j != dst && rvalid[j] && rslots[j*2+:2] == old_slot) ok = 0;

                if (j != old_slot && !fvalid[j] && weak_mask[j*4+dst]) ok = 0;
                if (j != dst && !rvalid[j] && weak_mask[old_slot*4+j]) ok = 0;
            end
            safe_map = {ok, dst};
        end
    endfunction

    wire [11:0] safe_maps = {
        safe_map(2'd3, forward_slots, reverse_slots, forward_valid, reverse_valid, weak_links),
        safe_map(2'd2, forward_slots, reverse_slots, forward_valid, reverse_valid, weak_links),
        safe_map(2'd1, forward_slots, reverse_slots, forward_valid, reverse_valid, weak_links),
        safe_map(2'd0, forward_slots, reverse_slots, forward_valid, reverse_valid, weak_links)
    };
    function [2:0] select_map;
        input [11:0] maps;
        input [1:0] slot;
        begin
            case (slot)
                0: select_map = maps[2:0];
                1: select_map = maps[5:3];
                2: select_map = maps[8:6];
                3: select_map = maps[11:9];
                default: select_map = 3'bxxx;
            endcase
        end
    endfunction
    function [34:0] select_geometry;
        input [139:0] geometry;
        input [1:0] slot;
        begin
            case (slot)
                0: select_geometry = geometry[34:0];
                1: select_geometry = geometry[69:35];
                2: select_geometry = geometry[104:70];
                3: select_geometry = geometry[139:105];
                default: select_geometry = 35'bx;
            endcase
        end
    endfunction
    wire [139:0] incoming_boxes = {
        compact_box(scene_boxes[206:168]),
        compact_box(scene_boxes[150:112]),
        compact_box(scene_boxes[94:56]),
        compact_box(scene_boxes[38:0])
    };
    reg [34:0] capture_source;
    reg [139:0] capture_scene_boxes;
    integer cb;
    reg [31:0] capture_scene;
    reg [1:0] capture_slot;
    reg capture_path_valid;
    reg [2:0] capture_old_map;
    always @* begin
        capture_source = 0;
        capture_scene_boxes = 0;
        capture_scene = 0;
        capture_slot = meta[33:32];
        capture_path_valid = 0;
        capture_old_map = select_map(safe_maps, meta[33:32]);
        if (meta[47:32] < 4) begin
            if (scene_valid && scene_frame != 0 && meta[31:0] == scene_frame) begin
                capture_scene_boxes = incoming_boxes;
                capture_scene = scene_frame;
                capture_path_valid = 1;
            end else if (meta[31:0] == live_frame && live_frame != 0) begin
                capture_scene_boxes = live_boxes;
                capture_scene = live_frame;
                capture_path_valid = 1;
            end else if (meta[31:0] == previous_frame && previous_frame != 0) begin
                capture_scene_boxes = previous_boxes;
                if (map_busy && state != MAP_APPLY) begin
                    capture_scene = previous_frame;
                    capture_path_valid = 1;
                end else begin
                    capture_scene = live_frame;
                    capture_slot = capture_old_map[1:0];
                    capture_path_valid = capture_old_map[2];
                end
            end
        end
        if (meta[47:32] < 4) capture_source = select_geometry(capture_scene_boxes, meta[33:32]);

        if (scene_valid && map_busy && meta[31:0] != scene_frame) capture_path_valid = 0;
        if (scene_valid && !scene_order_ok) capture_path_valid = 0;
    end
    wire [34:0] capture_compact = capture_source;
    wire [34:0] capture_projection = project_compact(capture_compact);
    wire [34:0] captured_roi = {
        crop_bottom[7:0] - 8'd1, meta[103:96], crop_right[8:0] - 9'd1, meta[88:80], 1'b1
    };
    wire capture_previous_normalized=meta[31:0]==previous_frame&&capture_scene==live_frame&&previous_frame!=0;
    wire [34:0] capture_current_support = select_geometry(live_boxes, capture_slot);
    wire bind_capture=capture_ok&&motion_known&&motion_count!=0&&capture_path_valid&&capture_compact[0]&&capture_projection==captured_roi&&
  (!capture_previous_normalized||contained_support(
        capture_current_support, captured_roi
    ));
    wire [34:0] result_box = {
        box_bottom[7:0] - 8'd1, box_y[7:0], box_right[8:0] - 9'd1, box_x[8:0], 1'b1
    };
    wire result_support_ok = !box_valid || support_hit(pending_support, result_box);

    reg [2:0] capture_hits, capture_live_hits, prefreeze_hits;
    integer ch;
    always @* begin
        capture_hits = 0;
        capture_live_hits = 0;
        prefreeze_hits = 0;
        for (ch = 0; ch < 4; ch = ch + 1) begin
            if (support_intersects(capture_scene_boxes[ch*35+:35], captured_roi))
                capture_hits = capture_hits + 1'b1;
            if (support_intersects(live_boxes[ch*35+:35], captured_roi))
                capture_live_hits = capture_live_hits + 1'b1;
            if (support_intersects(live_boxes[ch*35+:35], pending_region))
                prefreeze_hits = prefreeze_hits + 1'b1;
        end
    end
    wire [2:0] incoming_label = real_positive ? 3'd1 : real_negative ? 3'd2 : 3'd0;
    wire prefreeze_check = !pending_sealed || map_crop_guard;
    wire effective_unique=pending_unique&&!(state==MAP_APPLY&&pending_scene==previous_frame&&prefreeze_check&&prefreeze_hits!=1);
    wire [1:0] trajectory_label = incoming_label[1:0];
    wire [3:0] expired = {
        valid[3] && ttl[3] == 1,
        valid[2] && ttl[2] == 1,
        valid[1] && ttl[1] == 1,
        valid[0] && ttl[0] == 1
    };

    wire [1:0] scan_slot = state == MAP_ANCHOR ? row_index : slot_index;
    wire scan_live = state == MAP_ANCHOR ? direction : !direction;
    wire [34:0] scan_external = select_geometry(scan_live ? live_boxes : previous_boxes, scan_slot);

    wire [34:0] scan_projection = scan_external;
    wire pair_linked = linked(anchor_box, projected_box);
    wire [10:0] candidate_cost = cost(anchor_box, projected_box);
    wire unique_best = best_valid && ({1'b0, best_cost} + MATCH_MARGIN <= {1'b0, second_cost});
    wire [2:0] pending_map = select_map(
        safe_maps, pending_slot
    ), queued_map = select_map(
        safe_maps, queued_slot
    );
    wire [34:0] pending_new_box = select_geometry(live_boxes, pending_map[1:0]);
    wire pending_contained = contained_support(pending_new_box, pending_region);
    wire queued_current = queued_scene == live_frame;
    wire queued_previous = queued_scene == previous_frame && queued_map[2];
    wire [1:0] queued_resolved_slot = queued_current ? queued_slot : queued_map[1:0];
    wire queued_resolved=queued_bound&&(queued_current||queued_previous)&&!revoked_current[queued_resolved_slot];
    reg [3:0] mapped_revocations;
    reg [2:0] revoke_map;
    integer rj;
    always @* begin
        mapped_revocations = revoked_current;
        revoke_map = 0;
        for (rj = 0; rj < 4; rj = rj + 1) begin
            revoke_map = select_map(safe_maps, rj);
            if (revoked_previous[rj] && revoke_map[2]) mapped_revocations[revoke_map[1:0]] = 1;
        end
    end

    reg [3:0] revoked_current_next, revoked_previous_next;
    always @* begin
        revoked_current_next  = revoked_current;
        revoked_previous_next = revoked_previous;
        if (state == IDLE) begin
            revoked_current_next  = (|revoked_previous) ? mapped_revocations : 4'd0;
            revoked_previous_next = 0;
        end else if (state == MAP_APPLY) begin
            revoked_current_next  = mapped_revocations;
            revoked_previous_next = 0;
        end
        if (scene_valid && scene_frame != 0) begin
            revoked_previous_next = mapped_revocations;
            revoked_current_next  = 0;
            if (map_busy || !scene_order_ok) begin
                revoked_current_next  = 0;
                revoked_previous_next = 0;
            end
        end
        if(terminal_event&&queued_valid&&pending_bound&&!(scene_valid&&(map_busy||!scene_order_ok)))begin
            if (scene_valid) begin
                if (pending_scene == live_frame)
                    revoked_previous_next = revoked_previous_next | (4'b0001 << pending_slot);
            end else if (pending_scene == live_frame)
                revoked_current_next = revoked_current_next | (4'b0001 << pending_slot);
            else if (pending_scene == previous_frame) begin
                if (state == MAP_APPLY || (state == IDLE && |revoked_previous)) begin
                    if (pending_map[2])
                        revoked_current_next = revoked_current_next | (4'b0001 << pending_map[1:0]);
                end else revoked_previous_next = revoked_previous_next | (4'b0001 << pending_slot);
            end
        end
        if(cancel||!mapping_valid||!link_valid||link_session==0||epoch!=link_session)begin
            revoked_current_next  = 0;
            revoked_previous_next = 0;
        end
    end
    assign send=dirty&&mailbox_ready&&state==IDLE&&!need_build&&!queued_valid&&!(|revoked_current)&&!(|revoked_previous)&&!scene_valid&&!terminal_event&&!(tick&&|expired);

    always @(posedge clk) begin
        if (!rst_n) begin
            ticks <= 0;
            epoch <= 0;
            live_frame <= 0;
            previous_frame <= 0;
            live_boxes <= 0;
            previous_boxes <= 0;
            valid <= 0;
            pending <= 0;
            sent <= 0;
            pending_bound <= 0;
            pending_sealed <= 0;
            map_crop_guard <= 0;
            pending_unique <= 0;
            pending_frame <= 0;
            pending_roi <= 0;
            pending_session <= 0;
            pending_request <= 0;
            pending_region <= 0;
            pending_support <= 0;
            pending_slot <= 0;
            pending_scene <= 0;
            queued_valid <= 0;
            queued_bound <= 0;
            queued_label <= 0;
            queued_slot <= 0;
            queued_conf <= 0;
            queued_request <= 0;
            queued_scene <= 0;
            revoked_current <= 0;
            revoked_previous <= 0;
            state <= IDLE;
            need_build <= 0;
            dirty <= 0;
            direction <= 0;
            best_valid <= 0;
            row_index <= 0;
            slot_index <= 0;
            best_slot <= 0;
            cache_index <= 0;
            best_cost <= 2047;
            second_cost <= 2047;
            anchor_box <= 0;
            projected_box <= 0;
            forward_slots <= 0;
            reverse_slots <= 0;
            weak_links <= 0;
            forward_valid <= 0;
            reverse_valid <= 0;
            used_slots <= 0;
            work_labels <= 0;
            work_conf <= 0;
            work_requests <= 0;
            tracked_frame <= 0;
            tracked_session <= 0;
            labels <= 0;
            confidences <= 0;
            requests <= 0;
            association_rejected <= 0;
            for (k = 0; k < 4; k = k + 1) begin
                cache_label[k] <= 0;
                cache_slot[k] <= 0;
                cache_conf[k] <= 0;
                cache_request[k] <= 0;
                ttl[k] <= 0;
            end
        end else begin
            revoked_current <= revoked_current_next;
            revoked_previous <= revoked_previous_next;
            association_rejected <= 0;
            if (send) dirty <= 0;
            if (tick) begin
                ticks <= 0;
                for (k = 0; k < 4; k = k + 1)
                if (valid[k]) begin
                    if (ttl[k] <= 1) valid[k] <= 0;
                    else ttl[k] <= ttl[k] - 1'b1;
                end
            end else ticks <= ticks + 1'b1;
            case (state)
                IDLE: begin
                    if (|revoked_previous) begin
                        need_build <= 1;
                        tracked_frame <= 0;
                    end else begin
                        if (|revoked_current) begin
                            for (k = 0; k < 4; k = k + 1)
                            if (valid[k] && revoked_current[cache_slot[k]]) valid[k] <= 0;
                            need_build <= 1;
                            tracked_frame <= 0;
                        end
                        if (queued_valid) begin
                            queued_valid <= 0;
                            if (queued_resolved) begin
                                for (k = 3; k > 0; k = k - 1) begin
                                    valid[k]<=valid[k-1]&&!(tick&&ttl[k-1]<=1)&&!revoked_current[cache_slot[k-1]];
                                    cache_slot[k] <= cache_slot[k-1];
                                    cache_label[k] <= cache_label[k-1];
                                    cache_conf[k] <= cache_conf[k-1];
                                    cache_request[k] <= cache_request[k-1];
                                    ttl[k] <= tick && ttl[k-1] != 0 ? ttl[k-1] - 1'b1 : ttl[k-1];
                                end
                                valid[0] <= 1;
                                cache_slot[0] <= queued_resolved_slot;
                                cache_label[0] <= queued_label;
                                cache_conf[0] <= queued_conf;
                                cache_request[0] <= queued_request;
                                ttl[0] <= HOLD_TICKS;
                            end else association_rejected <= 1;
                            need_build <= 1;
                            tracked_frame <= 0;
                        end
                        if (need_build) begin
                            cache_index <= 0;
                            used_slots <= 0;
                            work_labels <= 0;
                            work_conf <= 0;
                            work_requests <= 0;
                            need_build <= 0;
                            state <= BUILD;
                        end
                    end
                end
                MAP_ANCHOR: begin
                    anchor_box <= scan_projection;
                    slot_index <= 0;
                    best_valid <= 0;
                    best_cost <= 2047;
                    second_cost <= 2047;
                    best_slot <= 0;
                    state <= MAP_PREP;
                end
                MAP_PREP: begin
                    projected_box <= scan_projection;
                    state <= MAP_SCAN;
                end
                MAP_SCAN: begin
                    if (!direction)
                        weak_links[{
                            row_index, slot_index
                        }] <= raw_overlap(
                            anchor_box, projected_box
                        );
                    if (pair_linked) begin
                        if (!best_valid || candidate_cost < best_cost) begin
                            second_cost <= best_valid ? best_cost : 11'd2047;
                            best_cost   <= candidate_cost;
                            best_slot   <= slot_index;
                            best_valid  <= 1;
                        end else if (candidate_cost < second_cost) second_cost <= candidate_cost;
                    end
                    if (slot_index == 3) state <= MAP_DECIDE;
                    else begin
                        slot_index <= slot_index + 1'b1;
                        state <= MAP_PREP;
                    end
                end
                MAP_DECIDE: begin
                    for (k = 0; k < 4; k = k + 1)
                    if (row_index == k) begin
                        if (direction) begin
                            reverse_valid[k] <= unique_best;
                            reverse_slots[k*2+:2] <= best_slot;
                        end else begin
                            forward_valid[k] <= unique_best;
                            forward_slots[k*2+:2] <= best_slot;
                        end
                    end
                    if (row_index != 3) begin
                        row_index <= row_index + 1'b1;
                        state <= MAP_ANCHOR;
                    end else if (!direction) begin
                        row_index <= 0;
                        direction <= 1;
                        state <= MAP_ANCHOR;
                    end else state <= MAP_APPLY;
                end
                MAP_APPLY: begin
                    for (k = 0; k < 4; k = k + 1) begin
                        if (valid[k]) begin
                            if (select_map(safe_maps, cache_slot[k]) >= 4)
                                cache_slot[k] <= select_map(safe_maps, cache_slot[k]);
                            else begin
                                valid[k] <= 0;
                                association_rejected <= 1;
                            end
                        end
                    end
                    if (pending && pending_bound && pending_scene == previous_frame) begin
                        pending_bound <= pending_map[2] && (!prefreeze_check || pending_contained);
                        pending_slot  <= pending_map[1:0];
                        pending_scene <= live_frame;
                        if (!pending_map[2] || (prefreeze_check && !pending_contained))
                            association_rejected <= 1;
                        if (prefreeze_check && prefreeze_hits != 1) pending_unique <= 0;
                        if (pending_map[2] && prefreeze_check && pending_contained)
                            pending_support <= support_union(pending_support, pending_new_box);
                    end
                    if (queued_valid && queued_bound && queued_scene == previous_frame) begin
                        queued_bound <= queued_map[2];
                        queued_slot  <= queued_map[1:0];
                        queued_scene <= live_frame;
                        if (!queued_map[2]) association_rejected <= 1;
                    end
                    need_build <= 1;
                    state <= IDLE;
                end
                BUILD: begin
                    if (valid[cache_index] && !(tick && ttl[cache_index] <= 1)) begin
                        if (!used_slots[cache_slot[cache_index]]) begin
                            used_slots[cache_slot[cache_index]] <= 1;
                            for (k = 0; k < 4; k = k + 1)
                            if (cache_slot[cache_index] == k) begin
                                work_labels[k*3+:3] <= {1'b0, cache_label[cache_index]};
                                work_conf[k*7+:7] <= cache_conf[cache_index];
                                work_requests[k*32+:32] <= cache_request[cache_index];
                            end
                        end else valid[cache_index] <= 0;
                    end
                    if (cache_index == 3) state <= PUBLISH;
                    else cache_index <= cache_index + 1'b1;
                end
                PUBLISH: begin
                    labels <= work_labels;
                    confidences <= work_conf;
                    requests <= work_requests;
                    tracked_frame<=(need_build||queued_valid||(|revoked_current)||(|revoked_previous))?32'd0:live_frame;
                    tracked_session <= epoch;
                    dirty <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
            if (tick && |expired) begin
                need_build <= 1;
                tracked_frame <= 0;
            end
            if (scene_valid && scene_frame != 0) begin
                previous_boxes <= live_boxes;
                previous_frame <= live_frame;
                for (k = 0; k < 4; k = k + 1)
                live_boxes[k*35+:35] <= compact_box(scene_boxes[k*56+:39]);
                live_frame <= scene_frame;
                tracked_frame <= 0;
                need_build <= 0;
                map_crop_guard <= pending && !pending_sealed;
                row_index <= 0;
                direction <= 0;
                weak_links <= 0;
                forward_valid <= 0;
                reverse_valid <= 0;
                state <= MAP_ANCHOR;
                if (map_busy || !scene_order_ok) begin

                    valid <= 0;
                    pending_bound <= 0;
                    queued_bound <= 0;
                    association_rejected <= 1;
                end
            end
            if (pending && (capture_frozen || wire_done) && !captured) pending_sealed <= 1;
            if (pending && wire_done && !captured) sent <= 1;
            if (terminal_event) begin
                if (!queued_valid) begin
                    queued_valid <= 1;
                    queued_bound<=pending_bound&&!(scene_valid&&(map_busy||!scene_order_ok))&&
      !(state==MAP_APPLY&&pending_scene==previous_frame&&(!pending_map[2]||(prefreeze_check&&!pending_contained)));
                    queued_slot <= pending_slot;
                    queued_scene <= pending_scene;
                    queued_label <= trajectory_label;
                    queued_conf <= trajectory_label == 1 ? confidence[6:0] : 7'd0;
                    queued_request <= pending_request;
                end else begin

                    association_rejected <= 1;
                end
                pending <= 0;
                sent <= 0;
                tracked_frame <= 0;
            end
            if (captured) begin
                pending <= capture_ok;
                sent <= 0;
                pending_sealed <= 0;
                pending_frame <= meta[31:0];
                pending_roi <= meta[47:32];
                pending_session <= session_id;
                pending_request <= request_id;
                pending_region <= captured_roi;
                pending_support <= capture_previous_normalized ? support_union(
                    capture_compact, capture_current_support
                ) : capture_compact;
                pending_slot <= capture_slot;
                pending_scene <= capture_scene;
                pending_bound <= bind_capture;
                pending_unique<=capture_hits==1&&(!capture_previous_normalized||capture_live_hits==1);
                if (!bind_capture) association_rejected <= 1;
            end
            if (cancel || !mapping_valid || !link_valid || link_session == 0) begin
                state <= IDLE;
                need_build <= 0;
                epoch <= 0;
                live_boxes <= 0;
                previous_boxes <= 0;
                live_frame <= 0;
                previous_frame <= 0;
                valid <= 0;
                pending <= 0;
                sent <= 0;
                pending_bound <= 0;
                pending_sealed <= 0;
                map_crop_guard <= 0;
                pending_unique <= 0;
                queued_valid <= 0;
                queued_bound <= 0;
                forward_valid <= 0;
                reverse_valid <= 0;
                tracked_frame <= 0;
                tracked_session <= 0;
                labels <= 0;
                confidences <= 0;
                requests <= 0;
                dirty <= 1;
            end else if (epoch != link_session) begin
                epoch <= link_session;
                state <= IDLE;
                need_build <= scene_valid && scene_frame != 0;
                valid <= 0;
                queued_valid <= 0;
                queued_bound <= 0;
                previous_boxes <= 0;
                previous_frame <= 0;
                forward_valid <= 0;
                reverse_valid <= 0;
                if (!scene_valid) begin
                    live_boxes <= 0;
                    live_frame <= 0;
                end
                pending <= captured && capture_ok;
                pending_bound<=captured&&bind_capture&&scene_valid&&meta[31:0]==scene_frame;
                sent <= 0;
                pending_sealed <= 0;
                map_crop_guard <= 0;
                pending_unique <= captured && bind_capture && scene_valid && capture_hits == 1;
                tracked_frame <= 0;
                tracked_session <= link_session;
                labels <= 0;
                confidences <= 0;
                requests <= 0;
                dirty <= 1;
            end
        end
    end
    // synthesis translate_off
    initial
        if(CLOCK_HZ<1||TICK_CYCLES<1||HOLD_TICKS<1||HOLD_TICKS>255||CONTEXT_PAD<0||CONTEXT_PAD>16||MATCH_MARGIN<1||MATCH_MARGIN>1024||MIN_ROI_W<1||MIN_ROI_W>320||MIN_ROI_H<1||MIN_ROI_H>240||MAX_FRAME_GAP<1)
            $fatal(1, "Invalid ROI evidence parameters");
    // synthesis translate_on
endmodule
