module video_pipeline_top #(
    parameter FRAME_W = 320,
    parameter FRAME_H = 240,
    parameter USE_BACKGROUND = 0,
    parameter MULTI_ALGO = 0,
    parameter DIFF_THRESHOLD = 8'd30,

    parameter END_DELAY = 6,

    parameter USE_CCL   = 1,
    parameter MAX_ROI   = 4,
    parameter MIN_WIN_W = 73,
    parameter MIN_WIN_H = 74,
    parameter PIXEL_FMT = 1,
    parameter MIN_AREA  = 60
) (
    input wire clk,
    input wire rst_n,

    input wire [ 6:0] det_cfg,
    input wire [23:0] cam_pixel,
    input wire        cam_valid,
    input wire        cam_frame_start,
    input wire        cam_frame_end,

    input wire force_inspect,

    input wire [31:0] cfg_session_id,

    output wire         desc_valid,
    input  wire         desc_ready,
    output wire [ 31:0] session_id,
    output wire [ 31:0] request_id,
    output wire [159:0] crop_meta,

    input  wire        lease_valid,
    output wire        lease_gnt,
    output wire [31:0] lease_frame_id,
    output wire [15:0] lease_width,
    output wire [15:0] lease_height,
    input  wire        lease_release,

    output wire        reader_idle,
    input  wire        reader_flush,
    input  wire        mem_req_valid,
    output wire        mem_req_ready,
    input  wire [31:0] mem_frame_id,
    input  wire [31:0] mem_pixel_index,
    output wire        mem_rsp_valid,
    input  wire        mem_rsp_ready,
    output wire [23:0] mem_rgb,
    output wire        mem_rsp_error,

    output wire [16:0] motion_count,
    output wire        bbox_done,

    output wire [  3:0] cclv_index,
    output wire [  9:0] cclv_x0,
    output wire [  9:0] cclv_x1,
    output wire [  8:0] cclv_y0,
    output wire [  8:0] cclv_y1,
    output wire [ 16:0] cclv_area,
    output wire         cclv_valid,
    output wire         cclv_done,
    output wire [  7:0] roi_diag,
    output wire         scene_valid,
    output wire [ 31:0] scene_frame,
    output wire [223:0] scene_boxes,
    output wire [ 11:0] scene_shapes,
    output wire [  6:0] scene_cfg,
    output wire [  3:0] cclv_count
);

    localparam DET_SHIFT = MULTI_ALGO ? 1 : USE_BACKGROUND ? 2 : 0;
    localparam CONTEXT_EN = MULTI_ALGO || USE_BACKGROUND;
    localparam DET_W = FRAME_W >> DET_SHIFT;
    localparam DET_H = FRAME_H >> DET_SHIFT;
    localparam DET_AREA = (MIN_AREA + (1 << (2 * DET_SHIFT)) - 1) >> (2 * DET_SHIFT);

    wire [ 23:0] prev_pixel;
    wire         prev_read_en;

    wire         motion_bit;
    wire         motion_valid;

    wire [  9:0] bbox_min_x;
    wire [  9:0] bbox_max_x;
    wire [  8:0] bbox_min_y;
    wire [  8:0] bbox_max_y;
    wire [ 16:0] bbox_count_raw;
    wire [ 16:0] bbox_count = bbox_count_raw << (2 * DET_SHIFT);
    wire         bbox_valid;

    wire         dp_desc_valid;
    wire         dp_desc_ready;
    wire [ 31:0] dp_session;
    wire [ 31:0] dp_request;
    wire [159:0] dp_crop_meta;
    wire [ 16:0] dp_motion_count;
    wire         dp_has_motion;
    wire [ 15:0] dp_dropped;
    wire [  3:0] pack_events;

    wire [ 31:0] curr_frame_id;
    wire [ 31:0] read_frame_id;

    wire         fb_rd_idle;
    wire         wr_frame_end_dly;
    wire         fb_drop_strobe;
    wire [ 31:0] fb_drop_frame_id;

    reg  [  6:0] cfg_epoch;
    reg  [ 31:0] mode_epoch_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_epoch <= 7'h21;
            mode_epoch_frame <= 0;
        end else if (MULTI_ALGO && cam_frame_start && det_cfg != cfg_epoch) begin
            cfg_epoch <= det_cfg;
            mode_epoch_frame <= curr_frame_id;
        end
    end
    reg patrol_scene_wait;
    reg [1:0] scene_target_d;

    wire frame_published = (read_frame_id == dp_crop_meta[31:0]) &&
      !(CONTEXT_EN && (cam_frame_end || patrol_scene_wait) && dp_motion_count==0) &&
      (!MULTI_ALGO||((dp_crop_meta[31:0]>=mode_epoch_frame)&&
       !(cam_frame_start&&det_cfg!=cfg_epoch)));

    reg [END_DELAY-1:0] end_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) end_sr <= {END_DELAY{1'b0}};
        else end_sr <= {end_sr[END_DELAY-2:0], cam_frame_end};
    end
    assign wr_frame_end_dly = end_sr[END_DELAY-1];

    frame_buffer_arbiter #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H)
    ) u_fb (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_data        (cam_pixel),
        .wr_valid       (cam_valid),
        .wr_frame_end   (wr_frame_end_dly),
        .prev_data      (prev_pixel),
        .prev_read_en   (prev_read_en),
        .mem_frame_id   (mem_frame_id),
        .mem_pixel_index(mem_pixel_index),
        .mem_req_valid  (mem_req_valid),
        .mem_req_ready  (mem_req_ready),
        .mem_rgb        (mem_rgb),
        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_ready  (mem_rsp_ready),
        .mem_rsp_error  (mem_rsp_error),
        .reader_flush   (reader_flush),
        .rd_idle        (fb_rd_idle),
        .lease_valid    (lease_valid || (desc_valid && desc_ready)),
        .lease_gnt      (lease_gnt),
        .lease_frame_id (lease_frame_id),
        .lease_width    (lease_width),
        .lease_height   (lease_height),
        .lease_release  (lease_release),
        .curr_frame_id  (curr_frame_id),
        .read_frame_id  (read_frame_id),
        .drop_strobe    (fb_drop_strobe),
        .drop_frame_id  (fb_drop_frame_id)
    );

    assign prev_read_en = cam_valid;

    assign reader_idle  = fb_rd_idle;

    wire raw_motion_bit, raw_motion_valid, filtered_sof;
    wire [6:0] detector_active_cfg;
    wire legacy_bit, legacy_valid, legacy_sof, bg_bit, bg_valid, bg_sof;
    generate
        if (MULTI_ALGO) begin : g_multi
            multi_algorithm_detector #(
                .W(FRAME_W),
                .H(FRAME_H),
                .DIFF_THRESHOLD(DIFF_THRESHOLD)
            ) detector (
                .clk(clk),
                .rst_n(rst_n),
                .rgb(cam_pixel),
                .valid(cam_valid),
                .sof(cam_frame_start),
                .eof(cam_frame_end),
                .cfg(det_cfg),
                .active_cfg(detector_active_cfg),
                .out_bit(motion_bit),
                .out_valid(motion_valid),
                .out_sof(filtered_sof)
            );
        end else begin : g_single
            assign detector_active_cfg = 7'd0;
            assign motion_bit = USE_BACKGROUND ? bg_bit : legacy_bit;
            assign motion_valid = USE_BACKGROUND ? bg_valid : legacy_valid;
            assign filtered_sof = USE_BACKGROUND ? bg_sof : legacy_sof;
            if (USE_BACKGROUND) begin : g_background
                tile_background #(
                    .W(FRAME_W),
                    .H(FRAME_H)
                ) detector (
                    .clk(clk),
                    .rst_n(rst_n),
                    .rgb(cam_pixel),
                    .valid(cam_valid),
                    .sof(cam_frame_start),
                    .eof(cam_frame_end),
                    .out_bit(bg_bit),
                    .out_valid(bg_valid),
                    .out_sof(bg_sof)
                );
            end else begin : g_legacy_bg
                assign bg_bit   = 0;
                assign bg_valid = 0;
                assign bg_sof   = 0;
            end
            reg [1:0] sof_delay;
            reg reference_ready;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sof_delay <= 0;
                    reference_ready <= 0;
                end else begin
                    sof_delay <= {sof_delay[0], cam_frame_start};
                    if (cam_frame_start) reference_ready <= read_frame_id != 0;
                end
            end

            motion_support_2x2 #(
                .W(FRAME_W),
                .H(FRAME_H)
            ) spatial_filter (
                .clk(clk),
                .rst_n(rst_n),
                .in_bit(raw_motion_bit && reference_ready),
                .in_valid(raw_motion_valid),
                .in_sof(sof_delay[1]),
                .out_bit(legacy_bit),
                .out_valid(legacy_valid),
                .out_sof(legacy_sof)
            );

            frame_diff #(
                .FRAME_W  (FRAME_W),
                .FRAME_H  (FRAME_H),
                .THRESHOLD(DIFF_THRESHOLD)
            ) u_frame_diff (
                .clk         (clk),
                .rst_n       (rst_n),
                .curr_pixel  (cam_pixel),
                .curr_valid  (cam_valid),
                .prev_pixel  (prev_pixel),
                .motion_bit  (raw_motion_bit),
                .motion_valid(raw_motion_valid)
            );

        end
    endgenerate

    motion_bbox #(
        .FRAME_W(DET_W),
        .FRAME_H(DET_H)
    ) u_bbox (
        .clk         (clk),
        .rst_n       (rst_n),
        .motion_bit  (motion_bit),
        .pixel_valid (motion_valid),
        .frame_start (filtered_sof),
        .min_x       (bbox_min_x),
        .max_x       (bbox_max_x),
        .min_y       (bbox_min_y),
        .max_y       (bbox_max_y),
        .motion_count(bbox_count_raw),
        .bbox_valid  (bbox_valid)
    );

    wire [9:0] ccl_x0_raw, ccl_x1_raw;
    wire [8:0] ccl_y0_raw, ccl_y1_raw;
    wire [16:0] ccl_area_raw;
    wire [ 9:0] ccl_min_x = (ccl_x0_raw << DET_SHIFT);
    wire [ 9:0] ccl_max_x = ((ccl_x1_raw << DET_SHIFT) + ((1 << DET_SHIFT) - 1));
    wire [ 8:0] ccl_min_y = (ccl_y0_raw << DET_SHIFT);
    wire [ 8:0] ccl_max_y = ((ccl_y1_raw << DET_SHIFT) + ((1 << DET_SHIFT) - 1));
    wire [16:0] ccl_area = ccl_area_raw << (2 * DET_SHIFT);
    wire [3:0] ccl_index, ccl_count;
    wire ccl_out_valid, ccl_done, ccl_overflow;

    ccl_engine #(
        .FRAME_W        (DET_W),
        .FRAME_H        (DET_H),
        .MIN_RETAIN_AREA(DET_AREA),
        .MAX_LABELS     (16)
    ) u_ccl (
        .clk           (clk),
        .rst_n         (rst_n),
        .motion_bit    (motion_bit),
        .pixel_valid   (motion_valid),
        .frame_start   (filtered_sof),
        .out_min_x     (ccl_x0_raw),
        .out_max_x     (ccl_x1_raw),
        .out_min_y     (ccl_y0_raw),
        .out_max_y     (ccl_y1_raw),
        .out_area      (ccl_area_raw),
        .out_index     (ccl_index),
        .out_valid     (ccl_out_valid),
        .target_count  (ccl_count),
        .label_overflow(ccl_overflow),
        .done          (ccl_done)
    );

    assign cclv_index = ccl_index;
    assign cclv_x0    = ccl_min_x;
    assign cclv_x1    = ccl_max_x;
    assign cclv_y0    = ccl_min_y;
    assign cclv_y1    = ccl_max_y;
    assign cclv_area  = ccl_area;
    assign cclv_valid = ccl_out_valid;
    assign cclv_done  = ccl_done;
    assign cclv_count = ccl_count;

    reg [31:0] detect_frame_id;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) detect_frame_id <= 32'd0;
        else if (cam_frame_start) detect_frame_id <= curr_frame_id;
    end

    wire [9:0] raw_x0 = USE_CCL ? ccl_min_x : bbox_min_x;
    wire [9:0] raw_x1 = USE_CCL ? ccl_max_x : bbox_max_x;
    wire [8:0] raw_y0 = USE_CCL ? ccl_min_y : bbox_min_y;
    wire [8:0] raw_y1 = USE_CCL ? ccl_max_y : bbox_max_y;
    wire [9:0] tgt_min_x = CONTEXT_EN ? (raw_x0 > 16 ? raw_x0 - 16 : 0) : raw_x0;
    wire [9:0] tgt_max_x=CONTEXT_EN?({1'b0,raw_x1}+16>=FRAME_W?FRAME_W-1:raw_x1+16):raw_x1;
    wire [8:0] tgt_min_y = CONTEXT_EN ? (raw_y0 > 16 ? raw_y0 - 16 : 0) : raw_y0;
    wire [8:0] tgt_max_y=CONTEXT_EN?({1'b0,raw_y1}+16>=FRAME_H?FRAME_H-1:raw_y1+16):raw_y1;
    wire [16:0] tgt_area = USE_CCL ? ccl_area : bbox_count;
    wire [3:0] tgt_roi = USE_CCL ? ccl_index : 4'd0;
    wire tgt_valid=(USE_CCL?ccl_out_valid:bbox_valid)&&(!CONTEXT_EN||tgt_area<=FRAME_W*FRAME_H*3/4);

    wire [2:0] component_shape;
    bbox_shape_descriptor #(
        .GRID_W  (DET_W),
        .GRID_H  (DET_H),
        .MIN_SIDE(16 >> DET_SHIFT)
    ) shape_desc (
        .x0(ccl_x0_raw),
        .x1(ccl_x1_raw),
        .y0(ccl_y0_raw),
        .y1(ccl_y1_raw),
        .area(ccl_area_raw),
        .shape(component_shape)
    );

    wire [9:0] ordered_x0, ordered_x1;
    wire [8:0] ordered_y0, ordered_y1;
    wire [16:0] ordered_area, ordered_motion;
    wire [3:0] ordered_roi;
    wire ordered_valid;
    wire [31:0] ordered_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            patrol_scene_wait <= 0;
            scene_target_d <= 0;
        end else begin
            scene_target_d <= {scene_target_d[0], ordered_valid};

            if(cam_frame_start || fb_drop_strobe || scene_target_d[1] ||
           (scene_valid && !(scene_boxes[0] || scene_boxes[56] ||
                            scene_boxes[112] || scene_boxes[168])))
                patrol_scene_wait <= 0;
            if (cam_frame_end) patrol_scene_wait <= 1;
        end
    end
    motion_scene_batch #(
        .MIN_AREA(MIN_AREA),
        .MAX_ROI (MAX_ROI)
    ) scenes (
        .clk(clk),
        .rst_n(rst_n),
        .frame_id(detect_frame_id),
        .published_frame(read_frame_id),
        .drop_strobe(fb_drop_strobe),
        .drop_frame(fb_drop_frame_id),
        .in_valid(tgt_valid),
        .in_done(USE_CCL ? ccl_done : bbox_valid),
        .in_x0(tgt_min_x),
        .in_x1(tgt_max_x),
        .in_y0(tgt_min_y),
        .in_y1(tgt_max_y),
        .in_area(tgt_area),
        .in_motion(bbox_count),
        .in_shape(USE_CCL && !ccl_overflow ? component_shape : 3'd0),
        .in_cfg(detector_active_cfg),
        .served(desc_valid && desc_ready && motion_count != 0),
        .served_roi(crop_meta[33:32]),
        .scene_valid(scene_valid),
        .scene_frame(scene_frame),
        .scene_boxes(scene_boxes),
        .scene_shapes(scene_shapes),
        .scene_cfg(scene_cfg),
        .out_valid(ordered_valid),
        .out_x0(ordered_x0),
        .out_x1(ordered_x1),
        .out_y0(ordered_y0),
        .out_y1(ordered_y1),
        .out_area(ordered_area),
        .out_roi(ordered_roi),
        .out_frame(ordered_frame),
        .out_motion(ordered_motion)
    );

    assign dp_desc_ready = desc_ready && frame_published;

    desc_packer #(
        .FRAME_W         (FRAME_W),
        .FRAME_H         (FRAME_H),
        .MAX_ROI         (MAX_ROI),
        .MIN_WIN_W       (MIN_WIN_W),
        .MIN_WIN_H       (MIN_WIN_H),
        .PIXEL_FMT       (PIXEL_FMT),
        .MIN_AREA        (MIN_AREA),
        .COMPACT_ROI     (0),
        .MOTION_FIRST    (CONTEXT_EN),
        .MOTION_BURST    (CONTEXT_EN ? MAX_ROI : 3),
        .PRESERVE_CONTEXT(CONTEXT_EN),
        .ROI_PAD         (CONTEXT_EN ? 0 : 2)
    ) u_desc_packer (
        .clk               (clk),
        .rst_n             (rst_n),
        .min_x             (ordered_x0),
        .max_x             (ordered_x1),
        .min_y             (ordered_y0),
        .max_y             (ordered_y1),
        .target_area       (ordered_area),
        .roi_id            (ordered_roi),
        .frame_motion_count(ordered_motion),
        .bbox_valid        (ordered_valid),
        .force_inspect     (force_inspect),
        .published_frame_id(read_frame_id),
        .frame_id          (ordered_frame),
        .cfg_session_id    (cfg_session_id),
        .drop_strobe       (fb_drop_strobe),
        .drop_frame_id     (fb_drop_frame_id),
        .desc_valid        (dp_desc_valid),
        .desc_ready        (dp_desc_ready),
        .session_id        (dp_session),
        .request_id        (dp_request),
        .crop_meta         (dp_crop_meta),
        .desc_motion_count (dp_motion_count),
        .has_motion        (dp_has_motion),
        .dropped           (dp_dropped),
        .event_flags       (pack_events),
        .queued            ()
    );

    assign desc_valid = dp_desc_valid && frame_published;
    assign session_id = dp_session;
    assign request_id = dp_request;
    assign crop_meta = dp_crop_meta;
    assign motion_count = dp_motion_count;

    assign bbox_done = desc_valid;

    assign roi_diag = {
        desc_valid && desc_ready && motion_count == 0,
        desc_valid && desc_ready && motion_count != 0,
        (USE_CCL ? ccl_out_valid : bbox_valid) && tgt_area != 0 && tgt_area < MIN_AREA,
        pack_events[3],
        pack_events[2],
        pack_events[1],
        pack_events[0],
        ordered_valid
    };

endmodule

module motion_support_2x2 #(
    parameter W = 320,
    H = 240
) (
    input  wire clk,
    rst_n,
    in_bit,
    in_valid,
    in_sof,
    output reg  out_bit,
    out_valid,
    out_sof
);
    (* ram_style="dram" *) reg line[0:W-1];
    reg [9:0] x;
    reg [8:0] y;
    reg left_bit, upper_left;
    wire [9:0] xx = in_sof ? 10'd0 : x;
    wire [8:0] yy = in_sof ? 9'd0 : y;
    wire up = (yy == 0) ? 1'b0 : line[xx];
    wire left = (xx == 0) ? 1'b0 : left_bit;
    wire ul = (xx == 0 || yy == 0) ? 1'b0 : upper_left;
    wire [2:0] support = {2'd0, in_bit} + {2'd0, left} + {2'd0, up} + {2'd0, ul};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            left_bit <= 0;
            upper_left <= 0;
            out_bit <= 0;
            out_valid <= 0;
            out_sof <= 0;
        end else begin
            out_valid <= in_valid;
            out_sof   <= in_sof && in_valid;
            if (in_sof) begin
                x <= in_valid ? 1 : 0;
                y <= 0;
            end else if (in_valid) begin
                if (x == W - 1) begin
                    x <= 0;
                    y <= (y == H - 1) ? 0 : y + 1'b1;
                end else x <= x + 1'b1;
            end
            if (in_valid) begin
                out_bit <= support >= 2;
                left_bit <= in_bit;
                upper_left <= up;
            end
        end
    end
    always @(posedge clk) if (in_valid) line[xx] <= in_bit;
endmodule

module motion_scene_batch #(
    parameter MIN_AREA = 64,
    MAX_ROI = 4
) (
    input wire clk,
    rst_n,
    input wire [31:0] frame_id,
    published_frame,
    input wire drop_strobe,
    input wire [31:0] drop_frame,
    input wire in_valid,
    in_done,
    input wire [9:0] in_x0,
    in_x1,
    input wire [8:0] in_y0,
    in_y1,
    input wire [16:0] in_area,
    in_motion,
    input wire served,
    input wire [1:0] served_roi,
    input wire [2:0] in_shape,
    input wire [6:0] in_cfg,
    output reg scene_valid,
    output reg [31:0] scene_frame,
    output reg [223:0] scene_boxes,
    output reg [11:0] scene_shapes,
    output reg [6:0] scene_cfg,
    output reg out_valid,
    output reg [9:0] out_x0,
    out_x1,
    output reg [8:0] out_y0,
    out_y1,
    output reg [16:0] out_area,
    out_motion,
    output reg [3:0] out_roi,
    output reg [31:0] out_frame
);
    reg [223:0] staged, emit_boxes;
    reg [11:0] staged_shapes;
    reg [ 6:0] collect_cfg;
    reg [ 6:0] safe_cfg;
    always @* begin
        safe_cfg = 0;
        case (in_cfg[4:0])
            5'd2, 5'd3, 5'd6, 5'd7, 5'd10, 5'd11, 5'd14, 5'd15, 5'd18, 5'd19, 5'd22, 5'd23:
            safe_cfg = {2'd0, in_cfg[4:0]};
            default: safe_cfg = 0;
        endcase
    end
    reg [2:0] safe_shape;

    always @* begin
        case (in_shape)
            3'd1, 3'd2, 3'd3: safe_shape = in_shape;
            default: safe_shape = 3'd0;
        endcase
    end
    reg [31:0] collect_frame, last_drop;
    reg last_drop_valid;
    reg [16:0] collect_motion;
    reg [2:0] count, remaining, emit_total;
    reg finish_pending;
    reg [1:0] prefer, emit_idx;
    wire [2:0] count_now = (collect_frame == frame_id) ? count : 0;
    wire candidate_ok=in_valid&&frame_id!=0&&in_area>=MIN_AREA&&in_x0<=in_x1&&in_y0<=in_y1;
    wire bad_stage=(collect_frame<published_frame)||(drop_strobe&&drop_frame==collect_frame)||
                  (last_drop_valid&&last_drop==collect_frame);
    wire [55:0] e = emit_boxes[emit_idx*56+:56];
    wire[1:0]start_idx=(count==1)?0:(count==2)?{1'b0,prefer[0]}:
                         (count==3&&prefer==3)?0:prefer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            staged <= 0;
            staged_shapes <= 0;
            scene_shapes <= 0;
            scene_cfg <= 0;
            collect_cfg <= 0;
            emit_boxes <= 0;
            collect_frame <= 0;
            collect_motion <= 0;
            last_drop <= 0;
            last_drop_valid <= 0;
            count <= 0;
            remaining <= 0;
            emit_total <= 0;
            finish_pending <= 0;
            prefer <= 0;
            emit_idx <= 0;
            scene_valid <= 0;
            scene_frame <= 0;
            scene_boxes <= 0;
            out_valid <= 0;
            out_x0 <= 0;
            out_x1 <= 0;
            out_y0 <= 0;
            out_y1 <= 0;
            out_area <= 0;
            out_motion <= 0;
            out_roi <= 0;
            out_frame <= 0;
        end else begin
            scene_valid <= 0;
            out_valid   <= 0;
            if (served) prefer <= served_roi + 1'b1;
            if (drop_strobe) begin
                last_drop <= drop_frame;
                last_drop_valid <= 1;
            end
            if (frame_id != collect_frame) begin
                collect_frame <= frame_id;
                collect_cfg <= safe_cfg;
                staged <= 0;
                staged_shapes <= 0;
                count <= 0;
                finish_pending <= 0;
            end
            if (candidate_ok && count_now < MAX_ROI) begin
                staged[count_now*56+:56] <= {in_area, in_y1, in_y0, in_x1, in_x0, 1'b1};
                staged_shapes[count_now*3+:3] <= safe_shape;
                count <= count_now + 1'b1;
                collect_frame <= frame_id;
                collect_motion <= in_motion;
            end
            if (in_done) begin
                finish_pending <= 1;
                collect_motion <= in_motion;
            end
            if (remaining != 0) begin
                if (out_frame == published_frame && !(drop_strobe && drop_frame == out_frame)) begin
                    out_valid <= 1;
                    out_roi <= {2'd0, emit_idx};
                    out_area <= e[55:39];
                    out_x0 <= e[10:1];
                    out_x1 <= e[20:11];
                    out_y0 <= e[29:21];
                    out_y1 <= e[38:30];
                    emit_idx <= (emit_idx + 3'd1 >= emit_total) ? 0 : emit_idx + 1'b1;
                    remaining <= remaining - 1'b1;
                end else remaining <= 0;
            end
            if (finish_pending) begin
                if (bad_stage) finish_pending <= 0;
                else if (collect_frame != 0 && published_frame == collect_frame) begin
                    scene_valid <= 1;
                    scene_frame <= collect_frame;
                    scene_boxes <= staged;
                    scene_shapes <= staged_shapes;
                    scene_cfg <= collect_cfg;
                    finish_pending <= 0;
                    emit_boxes <= staged;
                    emit_total <= count;
                    remaining <= count;
                    emit_idx <= start_idx;
                    out_frame <= collect_frame;
                    out_motion <= collect_motion;
                    out_valid <= 0;
                end
            end
        end
    end
    // synthesis translate_off
    initial if (MAX_ROI < 1 || MAX_ROI > 4) $fatal(1, "motion_scene_batch MAX_ROI");
    // synthesis translate_on
endmodule

module bbox_shape_descriptor #(
    parameter GRID_W = 160,
    GRID_H = 120,
    MIN_SIDE = 8
) (
    input  wire [ 9:0] x0,
    x1,
    input  wire [ 8:0] y0,
    y1,
    input  wire [16:0] area,
    output reg  [ 2:0] shape
);
    localparam WB = $clog2(GRID_W + 1), HB = $clog2(GRID_H + 1);
    wire [10:0] wide_w = {1'b0, x1} - {1'b0, x0} + 11'd1;
    wire [9:0] wide_h = {1'b0, y1} - {1'b0, y0} + 10'd1;
    wire [WB-1:0] w = wide_w[WB-1:0];
    wire [HB-1:0] h = wide_h[HB-1:0];

    wire [WB+HB-1:0] product = w * h;
    wire [20:0] wh = product;
    wire [20:0] a16 = {area, 4'd0};
    wire good=(x0<=x1)&&(y0<=y1)&&(x0>0)&&(y0>0)&&
   (x1<GRID_W-1)&&(y1<GRID_H-1)&&(wide_w>=MIN_SIDE)&&(wide_h>=MIN_SIDE)&&
   ((wide_w<<1)>=wide_h)&&((wide_h<<1)>=wide_w)&&(area!=0)&&(area<=wh);
    always @* begin
        shape = 3'd0;
        if (good) begin
            if (a16 >= (wh << 3) + (wh << 2) + (wh << 1)) shape = 3'd3;
            else if (a16 >= (wh << 3) + (wh << 1) + wh) shape = 3'd1;
            else if (a16 >= (wh << 2) + (wh << 1) && a16 < (wh << 3) + (wh << 1)) shape = 3'd2;

        end
    end
endmodule

module tile_background #(
    parameter W = 320,
    H = 240,
    THRESHOLD = 8
) (
    input wire clk,
    rst_n,
    input wire [23:0] rgb,
    input wire valid,
    sof,
    eof,
    output reg out_bit,
    out_valid,
    out_sof
);
    localparam TW = W / 4, TH = H / 4, N = TW * TH;
    reg  [9:0] x;
    reg  [8:0] y;
    wire [9:0] px = sof ? 0 : x;
    wire [8:0] py = sof ? 0 : y;
    reg [9:0] hr, hg, hb;
    (* ram_style="dram" *) reg [11:0] sr[0:TW-1], sg[0:TW-1], sb[0:TW-1];
    wire [9:0] r4 = (px[1:0] == 0 ? 10'd0 : hr) + {2'd0, rgb[23:16]};
    wire [9:0] g4 = (px[1:0] == 0 ? 10'd0 : hg) + {2'd0, rgb[15:8]};
    wire [9:0] b4 = (px[1:0] == 0 ? 10'd0 : hb) + {2'd0, rgb[7:0]};
    wire [11:0] r16 = (py[1:0] == 0 ? 12'd0 : sr[px>>2]) + {2'd0, r4};
    wire [11:0] g16 = (py[1:0] == 0 ? 12'd0 : sg[px>>2]) + {2'd0, g4};
    wire [11:0] b16 = (py[1:0] == 0 ? 12'd0 : sb[px>>2]) + {2'd0, b4};
    wire cell_end = valid && px[1:0] == 3 && py[1:0] == 3;
    (* ram_style="bram" *) reg [23:0] background[0:N-1];
    reg [23:0] bg_q, sample;
    reg [12:0] index, address;
    reg pending, first, ready, was_ready, adapt_all, adapt_q, update_q;
    reg [ 4:0] frame_mod;
    reg [16:0] pixels;
    reg [12:0] foreground;
    reg [ 2:0] end_delay;
    function [7:0] diff;
        input [7:0] a, b;
        begin
            diff = a > b ? a - b : b - a;
        end
    endfunction
    wire changed = diff(
        sample[23:16], bg_q[23:16]
    ) >= THRESHOLD || diff(
        sample[15:8], bg_q[15:8]
    ) >= THRESHOLD || diff(
        sample[7:0], bg_q[7:0]
    ) >= THRESHOLD;
    function [7:0] learn;
        input [7:0] old, new_value;
        begin
            learn = new_value > old ? old + 1'b1 : new_value < old ? old - 1'b1 : old;
        end
    endfunction

    always @(posedge clk) begin
        if (cell_end) bg_q <= background[index];
        if (pending) begin
            if (!was_ready || adapt_q) background[address] <= sample;
            else if (update_q && !changed)
                background[address] <= {
                    learn(bg_q[23:16], sample[23:16]),
                    learn(bg_q[15:8], sample[15:8]),
                    learn(bg_q[7:0], sample[7:0])
                };
        end
        if (valid && px[1:0] == 3) begin
            sr[px>>2] <= r16;
            sg[px>>2] <= g16;
            sb[px>>2] <= b16;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            hr <= 0;
            hg <= 0;
            hb <= 0;
            index <= 0;
            address <= 0;
            sample <= 0;
            pending <= 0;
            first <= 0;
            ready <= 0;
            was_ready <= 0;
            adapt_all <= 0;
            adapt_q <= 0;
            update_q <= 0;
            frame_mod <= 0;
            pixels <= 0;
            foreground <= 0;
            end_delay <= 0;
            out_bit <= 0;
            out_valid <= 0;
            out_sof <= 0;
        end else begin
            pending   <= cell_end;
            out_valid <= pending;
            out_sof   <= pending && first;
            end_delay <= {end_delay[1:0], eof};
            if (sof) begin
                index <= 0;
                foreground <= 0;
                pixels <= valid ? 1 : 0;
                x <= valid ? 1 : 0;
                y <= 0;
            end else if (valid) begin
                pixels <= pixels + 1'b1;
                if (x == W - 1) begin
                    x <= 0;
                    y <= y == H - 1 ? 0 : y + 1'b1;
                end else x <= x + 1'b1;
            end
            if (valid) begin
                hr <= r4;
                hg <= g4;
                hb <= b4;
            end
            if (cell_end) begin
                sample <= {r16[11:4], g16[11:4], b16[11:4]};
                address <= index;
                first <= index == 0;
                index <= index == N - 1 ? 0 : index + 1'b1;
                was_ready <= ready;
                adapt_q <= adapt_all;
                update_q <= frame_mod == 0;
            end
            if (pending) begin
                out_bit <= was_ready && !adapt_q && changed;
                if (was_ready && !adapt_q && changed) foreground <= foreground + 1'b1;
            end
            if (end_delay[2]) begin
                if (pixels == W * H) ready <= 1;
                else ready <= 0;

                adapt_all <= foreground > (N * 3 / 4);
                frame_mod <= frame_mod + 1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if (W < 8 || H < 4 || W % 4 || H % 4 || N > 8192) $fatal(1, "tile_background geometry");
    // synthesis translate_on
endmodule

module multi_algorithm_detector #(
    parameter W = 320,
    H = 240,
    DIFF_THRESHOLD = 12,
    BG_THRESHOLD = 8
) (
    input wire clk,
    rst_n,
    input wire [23:0] rgb,
    input wire valid,
    sof,
    eof,
    input wire [6:0] cfg,
    output wire out_bit,
    out_valid,
    out_sof,
    output reg [6:0] active_cfg
);
    localparam TW = W / 2, TH = H / 2, N = TW * TH, AW = $clog2(N);
    reg  [9:0] x;
    reg  [8:0] y;
    wire [9:0] px = sof ? 10'd0 : x;
    wire [8:0] py = sof ? 9'd0 : y;
    reg [7:0] hr, hg, hb;
    (* ram_style="dram" *) reg [8:0] sr[0:TW-1], sg[0:TW-1], sb[0:TW-1];
    wire [8:0] r2 = {1'b0, hr} + {1'b0, rgb[23:16]};
    wire [8:0] g2 = {1'b0, hg} + {1'b0, rgb[15:8]};
    wire [8:0] b2 = {1'b0, hb} + {1'b0, rgb[7:0]};
    wire [9:0] r4 = {1'b0, sr[px>>1]} + {1'b0, r2};
    wire [9:0] g4 = {1'b0, sg[px>>1]} + {1'b0, g2};
    wire [9:0] b4 = {1'b0, sb[px>>1]} + {1'b0, b2};
    wire cell_end = valid && px[0] && py[0];
    (* ram_style="bram" *) reg [23:0] background[0:N-1];
    (* ram_style="bram" *) reg [7:0] previous[0:N-1];
    reg [23:0] bg_q, sample;
    reg [7:0] prev_q;
    reg [AW-1:0] index, address;
    reg pending, first, ready, was_ready, adapt_all, adapt_q, update_q;
    reg [ 4:0] frame_mod;
    reg [16:0] pixels;
    reg [AW:0] foreground;
    reg [ 2:0] end_delay;
    reg mask_bit, mask_valid, mask_sof;
    wire [7:0] sample_gray;
    wire colour_bit;
    colour_segment colour (
        .rgb(sample),
        .profile(active_cfg[4:2]),
        .match(colour_bit),
        .gray(sample_gray)
    );
    function [7:0] diff;
        input [7:0] a, b;
        begin
            diff = a > b ? a - b : b - a;
        end
    endfunction
    wire bg_changed = diff(
        sample[23:16], bg_q[23:16]
    ) >= BG_THRESHOLD || diff(
        sample[15:8], bg_q[15:8]
    ) >= BG_THRESHOLD || diff(
        sample[7:0], bg_q[7:0]
    ) >= BG_THRESHOLD;
    wire motion = was_ready && (diff(sample_gray, prev_q) >= DIFF_THRESHOLD);
    wire background_bit = was_ready && !adapt_q && bg_changed;
    function [7:0] learn;
        input [7:0] old, new_value;
        begin
            learn = new_value > old ? old + 1'b1 : new_value < old ? old - 1'b1 : old;
        end
    endfunction

    always @(posedge clk) begin
        if (cell_end) begin
            bg_q   <= background[index];
            prev_q <= previous[index];
        end
        if (pending) begin
            previous[address] <= sample_gray;
            if (!was_ready || adapt_q) background[address] <= sample;
            else if (update_q && !bg_changed)
                background[address] <= {
                    learn(bg_q[23:16], sample[23:16]),
                    learn(bg_q[15:8], sample[15:8]),
                    learn(bg_q[7:0], sample[7:0])
                };
        end
        if (valid && px[0] && !py[0]) begin
            sr[px>>1] <= r2;
            sg[px>>1] <= g2;
            sb[px>>1] <= b2;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            hr <= 0;
            hg <= 0;
            hb <= 0;
            index <= 0;
            address <= 0;
            sample <= 0;
            pending <= 0;
            first <= 0;
            ready <= 0;
            was_ready <= 0;
            adapt_all <= 0;
            adapt_q <= 0;
            update_q <= 0;
            frame_mod <= 0;
            pixels <= 0;
            foreground <= 0;
            end_delay <= 0;
            mask_bit <= 0;
            mask_valid <= 0;
            mask_sof <= 0;
            active_cfg <= 7'h21;
        end else begin
            pending <= cell_end;
            mask_valid <= pending;
            mask_sof <= pending && first;
            end_delay <= {end_delay[1:0], eof};
            if (sof) begin
                active_cfg <= cfg;
                index <= 0;
                foreground <= 0;
                pixels <= valid ? 1 : 0;
                x <= valid ? 1 : 0;
                y <= 0;
            end else if (valid) begin
                pixels <= pixels + 1'b1;
                if (x == W - 1) begin
                    x <= 0;
                    y <= y == H - 1 ? 0 : y + 1'b1;
                end else x <= x + 1'b1;
            end
            if (valid && !px[0]) begin
                hr <= rgb[23:16];
                hg <= rgb[15:8];
                hb <= rgb[7:0];
            end
            if (cell_end) begin
                sample <= {r4[9:2], g4[9:2], b4[9:2]};
                address <= index;
                first <= index == 0;
                index <= index == N - 1 ? 0 : index + 1'b1;
                was_ready <= ready;
                adapt_q <= adapt_all;
                update_q <= frame_mod == 0;
            end
            if (pending) begin
                case (active_cfg[1:0])
                    0: mask_bit <= motion;
                    1: mask_bit <= background_bit;
                    2: mask_bit <= colour_bit;
                    3: mask_bit <= motion || colour_bit;
                endcase
                if (background_bit) foreground <= foreground + 1'b1;
            end
            if (end_delay[2]) begin
                ready <= pixels == W * H;
                adapt_all <= foreground > (N * 3 / 4);
                frame_mod <= frame_mod + 1'b1;
            end
        end
    end
    spatial_vote3x3 #(
        .W(TW),
        .H(TH)
    ) spatial (
        .clk(clk),
        .rst_n(rst_n),
        .in_bit(mask_bit),
        .in_valid(mask_valid),
        .in_sof(mask_sof),
        .profile(active_cfg[6:5]),
        .out_bit(out_bit),
        .out_valid(out_valid),
        .out_sof(out_sof)
    );
    // synthesis translate_off
    initial if (W < 4 || H < 4 || W % 2 || H % 2 || N > 65536) $fatal(1, "Invalid spatial geometry");
    // synthesis translate_on
endmodule

module colour_segment (
    input wire [23:0] rgb,
    input wire [2:0] profile,
    output reg match,
    output wire [7:0] gray
);
    wire [ 7:0] r = rgb[23:16], g = rgb[15:8], b = rgb[7:0];
    wire [15:0] yr = ({8'd0, r} << 6) + ({8'd0, r} << 3) + ({8'd0, r} << 2) + {8'd0, r};
    wire [15:0] yg = ({8'd0, g} << 7) + ({8'd0, g} << 4) + ({8'd0, g} << 2) + ({8'd0, g} << 1);
    wire [15:0] yb = ({8'd0, b} << 4) + ({8'd0, b} << 3) + ({8'd0, b} << 2) + {8'd0, b};
    wire [15:0] ysum = yr + yg + yb;
    assign gray = ysum[15:8];
    wire [7:0] maximum = r > g ? (r > b ? r : b) : (g > b ? g : b);
    wire [7:0] minimum = r < g ? (r < b ? r : b) : (g < b ? g : b);

    wire [9:0] rgb_sum = {2'd0, r} + {2'd0, g} + {2'd0, b};
    wire [7:0] chroma = maximum - minimum;
    wire [16:0] sum_wide = {7'd0, rgb_sum};
    wire [16:0] share_limit = (sum_wide << 6) + (sum_wide << 5) + (sum_wide << 2) + (sum_wide << 1);
    wire saturated = rgb_sum > 10'd90 && chroma > 8'd40;
    wire r_norm=saturated&&{1'b0,r,8'd0}>share_limit&&{1'b0,r}>={1'b0,g}+9'd8&&{1'b0,r}>={1'b0,b}+9'd8;
    wire g_norm=saturated&&{1'b0,g,8'd0}>share_limit&&{1'b0,g}>={1'b0,r}+9'd8&&{1'b0,g}>={1'b0,b}+9'd8;
    wire b_norm=saturated&&{1'b0,b,8'd0}>share_limit&&{1'b0,b}>={1'b0,r}+9'd8&&{1'b0,b}>={1'b0,g}+9'd8;
    always @* begin
        case (profile)
            0:
            match=(r>80&&{1'b0,r}>{1'b0,g}+9'd30&&{1'b0,r}>{1'b0,b}+9'd30)||r_norm;
            1:
            match=(g>80&&{1'b0,g}>{1'b0,r}+9'd30&&{1'b0,g}>{1'b0,b}+9'd30)||g_norm;
            2:
            match=(b>80&&{1'b0,b}>{1'b0,r}+9'd30&&{1'b0,b}>{1'b0,g}+9'd30)||b_norm;
            3: match = gray > 200;
            4: match = gray < 50;
            5: match = maximum >= 96 && (maximum - minimum) >= 64;
            default: match = 0;
        endcase
    end
endmodule

module spatial_vote3x3 #(
    parameter W = 160,
    H = 120
) (
    input wire clk,
    rst_n,
    in_bit,
    in_valid,
    in_sof,
    input wire [1:0] profile,
    output reg out_bit,
    out_valid,
    out_sof
);
    (* ram_style="dram" *) reg line1[0:W-1], line2[0:W-1];
    reg [9:0] x;
    reg [8:0] y;
    reg l0, ll0, l1, ll1, l2, ll2;
    wire [9:0] xx = in_sof ? 10'd0 : x;
    wire [8:0] yy = in_sof ? 9'd0 : y;
    wire u1 = yy == 0 ? 1'b0 : line1[xx], u2 = yy < 2 ? 1'b0 : line2[xx];
    wire[3:0]sum={3'd0,in_bit}+{3'd0,u1}+{3'd0,u2}+
  (xx==0?4'd0:({3'd0,l0}+{3'd0,l1}+{3'd0,l2}))+
  (xx<2?4'd0:({3'd0,ll0}+{3'd0,ll1}+{3'd0,ll2}));
    always @(posedge clk)
        if (in_valid) begin
            line1[xx] <= in_bit;
            line2[xx] <= u1;
        end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            l0 <= 0;
            ll0 <= 0;
            l1 <= 0;
            ll1 <= 0;
            l2 <= 0;
            ll2 <= 0;
            out_bit <= 0;
            out_valid <= 0;
            out_sof <= 0;
        end else begin
            out_valid <= in_valid;
            out_sof   <= in_valid && in_sof;
            if (in_valid) begin
                out_bit <= profile == 0 ? in_bit : sum >= (profile == 2 ? 5 : 3);
                l0 <= in_bit;
                ll0 <= l0;
                l1 <= u1;
                ll1 <= l1;
                l2 <= u2;
                ll2 <= l2;
                if (xx == W - 1) begin
                    x <= 0;
                    y <= yy == H - 1 ? 0 : yy + 1'b1;
                end else begin
                    x <= xx + 1'b1;
                    y <= yy;
                end
            end
        end
    end
endmodule
