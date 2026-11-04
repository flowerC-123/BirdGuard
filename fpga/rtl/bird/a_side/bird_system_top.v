module bird_system_top #(
    parameter integer B_CLOCK_HZ = 75_000_000,

    parameter FRAME_W = 320,
    parameter FRAME_H = 240,
    parameter USE_BACKGROUND = 0,
    parameter MULTI_ALGO = 0,
    parameter DIFF_THRESHOLD = 8'd30,
    parameter MIN_AREA = 60,
    parameter FORCE_INSPECT_EN = 1,
    parameter [16:0] AREA_TH_L1 = 17'd200,
    parameter [16:0] AREA_TH_L2 = 17'd1000,

    parameter [31:0] L1_CYCLES = B_CLOCK_HZ,
    parameter [31:0] L2_CYCLES = B_CLOCK_HZ * 3 / 2,
    parameter [31:0] L3_CYCLES = B_CLOCK_HZ * 5 / 2,
    parameter [31:0] COOLDOWN_CYCLES = B_CLOCK_HZ,
    parameter [15:0] VOLT_LOW_MV = 16'd10500,
    parameter [15:0] VOLT_OK_MV = 16'd11000,

    parameter [31:0] TONE_HALF_CYCLES    = B_CLOCK_HZ / 6000,
    parameter [31:0] SWEEP_PERIOD_CYCLES = B_CLOCK_HZ,
    parameter [31:0] BURST_ON_CYCLES     = B_CLOCK_HZ / 4,
    parameter [31:0] BURST_OFF_CYCLES    = B_CLOCK_HZ / 20,
    parameter [31:0] FLASH_HALF_CYCLES   = B_CLOCK_HZ / 10,
    parameter [31:0] FLASH_FAST_CYCLES   = B_CLOCK_HZ / 20,
    parameter [31:0] STEP_MAX            = (64'd4294967296 * 8000 + B_CLOCK_HZ / 2) / B_CLOCK_HZ,
    parameter [31:0] STEP_MIN            = (64'd4294967296 * 2000 + B_CLOCK_HZ / 2) / B_CLOCK_HZ,

    parameter integer B_BAUD                = 115200,
    parameter integer ROI_GAMMA_EN          = 0,
    parameter integer ROI_DETAIL            = 0,
    parameter integer ROI_HIRES             = 0,
    parameter integer B_REQUEST_GAP_MS      = 0,
    parameter integer B_MAX_INFLIGHT        = 1,
    parameter integer ADC_MEASUREMENT_VALID = 0,

    parameter integer ADC_DISPLAY_COMPAT = 0,
    parameter integer ALLOW_TIMEOUT_DEGRADE = 1,
    parameter integer REPLY_SECONDS = 6,
    parameter integer SOURCE_W = 320,
    parameter integer SOURCE_H = 240,

    parameter CCL_SELFVIEW = 0,
    parameter [31:0] LINK_SESSION_ID = 32'h2468_0001,

    parameter integer C_CLK_HZ = 50_000_000,
    parameter integer C_BAUD = 9600,
    parameter [15:0] VOLT_SCALE_NUM = 16'd8,
    parameter [15:0] VOLT_SCALE_DEN = 16'd1,
    parameter integer VVALID_CYCLES = 5_000_000,
    parameter integer INFO_CYCLES = 75_000_000,

    parameter integer FORCE_SEC = 5
) (
    input wire clk,
    input wire rst_n,

    input wire [ 6:0] det_cfg,
    input wire [23:0] cam_pixel,
    input wire        cam_valid,
    input wire        cam_frame_start,
    input wire        cam_frame_end,

    input wire pixel_clk,

    input  wire        roi_vin_rst_n,
    input  wire [23:0] roi_vin_rgb,
    input  wire        roi_vin_de,
    input  wire [23:0] video_rgb,
    input  wire        video_de,
    input  wire        video_hs,
    input  wire        video_vs,
    output wire [23:0] hdmi_rgb,
    output wire        hdmi_de,
    output wire        hdmi_hs,
    output wire        hdmi_vs,

    input  wire uart_rx,
    output wire uart_tx,

    inout  wire       i2c_sda,
    inout  wire       i2c_scl,
    input  wire [4:0] current_hour,
    output wire       stats_txd,
    output wire       stats_de_n,
    output wire       stats_re_n,
    output wire       stats_dir,
    output wire [7:0] DIG,
    output wire [7:0] SEL,

    output wire buzzer,
    output wire audio_pwm,
    output wire led_flash,

    output wire        deterrent_active,
    output wire        unconfirmed,
    output wire [15:0] battery_mv,
    output wire [15:0] total_triggers,
    output wire [15:0] hour_triggers,
    output wire        mapping_rejected,

    output wire [15:0] last_total_ms,
    output wire [15:0] last_transmit_ms,
    output wire [15:0] last_reply_ms,
    output wire [15:0] last_processing_ms,
    output wire        latency_valid,
    output wire [15:0] latency_samples,
    output wire [15:0] latency_timeouts,
    output wire [15:0] forced_count,

    output wire mon_tx
);

    wire [15:0] adc_raw_mv;
    wire [15:0] max_mv, min_mv;
    wire trigger_event;
    reg  volt_valid_pulse;
    wire volt_valid_gated;

    wire desc_valid, desc_ready, bbox_done;
    wire [31:0] session_id, request_id;
    wire [159:0] crop_meta;
    wire [ 16:0] motion_count;
    wire lease_valid, lease_gnt, lease_release;
    wire [31:0] lease_frame_id;
    wire [15:0] lease_width, lease_height;
    wire reader_idle, reader_flush;
    wire mem_req_valid, mem_req_ready;
    wire [31:0] mem_frame_id, mem_pixel_index;
    wire mem_rsp_valid, mem_rsp_ready;
    wire [23:0] mem_rgb;
    wire        mem_rsp_error;

    wire matched, confirmed_bird, timed_out, failed;
    wire [7:0] matched_decision, matched_confidence, matched_flags;

    wire [3:0] state_code;
    wire       state_valid;

    wire S_b_busy, S_b_wire_done, S_b_rejected, S_b_captured, S_b_rxbyte;
    wire [ 3:0] S_b_error;
    wire [31:0] S_b_proc_ms;
    wire [ 2:0] S_b_outstanding;
    wire [16:0] S_b_matched_motion;
    wire S_b_timing_valid, cancel_inflight, S_b_action_bird;
    wire [16:0] S_b_action_motion;
    wire [15:0] S_b_tx_ms, S_b_reply_ms, S_b_total_ms;

    wire [3:0] cclv_index;
    wire [9:0] cclv_x0, cclv_x1;
    wire [8:0] cclv_y0, cclv_y1;
    wire [16:0] cclv_area;
    wire cclv_valid, cclv_done;
    wire [3:0] cclv_count;
    wire scene_valid;
    wire [31:0] scene_frame;
    wire [223:0] scene_boxes;
    wire [11:0] scene_shapes;
    wire [6:0] scene_cfg;

    member_c_subsystem #(
        .MEASUREMENT_VALID(ADC_MEASUREMENT_VALID),
        .DISPLAY_ENABLE(ADC_MEASUREMENT_VALID || ADC_DISPLAY_COMPAT),
        .DISPLAY_REFERENCE(!ADC_MEASUREMENT_VALID && ADC_DISPLAY_COMPAT),
        .DISPLAY_SCALE_NUM(ADC_DISPLAY_COMPAT ? VOLT_SCALE_NUM : 16'd1),
        .DISPLAY_SCALE_DEN(ADC_DISPLAY_COMPAT ? VOLT_SCALE_DEN : 16'd1),
        .CLK_FREQ(C_CLK_HZ),
        .BAUD_RATE(C_BAUD)
    ) u_member_c (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_sda(i2c_sda),
        .i2c_scl(i2c_scl),
        .voltage_valid(volt_valid_gated),
        .trigger_event(trigger_event),
        .current_hour(current_hour),
        .uart_rxd(1'b1),
        .uart_txd(stats_txd),
        .rs485_de_n(stats_de_n),
        .rs485_re_n(stats_re_n),
        .rs485_dir_ctrl(stats_dir),
        .DIG(DIG),
        .SEL(SEL),
        .voltage_mv(adc_raw_mv),
        .max_voltage_mv(max_mv),
        .min_voltage_mv(min_mv),
        .total_triggers(total_triggers),
        .current_hour_count(hour_triggers)
    );

    wire [31:0] batt_scaled = (adc_raw_mv * VOLT_SCALE_NUM) /
                              (VOLT_SCALE_DEN == 0 ? 16'd1 : VOLT_SCALE_DEN);
    reg [15:0] batt_mv_r = 16'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) batt_mv_r <= 16'd0;
        else batt_mv_r <= batt_scaled[15:0];
    end
    assign battery_mv = batt_mv_r;

    wire [31:0] vvalid_cnt_w;
    reg  [31:0] vvalid_cnt = 32'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vvalid_cnt <= 32'd0;
            volt_valid_pulse <= 1'b0;
        end else begin
            volt_valid_pulse <= 1'b0;
            if (vvalid_cnt >= VVALID_CYCLES - 1) begin
                vvalid_cnt <= 32'd0;
                volt_valid_pulse <= 1'b1;
            end else begin
                vvalid_cnt <= vvalid_cnt + 1'b1;
            end
        end
    end
    assign vvalid_cnt_w = vvalid_cnt;
    assign volt_valid_gated = ADC_MEASUREMENT_VALID && volt_valid_pulse && (adc_raw_mv != 16'd0);

    localparam integer VK_TIMEOUT = 3 * VVALID_CYCLES;
    reg [31:0] vknown_to = 32'd0;
    reg        volt_known_lvl = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vknown_to <= 32'd0;
            volt_known_lvl <= 1'b0;
        end else if (volt_valid_gated) begin
            vknown_to <= 32'd0;
            volt_known_lvl <= 1'b1;
        end else if (vknown_to >= VK_TIMEOUT - 1) begin
            vknown_to <= 32'd0;
            volt_known_lvl <= 1'b0;
        end else begin
            vknown_to <= vknown_to + 1'b1;
        end
    end
    wire voltage_known_for_osd = volt_known_lvl ||
        (!ADC_MEASUREMENT_VALID && ADC_DISPLAY_COMPAT && adc_raw_mv!=16'd0);

    wire S_force_cand, S_force_lvl;
    wire [7:0] roi_diag;
    wire [383:0] roi_trace;
    wire roi_trace_motion;

    a_system_top #(
        .MULTI_REQUEST(B_MAX_INFLIGHT > 1),
        .ALLOW_TIMEOUT_DEGRADE(ALLOW_TIMEOUT_DEGRADE),
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H),
        .MULTI_ALGO(MULTI_ALGO),
        .USE_BACKGROUND(USE_BACKGROUND),
        .DIFF_THRESHOLD(DIFF_THRESHOLD),
        .MIN_AREA(MIN_AREA),
        .AREA_TH_L1(AREA_TH_L1),
        .AREA_TH_L2(AREA_TH_L2),
        .L1_CYCLES(L1_CYCLES),
        .L2_CYCLES(L2_CYCLES),
        .L3_CYCLES(L3_CYCLES),
        .COOLDOWN_CYCLES(COOLDOWN_CYCLES),
        .VOLT_LOW_MV(VOLT_LOW_MV),
        .VOLT_OK_MV(VOLT_OK_MV),
        .TONE_HALF_CYCLES(TONE_HALF_CYCLES),
        .SWEEP_PERIOD_CYCLES(SWEEP_PERIOD_CYCLES),
        .BURST_ON_CYCLES(BURST_ON_CYCLES),
        .BURST_OFF_CYCLES(BURST_OFF_CYCLES),
        .FLASH_HALF_CYCLES(FLASH_HALF_CYCLES),
        .FLASH_FAST_CYCLES(FLASH_FAST_CYCLES),
        .STEP_MAX(STEP_MAX),
        .STEP_MIN(STEP_MIN)
    ) u_a_system (
        .authenticated_bird(S_b_action_bird),
        .authenticated_area(S_b_action_motion),
        .outstanding(S_b_outstanding != 0),
        .cancel_inflight(cancel_inflight),
        .scene_valid(scene_valid),
        .scene_frame(scene_frame),
        .scene_boxes(scene_boxes),
        .scene_shapes(scene_shapes),
        .scene_cfg(scene_cfg),
        .clk(clk),
        .rst_n(rst_n),
        .det_cfg(det_cfg),
        .cam_pixel(cam_pixel),
        .cam_valid(cam_valid),
        .cam_frame_start(cam_frame_start),
        .cam_frame_end(cam_frame_end),

        .force_inspect(FORCE_INSPECT_EN && S_force_cand && S_force_lvl),
        .roi_diag(roi_diag),
        .voltage_valid(volt_valid_gated),
        .voltage_mv(batt_mv_r),

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
        .reader_flush(reader_flush),
        .reader_idle(reader_idle),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_frame_id(mem_frame_id),
        .mem_pixel_index(mem_pixel_index),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rgb(mem_rgb),
        .mem_rsp_error(mem_rsp_error),
        .matched(matched),
        .matched_decision(matched_decision),
        .matched_confidence(matched_confidence),
        .matched_flags(matched_flags),
        .confirmed_bird(confirmed_bird),
        .timed_out(timed_out),
        .failed(failed),
        .state_code(state_code),
        .state_valid(state_valid),

        .buzzer(buzzer),
        .audio_pwm(audio_pwm),
        .led_flash(led_flash),

        .deterrent_active(deterrent_active),
        .unconfirmed(unconfirmed),

        .cclv_index(cclv_index),
        .cclv_x0(cclv_x0),
        .cclv_x1(cclv_x1),
        .cclv_y0(cclv_y0),
        .cclv_y1(cclv_y1),
        .cclv_area(cclv_area),
        .cclv_valid(cclv_valid),
        .cclv_done(cclv_done),
        .cclv_count(cclv_count)
    );

    reg det_d = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) det_d <= 1'b0;
        else det_d <= deterrent_active;
    end
    assign trigger_event = deterrent_active & ~det_d;

    reg [ 3:0] state_d = 4'd0;
    reg [31:0] info_cnt = 32'd0;
    reg        info_valid = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_d <= 4'd0;
            info_cnt <= 32'd0;
            info_valid <= 1'b0;
        end else begin
            info_valid <= 1'b0;
            if (state_code != state_d) begin
                state_d <= state_code;
                info_valid <= 1'b1;
            end else if (info_cnt >= INFO_CYCLES - 1) begin
                info_cnt   <= 32'd0;
                info_valid <= 1'b1;
            end else begin
                info_cnt <= info_cnt + 1'b1;
            end
        end
    end

    member_b_ab_top #(
        .MAX_INFLIGHT(B_MAX_INFLIGHT),
        .VOLTAGE_REFERENCE(!ADC_MEASUREMENT_VALID && ADC_DISPLAY_COMPAT),
        .CLOCK_HZ(B_CLOCK_HZ),
        .BAUD(B_BAUD),
        .ROI_GAMMA_EN(ROI_GAMMA_EN),
        .ROI_DETAIL(ROI_DETAIL),
        .ROI_HIRES(ROI_HIRES),
        .REQUEST_GAP_CYCLES((B_CLOCK_HZ / 1000) * B_REQUEST_GAP_MS),
        .READ_TIMEOUT_CYCLES(45),
        .LEASE_TIMEOUT_CYCLES(50),

        .MAX_CAPTURE_CYCLES(ROI_HIRES ? B_CLOCK_HZ / 5 : 750000),
        .REPLY_SECONDS(REPLY_SECONDS),
        .SOURCE_W(SOURCE_W),
        .SOURCE_H(SOURCE_H),

        .CCL_SELFVIEW(CCL_SELFVIEW),
        .LIVE_SCENE  (1),
        .SCENE_CONFIG(1)
    ) u_member_b (
        .action_bird(S_b_action_bird),
        .action_motion(S_b_action_motion),
        .outstanding_count(S_b_outstanding),
        .matched_motion(S_b_matched_motion),
        .timing_valid(S_b_timing_valid),
        .matched_transmit_ms(S_b_tx_ms),
        .matched_reply_ms(S_b_reply_ms),
        .matched_total_ms(S_b_total_ms),
        .vin_clk(pixel_clk),
        .vin_rst_n(roi_vin_rst_n),
        .vin_de(roi_vin_de),
        .vin_rgb(roi_vin_rgb),
        .scene_valid(scene_valid),
        .scene_frame(scene_frame),
        .scene_boxes(scene_boxes),
        .scene_shapes(scene_shapes),
        .scene_cfg(scene_cfg),
        .clk(clk),
        .rst_n(rst_n),
        .cancel(B_MAX_INFLIGHT > 1 && cancel_inflight),
        .resend(1'b0),
        .link_session_valid(1'b1),
        .link_session_id(LINK_SESSION_ID),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .crop_meta(crop_meta),
        .session_id(session_id),
        .request_id(request_id),
        .bbox_done(bbox_done),
        .motion_count(motion_count),
        .lease_valid(lease_valid),
        .lease_gnt(lease_gnt),
        .lease_frame_id(lease_frame_id),
        .lease_width(lease_width),
        .lease_height(lease_height),
        .lease_release(lease_release),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_frame_id(mem_frame_id),
        .mem_pixel_index(mem_pixel_index),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rgb(mem_rgb),
        .mem_rsp_error(mem_rsp_error),
        .mem_rsp_ready(mem_rsp_ready),
        .reader_flush(reader_flush),
        .reader_idle(reader_idle),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),

        .busy(S_b_busy),
        .frozen(),
        .wire_done(S_b_wire_done),
        .matched(matched),
        .confirmed_bird(confirmed_bird),
        .timed_out(timed_out),
        .failed(failed),
        .rejected(S_b_rejected),
        .error_code(S_b_error),
        .roi_trace(roi_trace),
        .roi_trace_motion(roi_trace_motion),
        .captured_o(S_b_captured),
        .rx_byte_valid(S_b_rxbyte),
        .matched_frame_id(),
        .matched_roi_id(),
        .matched_status(),
        .matched_decision(matched_decision),
        .matched_confidence(matched_confidence),
        .matched_flags(matched_flags),
        .matched_processing_ms(S_b_proc_ms),
        .rx_packet_error(),
        .rx_partial_timeout(),
        .display_mapping_valid(1'b1),
        .cclv_index(cclv_index),
        .cclv_x0(cclv_x0),
        .cclv_x1(cclv_x1),
        .cclv_y0(cclv_y0),
        .cclv_y1(cclv_y1),
        .cclv_area(cclv_area),
        .cclv_valid(cclv_valid),
        .cclv_done(cclv_done),
        .cclv_count(cclv_count),
        .info_valid(info_valid),
        .state_valid(state_valid),
        .state_code(state_code),
        .voltage_known(voltage_known_for_osd),
        .voltage_mv(batt_mv_r),
        .pixel_clk(pixel_clk),
        .pixel_rst_n(rst_n),
        .video_rgb(video_rgb),
        .video_de(video_de),
        .video_hs(video_hs),
        .video_vs(video_vs),
        .hdmi_rgb(hdmi_rgb),
        .hdmi_de(hdmi_de),
        .hdmi_hs(hdmi_hs),
        .hdmi_vs(hdmi_vs),
        .mapping_rejected(mapping_rejected)
    );

    wire [15:0] S_motion_cnt, S_forced_cnt, S_drop_forced;
    still_bird_timer #(
        .CLOCK_HZ (C_CLK_HZ),
        .FORCE_SEC(FORCE_SEC)
    ) u_still_bird (
        .clk(clk),
        .rst_n(rst_n),
        .motion_candidate(desc_valid && desc_ready),
        .busy(S_b_busy),
        .candidate(S_force_cand),
        .forced(S_force_lvl),
        .motion_count(S_motion_cnt),
        .forced_count(S_forced_cnt),
        .dropped_forced_count(S_drop_forced)
    );
    reg [15:0] patrol_accepts;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) patrol_accepts <= 0;
        else if(FORCE_INSPECT_EN&&desc_valid&&desc_ready&&motion_count==0&&patrol_accepts!=16'hffff)
            patrol_accepts <= patrol_accepts + 1'b1;
    assign forced_count = patrol_accepts;

    latency_monitor #(
        .MULTI_REQUEST(B_MAX_INFLIGHT > 1),
        .CLOCK_HZ(C_CLK_HZ)
    ) u_latency (
        .context_valid(S_b_timing_valid),
        .context_transmit_ms(S_b_tx_ms),
        .context_reply_ms(S_b_reply_ms),
        .context_total_ms(S_b_total_ms),
        .clk(clk),
        .rst_n(rst_n),
        .arm(desc_valid && desc_ready),
        .wire_done(S_b_wire_done),
        .matched_reply(matched),
        .abandoned(timed_out),
        .capture_error(S_b_rejected),
        .processing_ms(S_b_proc_ms),
        .last_transmit_ms(last_transmit_ms),
        .last_reply_ms(last_reply_ms),
        .last_total_ms(last_total_ms),
        .last_processing_ms(last_processing_ms),
        .last_valid(latency_valid),
        .min_total_ms(),
        .max_total_ms(),
        .total_acc_ms(),
        .sample_count(latency_samples),
        .timeout_count(latency_timeouts),
        .capture_error_count()
    );

    pipe_monitor #(
        .CLK_HZ           (C_CLK_HZ),
        .BAUD             (115200),
        .PERIOD_MS        (500),
        .TRACE_DIAGNOSTICS(1),
        .MIN_AREA         (MIN_AREA)
    ) u_pipe_mon (
        .clk               (clk),
        .rst_n             (rst_n),
        .i_frame_start     (cam_frame_start),
        .i_frame_end       (cam_frame_end),
        .i_cclv_valid      (cclv_valid),
        .i_cclv_area       (cclv_area),
        .i_cclv_done       (cclv_done),
        .i_cclv_count      (cclv_count),
        .i_desc_valid      (desc_valid),
        .i_desc_ready      (desc_ready),
        .i_lease_valid     (lease_valid),
        .i_lease_gnt       (lease_gnt),
        .i_reader_idle     (reader_idle),
        .i_busy            (S_b_busy),
        .i_captured        (S_b_captured),
        .i_rejected        (S_b_rejected),
        .i_error_code      (S_b_error),
        .i_wire_done       (S_b_wire_done),
        .i_rx_byte         (S_b_rxbyte),
        .i_matched         (matched),
        .i_timed_out       (timed_out),
        .i_state_code      (state_code),
        .i_roi_diag        (roi_diag),
        .i_roi_trace       (roi_trace),
        .i_roi_trace_motion(roi_trace_motion),
        .mon_tx            (mon_tx)
    );

endmodule
