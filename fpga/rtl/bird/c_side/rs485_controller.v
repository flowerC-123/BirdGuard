module rs485_controller #(
    parameter CLK_FREQ  = 50000000,
    parameter BAUD_RATE = 9600,
    parameter DELAY_US  = 20000
) (
    input wire clk,
    input wire rst_n,

    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready,
    output wire uart_txd,

    input wire uart_rxd,
    output reg [7:0] rx_data,
    output reg rx_valid,
    output wire rx_error,

    output reg  de_n,
    output reg  re_n,
    output wire dir_ctrl
);

    localparam DELAY_CYCLES = CLK_FREQ / 1000000 * DELAY_US;
    localparam BIT_CYCLES = CLK_FREQ / BAUD_RATE;

    localparam MAX_DELAY = (DELAY_CYCLES > BIT_CYCLES) ? DELAY_CYCLES : BIT_CYCLES;
    localparam DELAY_WIDTH = (MAX_DELAY < 2) ? 1 : $clog2(MAX_DELAY + 1);

    wire [7:0] uart_rx_data;
    wire uart_rx_valid;
    wire uart_tx_ready;
    reg [7:0] uart_tx_data;
    reg uart_tx_valid;

    reg [2:0] state;
    reg [DELAY_WIDTH-1:0] delay_cnt;
    reg [7:0] tx_data_buf;

    localparam IDLE       = 3'd0;
    localparam PRE_DELAY  = 3'd1;
    localparam TX_START   = 3'd2;
    localparam TX_ACTIVE  = 3'd3;
    localparam STOP_WAIT  = 3'd4;
    localparam POST_DELAY = 3'd5;

    uart_tx_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(8),
        .STOP_BITS(1),
        .PARITY("NONE")
    ) u_uart (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(uart_tx_data),
        .tx_valid(uart_tx_valid),
        .tx_ready(uart_tx_ready),
        .txd(uart_txd),
        .rxd(uart_rxd),
        .rx_data(uart_rx_data),
        .rx_valid(uart_rx_valid),
        .rx_error(rx_error)
    );

    assign dir_ctrl = ~de_n;
    assign tx_ready = (state == IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            de_n <= 1'b1;
            re_n <= 1'b0;
            delay_cnt <= 0;
            uart_tx_data <= 0;
            uart_tx_valid <= 1'b0;
            tx_data_buf <= 0;
            rx_data <= 0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                IDLE: begin
                    de_n <= 1'b1;
                    re_n <= 1'b0;
                    uart_tx_valid <= 1'b0;
                    if (tx_valid) begin
                        tx_data_buf <= tx_data;
                        state <= PRE_DELAY;
                        delay_cnt <= DELAY_CYCLES;
                    end
                    if (uart_rx_valid) begin
                        rx_data  <= uart_rx_data;
                        rx_valid <= 1'b1;
                    end
                end

                PRE_DELAY: begin
                    de_n <= 1'b0;
                    re_n <= 1'b1;
                    if (delay_cnt == 0) begin
                        state <= TX_START;
                        uart_tx_data <= tx_data_buf;
                        uart_tx_valid <= 1'b1;
                    end else begin
                        delay_cnt <= delay_cnt - 1'b1;
                    end
                end

                TX_START: begin
                    de_n <= 1'b0;
                    re_n <= 1'b1;

                    if (uart_tx_valid && uart_tx_ready) begin
                        uart_tx_valid <= 1'b0;
                        state <= TX_ACTIVE;
                    end
                end

                TX_ACTIVE: begin
                    de_n <= 1'b0;
                    re_n <= 1'b1;
                    if (uart_tx_ready) begin
                        state <= STOP_WAIT;
                        delay_cnt <= BIT_CYCLES - 1;
                    end
                end

                STOP_WAIT: begin
                    de_n <= 1'b0;
                    re_n <= 1'b1;
                    if (delay_cnt == 0) begin
                        state <= POST_DELAY;
                        delay_cnt <= DELAY_CYCLES;
                    end else begin
                        delay_cnt <= delay_cnt - 1'b1;
                    end
                end

                POST_DELAY: begin
                    de_n <= 1'b0;
                    re_n <= 1'b1;
                    if (delay_cnt == 0) begin
                        state <= IDLE;
                        de_n  <= 1'b1;
                        re_n  <= 1'b0;
                    end else begin
                        delay_cnt <= delay_cnt - 1'b1;
                    end
                end

                default: begin
                    state <= IDLE;
                    uart_tx_valid <= 1'b0;
                    de_n <= 1'b1;
                    re_n <= 1'b0;
                end
            endcase
        end
    end

endmodule
