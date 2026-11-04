module member_b_ab_top #(
    parameter MAX_INFLIGHT = 1,
    VOLTAGE_REFERENCE = 0,
    parameter CLOCK_HZ = 75000000,
    BAUD = 115200,
    READ_TIMEOUT_CYCLES = 7500000,
    parameter LEASE_TIMEOUT_CYCLES = 7500000,
    MAX_CAPTURE_CYCLES = CLOCK_HZ,
    REPLY_SECONDS = 6,
    parameter SOURCE_W = 320,
    SOURCE_H = 240,
    DISPLAY_W = 1280,
    DISPLAY_H = 720,
    parameter CCL_SELFVIEW = 0,
    LIVE_SCENE = 0,
    TRACK_LABELS = 1,
    ROI_GAMMA_EN = 0,
    REQUEST_GAP_CYCLES = 0,
    ROI_DETAIL = 0,
    ROI_HIRES = 0,
    SCENE_CONFIG = 0
) (
    input wire vin_clk,
    vin_rst_n,
    vin_de,
    input wire [23:0] vin_rgb,
    input wire scene_valid,
    input wire [31:0] scene_frame,
    input wire [223:0] scene_boxes,
    input wire [11:0] scene_shapes,
    input wire [6:0] scene_cfg,
    input wire clk,
    rst_n,
    cancel,
    resend,
    input wire link_session_valid,
    input wire [31:0] link_session_id,
    input wire desc_valid,
    output wire desc_ready,
    input wire [159:0] crop_meta,
    input wire [31:0] session_id,
    request_id,
    input wire bbox_done,
    input wire [16:0] motion_count,
    output wire lease_valid,
    input wire lease_gnt,
    input wire [31:0] lease_frame_id,
    input wire [15:0] lease_width,
    lease_height,
    output wire lease_release,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [31:0] mem_frame_id,
    mem_pixel_index,
    input wire mem_rsp_valid,
    input wire [23:0] mem_rgb,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    reader_flush,
    input wire reader_idle,
    input wire uart_rx,
    output wire uart_tx,
    output wire busy,
    frozen,
    wire_done,
    matched,
    confirmed_bird,
    timed_out,
    failed,
    output wire rejected,
    output wire [3:0] error_code,
    output wire [31:0] matched_frame_id,
    output wire [15:0] matched_roi_id,
    output wire [7:0] matched_status,
    matched_decision,
    matched_confidence,
    matched_flags,
    output wire [31:0] matched_processing_ms,
    output wire rx_packet_error,
    rx_partial_timeout,
    output wire [2:0] outstanding_count,
    output wire [16:0] matched_motion,
    output wire action_bird,
    output wire [16:0] action_motion,
    output wire timing_valid,
    output wire [15:0] matched_transmit_ms,
    matched_reply_ms,
    matched_total_ms,

    output wire captured_o,
    output wire [383:0] roi_trace,
    output wire roi_trace_motion,
    output wire rx_byte_valid,
    input wire display_mapping_valid,
    info_valid,
    state_valid,
    input wire [3:0] state_code,
    input wire voltage_known,
    input wire [15:0] voltage_mv,
    input wire [3:0] cclv_index,
    input wire [9:0] cclv_x0,
    cclv_x1,
    input wire [8:0] cclv_y0,
    cclv_y1,
    input wire [16:0] cclv_area,
    input wire cclv_valid,
    cclv_done,
    input wire [3:0] cclv_count,
    input wire pixel_clk,
    pixel_rst_n,
    input wire [23:0] video_rgb,
    input wire video_de,
    video_hs,
    video_vs,
    output wire [23:0] hdmi_rgb,
    output wire hdmi_de,
    hdmi_hs,
    hdmi_vs,
    output wire mapping_rejected
);
    reg [31:0] endpoint_epoch;
    always @(posedge clk)
        if (!rst_n) endpoint_epoch <= 0;
        else endpoint_epoch <= link_session_id;
    wire cancel_all=cancel||!link_session_valid||link_session_id==0||endpoint_epoch!=link_session_id;
    wire [31:0] matched_session_id, matched_request_id;
    wire tdv,tdr,tbusy,tlease,tlrelease,terror,flush1,flush2,tcancel,captured,retired,motion_known;

    wire transport_ready, pacing_ready;
    wire [16:0] sample_motion;
    generate
        if (REQUEST_GAP_CYCLES > 0) begin : g_pacing
            localparam GAP_W = $clog2(REQUEST_GAP_CYCLES + 1);
            reg [GAP_W-1:0] gap_count;
            always @(posedge clk) begin
                if (!rst_n) gap_count <= 0;
                else if (wire_done) gap_count <= REQUEST_GAP_CYCLES;
                else if (gap_count != 0) gap_count <= gap_count - 1'b1;
            end
            assign pacing_ready = gap_count == 0;
        end else begin : g_unpaced
            assign pacing_ready = 1'b1;
        end
    endgenerate

    assign tdr=transport_ready && (pacing_ready ||
               (ROI_HIRES && (busy ? sample_motion!=0 : motion_count!=0)));
    wire [31:0] tsid, trid, held_frame, origin_session;
    wire [159:0] tmeta;
    wire [15:0] held_width, held_height;
    wire [159:0] debug_packet_meta;

    assign roi_trace = {tsid, trid, tmeta, debug_packet_meta};
    assign roi_trace_motion = motion_known && sample_motion != 0;
    a_descriptor_adapter #(
        .LEASE_TIMEOUT_CYCLES(LEASE_TIMEOUT_CYCLES),
        .MAX_CAPTURE_CYCLES  (MAX_CAPTURE_CYCLES)
    ) adapter (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(cancel),
        .link_session_valid(link_session_valid),
        .link_session_id(link_session_id),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .session_id(session_id),
        .request_id(request_id),
        .crop_meta(crop_meta),
        .bbox_done(bbox_done),
        .motion_count(motion_count),
        .lease_valid(lease_valid),
        .lease_gnt(lease_gnt),
        .lease_frame_id(lease_frame_id),
        .lease_width(lease_width),
        .lease_height(lease_height),
        .lease_release(lease_release),
        .reader_idle(reader_idle),
        .force_flush(flush1),
        .t_desc_valid(tdv),
        .t_desc_ready(tdr),
        .t_session(tsid),
        .t_request(trid),
        .t_busy(tbusy),
        .t_meta(tmeta),
        .t_lease_valid(tlease),
        .held_frame(held_frame),
        .held_width(held_width),
        .held_height(held_height),
        .t_lease_release(tlrelease),
        .t_error(terror),
        .t_cancel(tcancel),
        .captured(captured),
        .rejected(rejected),
        .retired(retired),
        .error_code(error_code),
        .origin_session(origin_session),
        .captured_motion(sample_motion),
        .motion_known(motion_known),
        .busy(busy)
    );
    wire [7:0] rxdata, rs, rd, rc, rf;
    wire rxvalid, rxerr, rv;
    wire [31:0] rsession, rrequest, processing_ms;
    wire rbox_valid, mbox_valid;
    wire [15:0] rbox_x, rbox_y, rbox_w, rbox_h, mbox_x, mbox_y, mbox_w, mbox_h;
    uart_rx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) receiver (
        .clk(clk),
        .rst_n(rst_n),
        .rx(uart_rx),
        .data(rxdata),
        .valid(rxvalid),
        .framing_error(rxerr)
    );
    roi_result_rx #(
        .GAP_CYCLES(CLOCK_HZ / 4),
        .PACKET_CYCLES((CLOCK_HZ / 2) * 5)
    ) decoder (
        .clk(clk),
        .rst_n(rst_n),
        .clear(MAX_INFLIGHT > 1 ? cancel_all : tcancel),
        .byte_valid(rxvalid),
        .byte_error(rxerr),
        .byte_data(rxdata),
        .reply_valid(rv),
        .packet_error(rx_packet_error),
        .partial_timeout(rx_partial_timeout),
        .reply_session(rsession),
        .reply_request(rrequest),
        .reply_status(rs),
        .reply_decision(rd),
        .reply_confidence(rc),
        .reply_flags(rf),
        .processing_ms(processing_ms),
        .reply_box_valid(rbox_valid),
        .reply_box_x(rbox_x),
        .reply_box_y(rbox_y),
        .reply_box_w(rbox_w),
        .reply_box_h(rbox_h)
    );
    member_b_transport #(
        .MAX_INFLIGHT(MAX_INFLIGHT),
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD),
        .READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES),
        .REPLY_SECONDS(REPLY_SECONDS),
        .ROI_GAMMA_EN(ROI_GAMMA_EN),
        .ROI_DETAIL(ROI_DETAIL),
        .ROI_HIRES(ROI_HIRES),
        .TX_PACING(ROI_HIRES)
    ) transport (
        .vin_clk(vin_clk),
        .vin_rst_n(vin_rst_n),
        .vin_de(vin_de),
        .vin_rgb(vin_rgb),
        .clk(clk),
        .rst_n(rst_n),
        .debug_packet_meta(debug_packet_meta),
        .send_enable(pacing_ready),
        .desc_valid(tdv),
        .desc_ready(transport_ready),
        .session_id(tsid),
        .request_id(trid),
        .crop_meta(tmeta),
        .lease_valid(tlease),
        .lease_frame_id(held_frame),
        .lease_width(held_width),
        .lease_height(held_height),
        .lease_release(tlrelease),
        .reader_idle(reader_idle),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_frame_id(mem_frame_id),
        .mem_pixel_index(mem_pixel_index),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rgb(mem_rgb),
        .mem_rsp_error(mem_rsp_error),
        .mem_rsp_ready(mem_rsp_ready),
        .reader_flush(flush2),
        .resend(resend),
        .cancel(tcancel),
        .cancel_all(cancel_all),
        .pending_count(outstanding_count),
        .matched_session_id(matched_session_id),
        .matched_request_id(matched_request_id),
        .uart_tx(uart_tx),
        .wire_done(wire_done),
        .busy(tbusy),
        .frozen(frozen),
        .transport_error(terror),
        .reply_valid(rv),
        .reply_session(rsession),
        .reply_request(rrequest),
        .reply_status(rs),
        .reply_decision(rd),
        .reply_confidence(rc),
        .reply_flags(rf),
        .reply_processing_ms(processing_ms),
        .reply_box_valid(rbox_valid),
        .reply_box_x(rbox_x),
        .reply_box_y(rbox_y),
        .reply_box_w(rbox_w),
        .reply_box_h(rbox_h),
        .matched(matched),
        .confirmed_bird(confirmed_bird),
        .timed_out(timed_out),
        .failed(failed),
        .matched_frame_id(matched_frame_id),
        .matched_roi_id(matched_roi_id),
        .matched_status(matched_status),
        .matched_decision(matched_decision),
        .matched_confidence(matched_confidence),
        .matched_flags(matched_flags),
        .matched_processing_ms(matched_processing_ms),
        .matched_box_valid(mbox_valid),
        .matched_box_x(mbox_x),
        .matched_box_y(mbox_y),
        .matched_box_w(mbox_w),
        .matched_box_h(mbox_h)
    );
    assign reader_flush=flush1 || flush2;
    assign captured_o    = captured;
    assign rx_byte_valid = rxvalid;
    wire ms, mready;
    wire [596:0] mp;

    wire annotate_motion = !LIVE_SCENE || (motion_known && sample_motion != 0);

    wire view_send;
    wire [596:0] view_payload;
    generate
        if (CCL_SELFVIEW) begin : g_selfview
            ccl_selfview #(
                .SOURCE_W (SOURCE_W),
                .SOURCE_H (SOURCE_H),
                .DISPLAY_W(DISPLAY_W),
                .DISPLAY_H(DISPLAY_H)
            ) cclview (
                .clk(clk),
                .rst_n(rst_n),
                .cclv_index(cclv_index),
                .cclv_x0(cclv_x0),
                .cclv_x1(cclv_x1),
                .cclv_y0(cclv_y0),
                .cclv_y1(cclv_y1),
                .cclv_area(cclv_area),
                .cclv_valid(cclv_valid),
                .cclv_done(cclv_done),
                .cclv_count(cclv_count),
                .mailbox_ready(mready),
                .send(view_send),
                .payload(view_payload)
            );
        end else begin : g_no_selfview
            assign view_send = 0;
            assign view_payload = 0;
        end
    endgenerate

    wire track_send;
    wire [596:0] tracked_mp;
    wire track_action;
    wire [16:0] track_action_motion;
    wire matched_patrol;
    wire live_publish_allowed;
    wire live_publish_ready = mready && live_publish_allowed;
    genvar ti;
    generate
        if (LIVE_SCENE && TRACK_LABELS && !CCL_SELFVIEW) begin : g_tracking
            wire [31:0] tracked_frame, tracked_session;
            wire [11:0] track_labels;
            wire [27:0] track_confidences;
            wire [127:0] track_requests;
            wire legacy_track_send;
            wire [31:0] legacy_frame, legacy_session;
            wire [ 11:0] legacy_labels;
            wire [ 27:0] legacy_conf;
            wire [127:0] legacy_requests;
            if (MAX_INFLIGHT == 1) begin : g_legacy_tracker
                ccl_result_tracker #(
                    .CLOCK_HZ(CLOCK_HZ),
                    .CONTEXT_PAD(ROI_HIRES ? 16 : 0)
                ) tracker (

                    .clk(clk),
                    .rst_n(rst_n),
                    .cancel(cancel),
                    .mapping_valid(display_mapping_valid),
                    .link_valid(link_session_valid),
                    .link_session(link_session_id),
                    .scene_valid(scene_valid),
                    .scene_frame(scene_frame),
                    .scene_boxes(scene_boxes),
                    .captured(captured),
                    .capture_error(rejected),
                    .motion_known(motion_known),
                    .motion_count(sample_motion),
                    .meta(tmeta),
                    .session_id(tsid),
                    .request_id(trid),
                    .capture_frozen(frozen),
                    .wire_done(wire_done),
                    .matched(matched),
                    .matched_frame(matched_frame_id),
                    .matched_roi(matched_roi_id),
                    .status(matched_status),
                    .decision(matched_decision),
                    .confidence(matched_confidence),
                    .flags(matched_flags),
                    .box_valid(mbox_valid),
                    .box_x(mbox_x),
                    .box_y(mbox_y),
                    .box_w(mbox_w),
                    .box_h(mbox_h),
                    .timed_out(timed_out),
                    .transport_fault(rejected || terror),
                    .mailbox_ready(live_publish_ready),
                    .send(legacy_track_send),
                    .tracked_frame(legacy_frame),
                    .tracked_session(legacy_session),
                    .labels(legacy_labels),
                    .confidences(legacy_conf),
                    .requests(legacy_requests),
                    .association_rejected()
                );
            end
            if (MAX_INFLIGHT > 1) begin : g_window

                ccl_result_window #(
                    .MAX_INFLIGHT(MAX_INFLIGHT),
                    .TRUSTED_MATCH_CONTEXT(1),
                    .CLOCK_HZ(CLOCK_HZ),
                    .CONTEXT_PAD(ROI_HIRES ? 16 : 0)
                ) tracker_window (
                    .action_bird  (track_action),
                    .action_motion(track_action_motion),

                    .clk(clk),
                    .rst_n(rst_n),
                    .cancel(cancel),
                    .mapping_valid(display_mapping_valid),
                    .link_valid(link_session_valid),
                    .link_session(link_session_id),
                    .scene_valid(scene_valid),
                    .scene_frame(scene_frame),
                    .scene_boxes(scene_boxes),
                    .captured(captured),
                    .capture_error(rejected),
                    .motion_known(motion_known),
                    .motion_count(sample_motion),
                    .meta(tmeta),
                    .session_id(tsid),
                    .request_id(trid),
                    .capture_frozen(frozen),
                    .wire_done(wire_done),
                    .matched_session(matched_session_id),
                    .matched_request(matched_request_id),
                    .matched(matched),
                    .matched_frame(matched_frame_id),
                    .matched_roi(matched_roi_id),
                    .status(matched_status),
                    .decision(matched_decision),
                    .confidence(matched_confidence),
                    .flags(matched_flags),
                    .box_valid(mbox_valid),
                    .box_x(mbox_x),
                    .box_y(mbox_y),
                    .box_w(mbox_w),
                    .box_h(mbox_h),
                    .timed_out(timed_out),
                    .transport_fault(rejected || terror),
                    .mailbox_ready(live_publish_ready),
                    .send(track_send),
                    .tracked_frame(tracked_frame),
                    .tracked_session(tracked_session),
                    .labels(track_labels),
                    .confidences(track_confidences),
                    .requests(track_requests),
                    .association_rejected()
                );
            end else begin : g_single
                assign track_action = 1'b0;
                assign track_action_motion = 0;
                assign track_send = legacy_track_send;
                assign tracked_frame = legacy_frame;
                assign tracked_session = legacy_session;
                assign track_labels = legacy_labels;
                assign track_confidences = legacy_conf;
                assign track_requests = legacy_requests;
            end
            wire coherent=tracked_frame==mp[543:512] && tracked_session==mp[575:544] &&
                tracked_session==link_session_id && !tcancel && display_mapping_valid && link_session_valid;

            assign live_publish_allowed=coherent || tcancel || !display_mapping_valid || !link_session_valid ||
                              mp[575:544]!=link_session_id ||
                              !(mp[0]||mp[128]||mp[256]||mp[384]);
            for (ti = 0; ti < 4; ti = ti + 1) begin : g_tags
                assign tracked_mp[ti*128+:128] = {
                    mp[ti*128+127],
                    coherent ? track_requests[ti*32+:32] : 32'd0,
                    coherent ? track_confidences[ti*7+:7] : 7'd0,
                    coherent ? track_labels[ti*3+:3] : 3'd0,
                    mp[ti*128+:85]
                };
            end
            assign tracked_mp[596:512] = mp[596:512];
        end else begin : g_no_tracking
            assign track_action = 1'b0;
            assign track_action_motion = 0;
            assign track_send = 1'b0;
            assign tracked_mp = mp;
            assign live_publish_allowed = 1'b1;
        end
    endgenerate
    wire ms_use = (CCL_SELFVIEW != 0) ? view_send : (ms || track_send);
    wire [596:0] mp_use = (CCL_SELFVIEW != 0) ? view_payload : tracked_mp;

    reg [6:0] scene_cfg_q;
    reg [31:0] cfg_frame_q, cfg_session_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            scene_cfg_q   <= 0;
            cfg_frame_q   <= 0;
            cfg_session_q <= 0;
        end
  else if(!tcancel && link_session_valid && display_mapping_valid &&
          LIVE_SCENE && scene_valid && scene_frame!=0 && link_session_id!=0)begin
            scene_cfg_q   <= scene_cfg;
            cfg_frame_q   <= scene_frame;
            cfg_session_q <= link_session_id;
        end
    end
    wire [6:0] display_cfg=(SCENE_CONFIG && !CCL_SELFVIEW &&
   cfg_frame_q==mp_use[543:512] && cfg_session_q==mp_use[575:544]) ? scene_cfg_q:7'd0;
    a_display_bridge #(
        .SOURCE_W  (SOURCE_W),
        .SOURCE_H  (SOURCE_H),
        .DISPLAY_W (DISPLAY_W),
        .DISPLAY_H (DISPLAY_H),
        .LIVE_SCENE(LIVE_SCENE)
    ) display_metadata (
        .scene_valid(scene_valid),
        .scene_frame(scene_frame),
        .scene_boxes(scene_boxes),
        .scene_shapes(scene_shapes),
        .scene_session(link_session_id),
        .clk(clk),
        .rst_n(rst_n),
        .mapping_valid(display_mapping_valid),
        .captured(captured && annotate_motion),
        .meta(tmeta),
        .session_id(tsid),
        .request_id(trid),
        .motion_count(sample_motion),
        .motion_known(motion_known),
        .capture_error(rejected),
        .matched(matched && annotate_motion),
        .matched_frame(matched_frame_id),
        .matched_roi(matched_roi_id),
        .status(matched_status),
        .decision(matched_decision),
        .confidence(matched_confidence),
        .flags(matched_flags),
        .timed_out(timed_out && annotate_motion),

        .transport_fault((rejected || terror) && annotate_motion),
        .cancel(tcancel || !link_session_valid || link_session_id == 0),
        .info_valid(info_valid),
        .state_valid(state_valid),
        .state_code(state_code),
        .voltage_known(voltage_known),
        .voltage_mv(voltage_mv),
        .mailbox_ready(live_publish_ready),
        .send(ms),
        .payload(mp),
        .mapping_rejected(mapping_rejected)
    );

    wire result_send, result_ready, result_geometry_rejected;
    wire [191:0] result_payload;
    wire legacy_result_send;
    wire [191:0] legacy_result_payload;
    generate
        if (MAX_INFLIGHT == 1) begin : g_legacy_result
            result_display_bridge result_metadata (
                .clk(clk),
                .rst_n(rst_n),
                .cancel(tcancel),
                .mapping_valid(display_mapping_valid),
                .link_session_valid(link_session_valid),
                .link_session_id(link_session_id),
                .captured(captured),
                .capture_error(rejected),
                .meta(tmeta),
                .session_id(tsid),
                .request_id(trid),
                .wire_done(wire_done),
                .packet_meta(debug_packet_meta),
                .matched(matched),
                .matched_frame(matched_frame_id),
                .matched_roi(matched_roi_id),
                .status(matched_status),
                .decision(matched_decision),
                .confidence(matched_confidence),
                .flags(matched_flags),
                .box_valid(mbox_valid),
                .box_x(mbox_x),
                .box_y(mbox_y),
                .box_w(mbox_w),
                .box_h(mbox_h),
                .timed_out(timed_out),
                .transport_fault(rejected || terror),
                .mailbox_ready(result_ready),
                .send(legacy_result_send),
                .payload(legacy_result_payload),
                .geometry_rejected(result_geometry_rejected)
            );
        end
    endgenerate
    generate
        if (MAX_INFLIGHT > 1) begin : g_result_window
            result_display_window #(
                .CLOCK_HZ(CLOCK_HZ),
                .MAX_INFLIGHT(MAX_INFLIGHT),
                .TRUSTED_MATCH_CONTEXT(1)
            ) result_window (
                .motion_known(motion_known),
                .matched_patrol(matched_patrol),
                .clk(clk),
                .rst_n(rst_n),
                .cancel(cancel_all),
                .mapping_valid(display_mapping_valid),
                .link_session_valid(link_session_valid),
                .link_session_id(link_session_id),
                .motion_count(motion_known ? sample_motion : 17'd0),
                .captured(captured),
                .capture_error(rejected),
                .meta(tmeta),
                .session_id(tsid),
                .request_id(trid),
                .wire_done(wire_done),
                .packet_meta(debug_packet_meta),
                .matched_session(matched_session_id),
                .matched_request(matched_request_id),
                .matched(matched),
                .matched_frame(matched_frame_id),
                .matched_roi(matched_roi_id),
                .status(matched_status),
                .decision(matched_decision),
                .confidence(matched_confidence),
                .flags(matched_flags),
                .box_valid(mbox_valid),
                .box_x(mbox_x),
                .box_y(mbox_y),
                .box_w(mbox_w),
                .box_h(mbox_h),
                .timed_out(timed_out),
                .transport_fault(rejected || terror),
                .mailbox_ready(result_ready),
                .send(result_send),
                .payload(result_payload),
                .geometry_rejected(),
                .matched_motion(matched_motion),
                .timing_valid(timing_valid),
                .transmit_ms(matched_transmit_ms),
                .reply_ms(matched_reply_ms),
                .total_ms(matched_total_ms)
            );
        end else begin : g_result_single
            assign matched_patrol = motion_known && sample_motion == 0;
            assign result_send = legacy_result_send;
            assign result_payload = legacy_result_payload;
            assign matched_motion = sample_motion;
            assign timing_valid = 1'b0;
            assign matched_transmit_ms = 0;
            assign matched_reply_ms = 0;
            assign matched_total_ms = 0;
        end
    endgenerate

    generate
        if (MAX_INFLIGHT > 1) begin : g_actions
            reg emit_bird, queued_action;
            reg [16:0] emit_motion, queued_motion;
            wire patrol_action = confirmed_bird && matched && matched_patrol && timing_valid;
            assign action_bird   = emit_bird && !cancel_all;
            assign action_motion = emit_motion;
            always @(posedge clk) begin
                if (!rst_n || cancel_all) begin
                    emit_bird <= 0;
                    queued_action <= 0;
                    emit_motion <= 0;
                    queued_motion <= 0;
                end else begin
                    emit_bird <= 0;
                    if (patrol_action) begin
                        emit_bird   <= 1;
                        emit_motion <= matched_motion;
                        if (track_action) begin
                            queued_action <= 1;
                            queued_motion <= track_action_motion;
                        end
                    end else if (queued_action) begin
                        emit_bird <= 1;
                        emit_motion <= queued_motion;
                        queued_action <= track_action;
                        if (track_action) queued_motion <= track_action_motion;
                    end else if (track_action) begin
                        emit_bird   <= 1;
                        emit_motion <= track_action_motion;
                    end
                end
            end
        end else begin : g_legacy_actions
            assign action_bird   = confirmed_bird;
            assign action_motion = sample_motion;
        end
    endgenerate
    member_b_osd #(
        .WIDTH(DISPLAY_W),
        .HEIGHT(DISPLAY_H),
        .RESULT_LAYER(CCL_SELFVIEW == 0),
        .PANEL_LAYOUT(1),
        .COLOR_LABELS(SCENE_CONFIG),
        .VOLTAGE_REFERENCE(VOLTAGE_REFERENCE)
    ) display (
        .result_send(result_send),
        .result_payload(result_payload),
        .result_ready(result_ready),
        .meta_clk(clk),
        .meta_rst_n(rst_n),
        .meta_send(ms_use),
        .meta_payload(mp_use),
        .meta_cfg(display_cfg),
        .meta_ready(mready),
        .pixel_clk(pixel_clk),
        .pixel_rst_n(pixel_rst_n),
        .video_rgb(video_rgb),
        .video_de(video_de),
        .video_hs(video_hs),
        .video_vs(video_vs),
        .hdmi_rgb(hdmi_rgb),
        .hdmi_de(hdmi_de),
        .hdmi_hs(hdmi_hs),
        .hdmi_vs(hdmi_vs)
    );
endmodule
