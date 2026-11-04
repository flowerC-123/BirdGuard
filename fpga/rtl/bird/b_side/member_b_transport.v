module member_b_transport #(
    parameter integer CLOCK_HZ = 75000000,
    BAUD = 115200,
    READ_TIMEOUT_CYCLES = 7500000,
    REPLY_SECONDS = 6,
    ROI_GAMMA_EN = 0,
    ROI_DETAIL = 0,
    ROI_HIRES = 0,
    TX_PACING = 0,
    MAX_INFLIGHT = 1
) (
    input wire vin_clk,
    vin_rst_n,
    vin_de,
    input wire [23:0] vin_rgb,
    input wire clk,
    rst_n,
    desc_valid,
    output wire desc_ready,
    input wire send_enable,
    input wire [31:0] session_id,
    request_id,
    input wire [159:0] crop_meta,
    input wire lease_valid,
    input wire [31:0] lease_frame_id,
    input wire [15:0] lease_width,
    lease_height,
    output wire lease_release,
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
    cancel,
    input wire cancel_all,
    output wire uart_tx,
    wire_done,
    busy,
    frozen,
    transport_error,
    output wire [159:0] debug_packet_meta,
    input wire reply_valid,
    input wire [31:0] reply_session,
    reply_request,
    input wire [7:0] reply_status,
    reply_decision,
    reply_confidence,
    reply_flags,
    input wire [31:0] reply_processing_ms,
    input wire reply_box_valid,
    input wire [15:0] reply_box_x,
    reply_box_y,
    reply_box_w,
    reply_box_h,
    output wire matched,
    confirmed_bird,
    timed_out,
    failed,
    output wire [31:0] matched_frame_id,
    output wire [15:0] matched_roi_id,
    output wire [7:0] matched_status,
    matched_decision,
    matched_confidence,
    matched_flags,
    output wire [31:0] matched_processing_ms,
    output wire matched_box_valid,
    output wire [15:0] matched_box_x,
    matched_box_y,
    matched_box_w,
    matched_box_h,
    output wire [31:0] matched_session_id,
    matched_request_id,
    output wire [2:0] pending_count
);
    wire snap_ready, snap_busy, guard_busy, waiting;
    wire [7:0] byte_data;
    wire byte_valid, byte_ready, byte_last, byte_done, packet_done;
    reg waiting_stop, wire_done_reg, release_pending;
    assign wire_done = wire_done_reg;
    wire window_ready, window_busy;

    assign busy = snap_busy || waiting_stop || ((MAX_INFLIGHT == 1) && guard_busy);
    assign desc_ready=snap_ready && !waiting_stop && ((MAX_INFLIGHT>1)?window_ready:!guard_busy);
    wire accepted = desc_valid && desc_ready;
    generate
        if (ROI_HIRES) begin : g_hires
            roi_hires_snapshot #(
                .CAPTURE_TIMEOUT_CYCLES(CLOCK_HZ / 10),
                .ROI_GAMMA_EN(ROI_GAMMA_EN),
                .DEFER_TX(TX_PACING)
            ) snapshot (
                .debug_packet_meta(debug_packet_meta),
                .vin_clk(vin_clk),
                .vin_rst_n(vin_rst_n),
                .vin_de(vin_de),
                .vin_rgb(vin_rgb),
                .clk(clk),
                .rst_n(rst_n),
                .send_enable(send_enable),
                .desc_valid(accepted),
                .desc_ready(snap_ready),
                .session_id(session_id),
                .request_id(request_id),
                .crop_meta(crop_meta),
                .lease_valid(lease_valid),
                .lease_frame_id(lease_frame_id),
                .lease_width(lease_width),
                .lease_height(lease_height),
                .lease_release(lease_release),
                .reader_idle(reader_idle),
                .mem_req_valid(mem_req_valid),
                .mem_req_ready(mem_req_ready),
                .mem_frame_id(mem_frame_id),
                .mem_pixel_index(mem_pixel_index),
                .mem_rsp_valid(mem_rsp_valid),
                .mem_rgb(mem_rgb),
                .mem_rsp_error(mem_rsp_error),
                .mem_rsp_ready(mem_rsp_ready),
                .reader_flush(reader_flush),
                .resend((MAX_INFLIGHT==1) && resend && guard_busy && waiting && !waiting_stop && !release_pending),
                .abort(cancel || ((MAX_INFLIGHT > 1) && cancel_all)),
                .release_snapshot(release_pending && !waiting_stop),
                .out_data(byte_data),
                .out_valid(byte_valid),
                .out_last(byte_last),
                .out_ready(byte_ready),
                .packet_done(packet_done),
                .busy(snap_busy),
                .frozen(frozen),
                .error(transport_error)
            );
        end else begin : g_legacy
            assign debug_packet_meta = crop_meta;
            roi_frame_snapshot #(
                .READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES),
                .ROI_GAMMA_EN(ROI_GAMMA_EN),
                .MAX_PIXELS(ROI_DETAIL ? 8192 : 5461),
                .GRAY_ONLY(ROI_DETAIL),
                .DETAIL_RESIZE(ROI_DETAIL)
            ) snapshot (
                .clk(clk),
                .rst_n(rst_n),
                .desc_valid(accepted),
                .desc_ready(snap_ready),
                .session_id(session_id),
                .request_id(request_id),
                .crop_meta(crop_meta),
                .lease_valid(lease_valid),
                .lease_frame_id(lease_frame_id),
                .lease_width(lease_width),
                .lease_height(lease_height),
                .lease_release(lease_release),
                .reader_idle(reader_idle),
                .mem_req_valid(mem_req_valid),
                .mem_req_ready(mem_req_ready),
                .mem_frame_id(mem_frame_id),
                .mem_pixel_index(mem_pixel_index),
                .mem_rsp_valid(mem_rsp_valid),
                .mem_rgb(mem_rgb),
                .mem_rsp_error(mem_rsp_error),
                .mem_rsp_ready(mem_rsp_ready),
                .reader_flush(reader_flush),
                .resend((MAX_INFLIGHT==1) && resend && guard_busy && waiting && !waiting_stop && !release_pending),
                .abort(cancel || ((MAX_INFLIGHT > 1) && cancel_all)),
                .release_snapshot(release_pending && !waiting_stop),
                .out_data(byte_data),
                .out_valid(byte_valid),
                .out_last(byte_last),
                .out_ready(byte_ready),
                .packet_done(packet_done),
                .busy(snap_busy),
                .frozen(frozen),
                .error(transport_error)
            );
        end
    endgenerate
    uart_tx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) serial_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(byte_data),
        .valid(byte_valid),
        .ready(byte_ready),
        .tx(uart_tx),
        .done(byte_done)
    );
    wire g_matched, g_confirmed, g_timeout, g_failed, g_box;
    wire [31:0] g_frame, g_processing;
    wire [15:0] g_roi, g_x, g_y, g_w, g_h;
    wire [7:0] g_status, g_decision, g_confidence, g_flags;
    reg [31:0] legacy_session, legacy_request;
    always @(posedge clk) begin
        if (!rst_n) begin
            legacy_session <= 0;
            legacy_request <= 0;
        end else if (accepted) begin
            legacy_session <= session_id;
            legacy_request <= request_id;
        end
    end

    generate
        if (MAX_INFLIGHT == 1) begin : g_legacy_guard
            roi_result_guard #(
                .CLOCK_HZ(CLOCK_HZ),
                .REPLY_SECONDS(REPLY_SECONDS)
            ) guard (
                .clk(clk),
                .rst_n(rst_n),
                .arm(accepted && MAX_INFLIGHT == 1),
                .cancel(cancel || transport_error),
                .tx_wire_done(wire_done),
                .session_id(session_id),
                .request_id(request_id),
                .source_frame_id(crop_meta[31:0]),
                .roi_id(crop_meta[47:32]),
                .reply_valid(reply_valid),
                .reply_session(reply_session),
                .reply_request(reply_request),
                .reply_status(reply_status),
                .reply_decision(reply_decision),
                .reply_confidence(reply_confidence),
                .reply_flags(reply_flags),
                .reply_processing_ms(reply_processing_ms),
                .reply_box_valid(reply_box_valid),
                .reply_box_x(reply_box_x),
                .reply_box_y(reply_box_y),
                .reply_box_w(reply_box_w),
                .reply_box_h(reply_box_h),
                .busy(guard_busy),
                .waiting(waiting),
                .matched(g_matched),
                .confirmed_bird(g_confirmed),
                .timed_out(g_timeout),
                .failed(g_failed),
                .matched_frame_id(g_frame),
                .matched_roi_id(g_roi),
                .matched_status(g_status),
                .matched_decision(g_decision),
                .matched_confidence(g_confidence),
                .matched_flags(g_flags),
                .matched_processing_ms(g_processing),
                .matched_box_valid(g_box),
                .matched_box_x(g_x),
                .matched_box_y(g_y),
                .matched_box_w(g_w),
                .matched_box_h(g_h)
            );
        end else begin : g_no_legacy_guard
            assign guard_busy = 1'b0;
            assign waiting = 1'b0;
            assign g_matched = 1'b0;
            assign g_confirmed = 1'b0;
            assign g_timeout = 1'b0;
            assign g_failed = 1'b0;
            assign g_box = 1'b0;
            assign g_frame = 0;
            assign g_processing = 0;
            assign g_roi = 0;
            assign g_x = 0;
            assign g_y = 0;
            assign g_w = 0;
            assign g_h = 0;
            assign g_status = 0;
            assign g_decision = 0;
            assign g_confidence = 0;
            assign g_flags = 0;
        end
    endgenerate
    generate
        if (MAX_INFLIGHT > 1) begin : g_parallel
            roi_result_window #(
                .CLOCK_HZ(CLOCK_HZ),
                .REPLY_SECONDS(REPLY_SECONDS),
                .MAX_INFLIGHT(MAX_INFLIGHT)
            ) guard_window (
                .clk(clk),
                .rst_n(rst_n),
                .arm(accepted),
                .cancel_all(cancel_all),
                .abort_current(cancel || transport_error),
                .tx_wire_done(wire_done),
                .session_id(session_id),
                .request_id(request_id),
                .source_frame_id(crop_meta[31:0]),
                .roi_id(crop_meta[47:32]),
                .reply_valid(reply_valid),
                .reply_session(reply_session),
                .reply_request(reply_request),
                .reply_status(reply_status),
                .reply_decision(reply_decision),
                .reply_confidence(reply_confidence),
                .reply_flags(reply_flags),
                .reply_processing_ms(reply_processing_ms),
                .reply_box_valid(reply_box_valid),
                .reply_box_x(reply_box_x),
                .reply_box_y(reply_box_y),
                .reply_box_w(reply_box_w),
                .reply_box_h(reply_box_h),
                .ready(window_ready),
                .busy(window_busy),
                .pending_count(pending_count),
                .matched(matched),
                .confirmed_bird(confirmed_bird),
                .timed_out(timed_out),
                .failed(failed),
                .matched_session_id(matched_session_id),
                .matched_request_id(matched_request_id),
                .matched_frame_id(matched_frame_id),
                .matched_roi_id(matched_roi_id),
                .matched_status(matched_status),
                .matched_decision(matched_decision),
                .matched_confidence(matched_confidence),
                .matched_flags(matched_flags),
                .matched_processing_ms(matched_processing_ms),
                .matched_box_valid(matched_box_valid),
                .matched_box_x(matched_box_x),
                .matched_box_y(matched_box_y),
                .matched_box_w(matched_box_w),
                .matched_box_h(matched_box_h)
            );
        end else begin : g_single
            assign window_ready = 1'b0;
            assign window_busy = 1'b0;
            assign pending_count = {2'b0, guard_busy};
            assign matched = g_matched;
            assign confirmed_bird = g_confirmed;
            assign timed_out = g_timeout;
            assign failed = g_failed;
            assign matched_session_id = legacy_session;
            assign matched_request_id = legacy_request;
            assign matched_frame_id = g_frame;
            assign matched_roi_id = g_roi;
            assign matched_status = g_status;
            assign matched_decision = g_decision;
            assign matched_confidence = g_confidence;
            assign matched_flags = g_flags;
            assign matched_processing_ms = g_processing;
            assign matched_box_valid = g_box;
            assign matched_box_x = g_x;
            assign matched_box_y = g_y;
            assign matched_box_w = g_w;
            assign matched_box_h = g_h;
        end
    endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin
            waiting_stop <= 0;
            wire_done_reg <= 0;
            release_pending <= 0;
        end else begin
            wire_done_reg <= 0;
            if (byte_valid && byte_ready && byte_last) waiting_stop <= 1;
            if (waiting_stop && byte_done) begin
                waiting_stop  <= 0;
                wire_done_reg <= 1;
            end
            if(((MAX_INFLIGHT>1)?wire_done:(matched || timed_out)) || cancel || transport_error ||
      ((MAX_INFLIGHT>1) && cancel_all))
                release_pending <= 1;
            else if (!snap_busy) release_pending <= 0;
        end
    end
endmodule
