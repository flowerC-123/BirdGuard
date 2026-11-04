module uart_tx_8n1 #(
    parameter integer CLOCK_HZ = 75000000,
    parameter integer BAUD = 115200
) (
    input wire clk,
    rst_n,
    input wire [7:0] data,
    input wire valid,
    output wire ready,
    output reg tx,
    output reg done
);
    localparam integer TICKS = (CLOCK_HZ + BAUD / 2) / BAUD;
    localparam integer CW = (TICKS < 2) ? 1 : $clog2(TICKS);
    reg [CW-1:0] count;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg active;
    assign ready = !active;
    always @(posedge clk) begin
        if (!rst_n) begin
            tx <= 1;
            done <= 0;
            active <= 0;
            count <= 0;
            bit_index <= 0;
            shift <= 10'h3ff;
        end else begin
            done <= 0;
            if (!active) begin
                tx <= 1;
                if (valid) begin
                    shift <= {1'b1, data, 1'b0};
                    tx <= 0;
                    active <= 1;
                    count <= TICKS - 1;
                    bit_index <= 0;
                end
            end else if (count != 0) count <= count - 1'b1;
            else if (bit_index == 9) begin
                active <= 0;
                tx <= 1;
                done <= 1;
            end else begin
                tx <= shift[1];
                shift <= {1'b1, shift[9:1]};
                bit_index <= bit_index + 1'b1;
                count <= TICKS - 1;
            end
        end
    end
endmodule
