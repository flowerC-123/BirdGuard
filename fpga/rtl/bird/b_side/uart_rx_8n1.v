module uart_rx_8n1 #(
    parameter CLOCK_HZ = 75000000,
    BAUD = 115200
) (
    input wire clk,
    rst_n,
    rx,
    output reg [7:0] data,
    output reg valid,
    framing_error
);
    localparam TICKS = (CLOCK_HZ + BAUD / 2) / BAUD;
    localparam HALF = TICKS / 2;
    localparam CW = $clog2(TICKS + 1);
    localparam RECOVER = 0, IDLE = 1, START = 2, DATA = 3, STOP = 4;
    (* async_reg="true" *) reg sync1, sync2;
    reg [2:0] state, bit_no;
    reg [CW-1:0] count;
    reg [7:0] shift;
    always @(posedge clk) begin
        if (!rst_n) begin
            sync1 <= 1;
            sync2 <= 1;
            state <= RECOVER;
            count <= TICKS - 1;
            bit_no <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
            framing_error <= 0;
        end else begin
            sync1 <= rx;
            sync2 <= sync1;
            valid <= 0;
            framing_error <= 0;
            case (state)
                RECOVER:
                if (!sync2) count <= TICKS - 1;
                else if (count != 0) count <= count - 1'b1;
                else state <= IDLE;
                IDLE:
                if (!sync2) begin
                    count <= HALF - 1;
                    state <= START;
                end
                START:
                if (count != 0) count <= count - 1'b1;
                else if (sync2) state <= IDLE;
                else begin
                    count  <= TICKS - 1;
                    bit_no <= 0;
                    state  <= DATA;
                end
                DATA:
                if (count != 0) count <= count - 1'b1;
                else begin
                    shift[bit_no] <= sync2;
                    count <= TICKS - 1;
                    if (bit_no == 7) state <= STOP;
                    else bit_no <= bit_no + 1'b1;
                end
                STOP:
                if (count != 0) count <= count - 1'b1;
                else if (sync2) begin
                    data  <= shift;
                    valid <= 1;
                    state <= IDLE;
                end else begin
                    framing_error <= 1;
                    state <= RECOVER;
                    count <= TICKS - 1;
                end
                default: begin
                    state <= RECOVER;
                    count <= TICKS - 1;
                end
            endcase
        end
    end
endmodule
