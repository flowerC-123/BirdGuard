`timescale 1ns / 1ps

module tb_reference_display #(
    parameter integer PROFILE   = 0,
    parameter integer LOW_PROBE = 1,
    parameter integer FLIGHTS   = 4
);
    localparam integer MEASURE = (PROFILE == 2);
    localparam integer COMPAT = (PROFILE == 0);
    localparam integer HAS_DISPLAY = MEASURE || COMPAT;
    localparam integer EXPECT_POWER = MEASURE && LOW_PROBE;
    localparam integer EXPECT_CANCEL = (FLIGHTS > 1) && EXPECT_POWER;
    reg clk = 0, pixel_clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    always #6.666667 pixel_clk = ~pixel_clk;
    tri1 sda, scl;
    wire [23:0] rgb;
    wire hdmi_de, hdmi_hs, hdmi_vs, uart_tx;
    wire stats_txd, stats_de_n, stats_re_n, stats_dir;
    wire [7:0] dig, sel;
    wire buzzer, audio_pwm, led_flash, deterrent_active, unconfirmed;
    wire [15:0] battery, total, hour, tr_ms, rp_ms, to_ms, pr_ms, samples, timeouts, forced;
    wire mapping_rejected, latency_valid, mon_tx;
    integer checks = 0, k, valid_pulses = 0, heartbeats = 0;
    bird_system_top #(
        .B_CLOCK_HZ(50000000),
        .B_BAUD(1500000),
        .B_REQUEST_GAP_MS(0),
        .B_MAX_INFLIGHT(FLIGHTS),
        .ROI_GAMMA_EN(1),
        .ROI_DETAIL(1),
        .ROI_HIRES(1),
        .MULTI_ALGO(1),
        .USE_BACKGROUND(1),
        .DIFF_THRESHOLD(8'd12),
        .MIN_AREA(17'd64),
        .CCL_SELFVIEW(0),
        .FORCE_INSPECT_EN(0),
        .C_CLK_HZ(50000000),
        .C_BAUD(9600),
        .ALLOW_TIMEOUT_DEGRADE(0),
        .ADC_MEASUREMENT_VALID(MEASURE),
        .ADC_DISPLAY_COMPAT(COMPAT),
        .VOLT_SCALE_NUM(16'd8),
        .VOLT_SCALE_DEN(16'd1),
        .VVALID_CYCLES(17),
        .INFO_CYCLES(13),
        .VOLT_LOW_MV(LOW_PROBE ? 16'd20000 : 16'd10500),
        .VOLT_OK_MV(LOW_PROBE ? 16'd21000 : 16'd11000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .det_cfg(7'd0),
        .cam_pixel(24'd0),
        .cam_valid(1'b0),
        .cam_frame_start(1'b0),
        .cam_frame_end(1'b0),
        .pixel_clk(pixel_clk),
        .roi_vin_rst_n(rst_n),
        .roi_vin_rgb(24'd0),
        .roi_vin_de(1'b0),
        .video_rgb(24'h112233),
        .video_de(1'b0),
        .video_hs(1'b0),
        .video_vs(1'b0),
        .hdmi_rgb(rgb),
        .hdmi_de(hdmi_de),
        .hdmi_hs(hdmi_hs),
        .hdmi_vs(hdmi_vs),
        .uart_rx(1'b1),
        .uart_tx(uart_tx),
        .i2c_sda(sda),
        .i2c_scl(scl),
        .current_hour(5'd3),
        .stats_txd(stats_txd),
        .stats_de_n(stats_de_n),
        .stats_re_n(stats_re_n),
        .stats_dir(stats_dir),
        .DIG(dig),
        .SEL(sel),
        .buzzer(buzzer),
        .audio_pwm(audio_pwm),
        .led_flash(led_flash),
        .deterrent_active(deterrent_active),
        .unconfirmed(unconfirmed),
        .battery_mv(battery),
        .total_triggers(total),
        .hour_triggers(hour),
        .mapping_rejected(mapping_rejected),
        .last_total_ms(to_ms),
        .last_transmit_ms(tr_ms),
        .last_reply_ms(rp_ms),
        .last_processing_ms(pr_ms),
        .latency_valid(latency_valid),
        .latency_samples(samples),
        .latency_timeouts(timeouts),
        .forced_count(forced),
        .mon_tx(mon_tx)
    );
    task cycle(input integer n);
        begin
            repeat (n) @(negedge clk);
        end
    endtask
    task check(input condition, input [511:0] why);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "VOLTAGE_SYSTEM profile=%0d low=%0d %0s", PROFILE, LOW_PROBE, why);
        end
    endtask
    task steady_checks;
        begin
            check(battery == (HAS_DISPLAY ? 16'd16384 : 16'd0),
                  "system output uses inherited 8x scaling only when display/data enabled");
            check(dut.adc_raw_mv == (HAS_DISPLAY ? 16'd2048 : 16'd0),
                  "raw interface retains ADC mV");
            check(dut.volt_valid_gated == (MEASURE && dut.volt_valid_pulse),
                  "reference display cannot make a sample valid");
            check(dut.u_a_system.u_fsm.voltage_valid == dut.volt_valid_gated,
                  "FSM receives measured validity only");
            check(dut.u_a_system.u_fsm.voltage_mv == battery, "FSM voltage scale wiring preserved");
            check(dut.volt_known_lvl == MEASURE,
                  "measured known history does not consume reference");
            check(dut.voltage_known_for_osd == HAS_DISPLAY,
                  "display validity is separate from measurement history");
            check(
                dut.u_member_b.voltage_known == HAS_DISPLAY && dut.u_member_b.voltage_mv == battery,
                "B header inputs use display policy");
            check(
                dut.u_member_b.mp[596]==HAS_DISPLAY&&dut.u_member_b.mp[595:580]==(HAS_DISPLAY?16'd1638:16'd0),
                "actual metadata producer packs known and 10mV display units");
            check(
                dut.max_mv==(MEASURE?16'd2048:16'd0)&&dut.min_mv==(MEASURE?16'd2048:16'd0),
                "reference not exported as measured extrema");
            check(dut.u_member_c.u_stats.min_voltage_mv == (MEASURE ? 16'd2048 : 16'hffff),
                  "unknown/reference never sampled into stats");
            check(dut.u_member_c.u_uart_link.voltage_mv == (MEASURE ? 16'd2048 : 16'd0),
                  "reference numeric data stays out of voltage telemetry");
            check(dut.cancel_inflight == EXPECT_CANCEL && dut.u_member_b.cancel == EXPECT_CANCEL,
                  "only real valid undervoltage cancels all parallel B contexts");
            check(dut.state_code == (EXPECT_POWER ? 4'd4 : 4'd0),
                  "reference and unknown remain standby even below test voltage threshold");
            check(dut.u_a_system.u_fsm.current_state == (EXPECT_POWER ? 4'd7 : 4'd0),
                  "power state and state code agree");
            check(!deterrent_active && !unconfirmed && !buzzer && !audio_pwm && !led_flash,
                  "voltage display cannot generate deterrent action");
            check(
                total==0&&hour==0&&samples==0&&timeouts==0&&forced==0&&!latency_valid,
                "no fake triggers requests or latency evidence");
            check(dut.S_b_outstanding == 0 && !dut.desc_valid && uart_tx == 1,
                  "no spurious recognition request without scene or patrol");
            check(sda && scl, "ADC stub keeps physical bus released");
        end
    endtask
    initial begin
        check(PROFILE >= 0 && PROFILE <= 2, "valid test profile");
        cycle(4);
        rst_n = 1;
        cycle(4);
        check(dut.u_member_c.DISPLAY_ENABLE == HAS_DISPLAY, "C display parameter propagation");
        check(dut.u_member_c.DISPLAY_REFERENCE == COMPAT,
              "C reference prefix parameter propagation");
        check(dut.u_member_c.DISPLAY_SCALE_NUM == (COMPAT ? 8 : 1),
              "reference scaled and legacy numeric path unchanged");
        check(
            dut.u_member_c.u_display.REFERENCE_VALUE==COMPAT&&dut.u_member_c.u_display.SHOW_DECIMAL_POINT==COMPAT,
            "reference segment marker and decimal enabled together");
        check(
            dut.u_member_b.VOLTAGE_REFERENCE==COMPAT&&dut.u_member_b.display.VOLTAGE_REFERENCE==COMPAT&&
        dut.u_member_b.display.overlay.VOLTAGE_REFERENCE==COMPAT,
            "reference marker propagated through actual B/CDC/HDMI hierarchy");
        check(
            dut.u_member_c.display_voltage_mv==(COMPAT?16'd16384:(MEASURE?16'd2048:16'd0)),
            "actual C numeric display uses selected units");
        for (k = 0; k < 600; k = k + 1) begin
            cycle(1);
            if (dut.volt_valid_gated) valid_pulses = valid_pulses + 1;
            if (dut.info_valid) heartbeats = heartbeats + 1;
            if (k > 40) steady_checks();
        end
        check((MEASURE && valid_pulses >= 30) || (!MEASURE && valid_pulses == 0),
              "independent periodic sample policy exercised repeatedly");
        check(heartbeats >= 40, "display heartbeat continues while reference/unknown/undervoltage");

        rst_n = 0;
        cycle(4);
        check(dut.cancel_inflight == 0 && dut.volt_valid_gated == 0 && dut.volt_known_lvl == 0,
              "reset clears power cancellation and measured history");
        check(total == 0 && hour == 0, "reset keeps event stats clear");
        rst_n = 1;
        cycle(80);
        steady_checks();
        $display(
            "PASS VOLTAGE_SYSTEM profile=%0d low_probe=%0d flights=%0d checks=%0d samples=%0d heartbeats=%0d",
            PROFILE, LOW_PROBE, FLIGHTS, checks, valid_pulses, heartbeats);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "WATCHDOG");
    end
endmodule
