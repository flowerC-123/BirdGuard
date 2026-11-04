module member_c_subsystem #(
    parameter CLK_FREQ  = 50000000,
    parameter BAUD_RATE = 9600,

    parameter MEASUREMENT_VALID = 1,
    parameter DISPLAY_ENABLE = MEASUREMENT_VALID,
    parameter DISPLAY_REFERENCE = 0,
    parameter [15:0] DISPLAY_SCALE_NUM = 16'd1,
    parameter [15:0] DISPLAY_SCALE_DEN = 16'd1
) (
    input  wire        clk,
    input  wire        rst_n,
    inout  wire        i2c_sda,
    inout  wire        i2c_scl,
    input  wire        voltage_valid,
    input  wire        trigger_event,
    input  wire [ 4:0] current_hour,
    input  wire        uart_rxd,
    output wire        uart_txd,
    output wire        rs485_de_n,
    output wire        rs485_re_n,
    output wire        rs485_dir_ctrl,
    output wire [ 7:0] DIG,
    output wire [ 7:0] SEL,
    output wire [15:0] voltage_mv,
    output wire [15:0] max_voltage_mv,
    output wire [15:0] min_voltage_mv,
    output wire [15:0] total_triggers,
    output wire [15:0] current_hour_count
);
    wire [11:0] adc_code;
    wire [15:0] adc_voltage_mv, stats_max_mv, stats_min_mv;
    wire report_busy_unused;

    wire [11:0] ain0 = 12'd2048;
    wire [11:0] ain1 = 12'd0;
    wire [11:0] ain2 = 12'd0;
    wire [11:0] ain3 = 12'd0;

    ads1015_ip u_ads1015 (
        .clk(clk),
        .rst_n(rst_n),
        .sda(i2c_sda),
        .scl(i2c_scl),
        .ain0(ain0),
        .ain1(ain1),
        .ain2(ain2),
        .ain3(ain3),
        .alert(),
        .dac_out(),
        .comp_out(),
        .sample_hold(),
        .adc_code(adc_code)
    );

    adc_to_voltage_mv u_scale (
        .adc_code  (adc_code),
        .voltage_mv(adc_voltage_mv)
    );

    wire [15:0] measured_voltage_mv = MEASUREMENT_VALID ? adc_voltage_mv : 16'd0;
    wire [31:0] display_scaled_mv = (adc_voltage_mv * DISPLAY_SCALE_NUM) /
                                    (DISPLAY_SCALE_DEN == 0 ? 16'd1 : DISPLAY_SCALE_DEN);
    wire [15:0] display_voltage_mv = DISPLAY_ENABLE ? display_scaled_mv[15:0] : 16'd0;
    assign voltage_mv = (MEASUREMENT_VALID || DISPLAY_ENABLE) ? adc_voltage_mv : 16'd0;
    assign max_voltage_mv = MEASUREMENT_VALID ? stats_max_mv : 16'd0;
    assign min_voltage_mv = MEASUREMENT_VALID ? stats_min_mv : 16'd0;

    seg_display_8digit #(
        .CLK_FREQ_HZ(CLK_FREQ),
        .MEASUREMENT_VALID(DISPLAY_ENABLE),
        .REFERENCE_VALUE(DISPLAY_REFERENCE),
        .SHOW_DECIMAL_POINT(DISPLAY_REFERENCE)
    ) u_display (
        .clk(clk),
        .rst_n(rst_n),
        .voltage_mv(display_voltage_mv),
        .DIG(DIG),
        .SEL(SEL)
    );

    stats_module u_stats (
        .clk(clk),
        .rst_n(rst_n),
        .voltage_mv(measured_voltage_mv),
        .voltage_valid(voltage_valid && MEASUREMENT_VALID),
        .trigger_event(trigger_event),
        .current_hour(current_hour),
        .max_voltage_mv(stats_max_mv),
        .min_voltage_mv(stats_min_mv),
        .total_triggers(total_triggers),
        .current_hour_count(current_hour_count)
    );

    member_c_uart_link #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .REPORT_SECONDS(1)
    ) u_uart_link (
        .clk(clk),
        .rst_n(rst_n),
        .voltage_mv(measured_voltage_mv),
        .max_voltage_mv(max_voltage_mv),
        .min_voltage_mv(min_voltage_mv),
        .total_triggers(total_triggers),
        .current_hour(current_hour),
        .current_hour_count(current_hour_count),
        .uart_rxd(uart_rxd),
        .uart_txd(uart_txd),
        .rs485_de_n(rs485_de_n),
        .rs485_re_n(rs485_re_n),
        .rs485_dir_ctrl(rs485_dir_ctrl),
        .report_busy(report_busy_unused)
    );
endmodule
