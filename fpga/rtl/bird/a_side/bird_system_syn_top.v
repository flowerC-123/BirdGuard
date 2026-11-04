module bird_system_syn_top (
    input wire clk,
    input wire rst_n,

    input wire [23:0] cam_pixel,
    input wire        cam_valid,
    input wire        cam_frame_start,
    input wire        cam_frame_end,

    input  wire        pixel_clk,
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
    output wire led_flash
);

    bird_system_top u_sys (
        .clk            (clk),
        .rst_n          (rst_n),
        .cam_pixel      (cam_pixel),
        .cam_valid      (cam_valid),
        .cam_frame_start(cam_frame_start),
        .cam_frame_end  (cam_frame_end),
        .pixel_clk      (pixel_clk),
        .video_rgb      (video_rgb),
        .video_de       (video_de),
        .video_hs       (video_hs),
        .video_vs       (video_vs),
        .hdmi_rgb       (hdmi_rgb),
        .hdmi_de        (hdmi_de),
        .hdmi_hs        (hdmi_hs),
        .hdmi_vs        (hdmi_vs),
        .uart_rx        (uart_rx),
        .uart_tx        (uart_tx),
        .i2c_sda        (i2c_sda),
        .i2c_scl        (i2c_scl),
        .current_hour   (current_hour),
        .stats_txd      (stats_txd),
        .stats_de_n     (stats_de_n),
        .stats_re_n     (stats_re_n),
        .stats_dir      (stats_dir),
        .DIG            (DIG),
        .SEL            (SEL),
        .buzzer         (buzzer),
        .audio_pwm      (audio_pwm),
        .led_flash      (led_flash),

        .deterrent_active(),
        .unconfirmed     (),
        .battery_mv      (),
        .total_triggers  (),
        .hour_triggers   (),
        .mapping_rejected()
    );

endmodule
