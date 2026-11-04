module member_c_uart_link #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD_RATE = 9600,
    parameter REPORT_SECONDS = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] voltage_mv,
    input  wire [15:0] max_voltage_mv,
    input  wire [15:0] min_voltage_mv,
    input  wire [15:0] total_triggers,
    input  wire [ 4:0] current_hour,
    input  wire [15:0] current_hour_count,
    input  wire        uart_rxd,
    output wire        uart_txd,
    output wire        rs485_de_n,
    output wire        rs485_re_n,
    output wire        rs485_dir_ctrl,
    output wire        report_busy
);
    localparam REPORT_CYCLES = CLK_FREQ * REPORT_SECONDS;
    reg [31:0] report_counter;
    reg report_tick;
    wire [7:0] tx_data;
    wire tx_valid;
    wire tx_ready;
    wire [7:0] rx_data_unused;
    wire rx_valid_unused, rx_error_unused;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            report_counter <= 32'd0;
            report_tick <= 1'b0;
        end else begin
            report_tick <= 1'b0;
            if (report_counter >= REPORT_CYCLES - 1) begin
                report_counter <= 32'd0;
                if (!report_busy) report_tick <= 1'b1;
            end else begin
                report_counter <= report_counter + 1'b1;
            end
        end
    end

    uart_stats_reporter u_reporter (
        .clk(clk),
        .rst_n(rst_n),
        .report_tick(report_tick),
        .voltage_mv(voltage_mv),
        .max_voltage_mv(max_voltage_mv),
        .min_voltage_mv(min_voltage_mv),
        .total_triggers(total_triggers),
        .current_hour(current_hour),
        .current_hour_count(current_hour_count),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .busy(report_busy)
    );

    rs485_controller #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DELAY_US (100)
    ) u_rs485 (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .uart_txd(uart_txd),
        .uart_rxd(uart_rxd),
        .rx_data(rx_data_unused),
        .rx_valid(rx_valid_unused),
        .rx_error(rx_error_unused),
        .de_n(rs485_de_n),
        .re_n(rs485_re_n),
        .dir_ctrl(rs485_dir_ctrl)
    );
endmodule
