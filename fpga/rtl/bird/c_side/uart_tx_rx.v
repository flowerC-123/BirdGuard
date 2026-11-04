module uart_tx_rx #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD_RATE = 9600,
    parameter DATA_BITS = 8,
    parameter STOP_BITS = 1,
    parameter PARITY = "NONE"
) (
    input wire clk,
    input wire rst_n,

    input wire [7:0] tx_data,
    input wire tx_valid,
    output reg tx_ready,
    output reg txd,

    input wire rxd,
    output reg [7:0] rx_data,
    output reg rx_valid,
    output reg rx_error
);

    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam BAUD_DIV_WIDTH = $clog2(BAUD_DIV + 1);

    reg [BAUD_DIV_WIDTH-1:0] tx_baud_cnt;
    reg [3:0] tx_bit_cnt;
    reg [9:0] tx_shift_reg;
    reg tx_busy;

    reg [BAUD_DIV_WIDTH-1:0] rx_baud_cnt;
    reg [3:0] rx_bit_cnt;
    reg [9:0] rx_shift_reg;
    reg rxd_sync1, rxd_sync2;
    reg rx_busy;
    reg rx_start_det;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_sync1 <= 1'b1;
            rxd_sync2 <= 1'b1;
        end else begin
            rxd_sync1 <= rxd;
            rxd_sync2 <= rxd_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_ready <= 1'b1;
            tx_busy <= 1'b0;
            txd <= 1'b1;
            tx_baud_cnt <= 0;
            tx_bit_cnt <= 0;
            tx_shift_reg <= 0;
        end else begin
            if (!tx_busy) begin
                if (tx_valid && tx_ready) begin
                    tx_busy <= 1'b1;
                    tx_ready <= 1'b0;
                    tx_shift_reg <= {1'b1, tx_data, 1'b0};
                    tx_bit_cnt <= DATA_BITS + STOP_BITS + 1;
                    tx_baud_cnt <= 0;
                end
            end else begin
                if (tx_baud_cnt == BAUD_DIV - 1) begin
                    tx_baud_cnt <= 0;
                    txd <= tx_shift_reg[0];
                    tx_shift_reg <= {1'b1, tx_shift_reg[9:1]};
                    tx_bit_cnt <= tx_bit_cnt - 1'b1;
                    if (tx_bit_cnt == 1) begin
                        tx_busy  <= 1'b0;
                        tx_ready <= 1'b1;
                    end
                end else begin
                    tx_baud_cnt <= tx_baud_cnt + 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_busy <= 1'b0;
            rx_valid <= 1'b0;
            rx_error <= 1'b0;
            rx_data <= 0;
            rx_baud_cnt <= 0;
            rx_bit_cnt <= 0;
            rx_shift_reg <= 0;
            rx_start_det <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            rx_error <= 1'b0;

            if (!rx_busy) begin
                if (!rxd_sync2 && !rx_start_det) begin
                    rx_start_det <= 1'b1;
                    rx_baud_cnt  <= 0;
                end else if (rx_start_det) begin
                    if (rx_baud_cnt == BAUD_DIV / 2 - 1) begin
                        rx_busy <= 1'b1;
                        rx_start_det <= 1'b0;
                        rx_bit_cnt <= DATA_BITS + STOP_BITS;
                        rx_baud_cnt <= 0;
                        rx_shift_reg <= 0;
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
            end else begin
                if (rx_baud_cnt == BAUD_DIV - 1) begin
                    rx_baud_cnt  <= 0;
                    rx_shift_reg <= {rxd_sync2, rx_shift_reg[9:1]};
                    rx_bit_cnt   <= rx_bit_cnt - 1'b1;
                    if (rx_bit_cnt == 1) begin
                        rx_busy <= 1'b0;

                        rx_data <= rx_shift_reg[9:2];
                        if (rxd_sync2 == 1'b1) rx_valid <= 1'b1;
                        else rx_error <= 1'b1;
                    end
                end else begin
                    rx_baud_cnt <= rx_baud_cnt + 1'b1;
                end
            end
        end
    end

endmodule
