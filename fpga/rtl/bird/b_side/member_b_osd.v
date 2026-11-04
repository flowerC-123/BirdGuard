module member_b_osd #(
    parameter WIDTH = 1280,
    HEIGHT = 720,
    MAX_HOLD_FRAMES = 120,
    VS_ACTIVE = 1,
    RESULT_LAYER = 0,
    PANEL_LAYOUT = 0,
    COLOR_LABELS = 0,
    VOLTAGE_REFERENCE = 0
) (
    input wire meta_clk,
    meta_rst_n,
    meta_send,
    input wire [596:0] meta_payload,
    output wire meta_ready,
    input wire [6:0] meta_cfg,
    input wire result_send,
    input wire [191:0] result_payload,
    output wire result_ready,
    input wire pixel_clk,
    pixel_rst_n,
    input wire [23:0] video_rgb,
    input wire video_de,
    video_hs,
    video_vs,
    output wire [23:0] hdmi_rgb,
    output wire hdmi_de,
    hdmi_hs,
    hdmi_vs
);
    wire valid, take, start;
    wire [603:0] data;
    reg  [  6:0] clean_cfg;

    always @* begin
        clean_cfg = 0;
        if (COLOR_LABELS)
            case (meta_cfg[4:0])
                5'd2, 5'd3, 5'd6, 5'd7, 5'd10, 5'd11, 5'd14, 5'd15, 5'd18, 5'd19, 5'd22, 5'd23:
                clean_cfg = {2'd0, meta_cfg[4:0]};
                default: clean_cfg = 0;
            endcase
    end
    wire [11:0] x, y;
    osd_mailbox #(
        .WIDTH(604)
    ) cdc (
        .src_clk(meta_clk),
        .src_rst_n(meta_rst_n),
        .src_send(meta_send),
        .src_payload({clean_cfg, meta_payload}),
        .src_ready(meta_ready),
        .dst_clk(pixel_clk),
        .dst_rst_n(pixel_rst_n),
        .dst_take(take),
        .dst_valid(valid),
        .dst_payload(data)
    );
    osd_video_xy #(
        .VS_ACTIVE(VS_ACTIVE)
    ) xy (
        .clk(pixel_clk),
        .rst_n(pixel_rst_n),
        .vs(video_vs),
        .de(video_de),
        .frame_start(start),
        .x(x),
        .y(y)
    );
    wire [23:0] live_rgb;
    wire live_cover;
    hdmi_osd #(
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT),
        .MAX_HOLD_FRAMES(MAX_HOLD_FRAMES),
        .PANEL_LAYOUT(PANEL_LAYOUT),
        .COLOR_LABELS(COLOR_LABELS),
        .VOLTAGE_REFERENCE(VOLTAGE_REFERENCE)
    ) overlay (
        .pixel_clk(pixel_clk),
        .rst_n(pixel_rst_n),
        .in_rgb(video_rgb),
        .in_de(video_de),
        .in_hs(video_hs),
        .in_vs(video_vs),
        .in_x(x),
        .in_y(y),
        .frame_start(start),
        .meta_valid(valid),
        .meta_payload(data[596:0]),
        .meta_cfg(data[603:597]),
        .meta_take(take),
        .out_rgb(live_rgb),
        .out_de(hdmi_de),
        .out_hs(hdmi_hs),
        .out_vs(hdmi_vs),
        .scene_age(),
        .scene_fresh(),
        .out_overlay(live_cover)
    );
    generate
        if (RESULT_LAYER != 0) begin : g_result
            wire rv, rt, covered, result_text;
            wire [191:0] rd;
            wire [ 23:0] rgb;
            osd_mailbox #(
                .WIDTH(192)
            ) result_cdc (
                .src_clk(meta_clk),
                .src_rst_n(meta_rst_n),
                .src_send(result_send),
                .src_payload(result_payload),
                .src_ready(result_ready),
                .dst_clk(pixel_clk),
                .dst_rst_n(pixel_rst_n),
                .dst_take(rt),
                .dst_valid(rv),
                .dst_payload(rd)
            );
            result_overlay #(
                .WIDTH(WIDTH),
                .HEIGHT(HEIGHT),
                .MAX_HOLD_FRAMES(MAX_HOLD_FRAMES),
                .PANEL_LAYOUT(PANEL_LAYOUT)
            ) result_view (
                .pixel_clk(pixel_clk),
                .rst_n(pixel_rst_n),
                .in_de(video_de),
                .in_x(x),
                .in_y(y),
                .frame_start(start),
                .meta_valid(rv),
                .meta_payload(rd),
                .meta_take(rt),
                .out_cover(covered),
                .out_rgb(rgb),
                .result_age(),
                .result_fresh(),
                .out_text(result_text)
            );

            assign hdmi_rgb=(PANEL_LAYOUT!=0 && result_text)?rgb:
                  (PANEL_LAYOUT!=0 && live_cover)?live_rgb:covered?rgb:live_rgb;
        end else begin : g_no_result
            assign result_ready = 1'b1;
            assign hdmi_rgb = live_rgb;
        end
    endgenerate
endmodule
