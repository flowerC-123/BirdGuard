module a_system_top #(
    parameter MULTI_REQUEST = 0,
    parameter ALLOW_TIMEOUT_DEGRADE = 1,

    parameter FRAME_W = 320,
    parameter FRAME_H = 240,
    parameter USE_BACKGROUND = 0,
    parameter MULTI_ALGO = 0,
    parameter DIFF_THRESHOLD = 8'd30,
    parameter MIN_AREA = 60,

    parameter [16:0] AREA_TH_L1 = 17'd200,
    parameter [16:0] AREA_TH_L2 = 17'd1000,

    parameter [31:0] L1_CYCLES = 32'd150_000_000,
    parameter [31:0] L2_CYCLES = 32'd300_000_000,
    parameter [31:0] L3_CYCLES = 32'd450_000_000,
    parameter [31:0] COOLDOWN_CYCLES = 32'd150_000_000,

    parameter [15:0] VOLT_LOW_MV = 16'd10500,
    parameter [15:0] VOLT_OK_MV  = 16'd11000,

    parameter [31:0] TONE_HALF_CYCLES    = 32'd12500,
    parameter [31:0] SWEEP_PERIOD_CYCLES = 32'd75_000_000,
    parameter [31:0] BURST_ON_CYCLES     = 32'd37_500_000,
    parameter [31:0] BURST_OFF_CYCLES    = 32'd37_500_000,
    parameter [31:0] FLASH_HALF_CYCLES   = 32'd7_500_000,
    parameter [31:0] FLASH_FAST_CYCLES   = 32'd1_875_000,
    parameter [31:0] STEP_MAX            = 32'd89478,
    parameter [31:0] STEP_MIN            = 32'd22369
) (
    input wire clk,
    input wire rst_n,

    input wire [ 6:0] det_cfg,
    input wire [23:0] cam_pixel,
    input wire        cam_valid,
    input wire        cam_frame_start,
    input wire        cam_frame_end,

    input wire force_inspect,

    input wire        voltage_valid,
    input wire [15:0] voltage_mv,

    output wire         desc_valid,
    input  wire         desc_ready,
    output wire [ 31:0] session_id,
    output wire [ 31:0] request_id,
    output wire [159:0] crop_meta,
    output wire         bbox_done,
    output wire [ 16:0] motion_count,

    input  wire        lease_valid,
    output wire        lease_gnt,
    output wire [31:0] lease_frame_id,
    output wire [15:0] lease_width,
    output wire [15:0] lease_height,
    input  wire        lease_release,

    input  wire        reader_flush,
    output wire        reader_idle,
    input  wire        mem_req_valid,
    output wire        mem_req_ready,
    input  wire [31:0] mem_frame_id,
    input  wire [31:0] mem_pixel_index,
    output wire        mem_rsp_valid,
    input  wire        mem_rsp_ready,
    output wire [23:0] mem_rgb,
    output wire        mem_rsp_error,

    input  wire        matched,
    input  wire [ 7:0] matched_decision,
    input  wire [ 7:0] matched_confidence,
    input  wire [ 7:0] matched_flags,
    input  wire        confirmed_bird,
    input  wire        timed_out,
    input  wire        failed,
    input  wire [16:0] authenticated_area,
    input  wire        authenticated_bird,
    input  wire        outstanding,
    output wire        cancel_inflight,

    output wire [3:0] state_code,
    output wire       state_valid,

    output wire buzzer,
    output wire audio_pwm,
    output wire led_flash,

    output wire deterrent_active,
    output wire unconfirmed,

    output wire [  3:0] cclv_index,
    output wire [  9:0] cclv_x0,
    output wire [  9:0] cclv_x1,
    output wire [  8:0] cclv_y0,
    output wire [  8:0] cclv_y1,
    output wire [ 16:0] cclv_area,
    output wire         cclv_valid,
    output wire         cclv_done,
    output wire [  3:0] cclv_count,
    output wire [  7:0] roi_diag,
    output wire         scene_valid,
    output wire [ 31:0] scene_frame,
    output wire [223:0] scene_boxes,
    output wire [ 11:0] scene_shapes,
    output wire [  6:0] scene_cfg
);

    wire desc_handshake = desc_valid && desc_ready;

    wire enable_level1, enable_level2, enable_level3;

    wire fsm_unconfirmed;

    assign deterrent_active = enable_level1 | enable_level2 | enable_level3;
    assign unconfirmed      = fsm_unconfirmed;

    video_pipeline_top #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H),
        .MULTI_ALGO(MULTI_ALGO),
        .USE_BACKGROUND(USE_BACKGROUND),
        .DIFF_THRESHOLD(DIFF_THRESHOLD),
        .MIN_AREA(MIN_AREA)
    ) u_pipeline (
        .roi_diag(roi_diag),
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
        .force_inspect(force_inspect),
        .cfg_session_id(32'd1),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .session_id(session_id),
        .request_id(request_id),
        .crop_meta(crop_meta),
        .lease_valid(lease_valid),
        .lease_gnt(lease_gnt),
        .lease_frame_id(lease_frame_id),
        .lease_width(lease_width),
        .lease_height(lease_height),
        .lease_release(lease_release),
        .reader_idle(reader_idle),
        .reader_flush(reader_flush),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_frame_id(mem_frame_id),
        .mem_pixel_index(mem_pixel_index),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rgb(mem_rgb),
        .mem_rsp_error(mem_rsp_error),
        .motion_count(motion_count),
        .bbox_done(bbox_done),
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

    top_fsm #(
        .MULTI_REQUEST(MULTI_REQUEST),
        .ALLOW_TIMEOUT_DEGRADE(ALLOW_TIMEOUT_DEGRADE),
        .AREA_TH_L1(AREA_TH_L1),
        .AREA_TH_L2(AREA_TH_L2),
        .L1_CYCLES(L1_CYCLES),
        .L2_CYCLES(L2_CYCLES),
        .L3_CYCLES(L3_CYCLES),
        .COOLDOWN_CYCLES(COOLDOWN_CYCLES),
        .VOLT_LOW_MV(VOLT_LOW_MV),
        .VOLT_OK_MV(VOLT_OK_MV)
    ) u_fsm (
        .clk(clk),
        .rst_n(rst_n),
        .matched(matched),
        .matched_decision(matched_decision),
        .matched_confidence(matched_confidence),
        .matched_flags(matched_flags),
        .confirmed_bird(confirmed_bird),
        .timed_out(timed_out),
        .failed(failed),
        .desc_issue(desc_handshake),
        .motion_count(motion_count),
        .authenticated_area(authenticated_area),
        .authenticated_bird(authenticated_bird),
        .outstanding(outstanding),
        .cancel_inflight(cancel_inflight),
        .voltage_valid(voltage_valid),
        .voltage_mv(voltage_mv),
        .enable_level1(enable_level1),
        .enable_level2(enable_level2),
        .enable_level3(enable_level3),
        .state_code(state_code),
        .state_valid(state_valid),
        .unconfirmed(fsm_unconfirmed),
        .current_state()
    );

    pwm_deterrent #(
        .TONE_HALF_CYCLES(TONE_HALF_CYCLES),
        .SWEEP_PERIOD_CYCLES(SWEEP_PERIOD_CYCLES),
        .BURST_ON_CYCLES(BURST_ON_CYCLES),
        .BURST_OFF_CYCLES(BURST_OFF_CYCLES),
        .FLASH_HALF_CYCLES(FLASH_HALF_CYCLES),
        .FLASH_FAST_CYCLES(FLASH_FAST_CYCLES),
        .STEP_MAX(STEP_MAX),
        .STEP_MIN(STEP_MIN)
    ) u_pwm (
        .clk(clk),
        .rst_n(rst_n),
        .enable_level1(enable_level1),
        .enable_level2(enable_level2),
        .enable_level3(enable_level3),
        .buzzer(buzzer),
        .audio_pwm(audio_pwm),
        .led_flash(led_flash)
    );

endmodule
